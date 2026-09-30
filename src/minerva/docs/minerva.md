# Minerva

Minerva is the IEEE 1722 packet processor. On receive it takes Ethernet frames
from the MAC, parses Ethernet, AVTP, NTSCF/TSCF, ACF and ABB/GBB, and hands the
payload and metadata of each ACF message to its consumer. Transmit mirrors it.
It follows zircon (`src/zircon`), cut down to this function, and is intended to
grow PTP and L2 switching routes.

## Scope

Minerva is pure packet parsing: it applies IEEE 802.3 and IEEE 1722 and nothing
above them.

| Minerva | Consumer |
| :--- | :--- |
| Strip the L2 header, one VLAN tag | Which `stream_id`s are accepted |
| Dispatch on ethertype, `subtype`, `acf_msg_type` | |
| Walk concatenated ACF messages | Responses |
| Check lengths, delimit each payload | |
| Report header fields as metadata | Anything that needs configuration |
| Build frames on transmit | |

## Interfaces

| Port | Format |
| :--- | :--- |
| From the MAC | 32-bit `taxi_axis_if`. The MAC RX FIFO must drop bad frames (`DROP_BAD_FRAME`); minerva does not examine `tuser`. |
| To the consumer | Payload and metadata per ACF message. Record format open. |
| From the consumer | Open. |
| To the MAC | 32-bit `taxi_axis_if`; the MAC pads short frames. |

## Datapath conventions

- 32 bits wide. At 125 MHz that is 4x the 1 Gb/s line rate, so the header is
  parsed well within the shortest frame time.
- One state per 32-bit word, as in `zircon_ip_rx_parse`, which covers Ethernet
  to UDP in one FSM with `DATA_W` fixed at 32 and emits a metadata stream.
- Lane 0 is first on the wire. A spec quadlet, whose bit offset 0 is the MSB,
  is `q = {tdata[7:0], tdata[15:8], tdata[23:16], tdata[31:24]}`; a field at
  offset `o` of width `w` is `q[31-o -: w]`.
- The L2 header is 14 or 18 bytes, two past a word boundary. Minerva realigns
  once, so AVTP starts at lane 0. Every 1722 header and ACF message is a whole
  number of quadlets, so everything below stays aligned: each header starts at
  lane 0 of some word.

## Receive layers

| Layer | Header | Selected by | Next |
| :--- | :--- | :--- | :--- |
| Ethernet | 14 bytes, 18 with one 802.1Q/802.1ad tag | | ethertype `0x22F0` AVTP; `0x88F7` PTP later |
| AVTP common header | first quadlet of the PDU | `subtype` | `0x82` NTSCF, `0x05` TSCF |
| NTSCF | 3 quadlets | | ACF messages, `ntscf_data_length` bytes |
| TSCF | 6 quadlets | | ACF messages, `stream_data_length` bytes |
| ACF message | `acf_msg_length` quadlets, header included | `acf_msg_type` | `0x0E` ABB, `0x0D` GBB |
| ABB | 2 quadlets | | `byte_msg_payload` |
| GBB | 4 quadlets | | `byte_msg_payload` |

An NTSCF or TSCF payload carries one or more ACF messages back to back. Each
starts where the previous one ended (`acf_msg_length` x 4 bytes on), and the
walk ends when the data length is used up.

### Word map, NTSCF with ABB

Words after the L2 header, fields MSB first:

| Word | Fields (bits) |
| :---: | :--- |
| 0 | `subtype` 8, `sv` 1, `version` 3, `r` 1, `ntscf_data_length` 11, `sequence_num` 8 |
| 1 | `stream_id[63:32]` |
| 2 | `stream_id[31:0]` |
| 3 | `acf_msg_type` 7, `acf_msg_length` 9, `pad` 2, `mtv` 1, `rsv` 2, `byte_bus_id` 11 |
| 4 | `evt` 4, `rsv` 2, `hs` 1, `cs` 1, `transaction_num` 8, `op` 1, `rsp` 1, `err` 1, `ms` 1, `read_size/segment_num` 12 |
| 5... | `byte_msg_payload`, then `pad` zero bytes; the next message starts at word 3 + `acf_msg_length` |

TSCF replaces words 0-2 with six words: `subtype` 8, `sv` 1, `version` 3,
`mr` 1, `rsv` 2, `tv` 1, `sequence_num` 8, `reserved` 7, `tu` 1; `stream_id`
over two words; `avtp_timestamp` 32; `reserved` 32; `stream_data_length` 16,
`reserved` 16.

GBB has the same fields as ABB, with `message_timestamp` (64 bits) inserted as
two words between ABB's words 3 and 4.

ABB payload bytes = `acf_msg_length` x 4 - 8 - `pad`; for GBB, 16 instead of 8.
The 1500-byte Ethernet payload bounds all of it: an ABB payload is at most
1500 - 12 - 8 = 1480 bytes.

Layouts: `refs/Open1722/include/avtp`.

## Validation

| Check | Source |
| :--- | :--- |
| `subtype` is NTSCF or TSCF | Open1722 `Ntscf_IsValid`, `Tscf_IsValid` |
| Data length fits in the bytes received after the header | Open1722 checks against the whole buffer, loose by the header (12 or 24 bytes); minerva counts from the end of the header |
| `acf_msg_type` is ABB or GBB | Open1722 `Abb_IsValid`, `Gbb_IsValid` |
| `acf_msg_length` x 4 >= header + `pad` | same |
| The message ends within the data length | the walk in `acf-can-common.c` |
| A frame that ends before its lengths say is truncated | streaming: known only at `tlast` |

Bytes after the data length are Ethernet padding and are ignored. A minimum
frame carries a 46-byte payload, so a 20-byte PDU with one empty ABB message
(NTSCF 12 + ABB 8) is followed by 26 bytes of padding. The frame's end (`tlast`) only
confirms that the frame was long enough.

A message's validity is known only at its last word, after its payload has
passed. The consumer therefore holds the payload until the metadata says the
message is good.

## Transmit

`minerva_tx_deparse` builds the L2 header: each input packet starts with an
8-byte prefix, destination address then ethertype, and `LOCAL_MAC` is inserted
as the source. The AVTP, NTSCF/TSCF and ACF headers are still to be designed.

## Modules

| Module | Function | Status |
| :--- | :--- | :--- |
| `minerva_rx_parse` | Strips L2 with one VLAN tag, routes AVTP on `tdest` | validated on hardware |
| `minerva_tx_deparse` | Builds the L2 header | validated on hardware |

## Verification cases

- Untagged, one tag, two tags (dropped)
- NTSCF, TSCF, unknown `subtype`
- One ACF message, several concatenated, ABB and GBB mixed, unknown `acf_msg_type`
- Payload lengths 0 to 3 (every `pad`), and the 1480-byte maximum
- Minimum frame with Ethernet padding after the data length
- Frame truncated inside a header, and inside a payload
- `ntscf_data_length` beyond the frame, `acf_msg_length` below the header, a
  message overrunning the data length
- Back-to-back frames, and backpressure from the consumer

## Open decisions

1. The metadata record: fields, widths, how many words it takes, and that it is
   issued once the message has been checked.
2. One receive FSM across all layers (zircon) or one module per layer.
3. On an unknown `subtype` or `acf_msg_type`: drop the frame, or skip the
   message by its `acf_msg_length`.
4. Whether `sv`, `version` and reserved bits are checked.
5. Sequence numbers: minerva reports `sequence_num`; tracking misses per
   stream (`ntscf_sn_miss`) keeps state per `stream_id`, in minerva or in the
   consumer.
6. The transmit input from the consumer.
7. PTP and L2 switching routes, later.

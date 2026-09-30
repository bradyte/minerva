# Minerva

Minerva is the IEEE 1722 packet processor. On receive it takes Ethernet frames
from the MAC, parses Ethernet, AVTP, NTSCF/TSCF, ACF and ABB/GBB, and hands
each ACF message to its consumer as a record followed by the payload. Transmit
mirrors it. It follows zircon (`src/zircon`), cut down to this function, and is
intended to grow PTP and L2 switching routes.

The first implementation covers NTSCF with ABB. TSCF, GBB and every other
format are deferred. Until added, an unknown `subtype` drops the frame and an
unknown `acf_msg_type` skips that message.

## Scope

Minerva is pure packet parsing: it applies IEEE 802.3 and IEEE 1722 and nothing
above them.

| Minerva | Consumer |
| :--- | :--- |
| Strip the L2 header, one VLAN tag | Receive memory: DMA sink, RAM, slot descriptors |
| Dispatch on ethertype, `subtype`, `acf_msg_type` | Which `stream_id`s are accepted |
| Walk concatenated ACF messages, skip unknown ones | Responses, addressed to the request's `stream_id` MacAddress |
| Check lengths, delimit each payload | Per-stream `sequence_num` tracking |
| Emit one record and payload per message | `sv` = 0, treated as best effort |
| Build frames on transmit | |

## Interfaces

| Port | Format |
| :--- | :--- |
| From the MAC | 32-bit `taxi_axis_if`. The MAC RX FIFO must drop bad frames (`DROP_BAD_FRAME`); minerva does not examine `tuser`. |
| To the consumer | 32-bit `taxi_axis_if`, one packet per ACF message; see Receive output. |
| From the consumer | Open. |
| To the MAC | 32-bit `taxi_axis_if`; the MAC pads short frames. |

## Receive output

One packet per ACF message: a 4-word record, then the payload.

| Signal | Meaning |
| :--- | :--- |
| `tdata` | record words 0-3, then the payload |
| `tid` | format code: 0 = NTSCF with ABB. Codes for deferred formats are assigned as they are added. |
| `tdest` | route: 0 = AVTP, to the consumer |
| `tuser` | at `tlast`: 1 = the frame ended before the message did |
| `tkeep` | all ones, except the last payload word |

A complete message is 16 + `payload_len` bytes. A message with no payload is the
record alone.

### Record

Record words hold values: bit 31 is the most significant bit of the word as
written in this table. The payload stays in wire order.

| Word | Bits | Field |
| :---: | :--- | :--- |
| 0 | 31:0 | `stream_id[63:32]` |
| 1 | 31:0 | `stream_id[31:0]` |
| 2 | 31:24 | `sequence_num` |
| | 23 | `mtv` |
| | 22:12 | `byte_bus_id` |
| | 11 | `sv` |
| | 10:0 | `payload_len`, octets: `acf_msg_length` x 4 - 8 - `pad`, at most 1480 |
| 3 | 31:28 | `evt` |
| | 27:26 | `rsv` |
| | 25 | `hs` |
| | 24 | `cs` |
| | 23:16 | `transaction_num` |
| | 15 | `op` |
| | 14 | `rsp` |
| | 13 | `err` |
| | 12 | `ms` |
| | 11:0 | `read_size/segment_num` |

Word 3 is ABB's second quadlet unchanged. For responses, the consumer splits
`stream_id` as MacAddress = `{word0, word1[31:16]}` and UniqueID =
`word1[15:0]`. Field meanings are in `avtp.md`.

Dropped from the headers: `subtype`, `version` and `r` (checked or ignored),
`ntscf_data_length` (used up by the walk), `acf_msg_type` (sent as `tid`),
`acf_msg_length` and `pad` (replaced by `payload_len`), and the reserved bits of
ABB's first quadlet.

### In the consumer's memory

The consumer writes each packet into RAM with `taxi_dma_client_axis_sink` and a
`taxi_dma_psdpram`, as `cndm_proto_rx` does:

1. The consumer posts a descriptor (`taxi_dma_desc_if`) for each free slot.
2. The sink writes the packet at the slot: record word `n` at slot + 4n,
   payload byte `k` at slot + 16 + k.
3. The sink returns a status: `len`, the descriptor's `tag`, and the packet's
   `tid`, `tdest` and `tuser`. A status with `tuser` = 1 re-posts the slot; any
   other is a message to process.

With no slot posted, the sink stops accepting, minerva stalls, and the MAC's RX
FIFO drops whole frames.

## Datapath conventions

- 32 bits wide. At 125 MHz that is 4x the 1 Gb/s line rate.
- One state per 32-bit word, as in `zircon_ip_rx_parse`, which covers Ethernet
  to UDP in one FSM with `DATA_W` fixed at 32. Formats are added as groups of
  states behind enable parameters, as zircon does with `IPV6_EN`.
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
| AVTP common header | first quadlet of the PDU | `subtype` | `0x82` NTSCF; `0x05` TSCF deferred |
| NTSCF | 3 quadlets | | ACF messages, `ntscf_data_length` bytes |
| TSCF *(deferred)* | 6 quadlets | | ACF messages, `stream_data_length` bytes |
| ACF message | `acf_msg_length` quadlets, header included | `acf_msg_type` | `0x0E` ABB; `0x0D` GBB deferred |
| ABB | 2 quadlets | | `byte_msg_payload` |
| GBB *(deferred)* | 4 quadlets | | `byte_msg_payload` |

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

TSCF *(deferred)* replaces words 0-2 with six words: `subtype` 8, `sv` 1,
`version` 3, `mr` 1, `rsv` 2, `tv` 1, `sequence_num` 8, `reserved` 7, `tu` 1;
`stream_id` over two words; `avtp_timestamp` 32; `reserved` 32;
`stream_data_length` 16, `reserved` 16.

GBB *(deferred)* has the same fields as ABB, with `message_timestamp` (64 bits)
inserted as two words between ABB's words 3 and 4.

The 1500-byte Ethernet payload bounds the ABB payload at 1500 - 12 - 8 = 1480
bytes. Field layouts and meanings: `avtp.md`, drawn from `refs/Open1722` and
`refs/libavtp`.

### Receive states

One FSM, extending the L2 states of `minerva_rx_parse`. Every state below the
ethertype sees one realigned word per input word.

| State | Word | Captures, checks | Next |
| :--- | :--- | :--- | :--- |
| `STATE_ETH` | L2 words 0-3 | ethertype at word 3 | AVTP: `STATE_AVTP`; VLAN: `STATE_VLAN`; other: `STATE_DROP` |
| `STATE_VLAN` | tag | inner ethertype; one tag only | as `STATE_ETH` |
| `STATE_AVTP` | AVTP 0 | `sv`, `sequence_num`; `data_rem` = `ntscf_data_length`; `subtype` is NTSCF, `version` is 0 | `STATE_NTSCF_1`, else `STATE_DROP` |
| `STATE_NTSCF_1` | AVTP 1 | `stream_id[63:32]` | `STATE_NTSCF_2` |
| `STATE_NTSCF_2` | AVTP 2 | `stream_id[31:0]` | `STATE_ACF`; `STATE_DROP` if `data_rem` is 0 |
| `STATE_ACF` | ACF 0 | `acf_msg_length` x 4 is at least 8 + `pad` and at most `data_rem`; `data_rem` -= `acf_msg_length` x 4; `msg_rem` = `acf_msg_length` - 1 | ABB: `STATE_ABB_1`; unknown type: `STATE_SKIP`; malformed: `STATE_DROP` |
| `STATE_ABB_1` | ABB 1 | word 3 of the record | `STATE_RECORD` |
| `STATE_RECORD` | input held | record words 0-3 out; `tlast` on word 3 if `payload_len` is 0 | `STATE_PAYLOAD`, or as after `STATE_PAYLOAD` |
| `STATE_PAYLOAD` | payload | one word out per word in; last word: `tkeep` from `pad`, `tlast`. Frame ends early: `tlast` with `tuser` = 1 | `STATE_ACF` if `data_rem` > 0, else `STATE_DROP` |
| `STATE_SKIP` | unknown message | `msg_rem` words, no output | `STATE_ACF` if `data_rem` > 0, else `STATE_DROP` |
| `STATE_DROP` | rest of frame | to `tlast`; also Ethernet padding | `STATE_ETH` |

A header state that sees `tlast` returns to `STATE_ETH` with nothing emitted.

- Every structural check resolves at `STATE_ACF`, before any output, so a
  malformed message never takes a slot. The only failure after output starts
  is truncation, and `tuser` marks it.
- No flush state: messages end on a quadlet boundary, so a valid message never
  ends part way through a realigned word; a frame that does is truncated.
- The record costs four held cycles. The worst case, back-to-back empty
  messages, takes 6 cycles per message against the 8 in which its 2 words
  arrive at line rate; the MAC's RX FIFO absorbs bursts.
- State: the captured fields for the record, `data_rem` (11 bits), `msg_rem`
  (9), `pad` (2), a record word pointer and the 16-bit realignment register.

## Validation

| Check | Source |
| :--- | :--- |
| `subtype` is NTSCF (TSCF deferred) | Open1722 `Ntscf_IsValid` |
| `version` is 0; version 1 is discarded | project: only version 0 is supported |
| Data length fits in the bytes received after the header | Open1722 checks against the whole buffer, loose by the header (12 or 24 bytes); minerva counts from the end of the header |
| `acf_msg_type` is ABB; others are skipped (GBB deferred) | Open1722 `Abb_IsValid`; project |
| `acf_msg_length` x 4 >= header + `pad` | Open1722 `Abb_IsValid` |
| The message ends within the data length | the walk in `acf-can-common.c` |
| A frame that ends before its lengths say is truncated | streaming: known only at `tlast` |

`sv` and the reserved bits are not checked: `sv` goes to the consumer in the
record, and a listener ignores reserved bits.

Bytes after the data length are Ethernet padding and are ignored. A minimum
frame carries a 46-byte payload, so a 20-byte PDU with one empty ABB message
(NTSCF 12 + ABB 8) is followed by 26 bytes of padding. The frame's end (`tlast`) only
confirms that the frame was long enough.

## Transmit

`minerva_tx_deparse` builds the L2 header: each input packet starts with an
8-byte prefix, destination address then ethertype, and `LOCAL_MAC` is inserted
as the source. The AVTP, NTSCF and ABB headers are still to be designed.

## Modules

| Module | Function | Status |
| :--- | :--- | :--- |
| `minerva_rx_parse` | Parses Ethernet to ABB; one record and payload per message | validated on hardware |
| `minerva_tx_deparse` | Builds the L2 header | validated on hardware |

## Versions

Each milestone is developed on its own branch, merged once it passes on
hardware, and tagged in git.

| Tag | Milestone |
| :--- | :--- |
| `minerva-0.1.0` | NTSCF with ABB received as record and payload, validated on the Zedboard with the record echo |

## Verification cases

- Untagged, one tag, two tags (dropped)
- NTSCF, unknown `subtype` (TSCF while deferred), `version` 1, `sv` 0 passed on
- One ABB message, several concatenated, an unknown `acf_msg_type` (GBB while
  deferred) skipped between ABB messages that are delivered
- Record fields and `payload_len` match the message; an empty payload gives a
  record-only packet
- Payload lengths 0 to 3 (every `pad`), and the 1480-byte maximum
- Minimum frame with Ethernet padding after the data length
- Frame truncated inside a header (nothing emitted) and inside a payload
  (`tuser` = 1)
- `ntscf_data_length` beyond the frame, `acf_msg_length` below the header, a
  message overrunning the data length
- Back-to-back frames, and backpressure from the consumer

## Open decisions

1. The transmit input from the consumer.
2. PTP and L2 switching routes, later.

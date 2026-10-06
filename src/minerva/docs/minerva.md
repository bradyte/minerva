# Minerva

Minerva is the IEEE 1722 packet processor. On receive it takes Ethernet frames
from the MAC, parses Ethernet, AVTP, NTSCF/TSCF, ACF and ABB/GBB, and hands
each ACF message to its consumer as a metadata block, with the payload on a
stream of its own. Transmit mirrors it. It follows zircon (`src/zircon`), cut down to this function, and is
intended to grow PTP and L2 switching routes.

The first implementation covers NTSCF with ABB. TSCF, GBB and every other
format are deferred. Until added, an unknown `subtype` takes the discard route
and an unknown `acf_msg_type` skips that message.

## Scope

Minerva is pure packet parsing: it applies IEEE 802.3 and IEEE 1722 and nothing
above them.

| Minerva | Consumer |
| :--- | :--- |
| Strip the L2 header, one VLAN tag | Storing each message, and all control logic |
| Dispatch on ethertype, `subtype`, `acf_msg_type` | Which `stream_id`s are accepted |
| Walk concatenated ACF messages, skip unknown ones | Responses, addressed to the request's `stream_id` MacAddress |
| Check lengths, delimit each payload | Per-stream `sequence_num` tracking |
| Emit one metadata block per message, and its payload | `sv` = 0, treated as best effort |
| Route each frame, and flag errors in the metadata | Handling error reports |
| Build frames on transmit | |

## Interfaces

| Port | Format |
| :--- | :--- |
| From the MAC | 32-bit `taxi_axis_if`. The MAC RX FIFO must drop bad frames (`DROP_BAD_FRAME`); minerva does not examine `tuser`. |
| To the consumer | `m_axis_meta`, one metadata block per ACF message, and `m_axis_payload`, when the metadata announces one; 32-bit `taxi_axis_if`. See Receive output. |
| From the producer | `s_axis_meta`, 8 words per message, and `s_axis_payload`, when the metadata announces one; 32-bit `taxi_axis_if`. See Transmit. |
| To the MAC | 32-bit `taxi_axis_if`; the MAC pads short frames. |

## Receive output

Each ACF message gives a metadata block on `m_axis_meta` and, when
`payload_len` is more than 0, one packet on `m_axis_payload`. The metadata
goes first, and nothing between minerva and the consumer may drop a packet
from one stream without the other.

| Stream | Signal | Meaning |
| :--- | :--- | :--- |
| `meta` | `tdata` | words 0-5, below |
| | `tlast` | on word 5 |
| | `tdest` | route: 0 = the consumer, 1 = discard |
| | `tkeep` | all ones; `tid` and `tuser` are unused |
| `payload` | `tdata` | the payload, in wire order, first octet in lane 0 |
| | `tkeep` | all ones, except the last beat: `1111 >> pad` |
| | `tdest` | 0 |
| | `tuser` | at `tlast`: 1 = the frame ended inside the payload |

### Metadata

Every word is a value: bit 31 is the most significant bit of the word as
written in this table. Common words come first and extras are appended, so a
consumer finds the same fields in the same words for every format.

| Word | Bits | Field |
| :---: | :--- | :--- |
| 0 | 31:24 | `format`: the AVTP `subtype` as received, 0x82 for NTSCF |
| | 23:16 | `flags`, below |
| | 15:0 | `payload_len`, octets: `acf_msg_length` x 4 - 8 - `pad`, at most 1480 |
| 1 | 31:0 | `stream_id[63:32]` |
| 2 | 31:0 | `stream_id[31:0]` |
| 3 | 31 | `sv` |
| | 30:23 | `sequence_num` |
| | 22:19 | `mr`, `tv`, `tu`, `fs`; 0 for NTSCF, which lacks them |
| | 18:0 | reserved, 0 |
| 4 | 31:0 | ACF quadlet 0 as received: `acf_msg_type[31:25]`, `acf_msg_length[24:16]`, `pad[15:14]`, `mtv[13]`, `rsv[12:11]`, `byte_bus_id[10:0]` |
| 5 | 31:0 | ABB quadlet 1 as received: `evt[31:28]`, `rsv[27:26]`, `hs[25]`, `cs[24]`, `transaction_num[23:16]`, `op[15]`, `rsp[14]`, `err[13]`, `ms[12]`, `read_size/segment_num[11:0]` |

| Flag | Word 0 bit | Set when |
| :--- | :---: | :--- |
| `ERR_EMPTY` | 16 | `ntscf_data_length` is 0 |
| `ERR_LEN` | 17 | `acf_msg_length` is below the header and pad, or runs past the data length |
| `ERR_TRUNC` | 18 | the frame ends before `ntscf_data_length` is used up, except after a payload has started, which ends with `tuser` instead |

- A block with a flag set reports an error: `payload_len` is 0, so no payload
  follows. A field is filled only once its whole quadlet has arrived; the
  frame's fields are cleared at each frame and the message's after each
  message. Messages before it in the frame are delivered as usual.
- A block on the discard route is for a frame no handler takes: another
  ethertype, another `subtype`, a `version` other than 0, a second VLAN tag,
  or a frame too short to tell. Its `payload_len` and `flags` are 0 and its
  other words are unspecified. The board drops it before the consumer.
- A message without a payload is its metadata alone.
- For responses, the consumer splits `stream_id` as MacAddress = `{w1,
  w2[31:16]}` and UniqueID = `w2[15:0]`. Field meanings are in `avtp.md`.

`subtype` becomes `format`; `version` and `r` are checked or ignored;
`ntscf_data_length` is used up by the walk. Word 4 keeps `acf_msg_type`,
`acf_msg_length` and `pad` as received, but `payload_len` is the length to use.

### Other formats

Formats beyond NTSCF with ABB keep words 0 to 5 and append their extras: TSCF
its `avtp_timestamp`, then GBB its `message_timestamp` in two words. GBB's
quadlets 0 and 3 have ABB's layout, so they are words 4 and 5. `tid` stays
free; the consumer reads the layout from `format` and `acf_msg_type`.

Minerva's part ends at these streams. Where the consumer keeps each message
and what it does with it are the consumer's design. A consumer that holds
`tready` low stalls minerva, and the MAC's RX FIFO then drops whole frames.

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
- `flow.md` follows an example frame through these conventions, byte by byte.

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
ethertype sees one realigned word per input word. A message, an error and a
frame for the discard route each request a metadata block, which `STATE_META`
loads; Ethernet padding and skipped messages give none.

| State | Word | Captures, checks | Next |
| :--- | :--- | :--- | :--- |
| `STATE_ETH` | L2 words 0-3 | ethertype at word 3 | AVTP: `STATE_AVTP`; VLAN: `STATE_VLAN`; other: discard block, then `STATE_DROP` |
| `STATE_VLAN` | tag | inner ethertype; one tag only | AVTP: `STATE_AVTP`; other: discard block |
| `STATE_AVTP` | AVTP 0 | `format`, `sv`, `sequence_num`; `data_rem` = `ntscf_data_length`; `subtype` is NTSCF, `version` is 0 | `STATE_NTSCF_1`, else discard block |
| `STATE_NTSCF_1` | AVTP 1 | `stream_id[63:32]` | `STATE_NTSCF_2` |
| `STATE_NTSCF_2` | AVTP 2 | `stream_id[31:0]` | `STATE_ACF`; `ERR_EMPTY` block if `data_rem` is 0 |
| `STATE_ACF` | ACF 0 | ACF quadlet 0; `acf_msg_length` x 4 is at least 8 + `pad` and at most `data_rem`; `data_rem` -= `acf_msg_length` x 4; `msg_rem` = `acf_msg_length` - 1 | ABB: `STATE_ABB_1`; unknown type: `STATE_SKIP`; malformed: `ERR_LEN` block |
| `STATE_ABB_1` | ABB 1 | ABB quadlet 1 | the message's block |
| `STATE_META` | input held | loads the requested block into a free slot | `STATE_PAYLOAD`, `STATE_ACF`, `STATE_DROP` or `STATE_ETH`, as requested |
| `STATE_PAYLOAD` | payload | one word out per word in; last word: `tkeep` from `pad`, `tlast`. Frame ends early: `tlast` with `tuser` = 1 | `STATE_ACF` if `data_rem` > 0, else `STATE_DROP` |
| `STATE_SKIP` | unknown message | `msg_rem` words, no output | `STATE_ACF` if `data_rem` > 0, else `STATE_DROP` |
| `STATE_DROP` | rest of frame | to `tlast`; also Ethernet padding | `STATE_ETH` |

A header state that sees `tlast` gives an `ERR_TRUNC` block, or a discard block
before the `subtype` is known, and returns to `STATE_ETH`. A frame that ends
with a message while `data_rem` is left gives the message's block, then an
`ERR_TRUNC` block.

- Every structural check resolves at `STATE_ACF`, before any payload, so a
  malformed message gives an error block and no payload. The only failure after
  a payload starts is truncation, and `tuser` marks it.
- No flush state: messages end on a quadlet boundary, so a valid message never
  ends part way through a realigned word; a frame that does is truncated.
- Two metadata slots, as in zircon: `STATE_META` fills one while the other is
  read out, and the input waits only when both are full. A block costs one
  held cycle. Back-to-back empty messages take 3 cycles each against the 8 in
  which their 2 words arrive at line rate, but a block takes 6 cycles to read
  out; the MAC's RX FIFO absorbs such bursts.
- State: the captured fields, `data_rem` (11 bits), `msg_rem` (9), `pad` (2),
  the L2 word pointer, the 16-bit realignment register, and two slots of six
  words.

## Validation

| Check | Source |
| :--- | :--- |
| `subtype` is NTSCF (TSCF deferred) | Open1722 `Ntscf_IsValid` |
| `version` is 0; version 1 takes the discard route | project: only version 0 is supported |
| Data length fits in the bytes received after the header | Open1722 checks against the whole buffer, loose by the header (12 or 24 bytes); minerva counts from the end of the header |
| `acf_msg_type` is ABB; others are skipped (GBB deferred) | Open1722 `Abb_IsValid`; project |
| `acf_msg_length` x 4 >= header + `pad` | Open1722 `Abb_IsValid` |
| The message ends within the data length | the walk in `acf-can-common.c` |
| A frame that ends before its lengths say is truncated | streaming: known only at `tlast` |

A failed check gives a flagged metadata block rather than a drop. `sv` and the
reserved bits are not checked: `sv` goes to the consumer in the metadata, and a
listener ignores reserved bits.

Bytes after the data length are Ethernet padding and are ignored. A minimum
frame carries a 46-byte payload, so a 20-byte PDU with one empty ABB message
(NTSCF 12 + ABB 8) is followed by 26 bytes of padding. The frame's end (`tlast`) only
confirms that the frame was long enough.

## Transmit

`minerva_tx` mirrors the parser, as zircon's transmit egress does: one
metadata block and its payload in, one frame out, the message as a single ABB
message in an NTSCF PDU.

```
s_axis_meta ──► minerva_tx_deparse ── header, 34 bytes ──┐
                       │ axis_payload_cmd {drop, len}     ├─► taxi_axis_concat ──► m_axis_mac_tx
s_axis_payload ──► minerva_tx_gate ──── payload ─────────┘
```

- `minerva_tx_deparse` holds metadata in two slots, as zircon does, checks
  each block, and sends a command for its payload. A good block gives the
  header: 8 beats, then the last 2 bytes with `tkeep` `0011`.
- `minerva_tx_gate` follows the commands in order: it passes a payload with
  zeros filling its last beat, which is the pad; for a message without a
  payload it sends one beat with no bytes, so the concat still has a packet;
  for a dropped message it drains the payload.
- `taxi_axis_concat` joins header and payload, byte by byte.

| Word | Bits | Field |
| :---: | :--- | :--- |
| 0 | 31:24 | `format`: 0x82 |
| | 23:16 | `flags`: 0 |
| | 15:0 | `payload_len` |
| 1, 2 | | `stream_id`: the sender's own stream |
| 3 | 31, 30:23 | `sv`, `sequence_num`; the rest 0 |
| 4 | 13, 10:0 | `mtv`, `byte_bus_id`; the other bits are ignored |
| 5 | 31:0 | ABB quadlet 1 |
| 6 | 31:0 | destination MAC `[47:16]` |
| 7 | 31:16 | destination MAC `[15:0]` |
| | 15:0 | reserved, 0 |

Words 0 to 5 are the receive layout. `s_axis_payload` carries a packet only
when `payload_len` is more than 0, in wire order from lane 0; `tuser` at its
`tlast` aborts the frame.

`stream_id[63:16]` is the MAC of the stream's talker and `[15:0]` its
UniqueID, 0 with one stream. A consumer replying to a request stores the
request's `stream_id[63:16]` as the destination and sends its own stream,
`{LOCAL_MAC, 0}`; it owns `sequence_num`.

Minerva adds the rest: `cfg_local_mac` as the Ethernet source, taken as each
header begins; ethertype 0x22F0; `subtype`, `version` 0 and the reserved bits;
`pad`, `acf_msg_length` and `ntscf_data_length` from `payload_len`; and the pad
as zeros.

A block of another `format`, with `flags` set, with `payload_len` over 1480
(1500 less the 12-byte NTSCF and 8-byte ABB headers), or of other than eight
words gives no frame, and its payload is drained, so the
messages after it stay paired. A payload that ends short or long, or an abort
at its end, ends the frame with `tuser` set, so the MAC TX FIFO drops it
(`TX_DROP_BAD_FRAME`).

## Modules

| Module | Function | Status |
| :--- | :--- | :--- |
| `minerva_rx_parse` | Parses Ethernet to ABB; a metadata block and payload per message | benches; 0.3.x validated on hardware |
| `minerva_tx` | Builds a frame from metadata and payload: the three below | benches |
| `minerva_tx_deparse` | The header from each metadata block, and a command for its payload | benches |
| `minerva_tx_gate` | The payload after each header, padded, stood in for, or drained | benches |

## Versions

Development is on `main`, where every commit builds and passes the benches.
Each milestone is tagged in git once it passes on hardware; a documentation
milestone needs no hardware run, and an incremental tag (x.y.Z) needs only the
benches.

| Tag | Milestone |
| :--- | :--- |
| `minerva-0.1.0` | NTSCF with ABB received as record and payload, validated on the Zedboard with the record echo |
| `minerva-0.2.0` | NTSCF with ABB sent from a transmit record, registered handshakes both ways, validated on the Zedboard with the record echo |
| `minerva-0.3.0` | Receive data flow documented at byte and bit level, from the MAC through the parser (`flow.md`) |
| `minerva-0.3.1` | Consumer hand-off documented (`flow.md`); the Zedboard stand-in consumer grouped as `echo_server`; benches only |
| `minerva-0.3.2` | Metadata beside the payload, as zircon does: `minerva_rx_parse` and `minerva_tx` on 0.4.0's contract, the Zedboard echo following; benches only |

## Verification cases

- Untagged, one tag, two tags (discard), a tag with `VLAN_EN` off (discard)
- NTSCF; unknown `subtype` (TSCF while deferred) and `version` 1 (discard);
  `sv` 0 passed on
- One ABB message, several concatenated, an unknown `acf_msg_type` (GBB while
  deferred) skipped between ABB messages that are delivered
- Metadata fields and `payload_len` match the message; an empty payload gives
  metadata alone
- Payload lengths 0 to 3 (every `pad`), and the 1480-byte maximum
- Minimum frame with Ethernet padding after the data length
- `ntscf_data_length` 0 (`ERR_EMPTY`); `acf_msg_length` below the header, and
  a message overrunning the data length (`ERR_LEN`)
- Frame truncated inside a header (`ERR_TRUNC`, with the fields that arrived
  whole), inside a payload (`tuser` = 1), and between messages (the message,
  then `ERR_TRUNC`)
- Back-to-back empty messages filling both slots; back-to-back frames;
  backpressure on each output

Transmit:

- Every metadata field placed in the frame, at every `pad` and the 1480-byte
  maximum; metadata alone gives a 34-byte frame
- `cfg_local_mac` changed between frames
- Dropped and drained: another `format`, `flags` set, metadata shorter or
  longer than eight words with and without a payload, `payload_len` over 1480;
  the next message still pairs with its own payload
- Marked bad (`tuser` = 1): a payload short or long by a byte or by words, an
  abort at the end of a payload
- Round trip: transmit metadata through `minerva_tx` and `minerva_rx_parse`
  comes back as its first six words, with the same payload

## Open decisions

1. Several messages per PDU on transmit; one per PDU for now.
2. PTP and L2 switching routes, later.
3. Metadata beside the payload, as zircon does: adopted 2026-10-05 and built
   for 0.4.0, as Receive output and Transmit describe.
   `zircon_ip_rx_ingress` broadcasts each frame to `zircon_ip_rx_parse`, which
   sends only metadata, and to a packet path that keeps the frame whole. On
   transmit, `zircon_ip_tx_deparse` builds the header from metadata and
   `taxi_axis_concat` joins it to the payload. Adopting it renames the record
   to metadata, lets a router steer each format by its metadata, removes the
   record's input stall, and reduces `minerva_tx_deparse` to headers. Frames on
   the wire do not change. Zircon's parse and deparse are benched; its ingress
   and egress are not, and the join of metadata to packets is not designed
   upstream. Decisions:
   1. Unit: decided 2026-10-05, one metadata block per ACF message, as minerva
      today, and one per PDU for formats with a single payload (AAF and CRF).
      Zircon's one block per frame was not taken.
   2. Empty payloads: decided 2026-10-05. Metadata goes for every message, first;
      a payload packet follows only when `payload_len` > 0, and truncation stays
      `tuser` on its last beat. Nothing between minerva and the consumer drops a
      packet from one stream without the other. Metadata carries every ABB
      header field; a message without a payload is its metadata alone.
   3. Packet stream: settled by 1, each payload cut out and realigned (minerva
      today), not the whole frame with offsets (zircon).
   4. Errors: decided 2026-10-05, the parser does not drop. It determines where
      each frame goes and flags errors in the metadata; handling them is the
      consumer's. The MAC still drops frames with Ethernet errors. A malformed
      AVTP frame gives one flagged metadata block, with the fields parsed so
      far and no payload. Frames for no handler, such as other ethertypes, take
      a route the board discards: on the Zedboard, a `taxi_axis_demux` on
      `tdest` sends it to a `taxi_axis_null_snk`. ACF message types without a
      handler are skipped by length, as today.
   5. Byte order: decided 2026-10-05, every metadata field is a value, addresses
      included (minerva today), since only FPGA logic consumes it. Zircon keeps
      addresses in wire order.

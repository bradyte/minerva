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
| Strip the L2 header, one VLAN tag | Storing each packet, and all control logic |
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
| From the consumer | 32-bit `taxi_axis_if`, one packet per message: the 6-word transmit record, then the payload; see Transmit. |
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

Minerva's part ends at this stream. Where the consumer keeps each packet and
what it does with it are the consumer's design. A consumer that holds `tready`
low stalls minerva, and the MAC's RX FIFO then drops whole frames.

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
  malformed message never produces output. The only failure after output starts
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

`minerva_tx_deparse` mirrors the parser: one packet in per message, one frame
out, the message as a single ABB message in an NTSCF PDU. Each record field is
a literal wire field, as zircon's TX metadata is.

| Signal | Meaning |
| :--- | :--- |
| `tdata` | record words 0-5, then the payload from lane 0 |
| `tid` | format code: 0 = NTSCF with ABB |
| `tdest` | route: 0 = AVTP |
| `tuser` | at `tlast`: 1 = abort |
| `tkeep` | all ones, except the last payload word |

| Word | Bits | Field |
| :---: | :--- | :--- |
| 0-3 | | as the receive record; `stream_id` is the sender's own stream |
| 4 | 31:0 | destination MAC `[47:16]` |
| 5 | 31:16 | destination MAC `[15:0]` |
| | 15:0 | reserved, 0 |

`stream_id[63:16]` is the MAC of the stream's talker and `[15:0]` its
UniqueID, 0 with one stream. A consumer replying to a request stores the
request's `stream_id[63:16]` as the destination and sends its own stream,
`{LOCAL_MAC, 0}`; it owns `sequence_num`.

Minerva adds the rest: `cfg_local_mac` as the Ethernet source, sampled as each
record begins; ethertype 0x22F0; `subtype`, `version` 0 and the reserved bits;
`pad`, `acf_msg_length` and `ntscf_data_length` from `payload_len`; and the pad
as zeros.

Checks, settled at record word 5 before anything is sent, drop the packet: an
unknown `tid` or `tdest`, a record shorter than 6 words, a payload missing or
not announced, `payload_len` over 1480, or an abort on a record alone. A
payload that ends short or long, or an abort at its end, ends the frame with
`tuser` set, so the MAC TX FIFO drops it (`TX_DROP_BAD_FRAME`).

## Modules

| Module | Function | Status |
| :--- | :--- | :--- |
| `minerva_rx_parse` | Parses Ethernet to ABB; one record and payload per message | validated on hardware |
| `minerva_tx_deparse` | Builds a frame from a transmit record and payload | validated on hardware |

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

## Verification cases

- Untagged, one tag, two tags (dropped), a tag with `VLAN_EN` off (dropped)
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

Transmit:

- Every record field placed in the frame, at every `pad` and the 1480-byte
  maximum; a record alone gives a 34-byte frame
- `cfg_local_mac` changed between frames
- Dropped: unknown `tid` or `tdest`, short records, a payload missing, not
  announced or over 1480 bytes, an aborted record alone
- Marked bad (`tuser` = 1): a payload short or long by a byte or by words, an
  abort at the end of a payload
- Round trip: a transmit record through `minerva_tx_deparse` and
  `minerva_rx_parse` comes back as the same receive record and payload

## Open decisions

1. Several messages per PDU on transmit; one per PDU for now.
2. PTP and L2 switching routes, later.
3. Metadata beside the payload, as zircon does: adopted 2026-10-05, for 0.4.0.
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
      a route the wrapper discards. ACF message types without a handler are
      skipped by length, as today.
   5. Byte order: decided 2026-10-05, every metadata field is a value, addresses
      included (minerva today), since only FPGA logic consumes it. Zircon keeps
      addresses in wire order.

### Metadata layout for 0.4.0

Decided 2026-10-05. 32-bit words, every field a value. Common words come
first and extras are appended, so every ACF unit (NTSCF or TSCF, ABB or GBB)
shares words 0 to 5.

| Word | Fields |
| :---: | :--- |
| 0 | `format[31:24]`, the AVTP `subtype` as received; `flags[23:16]`; `payload_len[15:0]` |
| 1 | `stream_id[63:32]` |
| 2 | `stream_id[31:0]` |
| 3 | `sv[31]`, `sequence_num[30:23]`, `mr[22]`, `tv[21]`, `tu[20]`, `fs[19]`; a field the format lacks is 0 |
| 4 | ACF message quadlet 0 as received; ABB and GBB share its layout |
| 5 | ABB quadlet 1, or GBB quadlet 3, which has the same layout |
| 6... | extras: TSCF `avtp_timestamp`, then GBB `message_timestamp` (2 words) |

Flags: bit 0 `ERR_EMPTY`, `ntscf_data_length` is 0; bit 1 `ERR_LEN`,
`acf_msg_length` is below the header and pad or runs past the data length; bit
2 `ERR_TRUNC`, the frame ends inside a header. Other bits are 0.

`tid` is unused (0), `tdest` is the route (0 the consumer, 1 discard), and
`tuser` at `tlast` of a payload marks it truncated. NTSCF and TSCF go to the
consumer, which reads the layout from `format` and `acf_msg_type`; AAF and CRF
take the discard route for now. Transmit takes the same words with the
destination MAC appended. The streams are `meta` and `payload`, and "record"
becomes "meta". 0.4.0 builds NTSCF with ABB only; TSCF, GBB, AAF and CRF
shaped the layout and stay deferred. The transition from 0.3.x is in
`minerva_0_4_0_release_notes.md`.

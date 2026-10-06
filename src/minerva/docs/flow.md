# Minerva data flow

How a frame's bytes and bits move through minerva, beat by beat. `minerva.md`
is the contract: the metadata layout, the checks and what each field means. This
document follows one example frame, built with `tb/avtp.py`, through
`minerva_rx_parse` to its consumer.

## Bytes and bits

- An AXI stream beat carries four byte lanes: lane `n` is `tdata[8n+7:8n]`,
  valid when `tkeep[n]` is 1. Lane 0 is first on the wire.
- A waveform viewer shows `tdata` as one hex number with lane 3 on the left, so
  the first byte is the rightmost pair of digits. Beat 0 below carries
  `DA D1 D2 D3` and reads `0xD3D2D1DA`.
- IEEE 1722 draws each quadlet in network order: bit offset 0 is the most
  significant bit of its first byte. A quadlet held as a value with its first
  byte in bits 31:24 puts a field at offset `o`, width `w`, at `[31-o -: w]`.
- Bit order on the cable is the PHY's and the MAC's concern. From the MAC on,
  each byte is a value.

## Example frame

One untagged frame carrying one ABB message in an NTSCF PDU:

| Field | Value |
| :--- | :--- |
| Destination | `DA:D1:D2:D3:D4:D5` |
| Source | `5A:51:52:53:54:55` |
| Ethertype | `0x22F0`, AVTP |
| `subtype` | `0x82`, NTSCF |
| `sv`, `version` | 1, 0 |
| `ntscf_data_length` | 36 bytes, the one ABB message |
| `sequence_num` | `0x2A` |
| `stream_id` | `0x5A515253_54550000`: talker MAC `5A:51:52:53:54:55`, UniqueID 0 |
| `acf_msg_type` | `0x0E`, ABB |
| `acf_msg_length` | 9 quadlets: 8 header bytes, 25 payload, 3 pad |
| `pad`, `mtv`, `byte_bus_id` | 3, 0, `0x012` |
| ABB word 1 | `0x00070000` (`transaction_num` 7) |
| Payload | 25 bytes, `A0` to `B8` |

The frame is 14 + 12 + 8 + 25 + 3 = 62 bytes, over the 60-byte minimum, so it
has no Ethernet padding.

## From the MAC

The MAC hands minerva a frame that has already been checked:

- `taxi_axis_gmii_rx` removes the preamble and SFD, checks the FCS and keeps its
  4 bytes back. A frame with a bad FCS, a receive error or over the length
  limit ends with `tuser` = 1.
- The MAC's RX FIFO drops those frames whole (`RX_DROP_BAD_FRAME`, set in the
  Zedboard `fpga_core`), so minerva never examines `tuser`.
- The FIFO's adapter packs the 8-bit MAC stream into 32-bit beats, first byte
  in lane 0. `tkeep` is all ones except on the last beat, and `tlast` marks the
  last beat.

The example frame arrives as 16 beats. The PDU bytes are numbered from the
first byte after the ethertype.

| Beat | Lane 0 | Lane 1 | Lane 2 | Lane 3 | `tdata` | `tkeep` | Holds | State |
| :---: | :---: | :---: | :---: | :---: | :--- | :---: | :--- | :--- |
| 0 | `DA` | `D1` | `D2` | `D3` | `0xD3D2D1DA` | `1111` | destination 0-3 | `STATE_ETH` |
| 1 | `D4` | `D5` | `5A` | `51` | `0x515AD5D4` | `1111` | destination 4-5, source 0-1 | `STATE_ETH` |
| 2 | `52` | `53` | `54` | `55` | `0x55545352` | `1111` | source 2-5 | `STATE_ETH` |
| 3 | `22` | `F0` | `82` | `80` | `0x8082F022` | `1111` | ethertype, PDU 0-1 | `STATE_ETH` |
| 4 | `24` | `2A` | `5A` | `51` | `0x515A2A24` | `1111` | PDU 2-5 | `STATE_AVTP` |
| 5 | `52` | `53` | `54` | `55` | `0x55545352` | `1111` | PDU 6-9 | `STATE_NTSCF_1` |
| 6 | `00` | `00` | `1C` | `09` | `0x091C0000` | `1111` | PDU 10-13 | `STATE_NTSCF_2` |
| 7 | `C0` | `12` | `00` | `07` | `0x070012C0` | `1111` | PDU 14-17 | `STATE_ACF` |
| 8 | `00` | `00` | `A0` | `A1` | `0xA1A00000` | `1111` | PDU 18-21 | `STATE_ABB_1` |
| | | | | | | | input held while the metadata block loads | `STATE_META` |
| 9 | `A2` | `A3` | `A4` | `A5` | `0xA5A4A3A2` | `1111` | PDU 22-25 | `STATE_PAYLOAD` |
| 10 | `A6` | `A7` | `A8` | `A9` | `0xA9A8A7A6` | `1111` | PDU 26-29 | `STATE_PAYLOAD` |
| 11 | `AA` | `AB` | `AC` | `AD` | `0xADACABAA` | `1111` | PDU 30-33 | `STATE_PAYLOAD` |
| 12 | `AE` | `AF` | `B0` | `B1` | `0xB1B0AFAE` | `1111` | PDU 34-37 | `STATE_PAYLOAD` |
| 13 | `B2` | `B3` | `B4` | `B5` | `0xB5B4B3B2` | `1111` | PDU 38-41 | `STATE_PAYLOAD` |
| 14 | `B6` | `B7` | `B8` | `00` | `0x00B8B7B6` | `1111` | PDU 42-45 | `STATE_PAYLOAD` |
| 15 | `00` | `00` | | | `0x----0000` | `0011` | PDU 46-47, `tlast` | `STATE_PAYLOAD` |

Lanes 2 and 3 of beat 15 are not valid and are shown as `-`.

### Where the beat boundaries fall

The L2 header is 14 bytes, or 18 with a tag, and both end 2 bytes into a beat.
Every 1722 header and ACF message is a whole number of quadlets, so every
quadlet after the ethertype straddles two beats: its first 2 bytes in lanes 2-3
of one beat, its last 2 in lanes 0-1 of the next. For the same reason:

- An AVTP frame without Ethernet padding also ends 2 bytes into a beat, with
  `tkeep` = `0011`, as beat 15 does.
- A frame under 60 bytes is padded by the sender's MAC to exactly 60, 15 whole
  beats. The padding follows `ntscf_data_length` and `STATE_DROP` discards it.

A VLAN tag inserts one beat, and every later beat moves down by one:

| Beat | Lane 0 | Lane 1 | Lane 2 | Lane 3 | Holds | State |
| :---: | :---: | :---: | :---: | :---: | :--- | :--- |
| 3 | `81` | `00` | `00` | `7B` | TPID `0x8100`, TCI (not examined) | `STATE_ETH` |
| 4 | `22` | `F0` | `82` | `80` | inner ethertype, PDU 0-1 | `STATE_VLAN` |
| 5 | `24` | `2A` | `5A` | `51` | PDU 2-5 | `STATE_AVTP` |

The tag is 4 bytes, so the PDU keeps the same 2-byte offset.

## Realignment

Three lines of `minerva_rx_parse` rebuild each quadlet from its two beats:

```systemverilog
// on every input transfer
shift_reg <= s_axis_mac_rx.tdata[31:16];

wire [31:0] shifted = {s_axis_mac_rx.tdata[15:0], shift_reg};
wire [31:0] quad = {shifted[7:0], shifted[15:8], shifted[23:16], shifted[31:24]};
```

- `shift_reg` keeps lanes 2-3 of the previous beat.
- `shifted` puts those in lanes 0-1 and this beat's lanes 0-1 in lanes 2-3. It
  is the quadlet that began in the previous beat, still in wire order.
- `quad` reverses the bytes, so the quadlet reads as a value with its first
  byte in bits 31:24, as the spec draws it.

Header fields are read from `quad`, at their spec bit offsets. The payload goes
out as `shifted`, so its bytes stay in wire order, first byte in lane 0.

| Quadlet | Beat | `shift_reg` | `shifted` | `quad` | Holds | Used |
| :---: | :---: | :--- | :--- | :--- | :--- | :--- |
| 0 | 4 | `0x8082` | `0x2A248082` | `0x8280242A` | AVTP header, NTSCF fields | fields captured |
| 1 | 5 | `0x515A` | `0x5352515A` | `0x5A515253` | `stream_id[63:32]` | metadata word 1 |
| 2 | 6 | `0x5554` | `0x00005554` | `0x54550000` | `stream_id[31:0]` | metadata word 2 |
| 3 | 7 | `0x091C` | `0x12C0091C` | `0x1C09C012` | ACF header, first ABB fields | metadata word 4 |
| 4 | 8 | `0x0700` | `0x00000700` | `0x00070000` | ABB word 1 | metadata word 5 |
| 5 | 9 | `0xA1A0` | `0xA3A2A1A0` | | payload 0-3 | sent as `shifted` |
| 6-10 | 10-14 | | `0xA7A6A5A4` ... `0xB7B6B5B4` | | payload 4-23 | sent as `shifted` |
| 11 | 15 | `0x00B8` | `0x000000B8` | | payload 24, 3 pad bytes | sent as `shifted` |

### Fields that cross a beat

Quadlets 0 and 3 hold several fields each. The tables trace each field to the
input bits it came from.

Quadlet 0, read in `STATE_AVTP` at beat 4:

| Field | `quad` bits | Input bits | Value |
| :--- | :--- | :--- | :--- |
| `subtype` | `[31:24]` | beat 3 `tdata[23:16]` | `0x82` |
| `sv` | `[23]` | beat 3 `tdata[31]` | 1 |
| `version` | `[22:20]` | beat 3 `tdata[30:28]` | 0 |
| `r` | `[19]` | beat 3 `tdata[27]` | 0 |
| `ntscf_data_length` | `[18:8]` | `{beat 3 tdata[26:24], beat 4 tdata[7:0]}` | 36 |
| `sequence_num` | `[7:0]` | beat 4 `tdata[15:8]` | `0x2A` |

Quadlet 3, read in `STATE_ACF` at beat 7:

| Field | `quad` bits | Input bits | Value |
| :--- | :--- | :--- | :--- |
| `acf_msg_type` | `[31:25]` | beat 6 `tdata[23:17]` | `0x0E` |
| `acf_msg_length` | `[24:16]` | `{beat 6 tdata[16], beat 6 tdata[31:24]}` | 9 |
| `pad` | `[15:14]` | beat 7 `tdata[7:6]` | 3 |
| `mtv` | `[13]` | beat 7 `tdata[5]` | 0 |
| `rsv` | `[12:11]` | beat 7 `tdata[4:3]` | 0 |
| `byte_bus_id` | `[10:0]` | `{beat 7 tdata[2:0], beat 7 tdata[15:8]}` | `0x012` |

`ntscf_data_length` is split across beats 3 and 4. Without the realignment,
every field would have to be assembled from two beats in its own way. With it,
each state reads one 32-bit value at fixed bit positions.

### The last beat

```systemverilog
wire in_whole = !s_axis_mac_rx.tlast || in_keep >= 3'd2;
```

A quadlet's last 2 bytes are in lanes 0-1 of the following beat. On the last
beat, `shifted` is whole only if that beat has at least 2 valid bytes. Beat 15
has 2 (`tkeep` = `0011`), so quadlet 11 is whole: `B8`, then the 3 pad bytes. A
last beat with 1 byte leaves the quadlet a byte short, so the frame ended inside
it. In a header, that gives an `ERR_TRUNC` block; in a payload, the payload
ends with `tuser` = 1; see Truncated payload below.

## To the consumer

Minerva sends each ABB message on two streams: a 6-word metadata block on
`m_axis_meta`, then, when `payload_len` is more than 0, the payload on
`m_axis_payload`. The example message gives a 24-byte block and a 25-byte
payload.

| Signal | `m_axis_meta` | `m_axis_payload` |
| :--- | :--- | :--- |
| `tdata` | a metadata word, as a value | payload bytes in wire order, first in lane 0 |
| `tkeep` | `1111` | `1111`; on the last beat `1111 >> pad` |
| `tlast` | on word 5 | on the last payload beat |
| `tdest` | 0, the consumer; 1, discard | 0 |
| `tuser` | unused | at `tlast`: 1 = the frame ended inside the payload |

The metadata block:

| Beat | Lane 0 | Lane 1 | Lane 2 | Lane 3 | `tdata` | Holds |
| :---: | :---: | :---: | :---: | :---: | :--- | :--- |
| 0 | `19` | `00` | `00` | `82` | `0x82000019` | `format`, `flags`, `payload_len` |
| 1 | `53` | `52` | `51` | `5A` | `0x5A515253` | `stream_id[63:32]` |
| 2 | `00` | `00` | `55` | `54` | `0x54550000` | `stream_id[31:0]` |
| 3 | `00` | `00` | `00` | `95` | `0x95000000` | `sv`, `sequence_num` |
| 4 | `12` | `C0` | `09` | `1C` | `0x1C09C012` | ACF quadlet 0 |
| 5 | `00` | `00` | `07` | `00` | `0x00070000` | ABB quadlet 1, `tlast` |

The payload:

| Beat | Lane 0 | Lane 1 | Lane 2 | Lane 3 | `tdata` | `tkeep` | Holds |
| :---: | :---: | :---: | :---: | :---: | :--- | :---: | :--- |
| 0 | `A0` | `A1` | `A2` | `A3` | `0xA3A2A1A0` | `1111` | payload 0-3 |
| 1 | `A4` | `A5` | `A6` | `A7` | `0xA7A6A5A4` | `1111` | payload 4-7 |
| 2 | `A8` | `A9` | `AA` | `AB` | `0xABAAA9A8` | `1111` | payload 8-11 |
| 3 | `AC` | `AD` | `AE` | `AF` | `0xAFAEADAC` | `1111` | payload 12-15 |
| 4 | `B0` | `B1` | `B2` | `B3` | `0xB3B2B1B0` | `1111` | payload 16-19 |
| 5 | `B4` | `B5` | `B6` | `B7` | `0xB7B6B5B4` | `1111` | payload 20-23 |
| 6 | `B8` | | | | `0x------B8` | `0001` | payload 24, `tlast` |

Lanes 1-3 of payload beat 6 carry the three pad bytes; `tkeep` marks them
invalid.

### Values and bytes

The metadata and the payload are laid out differently on purpose:

- **Metadata words are values.** Word 1 is `0x5A515253`, so lane 0 holds
  `53`, the reverse of the wire order `5A 51 52 53`. A consumer reads a field
  at its bit position with no byte swap: `payload_len` is word 0 `[15:0]`.
- **The payload is a byte stream.** `A0` arrived first and sits in lane 0, so
  the bytes reach memory in the order the talker sent them.

### Where each metadata bit comes from

A whole quadlet read at input beat `b` lands in a metadata word as:

| Metadata bits | Input bits |
| :--- | :--- |
| `[31:24]` | beat `b-1` `tdata[23:16]` |
| `[23:16]` | beat `b-1` `tdata[31:24]` |
| `[15:8]` | beat `b` `tdata[7:0]` |
| `[7:0]` | beat `b` `tdata[15:8]` |

| Word | Bits | Field | From | Value |
| :---: | :--- | :--- | :--- | :--- |
| 0 | `[31:24]` | `format` | quadlet 0 `[31:24]`: beat 3 `tdata[23:16]` | `0x82` |
| 0 | `[23:16]` | `flags` | minerva's checks | 0 |
| 0 | `[15:0]` | `payload_len` | `acf_msg_length` x 4 - 8 - `pad`, from quadlet 3 `[24:16]` and `[15:14]` | 36 - 8 - 3 = 25 |
| 1 | `[31:0]` | `stream_id[63:32]` | quadlet 1, beats 4-5 | `0x5A515253` |
| 2 | `[31:0]` | `stream_id[31:0]` | quadlet 2, beats 5-6 | `0x54550000` |
| 3 | `[31]` | `sv` | quadlet 0 `[23]`: beat 3 `tdata[31]` | 1 |
| 3 | `[30:23]` | `sequence_num` | quadlet 0 `[7:0]`: beat 4 `tdata[15:8]` | `0x2A` |
| 4 | `[31:0]` | ACF quadlet 0 | quadlet 3, beats 6-7 | `0x1C09C012` |
| 5 | `[31:0]` | ABB quadlet 1 | quadlet 4, beats 7-8 | `0x00070000` |

`payload_len` is the only computed field and `flags` the only one minerva
sets; every other bit is copied. The payload follows the same 2-byte shift:
payload beat `j` takes lanes 0-1 from lanes 2-3 of input beat 8 + `j`, and
lanes 2-3 from lanes 0-1 of input beat 9 + `j`.

### Other cases

| Frame | Out |
| :--- | :--- |
| One empty ABB message (`acf_msg_length` 2): 34 bytes, padded to 60 | Metadata alone: word 0 = `0x82000000` (`payload_len` 0), word 4 = `0x1C020012`. The padding is dropped. |
| The example message, then an empty one with `byte_bus_id` `0x013` and `transaction_num` 8: 70 bytes, `ntscf_data_length` 44 | The example's block and payload, then a block alone with word 0 = `0x82000000`, word 4 = `0x1C020013` and word 5 = `0x00080000`. Words 1-3 repeat, since they belong to the PDU. |
| An ACF message of another type among ABB messages | Nothing for it: it is skipped by its length, and the ABB messages come out unchanged. |
| The example frame cut inside a header, or at ABB quadlet 1 | An `ERR_TRUNC` block: word 0 = `0x82040000`, then the fields whose quadlets arrived whole. Cut after 21 PDU bytes, that is all of words 1-5. |
| A frame that fails a length check | An `ERR_LEN` or `ERR_EMPTY` block, with no payload. Messages before it in the frame are already out, intact. |
| Another ethertype or `subtype`, or a second tag | A block on the discard route, `tdest` 1, which the board drops. |
| A frame that ends inside a payload | The full metadata, then a truncated payload, below. |

The last payload beat's `tkeep` follows from `pad`:

| `pad` | 0 | 1 | 2 | 3 |
| :--- | :---: | :---: | :---: | :---: |
| Last `tkeep` | `1111` | `0111` | `0011` | `0001` |

### Truncated payload

The example frame cut after 49 bytes ends at input beat 12, which holds only
`AE`. The metadata block went out before the frame ended, unchanged:
`payload_len` is still 25. Then the payload:

| Beat | Lane 0 | Lane 1 | Lane 2 | Lane 3 | `tkeep` | Holds |
| :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| 0 | `A0` | `A1` | `A2` | `A3` | `1111` | payload 0-3 |
| 1 | `A4` | `A5` | `A6` | `A7` | `1111` | payload 4-7 |
| 2 | `A8` | `A9` | `AA` | `AB` | `1111` | payload 8-11 |
| 3 | `AC` | `AD` | `AE` | | `0111` | payload 12-14, `tlast`, `tuser` = 1 |

- Only `tuser` at `tlast` says the payload is bad. It is 15 bytes, short of the
  25 the metadata announced.
- The last beat is `1111` if the input's last beat held at least 2 bytes
  (`in_whole`), otherwise `0111`. Bytes after that word in the input's last
  beat are not sent.
- On the Zedboard, `echo_server` keeps the truncated payload with its
  metadata, so the two stay paired; `minerva_tx` marks the echo bad, and the
  MAC's TX FIFO drops it.

### Flow control

- The consumer can hold `tready` low on any beat of either stream. Minerva
  keeps that beat on the bus, unchanged, until the consumer takes it.
- Both outputs are registered: the metadata through its read-out register, the
  payload through taxi's registered output datapath, so the consumer's `tready`
  never reaches minerva's input in the same cycle.
- Minerva stops taking input while its payload output waits, or while both
  metadata slots are full. The MAC's RX FIFO holds the frames that arrive
  meanwhile and drops whole frames once it is full.
- On the Zedboard, `echo_server` stores the two streams apart: 256 bytes of
  metadata and a 2048-byte payload FIFO that passes a payload on only once all
  of it has arrived. Both hold minerva back when full.

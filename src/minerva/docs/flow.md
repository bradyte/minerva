# Minerva data flow

How a frame's bytes and bits move through minerva, beat by beat. `minerva.md`
is the contract: the record layout, the checks and what each field means. This
document follows one example frame, built with `tb/avtp.py`, through
`minerva_rx_parse`.

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
| | | | | | | | input held while the record goes out | `STATE_RECORD` |
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
| 1 | 5 | `0x515A` | `0x5352515A` | `0x5A515253` | `stream_id[63:32]` | record word 0 |
| 2 | 6 | `0x5554` | `0x00005554` | `0x54550000` | `stream_id[31:0]` | record word 1 |
| 3 | 7 | `0x091C` | `0x12C0091C` | `0x1C09C012` | ACF header, first ABB fields | fields captured |
| 4 | 8 | `0x0700` | `0x00000700` | `0x00070000` | ABB word 1 | record word 3 |
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
it. Nothing is sent if that happens in a header. In a payload, the packet ends
with `tuser` = 1 (`minerva.md`, Receive states).

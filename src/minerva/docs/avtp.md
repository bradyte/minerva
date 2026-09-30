**AVTP protocol summary**

Layouts are drawn only from open-source code and documentation:

| Source | Version | Covers |
| :--- | :--- | :--- |
| Open1722, `refs/Open1722` | COVESA `e0a9fca`, IEEE 1722-2025 | every header below; unit tests pin ABB and GBB to bytes |
| libavtp, `refs/libavtp` | Avnu `15ba8ce`, IEEE 1722-2016 | common header, common stream header (confirms TSCF) |

Offsets are bits from the most significant bit of the header's first quadlet,
in wire order. *(project)* marks a meaning supplied for this project rather
than by the sources. The design implements NTSCF with ABB first; *deferred*
marks everything outside that path.

Reserved fields (`r`, `rsv`, `reserved`): a talker sends zero and a listener
ignores them (Open1722 `docs/api-design.md`).

**AVTP common header**
| offset    | bit width | name                  | meaning
| :---:     | :---:     | :---                  | :---
| 0         | 8         | `subtype`             | selects the format
| 8         | 1         | `h`                   | header specific: `sv` (stream_id valid) in the common stream and control headers
| 9         | 3         | `version`             | 0 or 1 *(project)*
| 12        | 20        |                       | defined by each format

**`subtype` values**
| value | name | value | name |
| :---: | :--- | :---: | :--- |
| 0x00 | 61883_IIDC | 0x82 | NTSCF |
| 0x01 | MMA_STREAM | 0xEB | IEEE_8021_MLAA (Open1722 only) |
| 0x02 | AAF | 0xEC | ESCF |
| 0x03 | CVF | 0xED | EECF |
| 0x04 | CRF | 0xEE | AEF_DISCRETE |
| 0x05 | TSCF | 0xFA | ADP |
| 0x06 | SVF | 0xFB | AECP |
| 0x07 | RVF | 0xFC | ACMP |
| 0x6E | AEF_CONTINUOUS | 0xFE | MAAP |
| 0x6F | VSF_STREAM | 0xFF | EF_CONTROL |
| 0x7F | EF_STREAM | | |

**Non-Time-Synchronous Control Format (NTSCF) header**

3 quadlets. Open1722 only; its unit tests check the size, not the fields.
| offset    | bit width | name                  | meaning
| :---:     | :---:     | :---                  | :---
| 0         | 8         | `subtype`             | 0x82
| 8         | 1         | `sv`                  | stream_id valid
| 9         | 3         | `version`             | 0 or 1 *(project)*
| 12        | 1         | `r`                   | reserved
| 13        | 11        | `ntscf_data_length`   | octets of ACF messages after this header
| 24        | 8         | `sequence_num`        | sequence number of the AVTPDU; starts at any value, increments by one with each AVTPDU and wraps from 0xFF to 0x00, so a listener can detect lost or out-of-order packets *(project)*
| 32        | 64        | `stream_id`           | see **stream_id**
| 96        | 0 to n    | ACF messages          |

**Time-Synchronous Control Format (TSCF) header** *(deferred)*

6 quadlets. Open1722, and libavtp's common stream header places every named
field at the same position.
| offset    | bit width | name                  | libavtp name      | meaning
| :---:     | :---:     | :---                  | :---              | :---
| 0         | 8         | `subtype`             | `subtype`         | 0x05
| 8         | 1         | `sv`                  | `sv`              | stream_id valid
| 9         | 3         | `version`             | `version`         | 0 or 1 *(project)*
| 12        | 1         | `mr`                  | `mr`              | *deferred*
| 13        | 2         | `rsv`                 |                   | reserved
| 15        | 1         | `tv`                  | `tv`              | *deferred*
| 16        | 8         | `sequence_num`        | `seq_num`         | *deferred*
| 24        | 7         | `reserved`            |                   | reserved
| 31        | 1         | `tu`                  | `tu`              | *deferred*
| 32        | 64        | `stream_id`           | `stream_id`       | see **stream_id**
| 96        | 32        | `avtp_timestamp`      | `avtp_time`       | *deferred*
| 128       | 32        | `reserved`            | `format_specific` | reserved
| 160       | 16        | `stream_data_length`  | `stream_data_len` | octets of ACF messages after this header
| 176       | 16        | `reserved`            |                   | reserved
| 192       | 0 to n    | ACF messages          |                   |

**stream_id**

1722 carries `stream_id` as one 64-bit field, at offset 32 in both NTSCF and
TSCF, and treats it that way. Its contents follow the IEEE 802.1Q stream_id
format, given here for reference *(project)*:
| offset    | bit width | name                  | meaning
| :---:     | :---:     | :---                  | :---
| 0         | 48        | `MacAddress`          | the talker's (source) MAC address
| 48        | 16        | `UniqueID`            | distinguishes multiple streams from the same `MacAddress`

Offsets are from the most significant bit of `stream_id`, so `MacAddress` is
`stream_id[63:16]` and `UniqueID` is `stream_id[15:0]`.

**ACF common header**

The first quadlet of every ACF message. The messages follow one another in the
NTSCF or TSCF payload, each `acf_msg_length` quadlets on from the last.
| offset    | bit width | name                  | meaning
| :---:     | :---:     | :---                  | :---
| 0         | 7         | `acf_msg_type`        | selects the message format
| 7         | 9         | `acf_msg_length`      | quadlets in the whole message, this header included

**`acf_msg_type` values** (Open1722)
| value | name | value | name |
| :---: | :--- | :---: | :--- |
| 0x00 | FLEXRAY | 0x0D | BYTE_BUS (GBB) |
| 0x01 | CAN | 0x0E | BYTE_BUS_BRIEF (ABB) |
| 0x02 | CAN_BRIEF | 0x0F | I2C |
| 0x03 | LIN | 0x10 | I2C_BRIEF |
| 0x04 | MOST | 0x11 | CAN_XL |
| 0x05 | GPC | 0x12 | CAN_XL_BRIEF |
| 0x06 | SERIAL | 0x21 | CAN_V2 |
| 0x07 | PARALLEL | 0x22 | CAN_BRIEF_V2 |
| 0x08 | SENSOR | 0x23 | LIN_V2 |
| 0x09 | SENSOR_BRIEF | 0x76 | CHECKSUM |
| 0x0A | AECP | 0x77 | CRC |
| 0x0B | ANCILLARY | 0x78-0x7F | user defined |
| 0x0C | GISF | | |

**Abbreviated Byte Bus (ABB) message**

2 quadlets. Open1722 `Abb.h`; `unit/test-abb.c` pins every field to bytes.
| offset    | bit width | name                  | meaning
| :---:     | :---:     | :---                  | :---
| 0         | 7         | `acf_msg_type`        | 0x0E
| 7         | 9         | `acf_msg_length`      | quadlets in the whole message
| 16        | 2         | `pad`                 | zero octets after the payload, to end on a quadlet
| 18        | 1         | `mtv`                 | message timestamp valid
| 19        | 2         | `rsv`                 | reserved
| 21        | 11        | `byte_bus_id`         |
| 32        | 4         | `evt`                 |
| 36        | 2         | `rsv`                 | reserved
| 38        | 1         | `hs`                  |
| 39        | 1         | `cs`                  |
| 40        | 8         | `transaction_num`     |
| 48        | 1         | `op`                  |
| 49        | 1         | `rsp`                 |
| 50        | 1         | `err`                 |
| 51        | 1         | `ms`                  |
| 52        | 12        | `read_size/segment_num` | one field, two names
| 64        | 0 to n    | payload               |

Payload octets = `acf_msg_length` x 4 - 8 - `pad`. The first byte is 0x1C
while `acf_msg_length` is below 256.

The sources give no meanings for `byte_bus_id` to `read_size/segment_num`.
Minerva does not interpret them; it passes them to the consumer as metadata
*(project)*.

**Generic Byte Bus (GBB) message** *(deferred)*

4 quadlets. Open1722 `Gbb.h`; `unit/test-gbb.c` pins every field to bytes. The
ABB fields, with `message_timestamp` inserted as quadlets 1 and 2; meanings and
handling as ABB, `message_timestamp` included.
| offset    | bit width | name                  | meaning
| :---:     | :---:     | :---                  | :---
| 0         | 7         | `acf_msg_type`        | 0x0D
| 7         | 9         | `acf_msg_length`      |
| 16        | 2         | `pad`                 |
| 18        | 1         | `mtv`                 |
| 19        | 2         | `rsv`                 |
| 21        | 11        | `byte_bus_id`         |
| 32        | 64        | `message_timestamp`   |
| 96        | 4         | `evt`                 |
| 100       | 2         | `rsv`                 |
| 102       | 1         | `hs`                  |
| 103       | 1         | `cs`                  |
| 104       | 8         | `transaction_num`     |
| 112       | 1         | `op`                  |
| 113       | 1         | `rsp`                 |
| 114       | 1         | `err`                 |
| 115       | 1         | `ms`                  |
| 116       | 12        | `read_size/segment_num` |
| 128       | 0 to n    | payload               |

Payload octets = `acf_msg_length` x 4 - 16 - `pad`. The first byte is 0x1A
while `acf_msg_length` is below 256.

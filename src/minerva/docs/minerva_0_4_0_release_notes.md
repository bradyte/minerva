# Minerva 0.4.0 release notes

**Draft, 2026-10-06.** The contract and the transition plan from 0.3.x. The
build passes every bench; the notes are final when the hardware run passes and
`minerva-0.4.0` is tagged.

## Summary

0.4.0 splits minerva's one stream, a record followed by the payload, into two,
as taxi's zircon does: a metadata stream, `meta`, and a payload stream,
`payload`. The parser also stops dropping malformed AVTP frames and reports them
in the metadata instead. Function is otherwise unchanged: NTSCF with ABB, one
metadata block per ABB message. Frames on the wire do not change.

## What changes

| | 0.3.x | 0.4.0 |
| :--- | :--- | :--- |
| Streams | one: a 4-word record, then the payload | two: `meta`, then `payload` only when `payload_len` > 0 |
| Message without a payload | a record-only packet | metadata alone |
| Malformed AVTP frame | dropped | one metadata block with flags set, no payload |
| Other ethertypes and formats | dropped | route 1 (discard), dropped before the consumer |
| `tid` | format code, 0 | unused, 0 |
| `tdest` | 0 | 0 the consumer, 1 discard |
| `tuser` at `tlast` | truncated, on the record stream | truncated, on `payload` |
| Transmit input | 6-word record, then the payload, into `minerva_tx_deparse` | 8-word metadata, then `payload` only when `payload_len` > 0, into `minerva_tx` |
| Malformed transmit metadata | dropped | dropped, and its payload drained |

## What does not change

- Frames on the wire, both ways, so `echo_test.py` checks 0.4.0 as it did 0.3.x.
- The checks minerva applies; only what it does when one fails.
- Every metadata word is a value, bit 31 most significant; the payload is in
  wire order, first octet in lane 0, with the last beat's `tkeep` set by `pad`.
- ACF messages of other types are skipped, and a frame that ends inside a
  payload ends it with `tuser` = 1.

## Receive metadata

Six words per ABB message, `tlast` on word 5.

| Word | Bits | Field |
| :---: | :--- | :--- |
| 0 | 31:24 | `format`, the AVTP `subtype`: 0x82 for NTSCF |
| | 23:16 | `flags`, below |
| | 15:0 | `payload_len`, octets |
| 1 | 31:0 | `stream_id[63:32]` |
| 2 | 31:0 | `stream_id[31:0]` |
| 3 | 31 | `sv` |
| | 30:23 | `sequence_num` |
| | 22:19 | `mr`, `tv`, `tu`, `fs`: 0 for NTSCF |
| | 18:0 | reserved, 0 |
| 4 | 31:0 | ABB quadlet 0 as received: `acf_msg_type[31:25]`, `acf_msg_length[24:16]`, `pad[15:14]`, `mtv[13]`, `rsv[12:11]`, `byte_bus_id[10:0]` |
| 5 | 31:0 | ABB quadlet 1 as received |

| Flag | Word 0 bit | Set when |
| :--- | :---: | :--- |
| `ERR_EMPTY` | 16 | `ntscf_data_length` is 0 |
| `ERR_LEN` | 17 | `acf_msg_length` is below the header and pad, or runs past the data length |
| `ERR_TRUNC` | 18 | the frame ends before `ntscf_data_length` is used up, except after a payload has started, which ends with `tuser` instead |

A block with any flag set has `payload_len` 0, so no payload follows. A field
is filled only once its whole quadlet has arrived; the rest are 0. Messages
earlier in the same frame are delivered as usual, so a frame that ends between
two messages gives the first, then an `ERR_TRUNC` block.

## Mapping from the 0.3.x record

| 0.3.x | Field | 0.4.0 |
| :--- | :--- | :--- |
| w0 | `stream_id[63:32]` | w1 |
| w1 | `stream_id[31:0]` | w2 |
| w2[31:24] | `sequence_num` | w3[30:23] |
| w2[23] | `mtv` | w4[13] |
| w2[22:12] | `byte_bus_id` | w4[10:0] |
| w2[11] | `sv` | w3[31] |
| w2[10:0] | `payload_len` | w0[15:0] |
| w3 | ABB quadlet 1 | w5 |
| | `format`, `flags` | w0[31:16], new |
| | `acf_msg_type`, `acf_msg_length`, `pad` | w4[31:14], new |

## Migrating a consumer

1. Take two streams: `meta`, six words per message, and `payload`.
2. Read word 0 first. A nonzero `flags` is an error report with no payload;
   handle it and take the next metadata block.
3. Otherwise, if `payload_len` > 0, take exactly one packet from `payload`. If
   its `tuser` is 1 at `tlast`, the message was truncated: discard the message.
4. Decode the fields from their new positions, above.
5. Never drop a packet from one stream without the matching one from the other.

## Transmit metadata

Eight words, then `payload` only when `payload_len` > 0. Words 0 to 5 are the
receive layout, carrying the sender's own stream, `{LOCAL_MAC, 0}`; the
destination MAC is appended.

| Word | Field | From the 0.3.x transmit record |
| :---: | :--- | :--- |
| 0 | `format` 0x82, `flags` 0, `payload_len` | w2[10:0] |
| 1, 2 | `stream_id` | w0, w1 |
| 3 | `sv`, `sequence_num`; the rest 0 | w2 |
| 4 | `mtv`, `byte_bus_id` | w2 |
| 5 | ABB quadlet 1 | w3 |
| 6 | destination MAC `[47:16]` | w4 |
| 7 | destination MAC `[15:0]`, then 16 bits of 0 | w5 |

Minerva still fills in `acf_msg_type`, `acf_msg_length`, `pad` and
`ntscf_data_length` from `payload_len`, and ignores those bits of word 4. A
producer aborts a message with `tuser` = 1 at the payload's `tlast`; a message
without a payload is aborted by not sending it.

Metadata of another `format`, with `flags` set, with `payload_len` over 1480,
or of other than eight words gives no frame, and its payload, if it announces
one, is drained, so the messages after it stay paired.

`minerva_tx` replaces `minerva_tx_deparse` as the module to instantiate. Inside
it, `minerva_tx_deparse` now builds only the header, `minerva_tx_gate` makes
the payload follow it, and `taxi_axis_concat` joins the two.

## Migrating a producer

1. Instantiate `minerva_tx` (`minerva_tx.f`) in place of `minerva_tx_deparse`.
2. Send the eight metadata words, then one `payload` packet only when
   `payload_len` > 0.
3. Move the fields to their new positions, above.

## Staged migration

If a consumer cannot move in one step, a small bridge can rebuild the 0.3.x
stream from 0.4.0's: words 1 to 5 back into the 4-word record, the payload
appended, and error reports dropped. It is not planned unless needed.

## Verification

- Passed: the `minerva_rx_parse`, `minerva_tx` and loopback benches, covering
  both streams, the pairing rule, every flag, the discard route, and drop and
  drain on transmit.
- Passed: the Zedboard `fpga_core` bench, with `echo_server` on the new streams
  and the discard route dropped by a `taxi_axis_demux` on `tdest` into a
  `taxi_axis_null_snk`.
- To do: on hardware, `echo_test.py` (`-c 1000`, `-s` 13 to 15 and 1480,
  `-m 3`) echoes cleanly, and the build meets timing. Then `minerva-0.4.0` is
  tagged.

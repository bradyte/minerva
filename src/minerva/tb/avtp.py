#!/usr/bin/env python
# SPDX-License-Identifier: MIT
"""

Copyright (c) 2026 Tom Brady

Authors:
- Tom Brady

"""

import struct

SUBTYPE_NTSCF = 0x82
SUBTYPE_TSCF = 0x05

ACF_MSG_TYPE_CAN = 0x01
ACF_MSG_TYPE_GBB = 0x0D
ACF_MSG_TYPE_ABB = 0x0E

# format code on tid for each record layout
FORMAT_ABB = 0

# metadata routes on tdest, and the flags in metadata word 0 bits 23:16
ROUTE_CONSUMER = 0
ROUTE_DISCARD = 1

FLAG_ERR_EMPTY = 0x01
FLAG_ERR_LEN = 0x02
FLAG_ERR_TRUNC = 0x04


def abb_word0(byte_bus_id=0, mtv=0, payload_len=0,
              acf_msg_type=ACF_MSG_TYPE_ABB, acf_msg_length=None, pad=None):
    """ABB's first quadlet, as a value.

    acf_msg_type, acf_msg_length and pad default to their correct values for
    payload_len and can be overridden to build a malformed message.
    """
    fill = -payload_len % 4
    if pad is None:
        pad = fill
    if acf_msg_length is None:
        acf_msg_length = (8 + payload_len + fill) // 4
    return acf_msg_type << 25 | acf_msg_length << 16 | pad << 14 | mtv << 13 | byte_bus_id


def abb_word1(evt=0, hs=0, cs=0, transaction_num=0, op=0, rsp=0, err=0, ms=0, read_size=0):
    """ABB's second quadlet, as a value."""
    return (evt << 28 | hs << 25 | cs << 24 | transaction_num << 16 |
            op << 15 | rsp << 14 | err << 13 | ms << 12 | read_size)


def abb_message(byte_bus_id=0, mtv=0, word1=0, payload=b'',
                acf_msg_type=ACF_MSG_TYPE_ABB, acf_msg_length=None, pad=None):
    """An ABB message: header, payload, then zero bytes to a quadlet.

    acf_msg_type, acf_msg_length and pad default to their correct values and
    can be overridden to build a malformed message.
    """
    word0 = abb_word0(byte_bus_id, mtv, len(payload), acf_msg_type, acf_msg_length, pad)
    return struct.pack('>II', word0, word1) + payload + bytes(-len(payload) % 4)


def acf_message(acf_msg_type, body=b'', acf_msg_length=None):
    """An ACF message of any type: the common header quadlet, then the body and
    zero bytes to a quadlet.  The rest of the first quadlet is left zero."""
    fill = -len(body) % 4
    if acf_msg_length is None:
        acf_msg_length = (4 + len(body) + fill) // 4
    return struct.pack('>I', acf_msg_type << 25 | acf_msg_length << 16) + body + bytes(fill)


def ntscf_pdu(stream_id, sequence_num, messages, sv=1, version=0,
              subtype=SUBTYPE_NTSCF, ntscf_data_length=None):
    """An NTSCF AVTPDU carrying the given ACF messages back to back."""
    data = b''.join(messages)
    if ntscf_data_length is None:
        ntscf_data_length = len(data)
    word0 = subtype << 24 | sv << 23 | version << 20 | ntscf_data_length << 8 | sequence_num
    return struct.pack('>IQ', word0, stream_id) + data


def abb_record(stream_id, sequence_num, byte_bus_id, word1, payload_len, sv=1, mtv=0):
    """The four record words minerva sends for an ABB message, as the bytes a
    sink receives: each word is a value with bits 7:0 in lane 0."""
    word2 = sequence_num << 24 | mtv << 23 | byte_bus_id << 12 | sv << 11 | payload_len
    return struct.pack('<IIII', stream_id >> 32, stream_id & 0xffffffff, word2, word1)


def abb_packet(stream_id, sequence_num, byte_bus_id, word1, payload, sv=1, mtv=0):
    """The packet minerva sends for an ABB message: the record, then the
    payload without its pad."""
    return abb_record(stream_id, sequence_num, byte_bus_id, word1, len(payload), sv=sv, mtv=mtv) + payload


def meta(format=0, flags=0, payload_len=0, stream_id=0, sv=0, sequence_num=0, words=()):
    """A metadata block as the bytes a sink receives: each word is a value with
    bits 7:0 in lane 0.  Word 0 is {format, flags, payload_len}, words 1 and 2
    stream_id, word 3 {sv, sequence_num}, then the format's words."""
    w = [format << 24 | flags << 16 | payload_len,
         stream_id >> 32, stream_id & 0xffffffff,
         sv << 31 | sequence_num << 23, *words]
    return struct.pack(f'<{len(w)}I', *w)


def abb_meta(stream_id, sequence_num, byte_bus_id, word1, payload_len, sv=1, mtv=0):
    """The metadata minerva sends for an ABB message in an NTSCF PDU: ABB's
    two quadlets after the common words."""
    return meta(SUBTYPE_NTSCF, 0, payload_len, stream_id, sv, sequence_num,
                [abb_word0(byte_bus_id, mtv, payload_len), word1])


def abb_tx_meta(stream_id, sequence_num, byte_bus_id, word1, payload_len, dst_mac, sv=1, mtv=0):
    """The metadata a producer sends minerva_tx for an ABB message: the receive
    layout, then the destination address, bits 47:16 in word 6 and 15:0 in
    the top of word 7, whose low 16 bits are reserved as 0."""
    return (abb_meta(stream_id, sequence_num, byte_bus_id, word1, payload_len, sv=sv, mtv=mtv) +
            struct.pack('<II', dst_mac >> 16, (dst_mac & 0xffff) << 16))


def abb_tx_record(stream_id, sequence_num, byte_bus_id, word1, payload_len, dst_mac, sv=1, mtv=0):
    """The six record words minerva_tx_deparse takes for an ABB message, as
    the bytes a source sends: the RX record, then the destination address,
    bits 47:16 in word 4 and 15:0 in the top of word 5, whose low 16 bits are
    reserved as 0."""
    return (abb_record(stream_id, sequence_num, byte_bus_id, word1, payload_len, sv=sv, mtv=mtv) +
            struct.pack('<II', dst_mac >> 16, (dst_mac & 0xffff) << 16))


def abb_tx_packet(stream_id, sequence_num, byte_bus_id, word1, payload, dst_mac, sv=1, mtv=0):
    """The packet a producer sends minerva_tx_deparse for an ABB message: the
    six-word record, then the payload without its pad."""
    return abb_tx_record(stream_id, sequence_num, byte_bus_id, word1, len(payload), dst_mac, sv=sv, mtv=mtv) + payload

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
    fill = -len(payload) % 4
    if pad is None:
        pad = fill
    if acf_msg_length is None:
        acf_msg_length = (8 + len(payload) + fill) // 4
    word0 = acf_msg_type << 25 | acf_msg_length << 16 | pad << 14 | mtv << 13 | byte_bus_id
    return struct.pack('>II', word0, word1) + payload + bytes(fill)


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

# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#
# XFCP over the UART on Pmod JA, shared by the xfcp_*.py scripts.
#
# XFCP drops a bad request without replying, so every request has a timeout.
# Address and length field widths come from each module's ID reply.

import os
import select
import struct
import termios
import time

from xfcp import XfcpFrame

READ_REQ = 0x10
READ_RESP = 0x11
WRITE_REQ = 0x12
WRITE_RESP = 0x13
ID_REQ = 0xFE
ID_RESP = 0xFF


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)

    # raw 8N1 at 921600: no echo, line editing, translation or flow control
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0                                                # iflag
    attrs[1] = 0                                                # oflag
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL     # cflag
    attrs[3] = 0                                                # lflag
    attrs[4] = attrs[5] = termios.B921600                       # ispeed, ospeed
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)

    # discard anything left over from before
    termios.tcflush(fd, termios.TCIOFLUSH)

    return fd


def request(fd, pkt, timeout):
    data = pkt.build_cobs()
    while data:
        data = data[os.write(fd, data):]

    # collect the reply up to its 00 end marker
    rx_data = bytearray()
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise TimeoutError(f'no reply to {pkt}')
        b = os.read(fd, 1)
        if b == b'\x00':
            break
        rx_data.extend(b)

    return XfcpFrame.parse_cobs(rx_data)


def identify(fd, path, timeout):
    rsp = request(fd, XfcpFrame(path=path, ptype=ID_REQ), timeout)
    if rsp.path != path or rsp.ptype != ID_RESP:
        raise RuntimeError(f'unexpected reply {rsp}')
    return rsp.payload


def id_str(rom, offset):
    return rom[offset:offset+16].rstrip(b'\x00').decode('ascii')


def field_widths(rom):
    # taxi_xfcp_mod_axil and _apb ID: type, address width, data width, word size, count size
    addr_w, data_w, word_w, count_w = struct.unpack_from('<4H', rom, 2)
    if word_w != 8:
        raise RuntimeError(f'{word_w} bit words are not handled')
    return (addr_w+7)//8, (count_w+7)//8


def _header(widths, addr, length):
    addr_bytes, count_bytes = widths
    return addr.to_bytes(addr_bytes, 'little') + length.to_bytes(count_bytes, 'little')


def read(fd, path, widths, addr, length, timeout):
    hdr = _header(widths, addr, length)

    rsp = request(fd, XfcpFrame(path=path, ptype=READ_REQ, payload=hdr), timeout)

    # the reply carries the path back, and echoes the address and length
    if rsp.path != path or rsp.ptype != READ_RESP or rsp.payload[:len(hdr)] != hdr:
        raise RuntimeError(f'unexpected reply {rsp}')

    return rsp.payload[len(hdr):]


def write(fd, path, widths, addr, data, timeout):
    hdr = _header(widths, addr, len(data))

    rsp = request(fd, XfcpFrame(path=path, ptype=WRITE_REQ, payload=hdr + bytes(data)), timeout)

    # the module writes upward from addr, and replies once the last byte is done
    if rsp.path != path or rsp.ptype != WRITE_RESP or rsp.payload[:len(hdr)] != hdr:
        raise RuntimeError(f'unexpected reply {rsp}')

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#
# Read the MAC statistics over XFCP, through the UART on Pmod JA.
#
#   ./xfcp_stats.py                        # /dev/ttyACM0
#   ./xfcp_stats.py -p /dev/ttyUSB0
#
# XFCP drops a bad request without replying, so every request has a timeout.
# Address and length field widths come from each module's ID reply.

import argparse
import os
import select
import struct
import sys
import termios
import time

from xfcp import XfcpFrame

READ_REQ = 0x10
READ_RESP = 0x11
ID_REQ = 0xFE
ID_RESP = 0xFF

# switch port 0 is the statistics module: its port 0 holds the 64-bit
# counters, its port 1 their names
PATH_SWITCH = []
PATH_STAT_COUNT = [0, 0]
PATH_STAT_STR = [0, 1]

# the MAC's counter slots, STAT_ID_BASE 0 at level 1: TX 0-15, RX 16-31
STAT_COUNT = 32


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
    # taxi_xfcp_mod_axil ID: type, address width, data width, word size, count size
    addr_w, data_w, word_w, count_w = struct.unpack_from('<4H', rom, 2)
    if word_w != 8:
        raise RuntimeError(f'{word_w} bit words are not handled')
    return (addr_w+7)//8, (count_w+7)//8


def read(fd, path, widths, addr, length, timeout):
    addr_bytes, count_bytes = widths
    hdr = addr.to_bytes(addr_bytes, 'little') + length.to_bytes(count_bytes, 'little')

    rsp = request(fd, XfcpFrame(path=path, ptype=READ_REQ, payload=hdr), timeout)

    # the reply carries the path back, and echoes the address and length
    if rsp.path != path or rsp.ptype != READ_RESP or rsp.payload[:len(hdr)] != hdr:
        raise RuntimeError(f'unexpected reply {rsp}')

    return rsp.payload[len(hdr):]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('-p', '--port', default='/dev/ttyACM0')
    p.add_argument('-t', '--timeout', type=float, default=0.5,
                   help='per-request wait for the reply, in seconds')
    args = p.parse_args()

    fd = open_port(args.port)

    try:
        rom = identify(fd, PATH_SWITCH, args.timeout)
        print(f'{id_str(rom, 16)} / {id_str(rom, 48)}')

        count_widths = field_widths(identify(fd, PATH_STAT_COUNT, args.timeout))
        str_widths = field_widths(identify(fd, PATH_STAT_STR, args.timeout))

        for n in range(STAT_COUNT):
            # 8 byte prefix, 8 byte name, space padded; unused slots have no name
            s = read(fd, PATH_STAT_STR, str_widths, n*16, 16, args.timeout)
            prefix, name = s[0:8].strip(b' \x00'), s[8:].strip(b' \x00')
            if not name:
                continue

            val = int.from_bytes(read(fd, PATH_STAT_COUNT, count_widths, n*8, 8, args.timeout), 'little')

            label = (prefix + b'.' + name).decode('ascii')
            print(f'{label:<16} {val:>12}')

    except (TimeoutError, RuntimeError) as e:
        sys.exit(str(e))

    finally:
        os.close(fd)


if __name__ == '__main__':
    main()

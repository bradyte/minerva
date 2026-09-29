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

import argparse
import os
import sys

from xfcp_uart import open_port, identify, id_str, field_widths, read

# switch port 0 is the statistics module: its port 0 holds the 64-bit
# counters, its port 1 their names
PATH_SWITCH = []
PATH_STAT_COUNT = [0, 0]
PATH_STAT_STR = [0, 1]

# the MAC's counter slots, STAT_ID_BASE 0 at level 1: TX 0-15, RX 16-31
STAT_COUNT = 32


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

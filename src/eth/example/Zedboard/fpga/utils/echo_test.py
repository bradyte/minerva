#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#
# Send broadcast frames at the board and count what it echoes back.
#
#   sudo ./echo_test.py enp1s0                     # MAC loopback: byte-identical
#   sudo ./echo_test.py enp1s0 -e 0x22f0 -b 02:00:00:00:00:01
#                                                  # AVTP echo through minerva
#
# With --board-mac the echo must carry that source address and be otherwise
# identical.  Packet sockets see the outbound copy too, which is why
# PACKET_OUTGOING is filtered out.

import argparse
import socket
import statistics
import struct
import sys
import time

ETH_P_ALL = 0x0003
# IEEE local experimental ethertype
ETH_TYPE = 0x88B5
MAGIC = b'ZEDECHO0'
BROADCAST = b'\xff' * 6
# locally administered, so it cannot collide with a real card
SRC_MAC = b'\x02\x00\x00\x00\x00\x02'
MIN_FRAME = 60


def build(seq, size, ethertype):
    payload = MAGIC + struct.pack('!I', seq)
    payload += bytes((i + seq) & 0xff for i in range(max(0, size - 14 - len(payload))))
    frame = BROADCAST + SRC_MAC + struct.pack('!H', ethertype) + payload
    return frame.ljust(MIN_FRAME, b'\x00')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('iface')
    p.add_argument('-c', '--count', type=int, default=100)
    p.add_argument('-s', '--size', type=int, default=64,
                   help='frame size in bytes, excluding FCS')
    p.add_argument('-t', '--timeout', type=float, default=0.5,
                   help='per-frame wait for the echo, in seconds')
    p.add_argument('-i', '--interval', type=float, default=0.01)
    p.add_argument('-d', '--duration', type=float, default=None,
                   help='run for this many seconds instead of a fixed count')
    p.add_argument('-q', '--quiet', action='store_true',
                   help='do not print a line per lost frame')
    p.add_argument('-e', '--ethertype', type=lambda x: int(x, 0), default=ETH_TYPE)
    p.add_argument('-b', '--board-mac', type=lambda x: bytes.fromhex(x.replace(':', '')),
                   default=None, help='source address the echo must carry')
    args = p.parse_args()

    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    sock.bind((args.iface, 0))

    sent = 0
    echoed = 0
    corrupt = 0
    rtt = []

    started = time.perf_counter()
    seq = -1
    while True:
        seq += 1
        if args.duration is None:
            if seq >= args.count:
                break
        elif time.perf_counter() - started >= args.duration:
            break

        frame = build(seq, args.size, args.ethertype)
        expect = frame if args.board_mac is None else frame[:6] + args.board_mac + frame[12:]
        sock.settimeout(args.timeout)
        t0 = time.perf_counter()
        sock.send(frame)
        sent += 1

        deadline = t0 + args.timeout
        while True:
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                if not args.quiet:
                    print(f'seq {seq}: no echo')
                break
            sock.settimeout(remaining)
            try:
                data, addr = sock.recvfrom(2048)
            except socket.timeout:
                if not args.quiet:
                    print(f'seq {seq}: no echo')
                break
            # addr = (ifname, proto, pkttype, hatype, hwaddr)
            if addr[2] == socket.PACKET_OUTGOING:
                continue
            if data[12:14] != struct.pack('!H', args.ethertype):
                continue
            if data[14:22] != MAGIC:
                continue
            if struct.unpack('!I', data[22:26])[0] != seq & 0xffffffff:
                continue
            rtt.append((time.perf_counter() - t0) * 1e6)
            if data[:len(expect)] == expect:
                echoed += 1
            else:
                corrupt += 1
                print(f'seq {seq}: echoed with altered content')
            break

        time.sleep(args.interval)

    print(f'elapsed   {time.perf_counter() - started:.1f} s')
    print(f'sent      {sent}')
    print(f'echoed    {echoed}')
    print(f'corrupt   {corrupt}')
    print(f'lost      {sent - echoed - corrupt}')
    if rtt:
        print(f'rtt us    min {min(rtt):.0f}  median {statistics.median(rtt):.0f}  max {max(rtt):.0f}')

    return 0 if echoed == sent else 1


if __name__ == '__main__':
    sys.exit(main())

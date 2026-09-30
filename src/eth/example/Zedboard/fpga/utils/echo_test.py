#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#
# Send NTSCF requests carrying ABB messages at the board and check that each
# message comes back, rebuilt by the record echo from minerva's record.
#
#   sudo ./echo_test.py enp1s0                     # 12-byte payloads
#   sudo ./echo_test.py enp1s0 -s 1480             # the largest payload
#   sudo ./echo_test.py enp1s0 -m 3                # three messages per request
#
# The stream_id carries this interface's address, so each echo comes back to
# it from the board's address, alone in its own PDU and otherwise identical to
# the message sent.  Packet sockets see the outbound copy too, which is why
# PACKET_OUTGOING is filtered out.

import argparse
import socket
import statistics
import struct
import sys
import time

import avtp

ETH_P_ALL = 0x0003
ETHERTYPE_AVTP = 0x22F0
MAGIC = b'ZEDECHO0'
BROADCAST = b'\xff' * 6
# LOCAL_MAC in fpga_core
BOARD_MAC = b'\x02\x00\x00\x00\x00\x01'
MIN_FRAME = 60
# the largest NTSCF payload a frame holds
MAX_DATA = 1500 - 12
# an ABB payload starts after the L2, NTSCF and ABB headers
PAYLOAD_OFFSET = 14 + 12 + 8
UNIQUE_ID = 0x0001


def build(host_mac, board_mac, seq, size, messages):
    """A request holding ABB messages with size-byte payloads, and the echo
    expected for each.  The fields vary with seq so every record field is
    exercised."""
    stream_id = int.from_bytes(host_mac, 'big') << 16 | UNIQUE_ID
    sequence_num = seq & 0xff
    msgs = []
    echoes = []
    for k in range(messages):
        n = seq * messages + k
        payload = MAGIC + struct.pack('!I', seq & 0xffffffff)
        payload += bytes((i + n) & 0xff for i in range(size - len(payload)))
        word1 = avtp.abb_word1(evt=n & 0xf, transaction_num=n & 0xff, op=n & 1, read_size=n & 0xfff)
        msg = avtp.abb_message(n & 0x7ff, n & 1, word1, payload)
        msgs.append(msg)
        pdu = avtp.ntscf_pdu(stream_id, sequence_num, [msg])
        echoes.append((host_mac + board_mac + struct.pack('!H', ETHERTYPE_AVTP) + pdu).ljust(MIN_FRAME, b'\x00'))
    pdu = avtp.ntscf_pdu(stream_id, sequence_num, msgs)
    frame = BROADCAST + host_mac + struct.pack('!H', ETHERTYPE_AVTP) + pdu
    return frame.ljust(MIN_FRAME, b'\x00'), echoes


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('iface')
    p.add_argument('-c', '--count', type=int, default=100)
    p.add_argument('-s', '--size', type=int, default=12,
                   help='ABB payload bytes per message, 12 to 1480')
    p.add_argument('-m', '--messages', type=int, default=1,
                   help='ABB messages per request, each echoed in its own frame')
    p.add_argument('-t', '--timeout', type=float, default=0.5,
                   help='per-request wait for the echoes, in seconds')
    p.add_argument('-i', '--interval', type=float, default=0.01)
    p.add_argument('-d', '--duration', type=float, default=None,
                   help='run for this many seconds instead of a fixed count')
    p.add_argument('-q', '--quiet', action='store_true',
                   help='do not print a line per lost echo')
    p.add_argument('-b', '--board-mac', type=lambda x: bytes.fromhex(x.replace(':', '')),
                   default=BOARD_MAC, help='source address the echoes must carry')
    args = p.parse_args()

    if args.size < len(MAGIC) + 4 or args.messages < 1:
        p.error('each payload needs 12 bytes for the magic and the count')
    if args.messages * (8 + args.size + -args.size % 4) > MAX_DATA:
        p.error('the messages do not fit in one frame')

    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    sock.bind((args.iface, 0))

    # this interface's address goes in stream_id, so the echoes come back to it
    host_mac = sock.getsockname()[4]

    sent = 0
    expected = 0
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

        frame, echoes = build(host_mac, args.board_mac, seq, args.size, args.messages)
        pending = list(echoes)
        t0 = time.perf_counter()
        sock.send(frame)
        sent += 1
        expected += len(echoes)

        deadline = t0 + args.timeout
        while pending:
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                break
            sock.settimeout(remaining)
            try:
                data, addr = sock.recvfrom(2048)
            except socket.timeout:
                break
            # addr = (ifname, proto, pkttype, hatype, hwaddr)
            if addr[2] == socket.PACKET_OUTGOING:
                continue
            if data[12:14] != struct.pack('!H', ETHERTYPE_AVTP):
                continue
            if data[PAYLOAD_OFFSET:PAYLOAD_OFFSET + 8] != MAGIC:
                continue
            if struct.unpack('!I', data[PAYLOAD_OFFSET + 8:PAYLOAD_OFFSET + 12])[0] != seq & 0xffffffff:
                continue
            rtt.append((time.perf_counter() - t0) * 1e6)
            for echo in pending:
                if data[:len(echo)] == echo:
                    pending.remove(echo)
                    echoed += 1
                    break
            else:
                pending.pop()
                corrupt += 1
                print(f'seq {seq}: echoed with altered content')

        if pending and not args.quiet:
            print(f'seq {seq}: {len(pending)} of {len(echoes)} echoes missing')

        time.sleep(args.interval)

    print(f'elapsed   {time.perf_counter() - started:.1f} s')
    print(f'sent      {sent}')
    print(f'expected  {expected}')
    print(f'echoed    {echoed}')
    print(f'corrupt   {corrupt}')
    print(f'lost      {expected - echoed - corrupt}')
    if rtt:
        print(f'rtt us    min {min(rtt):.0f}  median {statistics.median(rtt):.0f}  max {max(rtt):.0f}')

    return 0 if echoed == expected else 1


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#
# Read and write the Zedboard registers over XFCP, by name.  The map is
# compiled from ../rdl/zedboard_regs.rdl on every run, so run it with the repo
# .venv active (it needs systemrdl-compiler).
#
#   ./xfcp_regs.py                         # build time, PHY and IDELAY summary
#   ./xfcp_regs.py dump                    # every register, with its fields
#   ./xfcp_regs.py read PHY_STATUS
#   ./xfcp_regs.py read BUILD_ID           # BUILD_ID_0..3 as one value, LSB first
#   ./xfcp_regs.py write SCRATCH 0x5a
#   ./xfcp_regs.py mdio 0x02               # MDIO read at the scanned PHY address
#   ./xfcp_regs.py mdio 0x10 0xff23        # MDIO write

import argparse
import os
import sys

from systemrdl import RDLCompiler, RegNode

from xfcp_uart import open_port, identify, id_str, field_widths, read, write

RDL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'rdl', 'zedboard_regs.rdl')

# switch port 1 is the register block
PATH_SWITCH = []
PATH_REGS = [1]


def load_map(path):
    rdlc = RDLCompiler()
    rdlc.compile_file(path)
    root = rdlc.elaborate()
    return {n.inst_name: n for n in root.top.descendants(unroll=True) if isinstance(n, RegNode)}


def build_time(v):
    # USR_ACCESS TIMESTAMP: day 5, month 4, year-2000 6, hour 5, minute 6, second 6 bits
    return (f'{2000 + (v >> 17 & 0x3f):04d}-{v >> 23 & 0xf:02d}-{v >> 27 & 0x1f:02d} '
            f'{v >> 12 & 0x1f:02d}:{v >> 6 & 0x3f:02d}:{v & 0x3f:02d}')


class Regs:
    def __init__(self, fd, timeout):
        self.fd = fd
        self.timeout = timeout
        self.map = load_map(RDL)
        self.widths = field_widths(identify(fd, PATH_REGS, timeout))

    def span(self, name):
        # a register, or NAME_0..NAME_n taken together, LSB first
        if name in self.map:
            return [self.map[name]]
        regs = []
        while f'{name}_{len(regs)}' in self.map:
            regs.append(self.map[f'{name}_{len(regs)}'])
        if not regs:
            raise KeyError(f'no register {name}')
        return regs

    def read(self, name):
        regs = self.span(name)
        data = read(self.fd, PATH_REGS, self.widths, regs[0].absolute_address, len(regs), self.timeout)
        return int.from_bytes(data, 'little')

    def write(self, name, value):
        regs = self.span(name)
        if not any(f.is_sw_writable for r in regs for f in r.fields()):
            raise KeyError(f'{name} is read-only')
        write(self.fd, PATH_REGS, self.widths, regs[0].absolute_address,
              value.to_bytes(len(regs), 'little'), self.timeout)

    def field(self, name, field):
        return next(f for f in self.map[name].fields() if f.inst_name == field)

    def fields(self, name, value):
        reg = self.map.get(name)
        if reg is None or len(reg.fields()) < 2:
            return ''
        return ' '.join(f'{f.inst_name}={value >> f.lsb & ((1 << f.width) - 1)}' for f in reg.fields())

    def mdio(self, reg_addr, data=None):
        self.write('MDIO_REG', reg_addr)
        if data is not None:
            self.write('MDIO_WDATA', data)

        # go last: the PHY only sees the request once it is complete
        go = 1 << self.field('MDIO_CTRL', 'go').lsb
        wr = 1 << self.field('MDIO_CTRL', 'write').lsb
        busy = 1 << self.field('MDIO_CTRL', 'busy').lsb
        self.write('MDIO_CTRL', go | (wr if data is not None else 0))

        for k in range(100):
            if not self.read('MDIO_CTRL') & busy:
                return self.read('MDIO_RDATA')
        raise TimeoutError('MDIO request still busy')


def summary(regs):
    build_id = regs.read('BUILD_ID')
    print(f'build     {build_time(build_id)}  (BUILD_ID 0x{build_id:08x})')
    status = regs.read('PHY_STATUS')
    print(f'PHY       {regs.fields("PHY_STATUS", status)}, MDIO address {regs.read("PHY_ADDR")}')
    print(f'IDELAY    tap {regs.read("IDELAY_TAP")}')


def dump(regs):
    for name, reg in sorted(regs.map.items(), key=lambda kv: kv[1].absolute_address):
        value = regs.read(name)
        print(f'0x{reg.absolute_address:04x}  {name:<14} 0x{value:02x}  {regs.fields(name, value)}')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('-p', '--port', default='/dev/ttyACM0')
    p.add_argument('-t', '--timeout', type=float, default=0.5,
                   help='per-request wait for the reply, in seconds')
    p.add_argument('cmd', nargs='?', default='summary', choices=['summary', 'dump', 'read', 'write', 'mdio'])
    p.add_argument('args', nargs='*')
    args = p.parse_args()

    fd = open_port(args.port)

    try:
        rom = identify(fd, PATH_SWITCH, args.timeout)
        print(f'{id_str(rom, 16)} / {id_str(rom, 48)}')

        regs = Regs(fd, args.timeout)

        if args.cmd == 'summary':
            summary(regs)

        elif args.cmd == 'dump':
            dump(regs)

        elif args.cmd == 'read':
            name, = args.args
            value = regs.read(name)
            print(f'{name} = 0x{value:0{2*len(regs.span(name))}x}  {regs.fields(name, value)}')

        elif args.cmd == 'write':
            name, value = args.args
            regs.write(name, int(value, 0))

        elif args.cmd == 'mdio':
            reg_addr = int(args.args[0], 0)
            if len(args.args) > 1:
                regs.mdio(reg_addr, int(args.args[1], 0))
            else:
                print(f'MDIO 0x{reg_addr:02x} = 0x{regs.mdio(reg_addr):04x}')

    except (TimeoutError, RuntimeError, KeyError, ValueError) as e:
        sys.exit(str(e))

    finally:
        os.close(fd)


if __name__ == '__main__':
    main()

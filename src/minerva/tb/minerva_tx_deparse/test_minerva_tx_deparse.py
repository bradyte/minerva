#!/usr/bin/env python
# SPDX-License-Identifier: MIT
"""

Copyright (c) 2026 Tom Brady

Authors:
- Tom Brady

"""

import itertools
import logging
import os
import sys

from scapy.layers.l2 import Ether
from scapy.packet import Raw

import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.regression import TestFactory

from cocotbext.axi import AxiStreamBus, AxiStreamSource, AxiStreamSink

try:
    from axis_stable import check_axis_stable
except ImportError:
    # attempt import from current directory
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    try:
        from axis_stable import check_axis_stable
    finally:
        del sys.path[0]


ETHERTYPE_AVTP = 0x22F0
ETHERTYPE_PTP = 0x88F7

# matches PARAM_LOCAL_MAC; every byte differs so a misplaced lane shows
LOCAL_MAC = '5A:51:52:53:54:55'


class TB(object):
    def __init__(self, dut):
        self.dut = dut

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk, 8, units="ns").start())

        self.source = AxiStreamSource(AxiStreamBus.from_entity(dut.s_axis_eth_tx), dut.clk, dut.rst)
        self.sink = AxiStreamSink(AxiStreamBus.from_entity(dut.m_axis_mac_tx), dut.clk, dut.rst)

        cocotb.start_soon(check_axis_stable(self.sink.bus, dut.clk, dut.rst))

    def set_idle_generator(self, generator=None):
        if generator:
            self.source.set_pause_generator(generator())

    def set_backpressure_generator(self, generator=None):
        if generator:
            self.sink.set_pause_generator(generator())

    async def reset(self):
        self.dut.rst.setimmediatevalue(0)
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)
        self.dut.rst.value = 1
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)
        self.dut.rst.value = 0
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)


def prefixed(dst, ethertype, payload):
    """Deparser input: destination and ethertype in wire order, then payload."""
    return bytes.fromhex(dst.replace(':', '')) + ethertype.to_bytes(2, 'big') + payload


def l2_frame(dst, ethertype, payload):
    return bytes(Ether(dst=dst, src=LOCAL_MAC, type=ethertype) / Raw(payload))


def payload_data(n, seed):
    return bytes((seed + k) & 0xff for k in range(n))


def last_tuser(frame):
    return frame.tuser[-1] if isinstance(frame.tuser, list) else frame.tuser


async def run_test_frame(dut, idle_inserter=None, backpressure_inserter=None):
    """The header comes out in wire order at every tail alignment."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    test_frames = []

    for ethertype in (ETHERTYPE_AVTP, ETHERTYPE_PTP):
        for dst in ('DA:D1:D2:D3:D4:D5', 'FF:FF:FF:FF:FF:FF'):
            for n in list(range(1, 9)) + list(range(46, 54)) + [1500]:
                payload = payload_data(n, len(test_frames))
                test_frames.append((prefixed(dst, ethertype, payload), l2_frame(dst, ethertype, payload)))

    for pkt, _ in test_frames:
        await tb.source.send(pkt)

    for _, frame in test_frames:
        rx_frame = await tb.sink.recv()

        assert bytes(rx_frame.tdata) == frame
        assert rx_frame.tuser == 0

    assert tb.sink.empty()

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


async def run_test_bad_prefix(dut, idle_inserter=None, backpressure_inserter=None):
    """A packet ending inside the prefix is closed out bad, neighbours intact."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    dst = 'DA:D1:D2:D3:D4:D5'
    good = prefixed(dst, ETHERTYPE_AVTP, payload_data(46, 1))
    later = prefixed(dst, ETHERTYPE_PTP, payload_data(47, 2))

    # (input packet, expected frame or None if it must be marked bad)
    test_pkts = [
        (good, l2_frame(dst, ETHERTYPE_AVTP, payload_data(46, 1))),
        # ends in the first prefix word
        (good[:4], None),
        # ends in the second prefix word
        (good[:6], None),
        # prefix but no payload
        (good[:8], None),
        (later, l2_frame(dst, ETHERTYPE_PTP, payload_data(47, 2))),
    ]

    for pkt, _ in test_pkts:
        await tb.source.send(pkt)

    for _, frame in test_pkts:
        rx_frame = await tb.sink.recv()

        if frame is None:
            assert last_tuser(rx_frame) == 1
        else:
            assert bytes(rx_frame.tdata) == frame
            assert rx_frame.tuser == 0

    assert tb.sink.empty()

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


def cycle_pause():
    return itertools.cycle([1, 1, 1, 0])


if getattr(cocotb, 'top', None) is not None:

    for test in [run_test_frame, run_test_bad_prefix]:

        factory = TestFactory(test)
        factory.add_option("idle_inserter", [None, cycle_pause])
        factory.add_option("backpressure_inserter", [None, cycle_pause])
        factory.generate_tests()


# cocotb-test

tests_dir = os.path.abspath(os.path.dirname(__file__))
rtl_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'rtl'))
lib_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'lib'))
taxi_src_dir = os.path.abspath(os.path.join(lib_dir, 'taxi', 'src'))


def process_f_files(files):
    lst = {}
    for f in files:
        if f[-2:].lower() == '.f':
            with open(f, 'r') as fp:
                l = fp.read().split()
            for f in process_f_files([os.path.join(os.path.dirname(f), x) for x in l]):
                lst[os.path.basename(f)] = f
        else:
            lst[os.path.basename(f)] = f
    return list(lst.values())


def test_minerva_tx_deparse(request):
    dut = "minerva_tx_deparse"
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = module

    verilog_sources = [
        os.path.join(tests_dir, f"{toplevel}.sv"),
        os.path.join(rtl_dir, f"{dut}.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_if.sv"),
    ]

    verilog_sources = process_f_files(verilog_sources)

    parameters = {}

    parameters['LOCAL_MAC'] = "48'h5A5152535455"

    extra_env = {f'PARAM_{k}': str(v) for k, v in parameters.items()}

    sim_build = os.path.join(tests_dir, "sim_build",
        request.node.name.replace('[', '-').replace(']', ''))

    cocotb_test.simulator.run(
        simulator="verilator",
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        toplevel=toplevel,
        module=module,
        parameters=parameters,
        sim_build=sim_build,
        extra_env=extra_env,
    )

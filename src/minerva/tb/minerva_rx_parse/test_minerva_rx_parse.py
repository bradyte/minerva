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

from scapy.layers.l2 import Ether, Dot1Q, Dot1AD
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

# demux port per routed ethertype, as in the RTL route table; PTP has no
# route yet, so it is dropped
ROUTE = {ETHERTYPE_AVTP: 0}


class TB(object):
    def __init__(self, dut):
        self.dut = dut

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk, 8, units="ns").start())

        self.source = AxiStreamSource(AxiStreamBus.from_entity(dut.s_axis_mac_rx), dut.clk, dut.rst)
        self.sink = AxiStreamSink(AxiStreamBus.from_entity(dut.m_axis_eth_rx), dut.clk, dut.rst)

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


def l2_frame(ethertype, payload, vlan=None):
    eth = Ether(src='5A:51:52:53:54:55', dst='DA:D1:D2:D3:D4:D5')
    if vlan == 'c':
        pkt = eth / Dot1Q(vlan=123, type=ethertype)
    elif vlan == 's':
        pkt = eth / Dot1AD(vlan=456, type=ethertype)
    else:
        eth.type = ethertype
        pkt = eth
    return bytes(pkt / Raw(payload))


def payload_data(n, seed):
    return bytes((seed + k) & 0xff for k in range(n))


async def run_test_route(dut, idle_inserter=None, backpressure_inserter=None):
    """Every routed ethertype, tagged or not, at every tail alignment."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    test_frames = []

    for ethertype in ROUTE:
        for vlan in (None, 'c', 's'):
            for n in list(range(46, 54)) + [1500]:
                payload = payload_data(n, len(test_frames))
                test_frames.append((l2_frame(ethertype, payload, vlan), payload, ROUTE[ethertype]))

    for frame, _, _ in test_frames:
        await tb.source.send(frame)

    for _, payload, route in test_frames:
        rx_frame = await tb.sink.recv()

        assert bytes(rx_frame.tdata) == payload
        assert rx_frame.tdest == route

    assert tb.sink.empty()

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


async def run_test_drop(dut, idle_inserter=None, backpressure_inserter=None):
    """Unrouted and runt frames vanish without disturbing their neighbours."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    hdr = l2_frame(ETHERTYPE_AVTP, b'')

    # (frame, expected payload or None if dropped, route)
    test_frames = [
        (l2_frame(ETHERTYPE_AVTP, payload_data(46, 1)), payload_data(46, 1), ROUTE[ETHERTYPE_AVTP]),
        # ethertype not in the route table
        (l2_frame(0x0800, payload_data(46, 2)), None, None),
        (l2_frame(0x0806, payload_data(46, 3), vlan='c'), None, None),
        # a second tag is not accepted
        (bytes(Ether() / Dot1AD(vlan=456) / Dot1Q(vlan=123, type=ETHERTYPE_AVTP) / Raw(payload_data(46, 4))), None, None),
        (l2_frame(ETHERTYPE_PTP, payload_data(46, 8)), None, None),
        (l2_frame(ETHERTYPE_AVTP, payload_data(50, 5), vlan='c'), payload_data(50, 5), ROUTE[ETHERTYPE_AVTP]),
        # runts ending inside the addresses, at the ethertype, and inside the
        # ethertype word
        (hdr[:10], None, None),
        (hdr, None, None),
        (l2_frame(ETHERTYPE_AVTP, payload_data(2, 6)), None, None),
        (l2_frame(ETHERTYPE_AVTP, b'', vlan='c'), None, None),
        (l2_frame(ETHERTYPE_AVTP, payload_data(47, 7)), payload_data(47, 7), ROUTE[ETHERTYPE_AVTP]),
    ]

    for frame, _, _ in test_frames:
        await tb.source.send(frame)

    for _, payload, route in test_frames:
        if payload is None:
            continue

        rx_frame = await tb.sink.recv()

        assert bytes(rx_frame.tdata) == payload
        assert rx_frame.tdest == route

    # let any wrongly forwarded frame surface
    await tb.source.wait()
    for k in range(20):
        await RisingEdge(dut.clk)

    assert tb.sink.empty()


def cycle_pause():
    return itertools.cycle([1, 1, 1, 0])


if getattr(cocotb, 'top', None) is not None:

    for test in [run_test_route, run_test_drop]:

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


def test_minerva_rx_parse(request):
    dut = "minerva_rx_parse"
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = module

    verilog_sources = [
        os.path.join(tests_dir, f"{toplevel}.sv"),
        os.path.join(rtl_dir, f"{dut}.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_if.sv"),
    ]

    verilog_sources = process_f_files(verilog_sources)

    parameters = {}

    parameters['VLAN_EN'] = 1
    parameters['DEST_W'] = 1

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

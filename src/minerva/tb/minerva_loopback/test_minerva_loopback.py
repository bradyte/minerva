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

import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.regression import TestFactory

from cocotbext.axi import AxiStreamBus, AxiStreamFrame, AxiStreamSource, AxiStreamSink, AxiStreamMonitor

try:
    from axis_stable import check_axis_stable
    import avtp
except ImportError:
    # attempt import from current directory
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    try:
        from axis_stable import check_axis_stable
        import avtp
    finally:
        del sys.path[0]


ETHERTYPE_AVTP = 0x22F0

# demux port for AVTP, as in the RTL route table
ROUTE_AVTP = 0

# every byte differs so a misplaced lane shows
LOCAL_MAC = 0x5A5152535455

# the talker's stream: the local MAC, UniqueID 0
STREAM_ID = LOCAL_MAC << 16


class TB(object):
    def __init__(self, dut):
        self.dut = dut

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk, 8, units="ns").start())

        self.source = AxiStreamSource(AxiStreamBus.from_entity(dut.s_axis_eth_tx), dut.clk, dut.rst)
        self.wire = AxiStreamMonitor(AxiStreamBus.from_entity(dut.axis_wire), dut.clk, dut.rst)
        self.sink = AxiStreamSink(AxiStreamBus.from_entity(dut.m_axis_eth_rx), dut.clk, dut.rst)

        cocotb.start_soon(check_axis_stable(self.wire.bus, dut.clk, dut.rst))
        cocotb.start_soon(check_axis_stable(self.sink.bus, dut.clk, dut.rst))

        dut.cfg_local_mac.setimmediatevalue(LOCAL_MAC)

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


def payload_data(n, seed):
    return bytes((seed + k) & 0xff for k in range(n))


def last_tuser(frame):
    return frame.tuser[-1] if isinstance(frame.tuser, list) else frame.tuser


def message(k, payload, sv=1):
    """The packet a producer sends for an ABB message with fields varied by k,
    its destination, and the packet a consumer must receive for it: the same
    record without the destination words, and the same payload."""
    dst = 0x02D1D2D3D400 | (k & 0xff)
    sequence_num = (0xfd + k) & 0xff
    byte_bus_id = (0x5ff + 0x123 * k) & 0x7ff
    mtv = k & 1
    word1 = avtp.abb_word1(evt=k & 0xf, hs=k & 1, cs=(k >> 1) & 1,
                           transaction_num=(0x40 + k) & 0xff, op=(k >> 2) & 1,
                           rsp=(k >> 3) & 1, err=(k >> 1) & 1, ms=k & 1,
                           read_size=(0xbff - k) & 0xfff)
    tx_pkt = avtp.abb_tx_packet(STREAM_ID, sequence_num, byte_bus_id, word1, payload, dst, sv=sv, mtv=mtv)
    rx_pkt = avtp.abb_packet(STREAM_ID, sequence_num, byte_bus_id, word1, payload, sv=sv, mtv=mtv)
    return tx_pkt, dst, rx_pkt


async def run_test_loopback(dut, idle_inserter=None, backpressure_inserter=None):
    """A record sent to the wire comes back unchanged: the consumer gets the
    producer's record without its destination words, and the same payload,
    while the wire carries the destination and the local MAC."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    test_msgs = []

    # every pad twice over, sv both ways, and the largest payload a frame holds
    for n in list(range(9)) + [1480]:
        k = len(test_msgs)
        test_msgs.append(message(k, payload_data(n, k), sv=(k >> 1) & 1))

    for tx_pkt, _, _ in test_msgs:
        await tb.source.send(AxiStreamFrame(tx_pkt, tid=avtp.FORMAT_ABB, tdest=ROUTE_AVTP, tuser=0))

    for _, dst, rx_pkt in test_msgs:
        # the header only the wire sees: minerva_rx_parse strips it
        wire_frame = await tb.wire.recv()
        wire = bytes(wire_frame.tdata)

        assert not last_tuser(wire_frame)
        assert wire[0:6] == dst.to_bytes(6, 'big')
        assert wire[6:12] == LOCAL_MAC.to_bytes(6, 'big')
        assert wire[12:14] == ETHERTYPE_AVTP.to_bytes(2, 'big')

        # the record and payload, back from the wire
        rx_frame = await tb.sink.recv()

        assert not last_tuser(rx_frame)
        assert rx_frame.tid == avtp.FORMAT_ABB
        assert rx_frame.tdest == ROUTE_AVTP
        assert bytes(rx_frame.tdata) == rx_pkt

    # nothing else comes back
    await tb.source.wait()
    for k in range(20):
        await RisingEdge(dut.clk)

    assert tb.wire.empty()
    assert tb.sink.empty()


def cycle_pause():
    return itertools.cycle([1, 1, 1, 0])


if getattr(cocotb, 'top', None) is not None:

    for test in [run_test_loopback]:

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


def test_minerva_loopback(request):
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = module

    verilog_sources = [
        os.path.join(tests_dir, f"{toplevel}.sv"),
        os.path.join(rtl_dir, "minerva_tx_deparse.sv"),
        os.path.join(rtl_dir, "minerva_rx_parse.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_if.sv"),
    ]

    verilog_sources = process_f_files(verilog_sources)

    parameters = {}

    parameters['ID_W'] = 4
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

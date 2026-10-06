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

        self.meta_source = AxiStreamSource(AxiStreamBus.from_entity(dut.s_axis_meta), dut.clk, dut.rst)
        self.payload_source = AxiStreamSource(AxiStreamBus.from_entity(dut.s_axis_payload), dut.clk, dut.rst)
        self.wire = AxiStreamMonitor(AxiStreamBus.from_entity(dut.axis_wire), dut.clk, dut.rst)
        self.meta_sink = AxiStreamSink(AxiStreamBus.from_entity(dut.m_axis_meta), dut.clk, dut.rst)
        self.payload_sink = AxiStreamSink(AxiStreamBus.from_entity(dut.m_axis_payload), dut.clk, dut.rst)

        cocotb.start_soon(check_axis_stable(self.wire.bus, dut.clk, dut.rst))
        cocotb.start_soon(check_axis_stable(self.meta_sink.bus, dut.clk, dut.rst))
        cocotb.start_soon(check_axis_stable(self.payload_sink.bus, dut.clk, dut.rst))

        dut.cfg_local_mac.setimmediatevalue(LOCAL_MAC)

    def set_idle_generator(self, generator=None):
        if generator:
            self.meta_source.set_pause_generator(generator())
            self.payload_source.set_pause_generator(generator())

    def set_backpressure_generator(self, generator=None):
        if generator:
            self.meta_sink.set_pause_generator(generator())
            self.payload_sink.set_pause_generator(generator())

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
    """The metadata a producer sends for an ABB message with fields varied by
    k, its destination, and the metadata a consumer must receive for it: the
    same words without the destination."""
    dst = 0x02D1D2D3D400 | (k & 0xff)
    sequence_num = (0xfd + k) & 0xff
    byte_bus_id = (0x5ff + 0x123 * k) & 0x7ff
    mtv = k & 1
    word1 = avtp.abb_word1(evt=k & 0xf, hs=k & 1, cs=(k >> 1) & 1,
                           transaction_num=(0x40 + k) & 0xff, op=(k >> 2) & 1,
                           rsp=(k >> 3) & 1, err=(k >> 1) & 1, ms=k & 1,
                           read_size=(0xbff - k) & 0xfff)
    tx_meta = avtp.abb_tx_meta(STREAM_ID, sequence_num, byte_bus_id, word1, len(payload), dst, sv=sv, mtv=mtv)
    rx_meta = avtp.abb_meta(STREAM_ID, sequence_num, byte_bus_id, word1, len(payload), sv=sv, mtv=mtv)
    return tx_meta, dst, rx_meta


async def run_test_loopback(dut, idle_inserter=None, backpressure_inserter=None):
    """Metadata and a payload sent to the wire come back unchanged: the
    consumer gets the producer's words without the destination, and the same
    payload, while the wire carries the destination and the local MAC."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    test_msgs = []

    # every pad twice over, sv both ways, the largest payload a frame holds,
    # then a run without payloads
    for n in list(range(9)) + [1480] + [0] * 6:
        k = len(test_msgs)
        payload = payload_data(n, k)
        test_msgs.append((*message(k, payload, sv=(k >> 1) & 1), payload))

    for tx_meta, _, rx_meta, payload in test_msgs:
        # the transmit layout is the receive layout with the destination
        # appended
        assert tx_meta[:24] == rx_meta

        await tb.meta_source.send(AxiStreamFrame(tx_meta))
        if payload:
            await tb.payload_source.send(AxiStreamFrame(payload, tuser=0))

    for _, dst, rx_meta, payload in test_msgs:
        # the header only the wire sees: minerva_rx_parse strips it
        wire_frame = await tb.wire.recv()
        wire = bytes(wire_frame.tdata)

        assert not last_tuser(wire_frame)
        assert wire[0:6] == dst.to_bytes(6, 'big')
        assert wire[6:12] == LOCAL_MAC.to_bytes(6, 'big')
        assert wire[12:14] == ETHERTYPE_AVTP.to_bytes(2, 'big')

        # the metadata and payload, back from the wire
        rx_frame = await tb.meta_sink.recv()

        assert rx_frame.tdest == avtp.ROUTE_CONSUMER
        assert bytes(rx_frame.tdata) == rx_meta

        if payload:
            rx_frame = await tb.payload_sink.recv()

            assert not last_tuser(rx_frame)
            assert bytes(rx_frame.tdata) == payload

    # nothing else comes back
    await tb.meta_source.wait()
    await tb.payload_source.wait()
    for k in range(20):
        await RisingEdge(dut.clk)

    assert tb.wire.empty()
    assert tb.meta_sink.empty()
    assert tb.payload_sink.empty()


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
        os.path.join(rtl_dir, "minerva_tx.f"),
        os.path.join(rtl_dir, "minerva_rx_parse.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_if.sv"),
    ]

    verilog_sources = process_f_files(verilog_sources)

    parameters = {}

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

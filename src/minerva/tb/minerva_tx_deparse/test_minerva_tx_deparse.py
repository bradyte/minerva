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

from cocotbext.axi import AxiStreamBus, AxiStreamFrame, AxiStreamSource, AxiStreamSink

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
HOST_MAC = 0xDAD1D2D3D4D5

# the talker's stream: the local MAC, UniqueID 0
STREAM_ID = LOCAL_MAC << 16

# expected for a frame that must end with tuser set
BAD = object()


class TB(object):
    def __init__(self, dut):
        self.dut = dut

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk, 8, units="ns").start())

        self.source = AxiStreamSource(AxiStreamBus.from_entity(dut.s_axis_eth_tx), dut.clk, dut.rst)
        self.sink = AxiStreamSink(AxiStreamBus.from_entity(dut.m_axis_mac_tx), dut.clk, dut.rst)

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


def mac_str(mac):
    return ':'.join(f'{b:02x}' for b in mac.to_bytes(6, 'big'))


def payload_data(n, seed):
    return bytes((seed + k) & 0xff for k in range(n))


def last_tuser(frame):
    return frame.tuser[-1] if isinstance(frame.tuser, list) else frame.tuser


def message(k, payload, dst=HOST_MAC, src=LOCAL_MAC, sv=1):
    """A producer packet for an ABB message with fields varied by k, and the
    frame minerva_tx_deparse builds from it, before the MAC pads it."""
    sequence_num = (0xfd + k) & 0xff
    byte_bus_id = (0x5ff + 0x123 * k) & 0x7ff
    mtv = k & 1
    word1 = avtp.abb_word1(evt=k & 0xf, hs=k & 1, cs=(k >> 1) & 1,
                           transaction_num=(0x40 + k) & 0xff, op=(k >> 2) & 1,
                           rsp=(k >> 3) & 1, err=(k >> 1) & 1, ms=k & 1,
                           read_size=(0xbff - k) & 0xfff)
    pkt = avtp.abb_tx_packet(STREAM_ID, sequence_num, byte_bus_id, word1, payload, dst, sv=sv, mtv=mtv)
    pdu = avtp.ntscf_pdu(STREAM_ID, sequence_num, [avtp.abb_message(byte_bus_id, mtv, word1, payload)], sv=sv)
    frame = bytes(Ether(dst=mac_str(dst), src=mac_str(src), type=ETHERTYPE_AVTP) / Raw(pdu))
    return pkt, frame


def send_frame(pkt, tid=avtp.FORMAT_ABB, tdest=ROUTE_AVTP, abort=False):
    """The input frame for a packet; abort sets tuser on its last beat only."""
    tuser = [0] * (len(pkt) - 1) + [1] if abort else 0
    return AxiStreamFrame(pkt, tid=tid, tdest=tdest, tuser=tuser)


async def run_frames(tb, test_frames):
    """Send each input and check what comes out, in order.

    test_frames holds (input frame, expected), where expected is the frame
    bytes, BAD for a frame that must end with tuser set, or None for an input
    that must give nothing.
    """
    for frame, _ in test_frames:
        await tb.source.send(frame)

    for _, expected in test_frames:
        if expected is None:
            continue

        rx_frame = await tb.sink.recv()

        if expected is BAD:
            assert last_tuser(rx_frame)
        else:
            assert not last_tuser(rx_frame)
            assert bytes(rx_frame.tdata) == expected

    # let any wrongly built frame surface
    await tb.source.wait()
    for k in range(20):
        await RisingEdge(tb.dut.clk)

    assert tb.sink.empty()



async def run_test_frame(dut, idle_inserter=None, backpressure_inserter=None):
    """Each record and payload gives the frame for it, byte for byte, at every
    pad, with every record field placed where it belongs."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    test_frames = []

    # every pad twice over, sv both ways, and the largest payload a frame holds
    for n in list(range(9)) + [1480]:
        k = len(test_frames)
        pkt, frame = message(k, payload_data(n, k), sv=(k >> 1) & 1)
        test_frames.append((send_frame(pkt), frame))

    await run_frames(tb, test_frames)


async def run_test_local_mac(dut, idle_inserter=None, backpressure_inserter=None):
    """The source address is cfg_local_mac as each record began."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    for k, mac in enumerate([LOCAL_MAC, 0x021122334455, 0x02AABBCCDDEE]):
        dut.cfg_local_mac.value = mac

        pkt, frame = message(k, payload_data(k + 5, k), src=mac)
        await tb.source.send(send_frame(pkt))

        rx_frame = await tb.sink.recv()
        assert not last_tuser(rx_frame)
        assert bytes(rx_frame.tdata) == frame


async def run_test_drop(dut, idle_inserter=None, backpressure_inserter=None):
    """A record that cannot become a frame gives nothing, and leaves its
    neighbours intact."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    test_frames = []

    def good():
        k = len(test_frames)
        pkt, frame = message(k, payload_data(k % 7, k))
        test_frames.append((send_frame(pkt), frame))

    def drop(frame):
        test_frames.append((frame, None))

    def record(payload_len):
        return avtp.abb_tx_record(STREAM_ID, 1, 0x123, 0, payload_len, HOST_MAC)

    good()

    # an unknown format or route
    drop(send_frame(message(1, payload_data(4, 0))[0], tid=1))
    drop(send_frame(message(2, payload_data(4, 0))[0], tdest=1))

    good()

    # shorter than a record
    for n in (4, 12, 20):
        drop(send_frame(record(0)[:n]))

    good()

    # a payload the record does not announce, one it announces that is
    # missing, and one too long for a frame
    drop(send_frame(record(0) + payload_data(8, 0)))
    drop(send_frame(record(4)))
    drop(send_frame(record(1481) + payload_data(1481, 0)))

    # a record alone, aborted
    drop(send_frame(record(0), abort=True))

    good()

    await run_frames(tb, test_frames)


async def run_test_bad(dut, idle_inserter=None, backpressure_inserter=None):
    """A payload that ends short or long, or is aborted, ends its frame with
    tuser set, and leaves its neighbours intact."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    test_frames = []

    def good():
        k = len(test_frames)
        pkt, frame = message(k, payload_data(k % 7 + 1, k))
        test_frames.append((send_frame(pkt), frame))

    def record(payload_len):
        return avtp.abb_tx_record(STREAM_ID, 1, 0x123, 0, payload_len, HOST_MAC)

    good()

    # short and long, within the last word and by whole words
    for payload_len, n in [(10, 9), (10, 6), (10, 11), (10, 15), (4, 3), (4, 5)]:
        test_frames.append((send_frame(record(payload_len) + payload_data(n, 0)), BAD))
        good()

    # aborted at the end of a payload that matches its record
    test_frames.append((send_frame(message(9, payload_data(13, 0))[0], abort=True), BAD))

    good()

    await run_frames(tb, test_frames)


def cycle_pause():
    return itertools.cycle([1, 1, 1, 0])


if getattr(cocotb, 'top', None) is not None:

    for test in [run_test_frame, run_test_local_mac, run_test_drop, run_test_bad]:

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

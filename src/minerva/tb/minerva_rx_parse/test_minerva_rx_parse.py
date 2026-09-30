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
ETHERTYPE_PTP = 0x88F7

# demux port for AVTP, as in the RTL route table
ROUTE_AVTP = 0


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


def eth_pad(frame):
    """Pad to the 60-byte minimum, as the talker's MAC would."""
    return frame + bytes(max(0, 60 - len(frame)))


def abb_request(k, sv=1):
    """An ABB message without a payload, with fields varied by k: its
    stream_id, sequence_num, the message, and the record it gives."""
    stream_id = (0x0200_0000_0000 | (k & 0xff)) << 16 | (0x1000 + k)
    sequence_num = (0xfd + k) & 0xff
    byte_bus_id = (0x5ff + 0x123 * k) & 0x7ff
    mtv = k & 1
    word1 = avtp.abb_word1(evt=k & 0xf, hs=k & 1, cs=(k >> 1) & 1,
                           transaction_num=(0x40 + k) & 0xff, op=(k >> 2) & 1,
                           rsp=(k >> 3) & 1, err=(k >> 1) & 1, ms=k & 1,
                           read_size=(0xbff - k) & 0xfff)
    msg = avtp.abb_message(byte_bus_id, mtv, word1)
    rec = avtp.abb_record(stream_id, sequence_num, byte_bus_id, word1, 0, sv=sv, mtv=mtv)
    return stream_id, sequence_num, msg, rec


async def run_test_record(dut, idle_inserter=None, backpressure_inserter=None):
    """An ABB message without a payload gives a record-only packet."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    # the builder against the vectors in Open1722's unit/test-abb.c
    assert avtp.abb_message(byte_bus_id=0x5ff)[:4] == bytes([0x1c, 0x02, 0x05, 0xff])
    assert avtp.abb_message(word1=avtp.abb_word1(evt=0xb))[4] == 0xb0
    assert avtp.abb_message(word1=avtp.abb_word1(transaction_num=0xbf))[5] == 0xbf
    assert avtp.abb_message(word1=avtp.abb_word1(op=1))[6] == 0x80
    assert avtp.abb_message(word1=avtp.abb_word1(read_size=0xbff))[6:8] == bytes([0x0b, 0xff])

    test_frames = []

    # tagged or not, sv set or not, and with or without the Ethernet padding
    # that follows a short PDU
    for vlan, sv, pad in itertools.product((None, 'c', 's'), (1, 0), (True, False)):
        stream_id, sequence_num, msg, rec = abb_request(len(test_frames), sv)
        frame = l2_frame(ETHERTYPE_AVTP, avtp.ntscf_pdu(stream_id, sequence_num, [msg], sv=sv), vlan)
        if pad:
            frame = eth_pad(frame)
        test_frames.append((frame, rec))

    for frame, _ in test_frames:
        await tb.source.send(frame)

    for _, rec in test_frames:
        rx_frame = await tb.sink.recv()

        assert bytes(rx_frame.tdata) == rec
        assert rx_frame.tid == avtp.FORMAT_ABB
        assert rx_frame.tdest == ROUTE_AVTP
        assert not rx_frame.tuser

    assert tb.sink.empty()

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


async def run_test_drop(dut, idle_inserter=None, backpressure_inserter=None):
    """Frames that cannot be parsed, or not yet, give nothing and leave their
    neighbours intact."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    # (frame, record expected, or None if nothing may come out)
    test_frames = []

    def good():
        stream_id, sequence_num, msg, rec = abb_request(len(test_frames))
        pdu = avtp.ntscf_pdu(stream_id, sequence_num, [msg])
        test_frames.append((eth_pad(l2_frame(ETHERTYPE_AVTP, pdu)), rec))

    def drop(frame):
        test_frames.append((frame, None))

    def avtp_frame(pdu):
        return eth_pad(l2_frame(ETHERTYPE_AVTP, pdu))

    stream_id = 0x0200_0000_0001_0001
    msg = avtp.abb_message(byte_bus_id=0x123, word1=avtp.abb_word1(transaction_num=7))

    good()

    # ethertypes other than AVTP, and a second tag
    drop(eth_pad(l2_frame(0x0800, avtp.ntscf_pdu(stream_id, 1, [msg]))))
    drop(eth_pad(l2_frame(0x0806, avtp.ntscf_pdu(stream_id, 2, [msg]), vlan='c')))
    drop(eth_pad(l2_frame(ETHERTYPE_PTP, avtp.ntscf_pdu(stream_id, 3, [msg]))))
    drop(eth_pad(bytes(Ether() / Dot1AD(vlan=456) / Dot1Q(vlan=123, type=ETHERTYPE_AVTP) /
        Raw(avtp.ntscf_pdu(stream_id, 4, [msg])))))

    good()

    # TSCF is deferred, only version 0 is parsed, and a PDU with no messages
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 5, [msg], subtype=avtp.SUBTYPE_TSCF)))
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 6, [msg], version=1)))
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 7, [])))

    # GBB is deferred; lengths below the header, too short for the pad, and
    # past the NTSCF payload
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 8, [avtp.abb_message(acf_msg_type=avtp.ACF_MSG_TYPE_GBB)])))
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 9, [avtp.abb_message(acf_msg_length=1)])))
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 10, [avtp.abb_message(pad=1)])))
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 11, [avtp.abb_message(acf_msg_length=3)])))

    good()

    # a payload is not handled yet
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 12, [avtp.abb_message(payload=b'\x01\x02\x03')])))

    # a second message is not handled yet; the first still comes out
    stream_id_2, sequence_num_2, msg_2, rec_2 = abb_request(len(test_frames))
    test_frames.append((avtp_frame(avtp.ntscf_pdu(stream_id_2, sequence_num_2, [msg_2, msg])), rec_2))

    # runts: frames ending inside or at the end of each header quadlet, and a
    # byte short of the last
    pdu = avtp.ntscf_pdu(stream_id, 13, [msg])
    for n in (2, 4, 6, 8, 10, 12, 14, 16, 19):
        drop(l2_frame(ETHERTYPE_AVTP, pdu[:n]))
    drop(l2_frame(ETHERTYPE_AVTP, b'')[:10])
    drop(l2_frame(ETHERTYPE_AVTP, b'', vlan='c'))

    good()

    for frame, _ in test_frames:
        await tb.source.send(frame)

    for _, rec in test_frames:
        if rec is None:
            continue

        rx_frame = await tb.sink.recv()

        assert bytes(rx_frame.tdata) == rec
        assert rx_frame.tid == avtp.FORMAT_ABB
        assert rx_frame.tdest == ROUTE_AVTP

    # let any wrongly forwarded frame surface
    await tb.source.wait()
    for k in range(20):
        await RisingEdge(dut.clk)

    assert tb.sink.empty()


def cycle_pause():
    return itertools.cycle([1, 1, 1, 0])


if getattr(cocotb, 'top', None) is not None:

    for test in [run_test_record, run_test_drop]:

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

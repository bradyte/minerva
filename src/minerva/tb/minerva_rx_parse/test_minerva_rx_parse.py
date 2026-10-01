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
import pytest

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


def payload_data(n, seed):
    return bytes((seed + k) & 0xff for k in range(n))


def stream(k):
    """A stream_id and sequence_num varied by k."""
    return (0x0200_0000_0000 | (k & 0xff)) << 16 | (0x1000 + k), (0xfd + k) & 0xff


def abb(k, stream_id, sequence_num, payload=b'', sv=1):
    """An ABB message with fields varied by k, and the packet minerva sends
    for it in a PDU with this stream_id, sequence_num and sv."""
    byte_bus_id = (0x5ff + 0x123 * k) & 0x7ff
    mtv = k & 1
    word1 = avtp.abb_word1(evt=k & 0xf, hs=k & 1, cs=(k >> 1) & 1,
                           transaction_num=(0x40 + k) & 0xff, op=(k >> 2) & 1,
                           rsp=(k >> 3) & 1, err=(k >> 1) & 1, ms=k & 1,
                           read_size=(0xbff - k) & 0xfff)
    msg = avtp.abb_message(byte_bus_id, mtv, word1, payload)
    pkt = avtp.abb_packet(stream_id, sequence_num, byte_bus_id, word1, payload, sv=sv, mtv=mtv)
    return msg, pkt


def tagged(dut, vlan, pkts):
    """The packets a frame gives: none if it is tagged and VLAN_EN is off."""
    return pkts if vlan is None or int(dut.VLAN_EN.value) else []


async def run_frames(tb, test_frames):
    """Send each frame and check that exactly its packets come out, in order.

    test_frames holds (frame, [(packet, truncated), ...]).  A truncated packet
    must carry the record and part of the payload, and end with tuser set.
    """
    for frame, _ in test_frames:
        await tb.source.send(frame)

    for _, pkts in test_frames:
        for pkt, truncated in pkts:
            rx_frame = await tb.sink.recv()
            data = bytes(rx_frame.tdata)
            tuser = rx_frame.tuser[-1] if isinstance(rx_frame.tuser, list) else rx_frame.tuser

            assert rx_frame.tid == avtp.FORMAT_ABB
            assert rx_frame.tdest == ROUTE_AVTP

            if truncated:
                assert tuser
                assert len(data) > 16 and pkt.startswith(data)
            else:
                assert not tuser
                assert data == pkt

    # let any wrongly forwarded packet surface
    await tb.source.wait()
    for k in range(20):
        await RisingEdge(tb.dut.clk)

    assert tb.sink.empty()


async def run_test_payload(dut, idle_inserter=None, backpressure_inserter=None):
    """An ABB message gives its record, then exactly its payload without the
    pad; an empty payload gives the record alone."""

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

    # tagged or not, with or without the Ethernet padding that follows a short
    # PDU, and every pad twice over, up to the largest payload a frame holds
    for vlan, pad in itertools.product((None, 'c', 's'), (True, False)):
        for n in list(range(9)) + [1480]:
            k = len(test_frames)
            stream_id, sequence_num = stream(k)
            sv = (k >> 1) & 1
            msg, pkt = abb(k, stream_id, sequence_num, payload_data(n, k), sv=sv)
            frame = l2_frame(ETHERTYPE_AVTP, avtp.ntscf_pdu(stream_id, sequence_num, [msg], sv=sv), vlan)
            if pad:
                frame = eth_pad(frame)
            test_frames.append((frame, tagged(dut, vlan, [(pkt, False)])))

    await run_frames(tb, test_frames)


async def run_test_concat(dut, idle_inserter=None, backpressure_inserter=None):
    """Messages back to back in one PDU each give a packet, in order; other
    message types are skipped by their length."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    # payload lengths of ABB messages, or another ACF type: SKIP with a body,
    # SKIP_1 only its header quadlet
    SKIP = 'skip'
    SKIP_1 = 'skip_1'

    cases = [
        [0, 0],
        [5, 0, 12],
        [1, 2, 3, 4],
        [SKIP, 7],
        [3, SKIP, 0],
        [0, SKIP_1, 9],
        [2, SKIP, SKIP_1, SKIP, 6],
        [SKIP],
        [SKIP_1, SKIP_1],
    ]

    test_frames = []

    for vlan, pad in itertools.product((None, 'c'), (True, False)):
        for case in cases:
            k = len(test_frames)
            stream_id, sequence_num = stream(k)
            msgs = []
            pkts = []
            for j, item in enumerate(case):
                if item == SKIP:
                    msgs.append(avtp.acf_message(avtp.ACF_MSG_TYPE_CAN, payload_data(10, j)))
                elif item == SKIP_1:
                    msgs.append(avtp.acf_message(avtp.ACF_MSG_TYPE_CAN))
                else:
                    msg, pkt = abb(16 * k + j, stream_id, sequence_num, payload_data(item, j))
                    msgs.append(msg)
                    pkts.append((pkt, False))
            frame = l2_frame(ETHERTYPE_AVTP, avtp.ntscf_pdu(stream_id, sequence_num, msgs), vlan)
            if pad:
                frame = eth_pad(frame)
            test_frames.append((frame, tagged(dut, vlan, pkts)))

    await run_frames(tb, test_frames)


async def run_test_truncate(dut, idle_inserter=None, backpressure_inserter=None):
    """A frame that ends inside a payload ends that packet with tuser set; one
    that ends anywhere else before a message is complete gives nothing for it,
    and the messages before are intact."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    test_frames = []

    # frames cut after n bytes of the PDU, without Ethernet padding
    def cut(pdu, n, vlan=None):
        return l2_frame(ETHERTYPE_AVTP, pdu[:n], vlan)

    # one message with a 20-byte payload from PDU byte 20: cut before the
    # first payload quadlet can be sent, through the payload, and at its end
    for vlan in (None, 'c'):
        for n in (21, 22, 23, 24, 26, 29, 30, 33, 37, 39, 40):
            k = len(test_frames)
            stream_id, sequence_num = stream(k)
            msg, pkt = abb(k, stream_id, sequence_num, payload_data(20, k))
            pdu = avtp.ntscf_pdu(stream_id, sequence_num, [msg])
            if n <= 22:
                pkts = []
            elif n < 40:
                pkts = [(pkt, True)]
            else:
                pkts = [(pkt, False)]
            test_frames.append((cut(pdu, n, vlan), tagged(dut, vlan, pkts)))

    # two messages, the second's payload from PDU byte 36: cut inside its ACF
    # quadlet, inside its second quadlet, before and inside its payload
    for n in (30, 34, 38, 41, 50, 56):
        k = len(test_frames)
        stream_id, sequence_num = stream(k)
        msg_1, pkt_1 = abb(k, stream_id, sequence_num, payload_data(8, k))
        msg_2, pkt_2 = abb(k + 1, stream_id, sequence_num, payload_data(20, k))
        pdu = avtp.ntscf_pdu(stream_id, sequence_num, [msg_1, msg_2])
        pkts = [(pkt_1, False)]
        if 38 < n < 56:
            pkts.append((pkt_2, True))
        elif n == 56:
            pkts.append((pkt_2, False))
        test_frames.append((cut(pdu, n), pkts))

    # cut inside a skipped message, before an ABB message
    stream_id, sequence_num = stream(len(test_frames))
    msg, pkt = abb(len(test_frames), stream_id, sequence_num, payload_data(4, 0))
    pdu = avtp.ntscf_pdu(stream_id, sequence_num, [avtp.acf_message(avtp.ACF_MSG_TYPE_CAN, payload_data(10, 0)), msg])
    test_frames.append((cut(pdu, 20), []))

    # ntscf_data_length beyond the frame: the complete message still comes
    # out, then the frame ends, or its Ethernet padding reads as a malformed
    # message and is dropped
    for pad in (False, True):
        k = len(test_frames)
        stream_id, sequence_num = stream(k)
        msg, pkt = abb(k, stream_id, sequence_num, payload_data(8, k))
        frame = l2_frame(ETHERTYPE_AVTP, avtp.ntscf_pdu(stream_id, sequence_num, [msg], ntscf_data_length=len(msg) + 16))
        if pad:
            frame = eth_pad(frame)
        test_frames.append((frame, [(pkt, False)]))

    await run_frames(tb, test_frames)


async def run_test_drop(dut, idle_inserter=None, backpressure_inserter=None):
    """Frames that cannot be parsed give nothing and leave their neighbours
    intact."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    test_frames = []

    def good():
        k = len(test_frames)
        stream_id, sequence_num = stream(k)
        msg, pkt = abb(k, stream_id, sequence_num)
        pdu = avtp.ntscf_pdu(stream_id, sequence_num, [msg])
        test_frames.append((eth_pad(l2_frame(ETHERTYPE_AVTP, pdu)), [(pkt, False)]))

    def drop(frame):
        test_frames.append((frame, []))

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

    # GBB is deferred, so skipped; ABB lengths below the header, too short
    # for the pad, and past the NTSCF payload
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 8, [avtp.abb_message(acf_msg_type=avtp.ACF_MSG_TYPE_GBB)])))
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 9, [avtp.abb_message(acf_msg_length=1)])))
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 10, [avtp.abb_message(pad=1)])))
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 11, [avtp.abb_message(acf_msg_length=3)])))

    good()

    # another message type with length 0, or past the NTSCF payload
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 12, [avtp.acf_message(avtp.ACF_MSG_TYPE_CAN, acf_msg_length=0), msg])))
    drop(avtp_frame(avtp.ntscf_pdu(stream_id, 13, [avtp.acf_message(avtp.ACF_MSG_TYPE_CAN, payload_data(8, 0), acf_msg_length=5)])))

    # runts: frames ending inside or at the end of each header quadlet, and a
    # byte short of the last
    pdu = avtp.ntscf_pdu(stream_id, 14, [msg])
    for n in (2, 4, 6, 8, 10, 12, 14, 16, 19):
        drop(l2_frame(ETHERTYPE_AVTP, pdu[:n]))
    drop(l2_frame(ETHERTYPE_AVTP, b'')[:10])
    drop(l2_frame(ETHERTYPE_AVTP, b'', vlan='c'))

    good()

    await run_frames(tb, test_frames)


def cycle_pause():
    return itertools.cycle([1, 1, 1, 0])


if getattr(cocotb, 'top', None) is not None:

    for test in [run_test_payload, run_test_concat, run_test_truncate, run_test_drop]:

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


@pytest.mark.parametrize("vlan_en", [0, 1])
def test_minerva_rx_parse(request, vlan_en):
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

    parameters['VLAN_EN'] = vlan_en
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

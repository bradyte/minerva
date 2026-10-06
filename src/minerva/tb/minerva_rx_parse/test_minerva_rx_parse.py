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


ETHERTYPE_PTP = 0x88F7

# expected in place of a metadata block on the discard route, whose words
# other than flags and payload_len are unspecified
DISCARD = 'discard'


class TB(object):
    def __init__(self, dut):
        self.dut = dut

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk, 8, units="ns").start())

        self.source = AxiStreamSource(AxiStreamBus.from_entity(dut.s_axis_mac_rx), dut.clk, dut.rst)
        self.meta_sink = AxiStreamSink(AxiStreamBus.from_entity(dut.m_axis_meta), dut.clk, dut.rst)
        self.payload_sink = AxiStreamSink(AxiStreamBus.from_entity(dut.m_axis_payload), dut.clk, dut.rst)

        cocotb.start_soon(check_axis_stable(self.meta_sink.bus, dut.clk, dut.rst))
        cocotb.start_soon(check_axis_stable(self.payload_sink.bus, dut.clk, dut.rst))

    def set_idle_generator(self, generator=None):
        if generator:
            self.source.set_pause_generator(generator())

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


def stream(k):
    """A stream_id and sequence_num varied by k."""
    return (0x0200_0000_0000 | (k & 0xff)) << 16 | (0x1000 + k), (0xfd + k) & 0xff


def abb(k, stream_id, sequence_num, payload=b'', sv=1):
    """An ABB message with fields varied by k, and the output minerva sends
    for it in a PDU with this stream_id, sequence_num and sv: its metadata,
    then its payload if it has one."""
    byte_bus_id, mtv, word1 = avtp.abb_fields(k)
    msg = avtp.abb_message(byte_bus_id, mtv, word1, payload)
    meta = avtp.abb_meta(stream_id, sequence_num, byte_bus_id, word1, len(payload), sv=sv, mtv=mtv)
    return msg, out(meta, payload)


def out(meta, payload=b'', truncated=False):
    """One expected output: a metadata block, then its payload, or None when
    the metadata announces no payload."""
    return meta, payload or None, truncated


def err(pdu, n, flags, msg_q=None, abb_q1=False):
    """The error metadata for an NTSCF PDU of which the frame carried n
    octets.  A field is filled only when its whole quadlet arrived: the
    stream fields from quadlets 0 to 2, and quadlet msg_q, the ACF header of
    the message in progress, with the next quadlet too for an ABB message."""
    def q(k):
        return int.from_bytes(pdu[4*k:4*k+4], 'big') if 4*k + 4 <= n else 0

    words = [q(msg_q) if msg_q is not None else 0,
             q(msg_q + 1) if msg_q is not None and abb_q1 else 0]
    return out(avtp.meta(avtp.SUBTYPE_NTSCF, flags, 0, q(1) << 32 | q(2),
                         (q(0) >> 23) & 1, q(0) & 0xff, words))


def tagged(dut, vlan, outputs):
    """The outputs a frame gives: a discard block if it is tagged and VLAN_EN
    is off."""
    return outputs if vlan is None or int(dut.VLAN_EN.value) else [out(DISCARD)]


async def run_frames(tb, test_frames):
    """Send each frame and check that exactly its outputs come out, in order.

    test_frames holds (frame, [(meta, payload, truncated), ...]).  meta is
    the metadata block expected, or DISCARD; payload is the payload expected
    after it, or None when the metadata announces none.  A truncated payload
    must be part of the expected one and end with tuser set.
    """
    for frame, _ in test_frames:
        await tb.source.send(frame)

    for _, outputs in test_frames:
        for meta, payload, truncated in outputs:
            rx_meta = await tb.meta_sink.recv()
            data = bytes(rx_meta.tdata)
            w0 = int.from_bytes(data[0:4], 'little')

            assert len(data) == 24

            if meta is DISCARD:
                assert rx_meta.tdest == avtp.ROUTE_DISCARD
                assert w0 & 0x00ffffff == 0
            else:
                assert rx_meta.tdest == avtp.ROUTE_CONSUMER
                assert data == meta

            if payload is None:
                continue

            rx_payload = await tb.payload_sink.recv()
            data = bytes(rx_payload.tdata)
            tuser = avtp.last_tuser(rx_payload)

            assert rx_payload.tdest == avtp.ROUTE_CONSUMER

            if truncated:
                assert tuser
                assert 0 < len(data) < len(payload) and payload.startswith(data)
            else:
                assert not tuser
                assert data == payload

    # let any wrongly forwarded output surface
    await tb.source.wait()
    for k in range(20):
        await RisingEdge(tb.dut.clk)

    assert tb.meta_sink.empty()
    assert tb.payload_sink.empty()


async def run_test_payload(dut, idle_inserter=None, backpressure_inserter=None):
    """An ABB message gives its metadata, then exactly its payload without the
    pad; an empty payload gives the metadata alone."""

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

    # the metadata builder against the example in the 0.4.0 release notes
    assert avtp.abb_meta(0x5A5152535455_0000, 0x2A, 0x012, avtp.abb_word1(transaction_num=7), 25) == \
        bytes.fromhex('19000082 5352515A 00005554 00000095 12C0091C 00000700')

    test_frames = []

    # tagged or not, with or without the Ethernet padding that follows a short
    # PDU, and every pad twice over, up to the largest payload a frame holds
    for vlan, pad in itertools.product((None, 'c', 's'), (True, False)):
        for n in list(range(9)) + [1480]:
            k = len(test_frames)
            stream_id, sequence_num = stream(k)
            sv = (k >> 1) & 1
            msg, output = abb(k, stream_id, sequence_num, avtp.payload_data(n, k), sv=sv)
            frame = l2_frame(avtp.ETHERTYPE_AVTP, avtp.ntscf_pdu(stream_id, sequence_num, [msg], sv=sv), vlan)
            if pad:
                frame = eth_pad(frame)
            test_frames.append((frame, tagged(dut, vlan, [output])))

    await run_frames(tb, test_frames)


async def run_test_concat(dut, idle_inserter=None, backpressure_inserter=None):
    """Messages back to back in one PDU each give their output, in order;
    other message types are skipped by their length.  A run of empty messages
    fills both metadata slots."""

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
        [0] * 12,
    ]

    test_frames = []

    for vlan, pad in itertools.product((None, 'c'), (True, False)):
        for case in cases:
            k = len(test_frames)
            stream_id, sequence_num = stream(k)
            msgs = []
            outputs = []
            for j, item in enumerate(case):
                if item == SKIP:
                    msgs.append(avtp.acf_message(avtp.ACF_MSG_TYPE_CAN, avtp.payload_data(10, j)))
                elif item == SKIP_1:
                    msgs.append(avtp.acf_message(avtp.ACF_MSG_TYPE_CAN))
                else:
                    msg, output = abb(16 * k + j, stream_id, sequence_num, avtp.payload_data(item, j))
                    msgs.append(msg)
                    outputs.append(output)
            frame = l2_frame(avtp.ETHERTYPE_AVTP, avtp.ntscf_pdu(stream_id, sequence_num, msgs), vlan)
            if pad:
                frame = eth_pad(frame)
            test_frames.append((frame, tagged(dut, vlan, outputs)))

    await run_frames(tb, test_frames)


async def run_test_truncate(dut, idle_inserter=None, backpressure_inserter=None):
    """A frame that ends after a payload has started ends that payload with
    tuser set.  One that ends anywhere else before ntscf_data_length is used
    up gives an ERR_TRUNC block after any complete messages."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    test_frames = []

    # frames cut after n bytes of the PDU, without Ethernet padding
    def cut(pdu, n, vlan=None):
        return l2_frame(avtp.ETHERTYPE_AVTP, pdu[:n], vlan)

    # one message with a 20-byte payload from PDU byte 20: cut before the
    # first payload beat (bytes 20 and 21 share a beat with ABB quadlet 1),
    # through the payload, and at its end
    for vlan in (None, 'c'):
        for n in (21, 22, 23, 24, 26, 29, 30, 33, 37, 39, 40):
            k = len(test_frames)
            stream_id, sequence_num = stream(k)
            payload = avtp.payload_data(20, k)
            msg, output = abb(k, stream_id, sequence_num, payload)
            pdu = avtp.ntscf_pdu(stream_id, sequence_num, [msg])
            if n <= 22:
                outputs = [err(pdu, n, avtp.FLAG_ERR_TRUNC, msg_q=3, abb_q1=True)]
            elif n < 40:
                outputs = [out(output[0], payload, truncated=True)]
            else:
                outputs = [output]
            test_frames.append((cut(pdu, n, vlan), tagged(dut, vlan, outputs)))

    # two messages, the second from PDU byte 28 with its payload from byte 36:
    # cut between them, inside its ACF quadlet, inside its second quadlet,
    # before and inside its payload, and at its end
    for n in (30, 34, 38, 41, 50, 56):
        k = len(test_frames)
        stream_id, sequence_num = stream(k)
        payload = avtp.payload_data(20, k)
        msg_1, output_1 = abb(k, stream_id, sequence_num, avtp.payload_data(8, k))
        msg_2, output_2 = abb(k + 1, stream_id, sequence_num, payload)
        pdu = avtp.ntscf_pdu(stream_id, sequence_num, [msg_1, msg_2])
        outputs = [output_1]
        if n <= 38:
            outputs.append(err(pdu, n, avtp.FLAG_ERR_TRUNC, msg_q=7, abb_q1=True))
        elif n < 56:
            outputs.append(out(output_2[0], payload, truncated=True))
        else:
            outputs.append(output_2)
        test_frames.append((cut(pdu, n), outputs))

    # cut inside a skipped message, before an ABB message
    stream_id, sequence_num = stream(len(test_frames))
    msg, output = abb(len(test_frames), stream_id, sequence_num, avtp.payload_data(4, 0))
    pdu = avtp.ntscf_pdu(stream_id, sequence_num, [avtp.acf_message(avtp.ACF_MSG_TYPE_CAN, avtp.payload_data(10, 0)), msg])
    test_frames.append((cut(pdu, 20), [err(pdu, 20, avtp.FLAG_ERR_TRUNC, msg_q=3)]))

    # ntscf_data_length beyond the frame: the complete message still comes
    # out, then the frame ends early, or its Ethernet padding reads as a
    # message of length 0
    for pad in (False, True):
        k = len(test_frames)
        stream_id, sequence_num = stream(k)
        msg, output = abb(k, stream_id, sequence_num, avtp.payload_data(8, k))
        pdu = avtp.ntscf_pdu(stream_id, sequence_num, [msg], ntscf_data_length=len(msg) + 16)
        frame = l2_frame(avtp.ETHERTYPE_AVTP, pdu)
        if pad:
            frame = eth_pad(frame)
            flags = avtp.FLAG_ERR_LEN
        else:
            flags = avtp.FLAG_ERR_TRUNC
        test_frames.append((frame, [output, err(pdu, len(pdu), flags)]))

    await run_frames(tb, test_frames)


async def run_test_drop(dut, idle_inserter=None, backpressure_inserter=None):
    """Frames for no handler give a discard block, and malformed NTSCF frames
    an error block; their neighbours are intact."""

    tb = TB(dut)

    await tb.reset()

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    test_frames = []

    def good():
        k = len(test_frames)
        stream_id, sequence_num = stream(k)
        msg, output = abb(k, stream_id, sequence_num)
        pdu = avtp.ntscf_pdu(stream_id, sequence_num, [msg])
        test_frames.append((eth_pad(l2_frame(avtp.ETHERTYPE_AVTP, pdu)), [output]))

    def discard(frame):
        test_frames.append((frame, [out(DISCARD)]))

    def error(pdu, flags, msg_q=None, frame=None):
        test_frames.append((frame or avtp_frame(pdu), [err(pdu, len(pdu), flags, msg_q)]))

    def avtp_frame(pdu):
        return eth_pad(l2_frame(avtp.ETHERTYPE_AVTP, pdu))

    stream_id = 0x0200_0000_0001_0001
    msg = avtp.abb_message(byte_bus_id=0x123, word1=avtp.abb_word1(transaction_num=7))

    good()

    # ethertypes other than AVTP, and a second tag
    discard(eth_pad(l2_frame(0x0800, avtp.ntscf_pdu(stream_id, 1, [msg]))))
    discard(eth_pad(l2_frame(0x0806, avtp.ntscf_pdu(stream_id, 2, [msg]), vlan='c')))
    discard(eth_pad(l2_frame(ETHERTYPE_PTP, avtp.ntscf_pdu(stream_id, 3, [msg]))))
    discard(eth_pad(bytes(Ether() / Dot1AD(vlan=456) / Dot1Q(vlan=123, type=avtp.ETHERTYPE_AVTP) /
        Raw(avtp.ntscf_pdu(stream_id, 4, [msg])))))

    good()

    # TSCF has no handler and only version 0 is parsed; a PDU with no messages
    discard(avtp_frame(avtp.ntscf_pdu(stream_id, 5, [msg], subtype=avtp.SUBTYPE_TSCF)))
    discard(avtp_frame(avtp.ntscf_pdu(stream_id, 6, [msg], version=1)))
    error(avtp.ntscf_pdu(stream_id, 7, []), avtp.FLAG_ERR_EMPTY)

    # GBB has no handler, so is skipped and gives nothing; ABB lengths below
    # the header, too short for the pad, and past the NTSCF payload
    test_frames.append((avtp_frame(avtp.ntscf_pdu(stream_id, 8, [avtp.abb_message(acf_msg_type=avtp.ACF_MSG_TYPE_GBB)])), []))
    error(avtp.ntscf_pdu(stream_id, 9, [avtp.abb_message(acf_msg_length=1)]), avtp.FLAG_ERR_LEN, msg_q=3)
    error(avtp.ntscf_pdu(stream_id, 10, [avtp.abb_message(pad=1)]), avtp.FLAG_ERR_LEN, msg_q=3)
    error(avtp.ntscf_pdu(stream_id, 11, [avtp.abb_message(acf_msg_length=3)]), avtp.FLAG_ERR_LEN, msg_q=3)

    good()

    # another message type with length 0, or past the NTSCF payload
    error(avtp.ntscf_pdu(stream_id, 12, [avtp.acf_message(avtp.ACF_MSG_TYPE_CAN, acf_msg_length=0), msg]),
        avtp.FLAG_ERR_LEN, msg_q=3)
    error(avtp.ntscf_pdu(stream_id, 13, [avtp.acf_message(avtp.ACF_MSG_TYPE_CAN, avtp.payload_data(8, 0), acf_msg_length=5)]),
        avtp.FLAG_ERR_LEN, msg_q=3)

    # runts: frames ending inside or at the end of each header quadlet, and a
    # byte short of the last; before the subtype is whole the frame is not
    # known to be NTSCF
    pdu = avtp.ntscf_pdu(stream_id, 14, [msg])
    for n in (2, 4, 6, 8, 10, 12, 14, 16, 19):
        if n < 4:
            discard(l2_frame(avtp.ETHERTYPE_AVTP, pdu[:n]))
        else:
            test_frames.append((l2_frame(avtp.ETHERTYPE_AVTP, pdu[:n]),
                [err(pdu, n, avtp.FLAG_ERR_TRUNC, msg_q=3, abb_q1=True)]))
    discard(l2_frame(avtp.ETHERTYPE_AVTP, b'')[:10])
    discard(l2_frame(avtp.ETHERTYPE_AVTP, b'', vlan='c'))

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

#!/usr/bin/env python
# SPDX-License-Identifier: CERN-OHL-S-2.0
"""

Copyright (c) 2020-2025 FPGA Ninja, LLC
Copyright (c) 2026 Tom Brady

Authors:
- Alex Forencich
- Tom Brady

"""

import itertools
import logging
import os

import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb.regression import TestFactory
from cocotb.utils import get_time_from_sim_steps

from cocotbext.eth import GmiiFrame, RgmiiPhy, PtpClockSimTime
from cocotbext.axi import AxiStreamBus, AxiStreamSource, AxiStreamSink, AxiStreamFrame


class TB:
    def __init__(self, dut, speed=1000e6):
        self.dut = dut

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        self.clk_period = 8

        cocotb.start_soon(Clock(dut.logic_clk, self.clk_period, units="ns").start())
        cocotb.start_soon(Clock(dut.stat_clk, self.clk_period, units="ns").start())

        self.rgmii_phy = RgmiiPhy(dut.rgmii_txd, dut.rgmii_tx_ctl, dut.rgmii_tx_clk,
            dut.rgmii_rxd, dut.rgmii_rx_ctl, dut.rgmii_rx_clk, speed=speed)

        self.axis_source = AxiStreamSource(AxiStreamBus.from_entity(dut.s_axis_tx), dut.logic_clk, dut.logic_rst)
        self.tx_cpl_sink = AxiStreamSink(AxiStreamBus.from_entity(dut.m_axis_tx_cpl), dut.logic_clk, dut.logic_rst)
        self.axis_sink = AxiStreamSink(AxiStreamBus.from_entity(dut.m_axis_rx), dut.logic_clk, dut.logic_rst)

        self.stat_sink = AxiStreamSink(AxiStreamBus.from_entity(dut.m_axis_stat), dut.stat_clk, dut.stat_rst)

        # PTP.  There is no taxi_ptp_td_leaf in the 1G MAC family, so the
        # timestamp reaches the MAC clock domains through taxi_ptp_clock_cdc
        # only - drive ptp_ts_in in logic_clk and let the DUT cross it.
        self.ptp_clock = PtpClockSimTime(ts_tod=dut.ptp_ts_in, clock=dut.logic_clk)
        dut.ptp_ts_step_in.setimmediatevalue(0)

        cocotb.start_soon(Clock(dut.ptp_clk, self.clk_period, units="ns").start())
        cocotb.start_soon(Clock(dut.ptp_sample_clk, self.clk_period, units="ns").start())

        dut.cfg_tx_pad_en.setimmediatevalue(0)
        dut.cfg_tx_min_pkt_len.setimmediatevalue(0)
        dut.cfg_tx_max_pkt_len.setimmediatevalue(0)
        dut.cfg_tx_ifg.setimmediatevalue(0)
        dut.cfg_tx_enable.setimmediatevalue(0)
        dut.cfg_rx_max_pkt_len.setimmediatevalue(0)
        dut.cfg_rx_enable.setimmediatevalue(0)

        dut.gtx_clk.setimmediatevalue(0)
        dut.gtx_clk90.setimmediatevalue(0)

        cocotb.start_soon(self._run_gtx_clk())

    @property
    def ptp_en(self):
        return bool(int(self.dut.PTP_TS_EN.value))

    async def reset(self):
        self.dut.gtx_rst.setimmediatevalue(0)
        self.dut.logic_rst.setimmediatevalue(0)
        self.dut.stat_rst.setimmediatevalue(0)
        self.dut.ptp_rst.setimmediatevalue(0)
        await RisingEdge(self.dut.gtx_clk)
        await RisingEdge(self.dut.gtx_clk)
        self.dut.gtx_rst.value = 1
        self.dut.logic_rst.value = 1
        self.dut.stat_rst.value = 1
        self.dut.ptp_rst.value = 1
        await RisingEdge(self.dut.gtx_clk)
        await RisingEdge(self.dut.gtx_clk)
        self.dut.gtx_rst.value = 0
        self.dut.logic_rst.value = 0
        self.dut.stat_rst.value = 0
        self.dut.ptp_rst.value = 0
        await RisingEdge(self.dut.gtx_clk)
        await RisingEdge(self.dut.gtx_clk)

    async def _run_gtx_clk(self):
        t = Timer(2, 'ns')
        while True:
            self.dut.gtx_clk.value = 1
            await t
            self.dut.gtx_clk90.value = 1
            await t
            self.dut.gtx_clk.value = 0
            await t
            self.dut.gtx_clk90.value = 0
            await t


async def wait_for_ptp_lock(tb, sig, clk, name, limit=2000000):
    """Wait for a taxi_ptp_clock_cdc lock, bounded.

    Bounded rather than a bare `while not locked` loop: an unlocked CDC is a
    plausible failure here, and it must report as a failure rather than spin
    until the harness kills the run.
    """
    tb.log.info("Wait for %s PTP CDC lock", name)
    for k in range(limit):
        if int(sig.value):
            tb.log.info("%s PTP CDC locked after %d cycles", name, k)
            return k
        await RisingEdge(clk)
    assert False, f"{name} PTP CDC did not lock within {limit} cycles"


def check_link_speed(dut, speed):
    if speed == 10e6:
        assert int(dut.link_speed.value) == 0
    elif speed == 100e6:
        assert int(dut.link_speed.value) == 1
    else:
        assert int(dut.link_speed.value) == 2


async def run_test_rx(dut, payload_lengths=None, payload_data=None, ifg=12, speed=1000e6):

    tb = TB(dut, speed)

    tb.rgmii_phy.rx.ifg = ifg
    tb.dut.cfg_tx_ifg.value = ifg
    tb.dut.cfg_rx_max_pkt_len.value = 9218-1
    tb.dut.cfg_rx_enable.value = 1

    await tb.reset()

    for k in range(100):
        await RisingEdge(dut.rgmii_rx_clk)

    check_link_speed(dut, speed)

    if tb.ptp_en:
        await wait_for_ptp_lock(tb, dut.rx_ptp_locked, dut.rgmii_rx_clk, "RX")
        for k in range(2000):
            await RisingEdge(dut.rgmii_rx_clk)

    tb.axis_sink.clear()

    test_frames = [payload_data(x) for x in payload_lengths()]
    tx_frames = []

    for test_data in test_frames:
        test_frame = GmiiFrame.from_payload(test_data, tx_complete=tx_frames.append)
        await tb.rgmii_phy.rx.send(test_frame)

    for test_data in test_frames:
        rx_frame = await tb.axis_sink.recv()
        tx_frame = tx_frames.pop(0)

        frame_error = rx_frame.tuser & 1

        assert rx_frame.tdata == test_data
        assert frame_error == 0

        if tb.ptp_en:
            ptp_ts_ns = (rx_frame.tuser >> 1) / 2**16
            sfd_ns = get_time_from_sim_steps(tx_frame.sim_time_sfd, "ns")

            tb.log.info("RX frame PTP TS: %f ns", ptp_ts_ns)
            tb.log.info("RX frame SFD sim time: %f ns", sfd_ns)
            tb.log.info("Difference: %f ns", ptp_ts_ns - sfd_ns)

            # Only checked at 1G.  taxi_ptp_clock_cdc is instantiated with
            # NS_W(6), which holds one 125 MHz period; at 100M and 10M the
            # recovered rgmii_rx_clk is slower than that and the timestamp
            # degrades.  See the header of taxi_eth_mac_1g_rgmii_ptp_fifo.sv.
            if speed == 1000e6:
                assert abs(ptp_ts_ns - sfd_ns - RX_TS_OFFSET_NS) < tb.clk_period*2
        else:
            assert rx_frame.tuser == 0

    assert tb.axis_sink.empty()

    await RisingEdge(dut.logic_clk)
    await RisingEdge(dut.logic_clk)


async def run_test_tx(dut, payload_lengths=None, payload_data=None, ifg=12, speed=1000e6):

    tb = TB(dut, speed)

    tb.rgmii_phy.rx.ifg = ifg
    tb.dut.cfg_tx_pad_en.value = 1
    tb.dut.cfg_tx_min_pkt_len.value = 60-1
    tb.dut.cfg_tx_max_pkt_len.value = 9218-1
    tb.dut.cfg_tx_ifg.value = ifg
    tb.dut.cfg_tx_enable.value = 1

    await tb.reset()

    for k in range(100):
        await RisingEdge(dut.rgmii_rx_clk)

    check_link_speed(dut, speed)

    if tb.ptp_en:
        await wait_for_ptp_lock(tb, dut.tx_ptp_locked, dut.logic_clk, "TX")
        for k in range(2000):
            await RisingEdge(dut.logic_clk)

    tb.rgmii_phy.tx.clear()
    tb.tx_cpl_sink.clear()

    test_frames = [payload_data(x) for x in payload_lengths()]

    for test_data in test_frames:
        await tb.axis_source.send(AxiStreamFrame(test_data, tid=0, tuser=0))

    for test_data in test_frames:
        rx_frame = await tb.rgmii_phy.tx.recv()

        assert rx_frame.get_payload() == test_data
        assert rx_frame.check_fcs()
        assert rx_frame.error is None

        if tb.ptp_en:
            tx_cpl = await tb.tx_cpl_sink.recv()

            ptp_ts_ns = int(tx_cpl.tdata[0]) / 2**16
            sfd_ns = get_time_from_sim_steps(rx_frame.sim_time_sfd, "ns")

            tb.log.info("TX frame PTP TS: %f ns", ptp_ts_ns)
            tb.log.info("TX frame SFD sim time: %f ns", sfd_ns)
            tb.log.info("Difference: %f ns", sfd_ns - ptp_ts_ns)

            if speed == 1000e6:
                assert abs(sfd_ns - ptp_ts_ns - TX_TS_OFFSET_NS) < tb.clk_period*2

    assert tb.rgmii_phy.tx.empty()

    await RisingEdge(dut.logic_clk)
    await RisingEdge(dut.logic_clk)


# Constant offset between the MAC's timestamp and the SFD on the wire, in ns.
# Not a tolerance - the tolerance is +/- 2 clock periods around these.  Both are
# measured from simulation rather than derived, the same way basex's pipe_delay
# constants are; if the datapath changes, re-measure rather than widening the
# tolerance.
RX_TS_OFFSET_NS = 20.9
TX_TS_OFFSET_NS = 7.2


async def run_test_rx_bad_fcs(dut, ifg=12, speed=1000e6):
    """A bad-FCS frame must not reach the parser.

    Delivering only validated frames is the MAC's job: RX_FRAME_FIFO with
    RX_DROP_BAD_FRAME drops a failed frame inside the RX FIFO.  Checked here
    because everything downstream is written assuming it.
    """

    tb = TB(dut, speed)

    tb.rgmii_phy.rx.ifg = ifg
    tb.dut.cfg_tx_ifg.value = ifg
    tb.dut.cfg_rx_max_pkt_len.value = 9218-1
    tb.dut.cfg_rx_enable.value = 1

    await tb.reset()

    for k in range(100):
        await RisingEdge(dut.rgmii_rx_clk)

    if tb.ptp_en:
        await wait_for_ptp_lock(tb, dut.rx_ptp_locked, dut.rgmii_rx_clk, "RX")
        for k in range(2000):
            await RisingEdge(dut.rgmii_rx_clk)

    tb.axis_sink.clear()

    good_a = incrementing_payload(64)
    good_b = incrementing_payload(96)
    bad = incrementing_payload(80)

    bad_frame = GmiiFrame.from_payload(bad)
    bad_frame.data[-1] ^= 0xff
    assert not bad_frame.check_fcs()

    await tb.rgmii_phy.rx.send(GmiiFrame.from_payload(good_a))
    await tb.rgmii_phy.rx.send(bad_frame)
    await tb.rgmii_phy.rx.send(GmiiFrame.from_payload(good_b))

    # Only the two good frames may appear, and in order - the bad one is
    # dropped entirely rather than delivered with an error flag set.
    for expected in (good_a, good_b):
        rx_frame = await tb.axis_sink.recv()
        assert rx_frame.tdata == expected
        assert rx_frame.tuser & 1 == 0

    for k in range(200):
        await RisingEdge(dut.logic_clk)

    assert tb.axis_sink.empty(), "bad-FCS frame reached the parser"

    await RisingEdge(dut.logic_clk)


async def run_test_tx_cpl_tid(dut, ifg=12, speed=1000e6):
    """TX completions must be matched by tid, not by position.

    A frame dropped in the TX FIFO never reaches the MAC, so it produces no
    completion.  Anything pairing completions to submissions positionally
    silently mis-attributes every timestamp after the first drop; the tag is
    what makes the pairing survive.
    """

    tb = TB(dut, speed)

    tb.rgmii_phy.rx.ifg = ifg
    tb.dut.cfg_tx_pad_en.value = 1
    tb.dut.cfg_tx_min_pkt_len.value = 60-1
    tb.dut.cfg_tx_max_pkt_len.value = 9218-1
    tb.dut.cfg_tx_ifg.value = ifg
    tb.dut.cfg_tx_enable.value = 1

    await tb.reset()

    for k in range(100):
        await RisingEdge(dut.rgmii_rx_clk)

    if tb.ptp_en:
        await wait_for_ptp_lock(tb, dut.tx_ptp_locked, dut.logic_clk, "TX")
        for k in range(2000):
            await RisingEdge(dut.logic_clk)

    tb.rgmii_phy.tx.clear()
    tb.tx_cpl_sink.clear()

    # tid 1 is marked bad on the last beat, so the TX frame FIFO drops it.
    frames = [(1 if k == 1 else 0, k, incrementing_payload(64 + k)) for k in range(4)]
    expect_tid = [k for bad, k, _ in frames if not bad]

    for bad, tid, data in frames:
        await tb.axis_source.send(AxiStreamFrame(data, tid=tid, tuser=bad))

    for bad, tid, data in frames:
        if bad:
            continue
        rx_frame = await tb.rgmii_phy.tx.recv()
        assert rx_frame.get_payload() == data
        assert rx_frame.check_fcs()

    got_tid = []
    for k in range(len(expect_tid)):
        cpl = await tb.tx_cpl_sink.recv()
        # the completion is a single beat, so tid comes back as a scalar
        tid_val = cpl.tid[0] if isinstance(cpl.tid, (list, tuple)) else cpl.tid
        got_tid.append(int(tid_val))

    tb.log.info("submitted tids %s, dropped 1, completion tids %s",
                [f[1] for f in frames], got_tid)

    assert got_tid == expect_tid, "completion tid does not track the transmitted frame"

    for k in range(200):
        await RisingEdge(dut.logic_clk)

    assert tb.tx_cpl_sink.empty(), "dropped frame produced a completion"

    await RisingEdge(dut.logic_clk)


def size_list():
    return list(range(60, 128)) + [512, 1514] + [60]*10


def incrementing_payload(length):
    return bytearray(itertools.islice(itertools.cycle(range(256)), length))


def cycle_en():
    return itertools.cycle([0, 0, 0, 1])


if getattr(cocotb, 'top', None) is not None:

    for test in [run_test_rx, run_test_tx]:

        factory = TestFactory(test)
        factory.add_option("payload_lengths", [size_list])
        factory.add_option("payload_data", [incrementing_payload])
        factory.add_option("ifg", [12])
        factory.add_option("speed", [1000e6, 100e6, 10e6])
        factory.generate_tests()

    # Frame validation and completion pairing are speed-independent, so these
    # run at 1G only rather than tripling an already slow matrix.
    for test in [run_test_rx_bad_fcs, run_test_tx_cpl_tid]:

        factory = TestFactory(test)
        factory.add_option("ifg", [12])
        factory.add_option("speed", [1000e6])
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


def test_taxi_eth_mac_1g_rgmii_ptp_fifo(request):
    dut = "taxi_eth_mac_1g_rgmii_ptp_fifo"
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = module

    verilog_sources = [
        os.path.join(tests_dir, f"{toplevel}.sv"),
        os.path.join(rtl_dir, f"{dut}.f"),
    ]

    verilog_sources = process_f_files(verilog_sources)

    parameters = {}

    parameters['SIM'] = 1
    parameters['VENDOR'] = "\"XILINX\""
    parameters['FAMILY'] = "\"virtex7\""
    # The Zedboard build sets USE_CLK90 = 0 so the ADIN1300's strapped 2 ns TXC
    # delay is the only TX delay in the path.
    parameters['USE_CLK90'] = 0
    parameters['PTP_TS_EN'] = 1
    parameters['PTP_TS_W'] = 96
    parameters['AXIS_DATA_W'] = 8
    parameters['TX_TAG_W'] = 16
    parameters['STAT_EN'] = 1
    parameters['STAT_TX_LEVEL'] = 2
    parameters['STAT_RX_LEVEL'] = parameters['STAT_TX_LEVEL']
    parameters['STAT_ID_BASE'] = 0
    parameters['STAT_UPDATE_PERIOD'] = 1024
    parameters['STAT_STR_EN'] = 1
    parameters['STAT_PREFIX_STR'] = "\"MAC\""
    parameters['TX_FIFO_DEPTH'] = 16384
    parameters['TX_FIFO_RAM_PIPELINE'] = 1
    parameters['TX_FRAME_FIFO'] = 1
    parameters['TX_DROP_OVERSIZE_FRAME'] = parameters['TX_FRAME_FIFO']
    parameters['TX_DROP_BAD_FRAME'] = parameters['TX_DROP_OVERSIZE_FRAME']
    parameters['TX_DROP_WHEN_FULL'] = 0
    parameters['TX_CPL_FIFO_DEPTH'] = 64
    parameters['RX_FIFO_DEPTH'] = 16384
    parameters['RX_FIFO_RAM_PIPELINE'] = 1
    parameters['RX_FRAME_FIFO'] = 1
    parameters['RX_DROP_OVERSIZE_FRAME'] = parameters['RX_FRAME_FIFO']
    parameters['RX_DROP_BAD_FRAME'] = parameters['RX_DROP_OVERSIZE_FRAME']
    parameters['RX_DROP_WHEN_FULL'] = parameters['RX_DROP_OVERSIZE_FRAME']

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

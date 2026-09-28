#!/usr/bin/env python
# SPDX-License-Identifier: MIT
"""

Copyright (c) 2020-2025 FPGA Ninja, LLC
Copyright (c) 2026 Tom Brady

Authors:
- Alex Forencich
- Tom Brady

"""

import logging
import os

import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, with_timeout

from cocotbext.eth import GmiiFrame, RgmiiPhy


class TB:
    def __init__(self, dut, speed=1000e6):
        self.dut = dut

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk, 8, units="ns").start())

        self.baset_phy = RgmiiPhy(dut.phy_txd, dut.phy_tx_ctl, dut.phy_tx_clk,
            dut.phy_rxd, dut.phy_rx_ctl, dut.phy_rx_clk, speed=speed)

        # no PHY management model: MDIO idles high, as the pull-up leaves it
        dut.phy_int_n.setimmediatevalue(1)
        dut.phy_mdio_i.setimmediatevalue(1)

    async def init(self):

        self.dut.rst.setimmediatevalue(0)

        for k in range(10):
            await RisingEdge(self.dut.clk)

        self.dut.rst.value = 1

        for k in range(10):
            await RisingEdge(self.dut.clk)

        self.dut.rst.value = 0

        for k in range(10):
            await RisingEdge(self.dut.clk)


async def mac_test(tb, source, sink):
    tb.log.info("Test MAC")

    tb.log.info("Multiple small packets")

    count = 64

    pkts = [bytearray([(x+k) % 256 for x in range(60)]) for k in range(count)]

    for p in pkts:
        await source.send(GmiiFrame.from_payload(p))

    for k in range(count):
        rx_frame = await sink.recv()

        tb.log.info("RX frame: %s", rx_frame)

        assert rx_frame.get_payload() == pkts[k]
        assert rx_frame.check_fcs()
        assert rx_frame.error is None

    tb.log.info("Multiple large packets")

    count = 32

    pkts = [bytearray([(x+k) % 256 for x in range(1514)]) for k in range(count)]

    for p in pkts:
        await source.send(GmiiFrame.from_payload(p))

    for k in range(count):
        rx_frame = await sink.recv()

        tb.log.info("RX frame: %s", rx_frame)

        assert rx_frame.get_payload() == pkts[k]
        assert rx_frame.check_fcs()
        assert rx_frame.error is None

    tb.log.info("MAC test done")


async def vlan_test(tb, source, sink):
    tb.log.info("Full-size 802.1Q tagged packet")

    # 1518 bytes with the tag, 1522 on the wire with the FCS; an oversize drop
    # must fail the test rather than hang it
    hdr = bytes.fromhex('ffffffffffff' '5a5152535455' '8100' '0064' '22f0')
    pkt = bytearray(hdr + bytes(k % 256 for k in range(1518 - len(hdr))))

    await source.send(GmiiFrame.from_payload(pkt))

    rx_frame = await with_timeout(sink.recv(), 100, 'us')

    assert rx_frame.get_payload() == pkt
    assert rx_frame.check_fcs()
    assert rx_frame.error is None


@cocotb.test()
async def run_test(dut):

    tb = TB(dut)

    await tb.init()

    tb.log.info("Start BASE-T MAC loopback test")

    await mac_test(tb, tb.baset_phy.rx, tb.baset_phy.tx)
    await vlan_test(tb, tb.baset_phy.rx, tb.baset_phy.tx)

    # the counters read over the VIO on hardware must agree with the traffic
    status = dut.ctrl_status_inst
    assert status.rx_good_cnt_reg.value.integer == 97
    assert status.tx_good_cnt_reg.value.integer == 97
    assert status.rx_bad_fcs_cnt_reg.value.integer == 0
    assert status.rx_bad_frame_cnt_reg.value.integer == 0

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


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


def test_fpga_core(request):
    dut = "fpga_core"
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f"{dut}.sv"),
        os.path.join(rtl_dir, "ctrl_status.sv"),
        os.path.join(taxi_src_dir, "eth", "rtl", "taxi_eth_mac_1g_rgmii_fifo.f"),
        os.path.join(taxi_src_dir, "phy", "adin1300", "rtl", "phy_management.f"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_null_snk.sv"),
        os.path.join(taxi_src_dir, "sync", "rtl", "taxi_sync_signal.sv"),
    ]

    verilog_sources = process_f_files(verilog_sources)

    parameters = {}

    parameters['SIM'] = "1'b1"
    parameters['VENDOR'] = "\"XILINX\""
    parameters['FAMILY'] = "\"zynq\""

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

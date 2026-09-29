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
import struct
import sys

import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, with_timeout

from cocotbext.eth import GmiiFrame, RgmiiPhy
from cocotbext.uart import UartSource, UartSink

try:
    from xfcp import XfcpFrame
except ImportError:
    # attempt import from current directory
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    try:
        from xfcp import XfcpFrame
    finally:
        del sys.path[0]


class TB:
    def __init__(self, dut, speed=1000e6):
        self.dut = dut

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk, 8, units="ns").start())

        self.baset_phy = RgmiiPhy(dut.phy_txd, dut.phy_tx_ctl, dut.phy_tx_clk,
            dut.phy_rxd, dut.phy_rx_ctl, dut.phy_rx_clk, speed=speed)

        self.uart_source = UartSource(dut.uart_rxd, baud=921600, bits=8, stop_bits=1)
        self.uart_sink = UartSink(dut.uart_txd, baud=921600, bits=8, stop_bits=1)

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

    async def xfcp_request(self, pkt):
        await self.uart_source.write(pkt.build_cobs())

        rx_data = bytearray()
        while True:
            b = await self.uart_sink.read(1)
            if b[0] == 0:
                break
            rx_data.extend(b)

        return XfcpFrame.parse_cobs(rx_data)

    async def xfcp_read(self, path, addr, length):
        pkt = XfcpFrame(path=path, ptype=0x10, payload=struct.pack('<HH', addr, length))

        rx_pkt = await with_timeout(self.xfcp_request(pkt), 10, 'ms')

        # the reply carries the path back, and echoes the address and length
        assert rx_pkt.path == path
        assert rx_pkt.ptype == 0x11
        assert rx_pkt.payload[:4] == pkt.payload

        return rx_pkt.payload[4:]


# host and board addresses; LOCAL_MAC matches fpga_core
HOST_MAC = bytes.fromhex('5a5152535455')
LOCAL_MAC = bytes.fromhex('020000000001')
BCAST = b'\xff' * 6

ETHERTYPE_AVTP = 0x22F0

# XFCP paths: switch port 0 is the statistics module, whose own port 0 holds
# the 64-bit counters and port 1 their names
XFCP_STAT_COUNT = [0, 0]
XFCP_STAT_STR = [0, 1]

# MAC counter IDs, STAT_ID_BASE 0 at level 1: TX 0-15, RX 16-31
STAT_TX_PKTS = 1
STAT_RX_PKTS = 16+1


def l2_frame(dst, src, ethertype, payload, vlan=None):
    tag = b'' if vlan is None else struct.pack('>HH', 0x8100, vlan)
    return bytearray(dst + src + tag + struct.pack('>H', ethertype) + payload)


def payload_data(n, seed):
    return bytes((seed + k) & 0xff for k in range(n))


async def avtp_echo_test(tb, source, sink):
    tb.log.info("AVTP echo through minerva")

    # (frame sent, echo expected or None if it must be dropped)
    test_frames = []

    # every tail alignment, then full size
    for n in (46, 47, 48, 49, 1500):
        p = payload_data(n, n)
        test_frames.append((l2_frame(BCAST, HOST_MAC, ETHERTYPE_AVTP, p),
                            l2_frame(BCAST, LOCAL_MAC, ETHERTYPE_AVTP, p)))

    # full-size tagged, 1522 bytes on the wire, comes back untagged
    p = payload_data(1500, 7)
    test_frames.append((l2_frame(BCAST, HOST_MAC, ETHERTYPE_AVTP, p, vlan=100),
                        l2_frame(BCAST, LOCAL_MAC, ETHERTYPE_AVTP, p)))

    # anything that is not AVTP is dropped
    test_frames.insert(1, (l2_frame(BCAST, HOST_MAC, 0x88B5, payload_data(46, 1)), None))
    test_frames.insert(5, (l2_frame(BCAST, HOST_MAC, 0x0800, payload_data(1500, 2)), None))

    for frame, _ in test_frames:
        await source.send(GmiiFrame.from_payload(frame))

    for _, echo in test_frames:
        if echo is None:
            continue

        rx_frame = await with_timeout(sink.recv(), 100, 'us')

        tb.log.info("RX frame: %s", rx_frame)

        assert rx_frame.get_payload() == echo
        assert rx_frame.check_fcs()
        assert rx_frame.error is None

    # nothing else may come back
    for k in range(2000):
        await RisingEdge(tb.dut.clk)

    assert sink.empty()

    return len(test_frames), sum(1 for _, echo in test_frames if echo is not None)


@cocotb.test()
async def run_test(dut):

    tb = TB(dut)

    await tb.init()

    rx_count, tx_count = await avtp_echo_test(tb, tb.baset_phy.rx, tb.baset_phy.tx)

    # the counters read over the VIO on hardware must agree with the traffic
    status = dut.ctrl_status_inst
    assert status.rx_good_cnt_reg.value.integer == rx_count
    assert status.tx_good_cnt_reg.value.integer == tx_count
    assert status.rx_bad_fcs_cnt_reg.value.integer == 0
    assert status.rx_bad_frame_cnt_reg.value.integer == 0

    # INT_N reaches the VIO through phy_management, active high
    assert status.phy_irq.value.integer == 0
    dut.phy_int_n.value = 0
    for k in range(4):
        await RisingEdge(dut.clk)
    assert status.phy_irq.value.integer == 1
    dut.phy_int_n.value = 1

    # the same traffic counted by the MAC statistics, read over XFCP
    for stat_id, name, count in [(STAT_TX_PKTS, 'TX_PKTS', tx_count), (STAT_RX_PKTS, 'RX_PKTS', rx_count)]:
        val = int.from_bytes(await tb.xfcp_read(XFCP_STAT_COUNT, stat_id*8, 8), 'little')

        s = await tb.xfcp_read(XFCP_STAT_STR, stat_id*16, 16)
        s = (s[0:8].strip() + b"." + s[8:].strip()).decode('ascii')

        tb.log.info("%s = %d", s, val)

        assert s == f'BASET.{name}'
        assert val == count

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
        os.path.join(rtl_dir, "avtp_echo.sv"),
        os.path.join(taxi_src_dir, "minerva", "rtl", "minerva_rx_parse.sv"),
        os.path.join(taxi_src_dir, "minerva", "rtl", "minerva_tx_deparse.sv"),
        os.path.join(taxi_src_dir, "eth", "rtl", "taxi_eth_mac_1g_rgmii_fifo.f"),
        os.path.join(taxi_src_dir, "xfcp", "rtl", "taxi_xfcp_if_uart.f"),
        os.path.join(taxi_src_dir, "xfcp", "rtl", "taxi_xfcp_switch.sv"),
        os.path.join(taxi_src_dir, "xfcp", "rtl", "taxi_xfcp_mod_stats.f"),
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

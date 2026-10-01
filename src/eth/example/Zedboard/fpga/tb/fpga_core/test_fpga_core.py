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
from cocotb.triggers import RisingEdge, Timer, with_timeout

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

try:
    from mdio_slave import MdioSlave
except ImportError:
    # attempt import from current directory
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    try:
        from mdio_slave import MdioSlave
    finally:
        del sys.path[0]

try:
    import avtp
except ImportError:
    # attempt import from current directory
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    try:
        import avtp
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

        # the ADIN1300's MDIO side, at a non-zero address so the scan is real
        self.mdio_phy = MdioSlave(dut.phy_mdc, dut.phy_mdio_i, dut.phy_mdio_o, dut.phy_mdio_t,
            PHY_ADDR, {0x02: PHY_ID_1, 0x03: PHY_ID_2})

        dut.phy_int_n.setimmediatevalue(1)
        dut.build_id.setimmediatevalue(BUILD_ID)

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

    async def xfcp_write(self, path, addr, data):
        pkt = XfcpFrame(path=path, ptype=0x12, payload=struct.pack('<HH', addr, len(data)) + bytes(data))

        rx_pkt = await with_timeout(self.xfcp_request(pkt), 10, 'ms')

        # the reply carries the path back, and echoes the address and length
        assert rx_pkt.path == path
        assert rx_pkt.ptype == 0x13
        assert rx_pkt.payload[:4] == pkt.payload[:4]


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

# switch port 1 is the register block, rdl/zedboard_regs.rdl
XFCP_REGS = [1]

REG_SCRATCH = 0x1000
REG_BUILD_ID_0 = 0x1001
REG_PHY_STATUS = 0x1005
REG_PHY_ADDR = 0x1006
REG_MDIO_REG = 0x1007
REG_MDIO_CTRL = 0x100A
REG_MDIO_RDATA_0 = 0x100B
REG_IDELAY_TAP = 0x100D

PHY_STATUS_PRESENT = 0x01
PHY_STATUS_INIT_DONE = 0x02
PHY_STATUS_IRQ = 0x04
MDIO_CTRL_GO = 0x01
MDIO_CTRL_WRITE = 0x02
MDIO_CTRL_BUSY = 0x80

# the model PHY, and what USR_ACCESSE2 would supply on hardware
PHY_ADDR = 7
PHY_ID_1 = 0x0283
PHY_ID_2 = 0xBC30
BUILD_ID = 0x1A2B3C4D


def l2_frame(dst, src, ethertype, payload, vlan=None):
    tag = b'' if vlan is None else struct.pack('>HH', 0x8100, vlan)
    return bytearray(dst + src + tag + struct.pack('>H', ethertype) + payload)


def payload_data(n, seed):
    return bytes((seed + k) & 0xff for k in range(n))


async def record_echo_test(tb, source, sink):
    tb.log.info("Record echo through minerva")

    # the host puts its own address in stream_id, so the echoes come back to it
    stream_id = int.from_bytes(HOST_MAC, 'big') << 16 | 0x0001

    # (frame sent, echoes expected)
    test_frames = []

    def request(items, vlan=None, sv=1, cut=None):
        """A frame from the host holding these messages: an ABB message given
        by its payload length, or any other ACF message as bytes.  Each ABB
        message comes back alone in its own PDU, rebuilt from the record."""
        k = len(test_frames)
        msgs = []
        echoes = []
        for j, item in enumerate(items):
            if isinstance(item, bytes):
                msgs.append(item)
                continue
            byte_bus_id = (0x5ff + 0x123 * (k + j)) & 0x7ff
            mtv = j & 1
            word1 = avtp.abb_word1(evt=j & 0xf, transaction_num=(k + j) & 0xff, op=k & 1, read_size=0x100 + j)
            payload = payload_data(item, k + j)
            msg = avtp.abb_message(byte_bus_id, mtv, word1, payload)
            msgs.append(msg)
            pdu = avtp.ntscf_pdu(stream_id, k, [msg], sv=sv)
            echoes.append(l2_frame(HOST_MAC, LOCAL_MAC, ETHERTYPE_AVTP, pdu).ljust(60, b'\x00'))
        pdu = avtp.ntscf_pdu(stream_id, k, msgs, sv=sv)
        if cut is not None:
            # the frame ends inside the last payload, so it has no echo
            pdu = pdu[:cut]
            echoes.pop()
        test_frames.append((l2_frame(BCAST, HOST_MAC, ETHERTYPE_AVTP, pdu, vlan).ljust(60, b'\x00'), echoes))

    def drop(ethertype):
        test_frames.append((l2_frame(BCAST, HOST_MAC, ethertype, payload_data(46, len(test_frames))), []))

    # a record alone, then every pad
    request([0])
    request([1])
    drop(0x88B5)
    request([2], sv=0)
    request([3])
    request([4])

    # the largest payload, then tagged, 1522 bytes on the wire, which comes
    # back untagged
    request([1480])
    request([1480], vlan=100)
    drop(0x0800)

    # three messages come back as three frames, and another ACF type is
    # skipped
    request([5, 0, 12])
    request([2, avtp.acf_message(avtp.ACF_MSG_TYPE_CAN, payload_data(10, 0)), 7])

    # a frame ending inside a payload: minerva marks the packet with tuser and
    # the message FIFO drops it; the message before it still comes back
    request([8, 100], cut=12 + 16 + 8 + 60)
    request([6])

    for frame, _ in test_frames:
        await source.send(GmiiFrame.from_payload(frame))

    for _, echoes in test_frames:
        for echo in echoes:
            rx_frame = await with_timeout(sink.recv(), 100, 'us')

            tb.log.info("RX frame: %s", rx_frame)

            assert rx_frame.get_payload() == echo
            assert rx_frame.check_fcs()
            assert rx_frame.error is None

    # nothing else may come back
    for k in range(2000):
        await RisingEdge(tb.dut.clk)

    assert sink.empty()

    return len(test_frames), sum(len(echoes) for _, echoes in test_frames)


async def mdio_request(tb, reg, data=None):
    # MDIO_REG, WDATA_0, WDATA_1 and CTRL are consecutive, so one XFCP write
    # sets up and starts a request; it writes upward, so go lands last
    ctrl = MDIO_CTRL_GO | (MDIO_CTRL_WRITE if data is not None else 0)
    await tb.xfcp_write(XFCP_REGS, REG_MDIO_REG, struct.pack('<BHB', reg, data or 0, ctrl))

    while (await tb.xfcp_read(XFCP_REGS, REG_MDIO_CTRL, 1))[0] & MDIO_CTRL_BUSY:
        pass

    return int.from_bytes(await tb.xfcp_read(XFCP_REGS, REG_MDIO_RDATA_0, 2), 'little')


async def registers_test(tb):
    tb.log.info("Registers over XFCP")

    dut = tb.dut

    # scratch resets to 0 and reads back what was written
    assert await tb.xfcp_read(XFCP_REGS, REG_SCRATCH, 1) == b'\x00'
    await tb.xfcp_write(XFCP_REGS, REG_SCRATCH, b'\x5a')
    assert await tb.xfcp_read(XFCP_REGS, REG_SCRATCH, 1) == b'\x5a'

    # build ID, LSB first
    build_id = int.from_bytes(await tb.xfcp_read(XFCP_REGS, REG_BUILD_ID_0, 4), 'little')
    assert build_id == BUILD_ID

    # the IDELAY tap resets to 12, and a write loads the new tap exactly once
    assert await tb.xfcp_read(XFCP_REGS, REG_IDELAY_TAP, 1) == bytes([12])

    loads = []

    async def watch_idelay():
        while True:
            await RisingEdge(dut.clk)
            if int(dut.phy_rx_idelay_load.value):
                loads.append(int(dut.phy_rx_idelay_value.value))

    watcher = cocotb.start_soon(watch_idelay())
    await tb.xfcp_write(XFCP_REGS, REG_IDELAY_TAP, bytes([20]))
    for k in range(10):
        await RisingEdge(dut.clk)
    watcher.kill()

    assert loads == [20]
    assert await tb.xfcp_read(XFCP_REGS, REG_IDELAY_TAP, 1) == bytes([20])

    # the PHY: adin1300_init waits 5 ms after reset before it scans
    for k in range(100):
        status = (await tb.xfcp_read(XFCP_REGS, REG_PHY_STATUS, 1))[0]
        if status & PHY_STATUS_INIT_DONE:
            break
        await Timer(200, 'us')

    tb.log.info("PHY_STATUS = 0x%02x", status)

    assert status == PHY_STATUS_PRESENT | PHY_STATUS_INIT_DONE
    assert await tb.xfcp_read(XFCP_REGS, REG_PHY_ADDR, 1) == bytes([PHY_ADDR])

    # the MDIO window reads the PHY ID and writes a register at the scanned address
    assert await mdio_request(tb, 0x02) == PHY_ID_1
    assert await mdio_request(tb, 0x03) == PHY_ID_2

    await mdio_request(tb, 0x10, 0xFF23)
    assert tb.mdio_phy.writes[-1] == (PHY_ADDR, 0x10, 0xFF23)
    assert await mdio_request(tb, 0x10) == 0xFF23


@cocotb.test()
async def run_test(dut):

    tb = TB(dut)

    await tb.init()

    rx_count, tx_count = await record_echo_test(tb, tb.baset_phy.rx, tb.baset_phy.tx)

    # INT_N reaches PHY_STATUS through adin1300_management, active high
    assert not (await tb.xfcp_read(XFCP_REGS, REG_PHY_STATUS, 1))[0] & PHY_STATUS_IRQ
    dut.phy_int_n.value = 0
    for k in range(4):
        await RisingEdge(dut.clk)
    assert (await tb.xfcp_read(XFCP_REGS, REG_PHY_STATUS, 1))[0] & PHY_STATUS_IRQ
    dut.phy_int_n.value = 1

    # the traffic counted by the MAC statistics, read over XFCP
    for stat_id, name, count in [(STAT_TX_PKTS, 'TX_PKTS', tx_count), (STAT_RX_PKTS, 'RX_PKTS', rx_count)]:
        val = int.from_bytes(await tb.xfcp_read(XFCP_STAT_COUNT, stat_id*8, 8), 'little')

        s = await tb.xfcp_read(XFCP_STAT_STR, stat_id*16, 16)
        s = (s[0:8].strip() + b"." + s[8:].strip()).decode('ascii')

        tb.log.info("%s = %d", s, val)

        assert s == f'BASET.{name}'
        assert val == count

    await registers_test(tb)

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
        # lint waivers for the generated register block, then its package,
        # which must be read before anything that uses it
        os.path.join(rtl_dir, "zedboard_regs.vlt"),
        os.path.join(rtl_dir, "zedboard_regs_pkg.sv"),
        os.path.join(rtl_dir, f"{dut}.sv"),
        os.path.join(rtl_dir, "zedboard_regs.sv"),
        os.path.join(rtl_dir, "record_echo.sv"),
        os.path.join(taxi_src_dir, "minerva", "rtl", "minerva_rx_parse.sv"),
        os.path.join(taxi_src_dir, "minerva", "rtl", "minerva_tx_deparse.sv"),
        os.path.join(taxi_src_dir, "eth", "rtl", "taxi_eth_mac_1g_rgmii_fifo.f"),
        os.path.join(taxi_src_dir, "xfcp", "rtl", "taxi_xfcp_if_uart.f"),
        os.path.join(taxi_src_dir, "xfcp", "rtl", "taxi_xfcp_switch.sv"),
        os.path.join(taxi_src_dir, "xfcp", "rtl", "taxi_xfcp_mod_stats.f"),
        os.path.join(taxi_src_dir, "xfcp", "rtl", "taxi_xfcp_mod_apb.f"),
        os.path.join(taxi_src_dir, "phy", "adin1300", "rtl", "adin1300_management.f"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_fifo.sv"),
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

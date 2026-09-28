#!/usr/bin/env python
# SPDX-License-Identifier: MIT
"""

Copyright (c) 2026 Tom Brady

Authors:
- Tom Brady

"""

import logging
import os

import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from cocotb.regression import TestFactory


PHY_ID_1 = 0x0283
PHY_ID_2 = 0xBC30


class MdioSlave:
    """Minimal MDIO slave: clause 22 reads and writes, clause 45 address and
    write frames.

    Answers only at its own address, which is what makes the address scan a
    real test: every other address must float high and be rejected.  Written
    here rather than taken from cocotbext because cocotbext.eth has no MDIO
    model.
    """

    def __init__(self, mdc, mdio_i, mdio_o, mdio_t, addr, regs):
        self.mdc = mdc
        self.mdio_i = mdio_i
        self.mdio_o = mdio_o
        self.mdio_t = mdio_t
        self.addr = addr
        self.regs = regs
        self.log = logging.getLogger("cocotb.mdio")
        self.reads = []
        self.writes = []
        # clause 45: the address last set per device, and (prtad, devad,
        # register, data) per write
        self.mmd_addr = {}
        self.c45_writes = []
        cocotb.start_soon(self._run())

    def _drive(self, value):
        # the master's own output loops back while it is driving; the slave
        # only takes the bus once the master releases it
        self.mdio_i.value = value

    async def _run(self):
        self.mdio_i.setimmediatevalue(1)
        ones = 0
        while True:
            await RisingEdge(self.mdc)

            if int(self.mdio_t.value) == 0:
                bit = int(self.mdio_o.value)
                self._drive(bit)
                if bit:
                    ones += 1
                    continue
                if ones < 32:
                    ones = 0
                    continue
                # start of frame: bit just sampled is ST[1] = 0
                ones = 0
                await self._frame()
            else:
                self._drive(1)

    async def _frame(self):
        async def get(n):
            v = 0
            for _ in range(n):
                await RisingEdge(self.mdc)
                v = (v << 1) | int(self.mdio_o.value)
                self._drive(int(self.mdio_o.value))
            return v

        st1 = await get(1)          # ST[0]
        op = await get(2)
        phyad = await get(5)
        regad = await get(5)

        if st1 == 0:
            # clause 45: PRTAD, DEVAD, then 16 bits from the master for an
            # address or write frame
            if op not in (0b00, 0b01) or phyad != self.addr:
                return
            await get(2)
            data = await get(16)
            if op == 0b00:
                self.mmd_addr[regad] = data
            else:
                self.c45_writes.append((phyad, regad, self.mmd_addr.get(regad), data))
            self._drive(1)
            return

        if op not in (0b01, 0b10):
            return

        if phyad != self.addr:
            # not us - leave the bus alone, the pull-up returns 0xFFFF
            return

        if op == 0b01:
            # write: master drives TA then 16 data bits
            await get(2)
            data = await get(16)
            self.writes.append((phyad, regad, data))
            self.regs[regad] = data
            self._drive(1)
            return

        # turnaround: master released at the first TA bit, slave drives 0
        await RisingEdge(self.mdc)
        self._drive(0)
        await RisingEdge(self.mdc)

        data = self.regs.get(regad, 0xFFFF)
        self.reads.append((phyad, regad))
        for i in range(16):
            self._drive((data >> (15 - i)) & 1)
            await RisingEdge(self.mdc)
        self._drive(1)


async def run_test(dut, phy_addr=7, present=True):

    log = logging.getLogger("cocotb.tb")
    log.setLevel(logging.DEBUG)

    cocotb.start_soon(Clock(dut.clk, 8, units="ns").start())

    regs = {0x02: PHY_ID_1, 0x03: PHY_ID_2} if present else {0x02: 0x1234}
    slave = MdioSlave(dut.mdc, dut.mdio_i, dut.mdio_o, dut.mdio_t,
                      phy_addr, regs)

    dut.rst.setimmediatevalue(1)
    for _ in range(10):
        await RisingEdge(dut.clk)

    assert int(dut.phy_reset_n.value) == 0, "PHY must be held in reset"

    dut.rst.value = 0

    # the PHY reset must be released before any MDIO traffic, and must be a
    # single clean edge - the ADIN1300 samples its straps on it
    seen_release = False
    edges = 0
    prev = 0
    for _ in range(2000):
        await RisingEdge(dut.clk)
        cur = int(dut.phy_reset_n.value)
        if cur != prev:
            edges += 1
            prev = cur
        if cur:
            seen_release = True
        if int(dut.done.value):
            break

    assert seen_release, "PHY reset never released"
    assert edges == 1, f"phy_reset_n glitched: {edges} transitions"

    # let the scan finish
    for _ in range(200000):
        if int(dut.done.value):
            break
        await RisingEdge(dut.clk)

    assert int(dut.done.value), "sequencer did not finish"

    # done asserts when the last command is accepted by the master, not when it
    # has been shifted onto the wire - let the final frame complete
    for _ in range(2000):
        await RisingEdge(dut.clk)

    log.info("present=%d addr=%d id=%08x reads=%d",
             int(dut.phy_present.value), int(dut.phy_addr.value),
             int(dut.phy_id.value), len(slave.reads))

    if present:
        assert int(dut.phy_present.value) == 1
        assert int(dut.phy_addr.value) == phy_addr
        assert int(dut.phy_id.value) == (PHY_ID_1 << 16) | PHY_ID_2
        # every address below the PHY's must have been probed, and no more
        probed = [a for a, r in slave.reads if r == 0x02]
        assert probed == [phy_addr], "slave answered an address that is not its own"

        # the RGMII receive delay must be turned off at the PHY, or the board
        # comes up unable to receive: GE_RGMII_CFG is 0xFF23 on device 0x1E
        assert slave.writes == [], f"unexpected clause 22 writes: {slave.writes}"
        assert slave.c45_writes == [(phy_addr, 0x1E, 0xFF23, 0x0E03)], \
            f"PHY config write wrong or missing: {slave.c45_writes}"
    else:
        assert int(dut.phy_present.value) == 0
        assert slave.writes == [] and slave.c45_writes == [], \
            "configured a PHY that was never identified"
    for _ in range(10):
        await RisingEdge(dut.clk)


if getattr(cocotb, 'top', None) is not None:

    factory = TestFactory(run_test)
    factory.add_option("phy_addr", [0, 7, 31])
    factory.add_option("present", [True])
    factory.generate_tests()

    factory = TestFactory(run_test)
    factory.add_option("phy_addr", [7])
    factory.add_option("present", [False])
    factory.generate_tests(postfix="_absent")


# cocotb-test

tests_dir = os.path.abspath(os.path.dirname(__file__))
rtl_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'rtl'))
lib_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'lib'))
taxi_src_dir = os.path.abspath(os.path.join(lib_dir, 'taxi', 'src'))


def test_phy_init(request):
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = module

    verilog_sources = [
        os.path.join(tests_dir, f"{toplevel}.sv"),
        os.path.join(rtl_dir, "phy_init.sv"),
        os.path.join(taxi_src_dir, "lss", "rtl", "taxi_mdio_master.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_if.sv"),
    ]

    parameters = {}
    parameters['PHY_ID_1'] = PHY_ID_1
    parameters['PHY_ID_2'] = PHY_ID_2
    parameters['RESET_LOW_CYCLES'] = 8
    parameters['RESET_WAIT_CYCLES'] = 32
    parameters['PRESCALE'] = 4

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

# SPDX-License-Identifier: MIT
"""

Copyright (c) 2026 Tom Brady

Authors:
- Tom Brady

"""

import logging

import cocotb
from cocotb.triggers import RisingEdge


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

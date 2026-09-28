#!/usr/bin/env python
# SPDX-License-Identifier: MIT
"""

Copyright (c) 2026 Tom Brady

Authors:
- Tom Brady

"""

from cocotb.triggers import RisingEdge


async def check_axis_stable(bus, clk, rst=None):
    """Once tvalid rises, it and the word must hold until the handshake.

    AxiStreamSink only samples on the handshake, so a word that changes while
    stalled passes it unseen.  Start this on an output bus alongside the sink.
    """

    names = [n for n in ('tdata', 'tkeep', 'tlast', 'tid', 'tdest', 'tuser') if hasattr(bus, n)]
    held = None

    while True:
        await RisingEdge(clk)

        if rst is not None and rst.value.integer:
            held = None
            continue

        word = {n: getattr(bus, n).value.binstr for n in names}

        if held is not None:
            assert bus.tvalid.value.integer, "tvalid dropped before the handshake"
            for n in names:
                assert word[n] == held[n], f"{n} changed while stalled: {held[n]} -> {word[n]}"

        stalled = bus.tvalid.value.integer and not bus.tready.value.integer
        held = word if stalled else None

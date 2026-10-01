# Zedboard + EVAL-ADIN1300FMCZ — architecture

The structural view of what gets built and why. Hardware facts are in
`board.md`.

## Goal

1G RGMII endpoint on a Zedboard with an ADI ADIN1300 FMC card. The device does
three things, and only these:

1. Process AVTP (IEEE 1722) ABB messages, driving an I2C master.
2. Process PTP.
3. Switch L2 traffic to a second MAC (far future).

Order of work: **Ethernet path → minerva → ABB to I2C → PTP.** A stage
is done when it works on the board, not only in simulation.

## Layout

The board design follows taxi's example convention and pulls each block in
through `lib/taxi`, so every block can be validated on its own.

```
src/eth/example/Zedboard/fpga/
  rtl/fpga.sv            clocks, reset, receive IDELAY, MDIO tristate, UART pins
  rtl/fpga_core.sv       MAC, minerva, PHY management, XFCP, registers
  rtl/record_echo.sv     test fixture: turns each RX record into a reply TX record
  rtl/zedboard_regs*.sv  register block, generated from rdl/ by PeakRDL
  rdl/                   zedboard_regs.rdl, the register map
  tb/fpga_core/          whole-core bench from the RGMII pins and the UART
  utils/                 echo_test.py, xfcp_regs.py, xfcp_stats.py (host)
src/minerva/             IEEE 1722 packet processor: minerva_rx_parse, minerva_tx_deparse
src/phy/adin1300/        PHY reset, identification, init table, MDIO access
```

## Datapath

```
ADIN1300 ◄─RGMII─► IDELAYE2 (RX, tap 12) ─► taxi_eth_mac_1g_rgmii_fifo
                                              │ m_axis_rx        ▲ s_axis_tx
                                              ▼                  │
                                      minerva_rx_parse   minerva_tx_deparse
                                              │ m_axis_eth_rx    ▲ s_axis_eth_tx
                                         message FIFO            │
                                              │                  │
                                              └──► record_echo ──┘
                                              (I2C consumer later)

Host ─UART, Pmod JA─► taxi_xfcp_if_uart ─► taxi_xfcp_switch
                                             ├─ port 0 ─► taxi_xfcp_mod_stats   MAC statistics
                                             └─ port 1 ─► taxi_xfcp_mod_apb ─► zedboard_regs

ADIN1300 ◄─MDIO/MDC, RESET_N── adin1300_management ◄── zedboard_regs
                               (adin1300_init, _mdio_cmd, _mdio_arb; INT_N in)
```

`fpga.sv` holds the MMCM (100 MHz in; `clk_int` 125 MHz and 200 MHz for
IDELAYCTRL out), the reset synchroniser, the receive IDELAYs and the MDIO
IOBUF. Everything else is in `fpga_core.sv`.

All fabric logic runs on `clk_int`, 125 MHz. The receive clock enters through a
BUFG inside the MAC, and the MAC's async FIFOs cross into `clk_int`. The logic
side is 32 bits wide: 4 Gb/s of capacity against a 1 Gb/s line.

## Stream contracts

Every stream is a 32-bit `taxi_axis_if` with `tkeep`, lane 0 first on the wire.
Ports are named for the side they face, as in zircon: `mac_` toward the MAC,
`eth_` toward the protocol sections or the switch.

| Stream | Carries |
|---|---|
| MAC `m_axis_rx` → `s_axis_mac_rx` | Whole frame, destination first, FCS stripped. Bad FCS, framing errors and oversize frames are already dropped by the MAC RX FIFO, so `tuser` is not examined. |
| `m_axis_eth_rx` | One packet per ACF message: the 4-word record, then the payload from lane 0. `tid` is the format, `tdest` the route, `tuser` a truncated message. |
| `s_axis_eth_tx` | One packet per message: the 6-word TX record (the RX record with the destination added), then the payload. |
| `m_axis_mac_tx` → MAC `s_axis_tx` | Whole frame with `LOCAL_MAC` as source. The MAC pads to 60 bytes and appends the FCS. |

The record layouts are in `src/minerva/docs/minerva.md`. Header fields exist
only to route: nothing past minerva receives the L2 header.

Addressing belongs to the consumer. `stream_id[63:16]` is the MAC of the
stream's talker and `[15:0]` its UniqueID, 0 with one stream each way. A reply
goes to the talker of the request's stream and carries the board's own stream,
`{LOCAL_MAC, 0}`.

`LOCAL_MAC` is a register (`net`, 0x1100), reset to `02:00:00:00:00:01`
(locally administered). It is the frame source and the consumer's `stream_id`.

### Minerva

The IEEE 1722 packet processor in zircon's shape, one FSM each way, cut to NTSCF
with ABB and none of zircon's L3/L4, checksums or buffering. Its records and
checks are in `src/minerva/docs/minerva.md`. Both modules register their
handshakes with taxi's output datapath, as `taxi_mac_ctrl_rx` does, so every
port signal leaves a flip-flop.

**`minerva_rx_parse`** removes the L2 header, routes by ethertype, then parses
AVTP, NTSCF, ACF and ABB into a record per message. The ethertype decode is one
`always_comb` block, as in `zircon_ip_rx_parse`:

| Ethertype | Result |
|---|---|
| 0x8100, 0x88A8 | one VLAN tag, then decode the inner ethertype; a second tag drops |
| 0x22F0 AVTP | pass, route 0 |
| anything else | drop |

A frame that ends inside the header drops. The header is 14 or 18 bytes, both
two past a word boundary, so holding two bytes back from each word puts the
payload at lane 0 — the only realignment in the receive path.

**`minerva_tx_deparse`** builds the whole frame from a TX record: the L2 header
from the record's destination and `cfg_local_mac`, then NTSCF and ABB. The 34
header bytes leave the payload two bytes past a word boundary, the receive
shift in reverse. A payload that does not match its record ends the frame with
`tuser` set, so the MAC TX FIFO drops it.

**Adding a protocol** is one case arm and a route code. A second live route
brings a `taxi_axis_demux` (`TDEST_ROUTE`) after the parser and a
`taxi_axis_arb_mux` before the deparser, probably wrapped as `minerva_rx` and
`minerva_tx` so the route codes and port numbers live in one place. PTP was
removed from the table until then, so it cannot reach the AVTP consumer.

## Decisions

**Upstream MAC, 1522 byte frames.** `taxi_eth_mac_1g_rgmii_fifo` with frame
FIFOs of 4096 bytes that drop bad frames. The length limits count the FCS and
make no allowance for a tag, so both are set to 1522 — at 1518 a full-size
802.1Q tagged frame was dropped, and AVTP streams commonly carry a priority tag.

**`USE_CLK90 = 0`.** The ADIN1300 straps to RGMII with a 2 ns internal delay on
TXC, so the fabric must not add a second one. Confirmed on the wire.

**BUFG on receive — forced, not chosen.** Confirmed against the device database
(Vivado 2025.1, `xc7z020clg484-1`):

| | Pin | Bank | Clock region |
|---|---|---|---|
| RXC | N19 `IO_L14P_T2_SRCC_34` | 34 | **X1Y1** |
| RXD[3:0], RX_CTL | E20/E18/D22/D21, G20 | 35 | **X1Y2** |
| TXC | B19 `IO_L13P_T2_MRCC_35` | 35 | X1Y2 |
| TXD[3:0], TX_CTL, MDIO, MDC | J22/K18/J21/J18, K19, J20/K21 | 34 | X1Y1 |

X1Y1 and X1Y2 are adjacent, so a BUFMR into X1Y2's BUFIOs was geometrically
possible — but **RXC lands on an SRCC pin**, and single-region clock-capable
pins cannot drive a BUFMR (UG472). No regional route reaches the data in X1Y2,
so `taxi_ssio_ddr_in`'s BUFG branch is the only option, and `FAMILY = "zynq"`
selects it deliberately. One pin over, LA00_CC (M19, MRCC) would have allowed
a BUFMR; the eval card uses it for an unpopulated TXC alternate instead.

Transmit also straddles the boundary but is far milder: every TX signal is an
output driven from `clk_int` through ODDRs, and a BUFG reaches both regions.

**The PHY's receive delay is off.** RGMII needs about 2 ns of clock delay
relative to data, from either the PHY or the board. Here the BUFG's insertion
delay already supplies it, and the PHY's 2 ns on top put sampling a full bit
period late — nothing decoded. Simulation could not catch it (the primitives
are bypassed under `SIM=1`) and static timing never analysed the capture path;
it was found by sweeping `GE_RGMII_CFG` over MDIO against a frame counter.
`adin1300_init` clears `GE_RGMII_RX_ID_EN` at startup.

**Receive eye, measured 2026-09-09** under a sustained broadcast flood, sweeping
the `IDELAYE2` tap over JTAG:

| taps | result |
|---|---|
| 0–24 | ~1400 frames per 3 s window, **zero** FCS errors |
| 25–31 | no frames |

25 taps at ~78 ps ≈ **1.95 ns of a 4 ns bit period**, with the hold edge below
tap 0, so the true eye is wider. `PHY_RX_IDELAY = 12` in `fpga.sv` leaves
≥0.94 ns of proven margin each way. The IDELAYs are `VAR_LOAD`, so the tap can
be re-swept from the `IDELAY_TAP` register, which resets to 12. MMCM deskew on RXC
would restore the PHY's 2 ns as the only delay, but costs an MMCM and rules out
10/100; not worth it against this margin. The failure mode is silence, not
corruption — a mis-sampled preamble never matches SFD — so only the good-frame
count marks the eye's edges.

**PHY initialisation is a table.** `adin1300_init` holds the PHY in reset for
100 µs, waits 5 ms, scans MDIO addresses for the ADIN1300 ID, then writes
`init_data` — a ROM of standard MDIO frames filled in an `initial` block, as
taxi's `taxi_i2c_init` does. Today it writes two registers: `GE_RGMII_CFG`
(0xFF23) = 0x0E03, a Clause 45 address and write to device 0x1E; and
`IRQ_MASK` (0x18) = 0x0005, a Clause 22 write enabling `INT_N` for a link
status change only. Adding a register is one line.

**The PHY interrupt reaches the registers.** `adin1300_management` synchronises
`INT_N` and reports it as `PHY_STATUS.irq`, active high. It asserts on a link
change and holds until `IRQ_STATUS` (0x19) is read through the MDIO window.
Note that `link_speed` is no link indicator: it is inferred from RXC, which the
PHY keeps running with the cable out.

**Control and status over XFCP.** The host reaches the fabric through a UART on
Pmod JA at 921600 baud and taxi's XFCP chain, as in the Arty example. Port 0
reads the MAC statistics (`taxi_xfcp_mod_stats`, named 64-bit counters). Port 1
bridges to APB and the register block PeakRDL generates from
`rdl/zedboard_regs.rdl`; `docs/registers.md` is the map. Registers are 8 bits,
wider values split LSB first. `diag` at 0x1000 holds the scratch register,
build ID, PHY status and address, the MDIO window (Clause 22 only) and the
IDELAY tap; `net` at 0x1100 holds `LOCAL_MAC`. 0x0000–0x0FFF is reserved for
the server, which brings its own register block, to be joined by
`taxi_apb_interconnect`. `utils/xfcp_regs.py` reads and writes registers by
name; `utils/xfcp_stats.py` reads the counters.

## Verified in simulation

Verilator 5.038, cocotb. Each bench has been shown to fail against
deliberately planted bugs.

| Bench | Covers |
|---|---|
| `src/minerva/tb/minerva_rx_parse` | Records and payloads at every pad up to 1480 bytes, concatenated messages, skipped types, truncation; drops for other ethertypes, subtypes and versions, bad lengths, a double tag and runts; untagged, C-tag and S-tag, `VLAN_EN` on and off; idle and backpressure |
| `src/minerva/tb/minerva_tx_deparse` | Each record built into its frame byte for byte at every pad and 1480 bytes; `cfg_local_mac` changes; drops for an unknown format or route and records that do not match their payload; `tuser` for a short, long or aborted payload; idle and backpressure |
| `src/minerva/tb/minerva_loopback` | A record through the deparser and the parser comes back unchanged; the wire carries the destination and `cfg_local_mac` |
| `src/phy/adin1300/tb/adin1300_init` | One clean reset edge; ID scan with the PHY at addresses 0, 7, 31 and absent; the Clause 45 `GE_RGMII_CFG` write and the Clause 22 `IRQ_MASK` write, nothing else |
| `tb/fpga_core` | From the RGMII pins: each ABB message answered in the board's stream at every pad and at full size, a 1522 byte tagged request answered untagged, three messages answered separately, truncated and other frames dropped; over the UART, every register, a reply following a changed `LOCAL_MAC`, MAC statistics in agreement; `INT_N` reaches `PHY_STATUS` |

Every minerva bench also runs `axis_stable.py`, which fails a test if an output
word changes while stalled. `AxiStreamSink` samples only on the handshake and
cannot see that; it is the class of bug the old `eth_tx` had.

## Verified on hardware

Direct link to a host, `utils/echo_test.py`, and the XFCP scripts over the
Pmod UART.
Round-trip times (median 100–150 µs) measure the host stack, not the fabric.

| Date | Build | Result |
|---|---|---|
| 2026-09-09 | PHY bring-up | ID read over MDIO, straps at defaults, receive eye measured |
| 2026-09-10 | original echo design | first frames through the fabric and back over the cable |
| 2026-09-28 | MAC loopback, taxi layout | 64 B, 1514 B and 60 s sustained (5867 frames): no loss or corruption; RX = TX counters, no bad frames |
| 2026-09-28 | `phy_init` over Clause 45 | receive works, so `RX_ID_EN` was cleared; recovers after BTNC and a cable replug |
| 2026-09-28 | 1522 byte limit | 1518 byte frames (1522 on the wire) echoed |
| 2026-09-28 | minerva AVTP echo | 64 B and 1514 B echoed byte-exact from `LOCAL_MAC` to broadcast; other ethertypes dropped; no bad frames; timing met, WNS 0.176 ns |
| 2026-09-29 | PHY interrupt | `phy_irq` latched on link-up, cleared by reading `IRQ_STATUS` (0x014D), set again on unplugging; AVTP echo unaffected |
| 2026-09-29 | MAC statistics over XFCP | after `echo_test.py -c 1000`, `TX_PKTS` and `RX_PKTS` each rose by exactly 1000; no error counter moved |
| 2026-09-29 | PeakRDL registers over XFCP | build ID decodes, scratch reads back, the MDIO window reads the PHY ID and clears the interrupt, an `IDELAY_TAP` write leaves the echo clean; WNS +0.123 ns |
| 2026-09-30 | record echo, `minerva-0.1.0` | 1000 requests at 12 B, payloads of 13–15 and 1480 B, three messages per request: nothing lost or corrupt, MAC statistics match; WNS +0.900 ns |
| 2026-10-01 | TX record echo, `minerva-0.2.0` | `echo_test.py` clean, replies in the board's stream from the `LOCAL_MAC` register; WNS +0.551 ns, worst path the reset fan-out to the XFCP APB bridge |

After BTNC, the first one or two frames of a run can be lost while the link
re-trains. The counters show they never reach the FPGA.

## Not verified

- **Line rate.** `echo_test.py` sends about 100 frames/s, ~0.1% of 1G, so the
  MAC FIFOs have never run full on the board. Needs a traffic generator; the
  64-bit MAC statistics can count it.
- **Tagged frames from a host.** The 1522 byte limit was checked with untagged
  1518 byte frames; tag stripping is covered in simulation only.
- **10/100.** Every measurement is at 1G.
- **Pin timing margin and the bank 34/35 BUFG skew** across voltage and
  temperature. One board, one room.
- **PTP.**

## PTP (deferred)

The upstream 1G MAC wrapper does not pass `PTP_TS_EN` through. A fork that did
was removed on 2026-10-01 (`cf74114`), to be redone when PTP resumes. The 1G MAC
family has no `taxi_ptp_td_leaf`, so time reaches the MAC through
`taxi_ptp_clock_cdc` only.

## Open questions

- 802.1AS uses peer delay (Pdelay_Req/Resp/Resp_Follow_Up). How `rateRatio`
  and `correctionField` should feed the servo is a spec question, not one to
  infer.

## Bring-up history

Hardware started before the MAC worked. The ladder: read the PHY ID over MDIO;
drive the PHY's frame checker and generator to isolate transmit from receive;
all-digital loopback; then a real link to a host — complete by 2026-09-10. The
JTAG scripts it used were removed on 2026-09-28.

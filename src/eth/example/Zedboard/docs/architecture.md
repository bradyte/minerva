# Zedboard + EVAL-ADIN1300FMCZ — architecture

Seed document. `../MIGRATION.md` holds the porting rationale and board findings;
this file is the structural view of what gets built.

## Goal

1G RGMII endpoint on a Zedboard with an ADI ADIN1300 FMC card. Two deliverables,
in order:

1. Synchronise to a gPTP grandmaster (802.1AS) and emit a 1PPS locked to it.
2. IEEE 1722 control and audio — the actual deliverable; PTP is the foundation.

## Layers

```
                     ┌─────────────────────────────────────────┐
                     │              dig_top                    │
   ADIN1300  RGMII   │  ┌────────────────────────────────────┐ │
   ─────────────────►│  │ taxi_eth_mac_1g_rgmii_ptp_fifo     │ │
   RXC/RXD[3:0]      │  │  (fork: upstream discards the ts)  │ │
   RX_CTL            │  └──┬──────────────┬──────────────────┘ │
                     │     │ m_axis_rx    │ m_axis_tx_cpl      │
   TXC/TXD[3:0]      │     │ tuser[96:1]  │ tdata=ts, tid=tag  │
   TX_CTL   ◄────────│     │ = RX ts      │                    │
                     │     ▼              ▼                    │
                     │  ┌────────────────────────────────────┐ │
                     │  │ packet_router — L2 strip,          │ │
                     │  │ EtherType demux (0x88F7 / 0x22F0)  │ │
                     │  └──┬──────────────────────┬──────────┘ │
                     │     │ PTP                  │ 1722       │
                     │     ▼                      ▼            │
                     │  ┌──────────┐        ┌──────────────┐   │
                     │  │ ptp_core │        │ avtp_rx      │   │
                     │  │  servo   │        │ control+audio│   │
                     │  └────┬─────┘        └──────────────┘   │
                     │       │ period/offset                   │
                     │       ▼                                 │
                     │  ┌──────────────┐   ┌────────────────┐  │
                     │  │taxi_ptp_clock│──►│taxi_ptp_perout │──┼──► 1PPS
                     │  │  (the PHC)   │   │ 1s / 1us deflt │  │
                     │  └──────┬───────┘   └────────────────┘  │
                     │         │ ptp_ts_in (96b ToD)           │
                     │         └──────────► back to the MAC    │
                     └─────────────────────────────────────────┘
   MDIO ◄────────────── taxi_mdio_master (PHY config + diagnostics)
```

## Decisions already made

**The MAC is a fork.** `taxi_eth_mac_1g_rgmii_fifo` hardcodes `PTP_TS_EN = 0`,
so it drops the timestamps the MAC below it already produces. The fork
`taxi_eth_mac_1g_rgmii_ptp_fifo` plumbs the parameter through and adds two
`taxi_ptp_clock_cdc` instances. Everything else — the completion interface, its
FIFO, the widened RX `tuser` — was already present upstream.

**No `PTP_TD_EN`.** The 1G MAC family has no `taxi_ptp_td_leaf`, unlike the
BASE-X and 10G MACs. Time reaches the MAC clock domains through
`taxi_ptp_clock_cdc` only, which is the right shape for a single port. Note this
means the design exercises a taxi code path that taxi's own tests do not — the
basex testbench defaults to `PTP_TD_EN = 1` and takes the other branch.

**`USE_CLK90 = 0`.** The ADIN1300 straps to RGMII with a 2 ns internal delay on
TXC, so the fabric must not add a second one. Confirmed on the wire by the echo
below.

**The PHY's receive delay is turned off.** The premise that "the PHY supplies
both delays, so the fabric adds none" held for transmit but was wrong for
receive: the BUFG the bank split forces is itself supplying the receive delay,
and the PHY's 2 ns on top put sampling a full bit period late. Nothing caught
this — simulation bypasses the primitives under `SIM=1`, and static timing never
analysed the capture path. It was found by sweeping `GE_RGMII_CFG` over MDIO
against a frame counter. `phy_init` now clears `GE_RGMII_RX_ID_EN` at startup.

**Receive eye, measured 2026-09-09** under a sustained broadcast flood, sweeping
the `IDELAYE2` tap over JTAG (`utils/idelay_sweep.tcl`):

| taps | result |
|---|---|
| 0–24 | ~1400 frames per 3 s window, **zero** FCS errors |
| 25–31 | no frames |

25 contiguous taps at ~78 ps each ≈ **1.95 ns of a 4 ns bit period**. Tap 25 is
the setup-limited edge; the hold edge lies below tap 0 and is off-scale, so the
true eye is wider. `IDELAY_VALUE` is set to 12, giving ≥0.94 ns of proven margin
in both directions.

That settles the concern about depending on BUFG insertion delay instead of the
PHY's trimmed DLL: incidental or not, it lands well inside the window with room
for PVT drift. MMCM deskew on RXC would restore the PHY's specified 2 ns as the
only delay, but costs an MMCM on the recovered clock and rules out 10/100 since
it cannot track RXC changing frequency. Not worth it against this margin.

Note the failure mode is silence, not corruption: `bad_fcs` was zero at every
tap including the dead ones. A mis-sampled preamble means SFD never matches and
no frame starts, so only the good-frame count marks the edges — which is why the
scan needs a high frame rate to mean anything.

**BUFG on receive — forced, not chosen.** Confirmed against the device database
(Vivado 2025.1, `xc7z020clg484-1`):

| | Pin | Bank | Clock region |
|---|---|---|---|
| RXC | N19 `IO_L14P_T2_SRCC_34` | 34 | **X1Y1** |
| RXD[3:0], RX_CTL | E20/E18/D22/D21, G20 | 35 | **X1Y2** |
| TXC | B19 `IO_L13P_T2_MRCC_35` | 35 | X1Y2 |
| TXD[3:0], TX_CTL, MDIO, MDC | J22/K18/J21/J18, K19, J20/K21 | 34 | X1Y1 |

X1Y1 and X1Y2 are vertically adjacent, so a BUFMR into X1Y2's BUFIOs was
geometrically possible — but **RXC lands on an SRCC pin**. Single-region
clock-capable pins drive BUFIO/BUFR only within their own region, and BUFG; they
cannot drive a BUFMR (UG472). So no regional route reaches the data in X1Y2, and
`taxi_ssio_ddr_in`'s BUFG branch is the only option.

One pin over and this would not exist: LA00_CC (M19) is `MRCC` in Bank 34, and a
BUFMR from there into X1Y2 would have worked. The eval card uses LA00_CC for an
unpopulated TXC alternate and puts RXC on LA01_CC instead.

Consequence: pass a `FAMILY` that selects the BUFG branch **deliberately**. It
looks like the omission MIGRATION.md flagged as a bug; here it is required.

Transmit also straddles the boundary (TXC in X1Y2, TXD/TX_CTL in X1Y1) but is
far milder — every TX signal is an output driven from the same `gtx_clk` through
ODDRs, and a BUFG already reaches both regions with low skew.

## Verified in simulation

`src/eth/tb/taxi_eth_mac_1g_rgmii_ptp_fifo/`, Verilator 5.038:

| Test | Covers |
|---|---|
| `run_test_rx` / `run_test_tx` | frame integrity at 1G and 100M |
| | RX timestamp in `tuser`, offset 20.9 ns |
| | TX timestamp on completion, offset 7.2 ns |
| `run_test_rx_bad_fcs` | a bad-FCS frame never reaches the parser |
| `run_test_tx_cpl_tid` | completions pair by `tid`, surviving a dropped frame |

Offsets are measured, not derived; re-measure if the datapath changes.

## Verified on hardware

**Echo, 2026-09-10.** `dig_top` selects between `frame_gen` and a
receive-to-transmit echo with `taxi_axis_mux`. `utils/echo_run.tcl` arms it over
JTAG; `utils/echo_test.py` sends numbered frames from a host packet socket and
compares what returns. Over a direct link, 100 frames came back byte for byte,
none lost, none corrupted, with no FCS or bad-frame errors at the MAC.
Round-trip times measure the host stack, not the fabric.

That closes the transmit direction. Nothing before it had: the PHY's all-digital
loopback exercised the fabric-to-PHY path but never the twisted pair, and the
simulation suite passes with `USE_CLK90` set either way, since `taxi_oddr` takes
its behavioural branch under `SIM=1` and cocotbext's `RgmiiPhy` does not model
the PHY's internal delay. The delay pairing was only ever decidable here.

## NOT verified

- Pin timing margin and the Bank 34/35 BUFG skew across voltage and temperature.
  One board, one room.
- 10/100 operation. Every measurement here is at 1G.
- The PTP datapath. `PTP_TS_EN` is 0 in `dig_top` and `ptp_ts_in` is tied off,
  so the fork's timestamps are exercised only by its own testbench.

## Bring-up ladder

Hardware can start before the MAC works; L0 needs only MDIO.

| | What | Needs |
|---|---|---|
| L0 | Read the PHY ID over MDIO | `taxi_mdio_master` + VIO. Validates J18 at 2.5 V, bank IOSTANDARDs, FMC seating, PHY address |
| L1a | PHY frame checker counts frames the FPGA sends | `FC_TX_SEL` (0x9407), `FC_EN` (0x9403); read `RX_ERR_CNT` (0x0014) first to latch, then `FC_FRM_CNT_H/L` (0x940A/B). Isolates the TX direction |
| L1b | PHY frame generator drives frames at the MAC | `DIAG_CLK_EN` (0x0012), `FG_EN` (0x9415), `FG_DONE` (0x941E); judged by `rx_error_bad_fcs`. Isolates RX |
| L2 | All-digital loopback, both directions | `MII_CONTROL` (0x0000) bit 14. No cable |
| L3 | Real link, direct to a host | Cable. **Done** — see the echo above |
| L4 | Switch, then gPTP | Grandmaster |

L1a/L1b exist because TX and RX have independent failure modes here — double
delay versus the bank split — and a plain loopback cannot tell them apart.

The 0x9xxx registers are extended-address; `taxi_mdio_master` drives ST/OP raw
so it can do either Clause 22 indirect or Clause 45, but which the ADIN1300
wants is unconfirmed.

## Open questions

- Whether the FMC card's strap resistors leave the PHY at its RGMII defaults.
- 802.1AS uses the peer delay mechanism (Pdelay_Req/Resp/Resp_Follow_Up); the
  Nexys `ptp_rx` parses only the end-to-end set, so the receive parser is rework
  rather than a port. How rateRatio and correctionField should feed the servo is
  a spec question, not one to infer.

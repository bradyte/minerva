# Board requirements — Zedboard + EVAL-ADIN1300FMCZ

Facts about the hardware. Decisions taken because of them are in
`architecture.md`.

Zedboard, `xc7z020clg484-1`. ADI EVAL-ADIN1300FMCZ on the FMC-LPC connector.

## Vadj — set J18 to 2.5 V before powering the card

The FMC card's VDDIO defaults to 2.5 V (R16 = 200 kΩ; movable to 1.8 V with
R16 = 130 kΩ). The Zedboard ships with Vadj at 1.8 V.

Bank 34 and Bank 35 Vcco follow Vadj, so every signal on those banks is
`LVCMOS25` — that includes the user push buttons, DIP switches, USB OTG reset
and XADC channels, not just the FMC pins. Bank 13 (clock, Pmods) and Bank 33
(LEDs) are not Vadj banks and stay at 3.3 V.

Beware: **J18** is both the Vadj jumper designator and, unrelatedly, the package
pin carrying TXD_3.

## Clock and control

| Function | Pin | Bank | Standard |
|---|---|---|---|
| 100 MHz oscillator | Y9 | 13 | LVCMOS33 |
| Reset (BTNC) | P16 | 34 | LVCMOS25 |
| LEDs LD0–LD7 | T22 T21 U22 U21 V22 W22 U19 U14 | 33 | LVCMOS33 |

## RGMII and management pinout

Connector pin → net from `adin1300fmcz_ASP-134604-01_pinout.csv`; LA name →
package pin from `../Zedboard-Master.xdc`. All `LVCMOS25`.

| Function | FMC | LA name | Package | Bank | Clock region |
|---|---|---|---|---|---|
| RXC | D8 | LA01_P_CC | N19 | 34 | X1Y1 |
| RX_CTL | G21 | LA20_P | G20 | 35 | X1Y2 |
| RXD_0 | H26 | LA21_N | E20 | 35 | X1Y2 |
| RXD_1 | D27 | LA26_N | E18 | 35 | X1Y2 |
| RXD_2 | G27 | LA25_P | D22 | 35 | X1Y2 |
| RXD_3 | C27 | LA27_N | D21 | 35 | X1Y2 |
| TXC | D20 | LA17_P_CC | B19 | 35 | X1Y2 |
| TX_CTL | C18 | LA14_P | K19 | 34 | X1Y1 |
| TXD_0 | G13 | LA08_N | J22 | 34 | X1Y1 |
| TXD_1 | D12 | LA05_N | K18 | 34 | X1Y1 |
| TXD_2 | G12 | LA08_P | J21 | 34 | X1Y1 |
| TXD_3 | D11 | LA05_P | J18 | 34 | X1Y1 |
| MDIO | G18 | LA16_P | J20 | 34 | X1Y1 |
| MDC | G19 | LA16_N | K21 | 34 | X1Y1 |
| RESET | H19 | LA15_P | J16 | 34 | X1Y1 |
| INT_N | D18 | LA13_N | M17 | 34 | X1Y1 |
| LINK_ST | C23 | LA18_N_CC | C20 | 35 | X1Y2 |

Not populated: TXC alternate on G6/LA00_P_CC (M19, Bank 34, **MRCC**), INT_N
alternate on H32/LA28_N, GP_CLK/RX_ER alternate on H20/LA15_N.

Connected but unused: GP_CLK/RX_ER on C22/LA18_P_CC — RGMII signals receive
errors on RX_CTL's falling edge, so there is no RX_ER to wire.

### Clock/data bank split

Both directions straddle the Bank 34/35 boundary, clock apart from data.
RXC is on **N19 = `IO_L14P_T2_SRCC_34`** — single-region clock capable, so it
cannot drive a BUFMR into Bank 35's clock region (UG472). TXC on B19 is MRCC,
as is the unpopulated LA00_CC alternate.

## PHY

Hardware strap defaults (`MACIF_SEL1`/`MACIF_SEL0` have weak internal
pull-downs, datasheet Table 27): **RGMII with a 2 ns internal delay on both RXC
and TXC**. External resistors are required for any other MAC interface mode.

Confirmed on hardware 2026-09-09: `GE_RGMII_CFG` (0xFF23) reads 0x0E07, the
datasheet reset value, so the card fits no override resistors and the straps
are at their defaults.

**The receive internal delay must be turned off on this board.** RGMII requires
about 2 ns of clock delay relative to data at the capture point; the datasheet
(timing table, note 3) allows it to come from the PCB instead of the PHY, and
specifies 1.5–2.0 ns. Here it comes from the FPGA's BUFG insertion delay on the
recovered receive clock, which the bank split forces. With the PHY's 2 ns on top
the total is roughly a whole 4 ns bit period and nothing decodes. Measured: with
`GE_RGMII_RX_ID_EN` set, zero frames at every `GE_RGMII_RX_SEL` value; cleared,
frames arrive with zero FCS errors. `phy_init` writes 0x0E03 after the scan.

`GE_RGMII_RX_SEL` (bits [8:6]) had no observable effect either way — too fine a
trim to matter against a 2 ns step.

| | |
|---|---|
| PHY_ID_1 (0x02) | 0x0283 |
| PHY_ID_2 (0x03) | 0xBC30 |
| MDIO address | **0** — confirmed on hardware 2026-09-09 |
| RESET_N low | ≥ 10 µs |
| Ready after RESET_N release | 5 ms |

Straps are sampled on the rising edge of RESET_N, so that edge must be clean.
The MDIO address straps `PHYAD_0`–`PHYAD_3` are multiplexed onto `RXD_0`–`RXD_3`,
so the address is set by resistors on the eval card; address 0 means none fitted.

Extended management interface and subsystem registers live at MMD address 0x1E.
Two ways in: Clause 45 addressing 0x1E directly, or — for hosts without Clause 45
— indirectly through `EXT_REG_PTR` (0x10) and `EXT_REG_DATA` (0x11) using
Clause 22. `taxi_mdio_master` drives ST/OP raw, so either works. That is the
path to the frame generator and checker used by L1a/L1b.

## UART

The board has **no PL-side UART**. J14's USB-UART goes through a CY7C64225
bridge to `PS_MIO47` (RXD) and `PS_MIO48` (TXD) — Zynq PS UART0. Fabric-side
serial needs either a Pmod USB-serial adapter or a path through the PS.

## Reference documents

`../adin1300fmcz/` holds the ADIN1300 datasheet and EVAL-ADIN1300FMCZ user
guide, the Zedboard schematic, and the connector pinout crops.

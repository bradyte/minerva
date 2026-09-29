# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#

# ADIN1300 RGMII on the EVAL-ADIN1300FMCZ, FMC-LPC connector.
# Pinout and bank/clock-region map: ../../docs/board.md
# Why the receive clock cannot use BUFIO:  ../../docs/architecture.md
#
# Requires Vadj = 2.5 V (jumper J18).

# Receive - clock in bank 34, data and control in bank 35

# RXC/RX_CLK  = FMC D8  = LA01_P_CC
set_property -dict {PACKAGE_PIN N19 IOSTANDARD LVCMOS25} [get_ports phy_rx_clk]

# RX_CTL/RX_DV = FMC G21 = LA20_P
set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS25} [get_ports phy_rx_ctl]

# RXD_0 = FMC H26 = LA21_N
# RXD_1 = FMC D27 = LA26_N
# RXD_2 = FMC G27 = LA25_P
# RXD_3 = FMC C27 = LA27_N
set_property -dict {PACKAGE_PIN E20 IOSTANDARD LVCMOS25} [get_ports {phy_rxd[0]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS25} [get_ports {phy_rxd[1]}]
set_property -dict {PACKAGE_PIN D22 IOSTANDARD LVCMOS25} [get_ports {phy_rxd[2]}]
set_property -dict {PACKAGE_PIN D21 IOSTANDARD LVCMOS25} [get_ports {phy_rxd[3]}]

# Transmit - clock in bank 35, data and control in bank 34

# TXC/TX_CLK = FMC D20 = LA17_P_CC
set_property -dict {PACKAGE_PIN B19 IOSTANDARD LVCMOS25} [get_ports phy_tx_clk]

# TX_CTL/TX_EN = FMC C18 = LA14_P
set_property -dict {PACKAGE_PIN K19 IOSTANDARD LVCMOS25} [get_ports phy_tx_ctl]

# TXD_0 = FMC G13 = LA08_N
# TXD_1 = FMC D12 = LA05_N
# TXD_2 = FMC G12 = LA08_P
# TXD_3 = FMC D11 = LA05_P
set_property -dict {PACKAGE_PIN J22 IOSTANDARD LVCMOS25} [get_ports {phy_txd[0]}]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS25} [get_ports {phy_txd[1]}]
set_property -dict {PACKAGE_PIN J21 IOSTANDARD LVCMOS25} [get_ports {phy_txd[2]}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS25} [get_ports {phy_txd[3]}]

# Management and status

# MDIO = FMC G18 = LA16_P
# MDC  = FMC G19 = LA16_N
set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVCMOS25} [get_ports phy_mdio]
set_property -dict {PACKAGE_PIN K21 IOSTANDARD LVCMOS25} [get_ports phy_mdc]

# RESET      = FMC H19 = LA15_P
# INT_N/CRS  = FMC D18 = LA13_N
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS25} [get_ports phy_reset_n]
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS25} [get_ports phy_int_n]

# LINK_ST = FMC C23 = LA18_N_CC   (bank 35)
#set_property -dict {PACKAGE_PIN C20 IOSTANDARD LVCMOS25} [get_ports phy_link_st]

# Timing

create_clock -period 8.000 -name phy_rx_clk [get_ports phy_rx_clk]

set_false_path -to [get_ports phy_reset_n]
set_output_delay 0 [get_ports phy_reset_n]
set_false_path -from [get_ports phy_int_n]
set_input_delay 0 [get_ports phy_int_n]
set_false_path -to [get_ports phy_mdc]
set_output_delay 0 [get_ports phy_mdc]
set_false_path -to [get_ports phy_mdio]
set_output_delay 0 [get_ports phy_mdio]
set_false_path -from [get_ports phy_mdio]
set_input_delay 0 [get_ports phy_mdio]

# No IDELAY value and no TX phase shift: the PHY supplies both delays.
# set_input_delay on phy_rxd is deliberately absent until the tap sweep
# provides real numbers - see ../../docs/architecture.md.

# Placement

# taxi_rgmii_phy_if.tcl limits the TXC registers to TXC ODDR path to a quarter
# period (2 ns), so the registers sit beside the ODDR (OLOGIC_X1Y124, pin B19)
create_pblock pblock_rgmii_tx_clk
add_cells_to_pblock [get_pblocks pblock_rgmii_tx_clk] [get_cells core_inst/eth_mac_inst/eth_mac_1g_rgmii_inst/rgmii_phy_if_inst/rgmii_tx_clk_*_reg_reg]
resize_pblock [get_pblocks pblock_rgmii_tx_clk] -add {SLICE_X112Y123:SLICE_X113Y125}

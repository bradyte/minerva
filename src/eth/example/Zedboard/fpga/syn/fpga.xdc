# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#

# Zedboard general constraints.  Pins and bank/voltage rules: ../../docs/board.md
# FMC / RGMII pins are in eth_rgmii.xdc.
#
# Requires Vadj = 2.5 V (jumper J18); bank 34 is therefore LVCMOS25.

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# Build timestamp for USR_ACCESSE2, read back as BUILD_ID
set_property BITSTREAM.CONFIG.USR_ACCESS TIMESTAMP [current_design]

# Clock: 100 MHz oscillator, bank 13
set_property -dict {PACKAGE_PIN Y9 IOSTANDARD LVCMOS33} [get_ports clk_100mhz]
create_clock -period 10.000 -name clk_100mhz [get_ports clk_100mhz]

# Reset: centre push button, bank 34
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS25} [get_ports reset]

set_false_path -from [get_ports reset]
set_input_delay 0 [get_ports reset]

# User LEDs, bank 33
set_property -dict {PACKAGE_PIN T22 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN T21 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN U21 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN V22 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN W22 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {led[7]}]

set_false_path -to [get_ports {led[*]}]
set_output_delay 0 [get_ports {led[*]}]

# UART: Pmod JA, bank 13.  The pull-up idles RXD when the adapter is unplugged.
set_property -dict {PACKAGE_PIN AA11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {uart_txd}] ;# JA2
set_property -dict {PACKAGE_PIN Y11  IOSTANDARD LVCMOS33 PULLUP true} [get_ports {uart_rxd}] ;# JA1

set_false_path -to [get_ports {uart_txd}]
set_output_delay 0 [get_ports {uart_txd}]
set_false_path -from [get_ports {uart_rxd}]
set_input_delay 0 [get_ports {uart_rxd}]

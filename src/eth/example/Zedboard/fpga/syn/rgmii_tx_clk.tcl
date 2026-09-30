# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#

# RGMII TXC ODDR timing with USE_CLK90 = 0
#
# taxi_rgmii_phy_if.tcl limits the paths from the TXC registers to the TXC ODDR
# to a quarter period, the budget when the ODDR runs on gtx_clk90.  With
# USE_CLK90 = 0 the ODDR runs on the registers' own clock and captures a full
# period after launch, so the limit is reset to one period.  This file must
# follow taxi_rgmii_phy_if.tcl, and leaves its limit alone if the clocks differ.

set inst core_inst/eth_mac_inst/eth_mac_1g_rgmii_inst/rgmii_phy_if_inst

set src_clk [get_clocks -of_objects [get_pins $inst/rgmii_tx_clk_1_reg_reg/C]]
set oddr_clk [get_clocks -of_objects [get_pins $inst/clk_oddr_inst/oddr[0].oddr_inst/C]]

if {[llength $src_clk] == 1 && [llength $oddr_clk] == 1 &&
        [get_property NAME $src_clk] eq [get_property NAME $oddr_clk]} {
    set period [get_property PERIOD $src_clk]
    puts "TXC ODDR shares the TXC register clock: max delay reset to $period ns for $inst"
    set_max_delay -reset_path -from [get_cells $inst/rgmii_tx_clk_1_reg_reg] -to [get_cells $inst/clk_oddr_inst/oddr[0].oddr_inst] $period
    set_max_delay -reset_path -from [get_cells $inst/rgmii_tx_clk_2_reg_reg] -to [get_cells $inst/clk_oddr_inst/oddr[0].oddr_inst] $period
}

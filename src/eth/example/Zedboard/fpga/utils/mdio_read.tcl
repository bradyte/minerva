# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#
# Read one clause 22 PHY register over the VIO's MDIO request port.
#   cd ../fpga && vivado -mode batch -nojournal -nolog -source ../utils/mdio_read.tcl -tclargs 0x19
# An optional second argument overrides the PHY address; the default is the
# one the startup scan found.  Reading IRQ_STATUS (0x19) clears phy_irq.

# the project name follows FPGA_TOP, so find the probe file rather than fix it
set LTX [lindex [glob -nocomplain *.ltx] 0]
if {$LTX eq ""} { error "no .ltx in [pwd] - run from the build directory" }

if {![info exists argv] || [llength $argv] < 1} { error "usage: -tclargs <reg> ?<phy_addr>?" }
set REG [expr {[lindex $argv 0]}]

proc vio_connect {ltx} {
    catch {open_hw_manager}
    catch {connect_hw_server}
    catch {open_hw_target}
    set dev [lindex [get_hw_devices xc7z*] 0]
    if {$dev eq ""} { error "no xc7z device on the JTAG chain - is the board powered?" }
    current_hw_device $dev
    set_property PROBES.FILE      $ltx $dev
    set_property FULL_PROBES.FILE $ltx $dev
    refresh_hw_device $dev
    set vio [lindex [get_hw_vios -of_objects $dev] 0]
    if {$vio eq ""} { error "no VIO core found - is fpga.ltx current?" }
    return $vio
}

set vio [vio_connect $LTX]
proc vp {n} { return [get_hw_probes -of_objects $::vio *ctrl_status_inst/$n] }

refresh_hw_vio $vio
if {[llength $argv] > 1} {
    set PHY [expr {[lindex $argv 1]}]
} else {
    set_property INPUT_VALUE_RADIX HEX [vp phy_addr]
    set PHY [expr {"0x[get_property INPUT_VALUE [vp phy_addr]]"}]
}

foreach n {req_phy_addr req_reg_addr} { set_property OUTPUT_VALUE_RADIX HEX [vp $n] }
set_property OUTPUT_VALUE [format %02X $PHY] [vp req_phy_addr]
set_property OUTPUT_VALUE [format %02X $REG] [vp req_reg_addr]
set_property OUTPUT_VALUE 0 [vp req_wr]
set_property OUTPUT_VALUE 0 [vp req_go]
commit_hw_vio $vio

# mdio_cmd acts on the rising edge of go
set_property OUTPUT_VALUE 1 [vp req_go]
commit_hw_vio $vio

set busy 1
for {set i 0} {$i < 50 && $busy} {incr i} {
    after 10
    refresh_hw_vio $vio
    set busy [get_property INPUT_VALUE [vp req_busy]]
}
if {$busy} { error "MDIO request still busy" }

refresh_hw_vio $vio
set_property INPUT_VALUE_RADIX HEX [vp req_rd_data]
puts [format "phy %02X reg %02X = 0x%s" $PHY $REG [get_property INPUT_VALUE [vp req_rd_data]]]
puts "phy_irq                [get_property INPUT_VALUE [vp phy_irq]]"

# leave go low, ready for the next read
set_property OUTPUT_VALUE 0 [vp req_go]
commit_hw_vio $vio

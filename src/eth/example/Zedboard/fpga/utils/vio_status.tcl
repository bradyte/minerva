# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#
# Print the PHY status and MAC frame counters from the VIO.  Read-only.
#   cd ../fpga && vivado -mode batch -nojournal -nolog -source ../utils/vio_status.tcl
# or source it from the Hardware Manager TCL console.

# the project name follows FPGA_TOP, so find the probe file rather than fix it
set LTX [lindex [glob -nocomplain *.ltx] 0]
if {$LTX eq ""} { error "no .ltx in [pwd] - run from the build directory" }

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
refresh_hw_vio $vio

foreach name {phy_present phy_id_done phy_addr phy_id phy_irq link_speed
              rx_good_cnt_reg tx_good_cnt_reg rx_bad_fcs_cnt_reg rx_bad_frame_cnt_reg} {
    set p [get_hw_probes -of_objects $vio *ctrl_status_inst/$name]
    if {[string match *_cnt_reg $name]} { set_property INPUT_VALUE_RADIX UNSIGNED $p }
    puts [format "%-22s %s" $name [get_property INPUT_VALUE $p]]
}

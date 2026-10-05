# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#

# FPGA settings
FPGA_PART = xc7z020clg484-1
FPGA_TOP = fpga
FPGA_ARCH = zynq

RTL_DIR = ../rtl
LIB_DIR = ../lib
TAXI_SRC_DIR = $(LIB_DIR)/taxi/src

# Files for synthesis
SYN_FILES = $(RTL_DIR)/fpga.sv
SYN_FILES += $(RTL_DIR)/fpga_core.sv
SYN_FILES += $(RTL_DIR)/zedboard_regs_pkg.sv
SYN_FILES += $(RTL_DIR)/zedboard_regs.sv
SYN_FILES += $(RTL_DIR)/echo_server.sv
SYN_FILES += $(RTL_DIR)/record_echo.sv
SYN_FILES += $(TAXI_SRC_DIR)/minerva/rtl/minerva_rx_parse.sv
SYN_FILES += $(TAXI_SRC_DIR)/minerva/rtl/minerva_tx_deparse.sv
SYN_FILES += $(TAXI_SRC_DIR)/eth/rtl/taxi_eth_mac_1g_rgmii_fifo.f
SYN_FILES += $(TAXI_SRC_DIR)/xfcp/rtl/taxi_xfcp_if_uart.f
SYN_FILES += $(TAXI_SRC_DIR)/xfcp/rtl/taxi_xfcp_switch.sv
SYN_FILES += $(TAXI_SRC_DIR)/xfcp/rtl/taxi_xfcp_mod_stats.f
SYN_FILES += $(TAXI_SRC_DIR)/xfcp/rtl/taxi_xfcp_mod_apb.f
SYN_FILES += $(TAXI_SRC_DIR)/phy/adin1300/rtl/adin1300_management.f
SYN_FILES += $(TAXI_SRC_DIR)/axis/rtl/taxi_axis_fifo.sv
SYN_FILES += $(TAXI_SRC_DIR)/axis/rtl/taxi_axis_null_snk.sv
SYN_FILES += $(TAXI_SRC_DIR)/sync/rtl/taxi_sync_reset.sv
SYN_FILES += $(TAXI_SRC_DIR)/sync/rtl/taxi_sync_signal.sv

# XDC files
XDC_FILES += ../syn/fpga.xdc
XDC_FILES += ../syn/eth_rgmii.xdc
XDC_FILES += $(TAXI_SRC_DIR)/eth/syn/vivado/taxi_rgmii_phy_if.tcl
XDC_FILES += ../syn/rgmii_tx_clk.tcl
XDC_FILES += $(TAXI_SRC_DIR)/eth/syn/vivado/taxi_eth_mac_fifo.tcl
XDC_FILES += $(TAXI_SRC_DIR)/axis/syn/vivado/taxi_axis_async_fifo.tcl
XDC_FILES += $(TAXI_SRC_DIR)/sync/syn/vivado/taxi_sync_reset.tcl
XDC_FILES += $(TAXI_SRC_DIR)/sync/syn/vivado/taxi_sync_signal.tcl

# Configuration
#CONFIG_TCL_FILES = ./config.tcl

include ../common/vivado.mk

program: $(PROJECT).bit
	echo "open_hw_manager" > program.tcl
	echo "connect_hw_server" >> program.tcl
	echo "open_hw_target" >> program.tcl
	echo "set dev [lindex [get_hw_devices xc7z*] 0]" >> program.tcl
	echo "current_hw_device \$$dev" >> program.tcl
	echo "refresh_hw_device -update_hw_probes false \$$dev" >> program.tcl
	echo "set_property PROGRAM.FILE {$(PROJECT).bit} \$$dev" >> program.tcl
	echo "program_hw_devices \$$dev" >> program.tcl
	echo "exit" >> program.tcl
	vivado -nojournal -nolog -mode batch -source program.tcl

# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#
# Regenerate the register block and its documentation from zedboard_regs.rdl,
# with the repo .venv active (peakrdl-regblock, peakrdl-markdown).  The output
# is committed, so builds and benches never need PeakRDL; edit the .rdl, never
# the generated files.

PEAKRDL ?= peakrdl
RTL_DIR = ../rtl
DOCS_DIR = ../../docs

.PHONY: all
all: $(RTL_DIR)/zedboard_regs.sv $(DOCS_DIR)/registers.md

$(RTL_DIR)/zedboard_regs.sv: zedboard_regs.rdl
	$(PEAKRDL) regblock $< -o $(RTL_DIR) --cpuif apb4-flat --addr-width 16

$(DOCS_DIR)/registers.md: zedboard_regs.rdl
	$(PEAKRDL) markdown $< -o $@

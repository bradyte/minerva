// SPDX-License-Identifier: MIT
/*

Copyright (c) 2026 Tom Brady

Authors:
- Tom Brady

*/

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ADIN1300 bring-up sequencer testbench
 *
 * adin1300_init plus the MDIO master it drives, so the test exercises the real
 * clause 22 frame on the wire rather than the command stream in isolation.
 */
module test_adin1300_init #
(
    /* verilator lint_off WIDTHTRUNC */
    parameter logic [15:0] PHY_ID_1 = 16'h0283,
    parameter logic [15:0] PHY_ID_2 = 16'hBC30,
    parameter RESET_LOW_CYCLES = 8,
    parameter RESET_WAIT_CYCLES = 32,
    parameter [7:0] PRESCALE = 8'd4
    /* verilator lint_on WIDTHTRUNC */
)
();

logic clk;
logic rst;

taxi_axis_if #(.DATA_W(32), .KEEP_W(1), .KEEP_EN(0)) axis_cmd();
taxi_axis_if #(.DATA_W(16), .KEEP_W(1), .KEEP_EN(0)) axis_rd();

logic phy_reset_n;
logic [4:0] phy_addr;
logic phy_present;
logic [31:0] phy_id;
logic done;

logic mdc;
logic mdio_i;
logic mdio_o;
logic mdio_t;

adin1300_init #(
    .PHY_ID_1(PHY_ID_1),
    .PHY_ID_2(PHY_ID_2),
    .RESET_LOW_CYCLES(RESET_LOW_CYCLES),
    .RESET_WAIT_CYCLES(RESET_WAIT_CYCLES)
)
uut (
    .clk(clk),
    .rst(rst),
    .m_axis_cmd(axis_cmd),
    .s_axis_rd_data(axis_rd),
    .phy_reset_n(phy_reset_n),
    .phy_addr(phy_addr),
    .phy_present(phy_present),
    .phy_id(phy_id),
    .done(done)
);

taxi_mdio_master
mdio_master_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_cmd(axis_cmd),
    .m_axis_rd_data(axis_rd),
    .mdc_o(mdc),
    .mdio_i(mdio_i),
    .mdio_o(mdio_o),
    .mdio_t(mdio_t),
    .busy(),
    .prescale(PRESCALE)
);

endmodule

`resetall

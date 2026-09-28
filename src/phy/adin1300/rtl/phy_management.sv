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
 * PHY management
 *
 * Owns the PHY reset and the MDIO master.  Initialization holds source 0 of
 * the arbiter; the request port is source 1, left free for whatever
 * drives it - a VIO today, the PS or a register block later.
 */
module phy_management #
(
    // 125 MHz / (2 * (1 + 24)) = 2.5 MHz MDC, inside the 2.5 MHz ceiling
    // clause 22 specifies
    parameter logic [7:0] MDC_PRESCALE = 8'd24
)
(
    input  wire logic         clk,
    input  wire logic         rst,

    /*
     * MDIO and PHY reset
     */
    input  wire logic         phy_mdio_i,
    output wire logic         phy_mdio_o,
    output wire logic         phy_mdio_t,
    output wire logic         phy_mdc,
    output wire logic         phy_reset_n,

    /*
     * Startup scan result
     */
    output wire logic [4:0]   phy_addr,
    output wire logic         phy_present,
    output wire logic [31:0]  phy_id,
    output wire logic         phy_id_done,

    /*
     * Single-transaction request port
     */
    input  wire logic [4:0]   req_phy_addr,
    input  wire logic [4:0]   req_reg_addr,
    input  wire logic [15:0]  req_wr_data,
    input  wire logic         req_wr,
    input  wire logic         req_go,
    output wire logic [15:0]  req_rd_data,
    output wire logic         req_busy
);

taxi_axis_if #(.DATA_W(32), .KEEP_W(1), .KEEP_EN(0)) axis_cmd[2]();
taxi_axis_if #(.DATA_W(16), .KEEP_W(1), .KEEP_EN(0)) axis_rd[2]();
taxi_axis_if #(.DATA_W(32), .KEEP_W(1), .KEEP_EN(0)) axis_cmd_int();
taxi_axis_if #(.DATA_W(16), .KEEP_W(1), .KEEP_EN(0)) axis_rd_int();

phy_init
phy_init_inst (
    .clk(clk),
    .rst(rst),

    .m_axis_cmd(axis_cmd[0]),
    .s_axis_rd_data(axis_rd[0]),

    .phy_reset_n(phy_reset_n),

    .phy_addr(phy_addr),
    .phy_present(phy_present),
    .phy_id(phy_id),
    .done(phy_id_done)
);

mdio_cmd
mdio_cmd_inst (
    .clk(clk),
    .rst(rst),

    .m_axis_cmd(axis_cmd[1]),
    .s_axis_rd_data(axis_rd[1]),

    .req_phy_addr(req_phy_addr),
    .req_reg_addr(req_reg_addr),
    .req_wr_data(req_wr_data),
    .req_wr(req_wr),
    .req_go(req_go),

    .rd_data(req_rd_data),
    .busy(req_busy)
);

mdio_arb #(
    .S_COUNT(2)
)
mdio_arb_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_cmd(axis_cmd),
    .m_axis_rd_data(axis_rd),

    .m_axis_cmd(axis_cmd_int),
    .s_axis_rd_data(axis_rd_int)
);

taxi_mdio_master
mdio_master_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_cmd(axis_cmd_int),
    .m_axis_rd_data(axis_rd_int),

    .mdc_o(phy_mdc),
    .mdio_i(phy_mdio_i),
    .mdio_o(phy_mdio_o),
    .mdio_t(phy_mdio_t),

    .busy(),

    .prescale(MDC_PRESCALE)
);

endmodule

`resetall

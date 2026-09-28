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
 * Minerva RX parser testbench
 */
module test_minerva_rx_parse #
(
    /* verilator lint_off WIDTHTRUNC */
    parameter logic VLAN_EN = 1'b1,
    parameter DEST_W = 1
    /* verilator lint_on WIDTHTRUNC */
)
();

logic clk;
logic rst;

taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1)) s_axis();
taxi_axis_if #(.DATA_W(32), .DEST_EN(1), .DEST_W(DEST_W)) m_axis();

minerva_rx_parse #(
    .VLAN_EN(VLAN_EN)
)
uut (
    .clk(clk),
    .rst(rst),

    /*
     * Frame input, from the MAC
     */
    .s_axis(s_axis),

    /*
     * Payload output, route on tdest
     */
    .m_axis(m_axis)
);

endmodule

`resetall

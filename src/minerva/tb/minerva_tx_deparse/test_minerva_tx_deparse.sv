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
 * Minerva TX deparser testbench
 */
module test_minerva_tx_deparse #
(
    /* verilator lint_off WIDTHTRUNC */
    parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01
    /* verilator lint_on WIDTHTRUNC */
)
();

logic clk;
logic rst;

taxi_axis_if #(.DATA_W(32)) s_axis();
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1)) m_axis();

minerva_tx_deparse #(
    .LOCAL_MAC(LOCAL_MAC)
)
uut (
    .clk(clk),
    .rst(rst),

    /*
     * Payload input, destination and ethertype prefixed
     */
    .s_axis(s_axis),

    /*
     * Frame output, to the MAC
     */
    .m_axis(m_axis)
);

endmodule

`resetall

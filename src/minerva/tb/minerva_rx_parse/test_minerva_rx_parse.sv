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
    parameter ID_W = 4,
    parameter DEST_W = 1
    /* verilator lint_on WIDTHTRUNC */
)
();

logic clk;
logic rst;

taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1)) s_axis_mac_rx();
taxi_axis_if #(.DATA_W(32), .ID_EN(1), .ID_W(ID_W), .DEST_EN(1), .DEST_W(DEST_W), .USER_EN(1), .USER_W(1)) m_axis_eth_rx();

minerva_rx_parse #(
    .VLAN_EN(VLAN_EN)
)
uut (
    .clk(clk),
    .rst(rst),

    /*
     * Frame input, from the MAC
     */
    .s_axis_mac_rx(s_axis_mac_rx),

    /*
     * Message output: record, then payload
     */
    .m_axis_eth_rx(m_axis_eth_rx)
);

endmodule

`resetall

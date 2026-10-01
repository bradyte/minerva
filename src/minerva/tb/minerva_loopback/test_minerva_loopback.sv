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
 * Minerva loopback testbench
 *
 * minerva_tx_deparse into minerva_rx_parse, so a record goes to the wire and
 * back.
 */
module test_minerva_loopback #
(
    /* verilator lint_off WIDTHTRUNC */
    parameter ID_W = 4,
    parameter DEST_W = 1
    /* verilator lint_on WIDTHTRUNC */
)
();

logic clk;
logic rst;

taxi_axis_if #(.DATA_W(32), .ID_EN(1), .ID_W(ID_W), .DEST_EN(1), .DEST_W(DEST_W), .USER_EN(1), .USER_W(1)) s_axis_eth_tx();
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1)) axis_wire();
taxi_axis_if #(.DATA_W(32), .ID_EN(1), .ID_W(ID_W), .DEST_EN(1), .DEST_W(DEST_W), .USER_EN(1), .USER_W(1)) m_axis_eth_rx();

logic [47:0] cfg_local_mac;

minerva_tx_deparse
tx_deparse_inst (
    .clk(clk),
    .rst(rst),

    /*
     * Message input: record, then payload
     */
    .s_axis_eth_tx(s_axis_eth_tx),

    /*
     * Frame output
     */
    .m_axis_mac_tx(axis_wire),

    /*
     * Configuration
     */
    .cfg_local_mac(cfg_local_mac)
);

minerva_rx_parse
rx_parse_inst (
    .clk(clk),
    .rst(rst),

    /*
     * Frame input
     */
    .s_axis_mac_rx(axis_wire),

    /*
     * Message output: record, then payload
     */
    .m_axis_eth_rx(m_axis_eth_rx)
);

endmodule

`resetall

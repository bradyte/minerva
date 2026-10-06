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
 * minerva_tx into minerva_rx_parse, so metadata and a payload go to the wire
 * and back.
 */
module test_minerva_loopback #
(
    /* verilator lint_off WIDTHTRUNC */
    parameter DEST_W = 1
    /* verilator lint_on WIDTHTRUNC */
)
();

logic clk;
logic rst;

taxi_axis_if #(.DATA_W(32)) s_axis_meta();
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1)) s_axis_payload();
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1)) axis_wire();
taxi_axis_if #(.DATA_W(32), .DEST_EN(1), .DEST_W(DEST_W)) m_axis_meta();
taxi_axis_if #(.DATA_W(32), .DEST_EN(1), .DEST_W(DEST_W), .USER_EN(1), .USER_W(1)) m_axis_payload();

logic [47:0] cfg_local_mac;

minerva_tx
tx_inst (
    .clk(clk),
    .rst(rst),

    /*
     * Metadata and payload input
     */
    .s_axis_meta(s_axis_meta),
    .s_axis_payload(s_axis_payload),

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
     * Metadata and payload output
     */
    .m_axis_meta(m_axis_meta),
    .m_axis_payload(m_axis_payload)
);

endmodule

`resetall

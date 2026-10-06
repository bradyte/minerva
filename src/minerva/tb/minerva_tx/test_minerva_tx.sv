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
 * Minerva TX testbench
 */
module test_minerva_tx ();

logic clk;
logic rst;

taxi_axis_if #(.DATA_W(32)) s_axis_meta();
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1)) s_axis_payload();
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1)) m_axis_mac_tx();

logic [47:0] cfg_local_mac;

minerva_tx
uut (
    .clk(clk),
    .rst(rst),

    /*
     * Metadata input, one block per message
     */
    .s_axis_meta(s_axis_meta),

    /*
     * Payload input, when the metadata announces one
     */
    .s_axis_payload(s_axis_payload),

    /*
     * Frame output, to the MAC
     */
    .m_axis_mac_tx(m_axis_mac_tx),

    /*
     * Configuration
     */
    .cfg_local_mac(cfg_local_mac)
);

endmodule

`resetall

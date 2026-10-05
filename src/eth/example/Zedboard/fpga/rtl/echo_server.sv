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
 * Echo server
 *
 * Test fixture standing in for minerva's consumer: consumes each message from
 * minerva_rx_parse, stores it, and produces the reply for minerva_tx_deparse.
 */
module echo_server
(
    input  wire logic         clk,
    input  wire logic         rst,

    /*
     * Record, then payload, from minerva_rx_parse
     */
    taxi_axis_if.snk          s_axis_eth_rx,

    /*
     * Reply record, then payload, to minerva_tx_deparse
     */
    taxi_axis_if.src          m_axis_eth_tx,

    /*
     * Configuration
     */
    input  wire logic [47:0]  cfg_local_mac
);

taxi_axis_if #(
    .DATA_W(s_axis_eth_rx.DATA_W),
    .KEEP_EN(s_axis_eth_rx.KEEP_EN),
    .KEEP_W(s_axis_eth_rx.KEEP_W),
    .LAST_EN(s_axis_eth_rx.LAST_EN),
    .ID_EN(s_axis_eth_rx.ID_EN),
    .ID_W(s_axis_eth_rx.ID_W),
    .DEST_EN(s_axis_eth_rx.DEST_EN),
    .DEST_W(s_axis_eth_rx.DEST_W),
    .USER_EN(s_axis_eth_rx.USER_EN),
    .USER_W(s_axis_eth_rx.USER_W)
) axis_eth_rx_fifo();

// each message is held until it is complete, and a truncated one, marked by
// tuser, is dropped
taxi_axis_fifo #(
    .DEPTH(2048),
    .FRAME_FIFO(1),
    .DROP_BAD_FRAME(1),
    .DROP_WHEN_FULL(0)
)
storage_inst (
    .clk(clk),
    .rst(rst),

    /*
     * AXI4-Stream input (sink)
     */
    .s_axis(s_axis_eth_rx),

    /*
     * AXI4-Stream output (source)
     */
    .m_axis(axis_eth_rx_fifo),

    /*
     * Pause
     */
    .pause_req(1'b0),
    .pause_ack(),

    /*
     * Status
     */
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

record_echo
producer_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_eth_rx(axis_eth_rx_fifo),
    .m_axis_eth_tx(m_axis_eth_tx),

    .cfg_local_mac(cfg_local_mac)
);

endmodule

`resetall

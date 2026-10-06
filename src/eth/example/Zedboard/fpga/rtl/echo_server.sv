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
 * minerva_rx_parse, stores it, and produces the reply for minerva_tx.  The
 * metadata and the payload are stored apart and never dropped one without the
 * other; a truncated payload passes on marked by tuser, and minerva_tx marks
 * its frame bad.
 */
module echo_server
(
    input  wire logic         clk,
    input  wire logic         rst,

    /*
     * Receive metadata and payload, from minerva_rx_parse
     */
    taxi_axis_if.snk          s_axis_meta,
    taxi_axis_if.snk          s_axis_payload,

    /*
     * Transmit metadata and payload, to minerva_tx
     */
    taxi_axis_if.src          m_axis_meta,
    taxi_axis_if.src          m_axis_payload,

    /*
     * Configuration
     */
    input  wire logic [47:0]  cfg_local_mac
);

taxi_axis_if #(
    .DATA_W(s_axis_meta.DATA_W),
    .KEEP_EN(s_axis_meta.KEEP_EN),
    .KEEP_W(s_axis_meta.KEEP_W),
    .LAST_EN(s_axis_meta.LAST_EN),
    .ID_EN(s_axis_meta.ID_EN),
    .ID_W(s_axis_meta.ID_W),
    .DEST_EN(s_axis_meta.DEST_EN),
    .DEST_W(s_axis_meta.DEST_W),
    .USER_EN(s_axis_meta.USER_EN),
    .USER_W(s_axis_meta.USER_W)
) axis_meta_stored();

// each metadata block, held until the producer takes it
taxi_axis_fifo #(
    .DEPTH(256),
    .FRAME_FIFO(0)
)
meta_storage_inst (
    .clk(clk),
    .rst(rst),

    /*
     * AXI4-Stream input (sink)
     */
    .s_axis(s_axis_meta),

    /*
     * AXI4-Stream output (source)
     */
    .m_axis(axis_meta_stored),

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

// each payload, held until it is complete; one marked by tuser is kept, so it
// stays paired with its metadata
taxi_axis_fifo #(
    .DEPTH(2048),
    .FRAME_FIFO(1),
    .DROP_BAD_FRAME(0),
    .DROP_WHEN_FULL(0)
)
payload_storage_inst (
    .clk(clk),
    .rst(rst),

    /*
     * AXI4-Stream input (sink)
     */
    .s_axis(s_axis_payload),

    /*
     * AXI4-Stream output (source)
     */
    .m_axis(m_axis_payload),

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

meta_echo
producer_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_meta(axis_meta_stored),
    .m_axis_meta(m_axis_meta),

    .cfg_local_mac(cfg_local_mac)
);

endmodule

`resetall

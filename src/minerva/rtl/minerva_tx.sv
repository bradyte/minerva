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
 * Minerva TX
 *
 * Builds one frame per message from its metadata and payload, as zircon's
 * transmit egress does: minerva_tx_deparse makes the header from the metadata,
 * minerva_tx_gate makes the payload follow the header's command, and
 * taxi_axis_concat joins the two.  cfg_local_mac is the source.
 */
module minerva_tx
(
    input  wire logic         clk,
    input  wire logic         rst,

    /*
     * Metadata input, one block per message
     */
    taxi_axis_if.snk          s_axis_meta,

    /*
     * Payload input, when the metadata announces one
     */
    taxi_axis_if.snk          s_axis_payload,

    /*
     * Frame output, to the MAC
     */
    taxi_axis_if.src          m_axis_mac_tx,

    /*
     * Configuration
     */
    input  wire logic [47:0]  cfg_local_mac
);

localparam USER_W = m_axis_mac_tx.USER_W;

// check configuration
if (!m_axis_mac_tx.KEEP_EN || !m_axis_mac_tx.USER_EN)
    $fatal(0, "Error: Frame output requires KEEP_EN and USER_EN (instance %m)");

// the header, then the payload, of each frame
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(USER_W)) axis_frame[2]();

// what to do with each message's payload: {drop, len}
taxi_axis_if #(.DATA_W(32), .KEEP_EN(0), .LAST_EN(0)) axis_payload_cmd();

minerva_tx_deparse
deparse_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_meta(s_axis_meta),
    .m_axis_hdr(axis_frame[0]),
    .m_axis_cmd(axis_payload_cmd),

    .cfg_local_mac(cfg_local_mac)
);

minerva_tx_gate
gate_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_cmd(axis_payload_cmd),
    .s_axis_payload(s_axis_payload),
    .m_axis_payload(axis_frame[1])
);

taxi_axis_concat #(
    .S_COUNT(2)
)
concat_inst (
    .clk(clk),
    .rst(rst),

    /*
     * AXI4-Stream inputs (sinks)
     */
    .s_axis(axis_frame),

    /*
     * AXI4-Stream output (source)
     */
    .m_axis(m_axis_mac_tx)
);

endmodule

`resetall

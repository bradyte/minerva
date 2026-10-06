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
 * Minerva TX payload gate
 *
 * Takes one command from minerva_tx_deparse per message, {drop, len}, in the
 * order of the headers, and gives taxi_axis_concat the payload packet that
 * follows each header.  A payload is passed with zeros filling its last beat:
 * it starts in lane 0, so that is its pad.  A message without a payload gives
 * one beat with no bytes, so the concat still has a packet; a dropped
 * message's payload is drained.  A payload that ends short or long, or tuser
 * at tlast, ends with tuser set, so the MAC's TX FIFO drops the frame.
 */
module minerva_tx_gate
(
    input  wire logic  clk,
    input  wire logic  rst,

    /*
     * Payload command input: {drop, len}
     */
    taxi_axis_if.snk   s_axis_cmd,

    /*
     * Payload input, from the producer
     */
    taxi_axis_if.snk   s_axis_payload,

    /*
     * Payload output, to the concat
     */
    taxi_axis_if.src   m_axis_payload
);

localparam DATA_W = s_axis_payload.DATA_W;
localparam USER_W = m_axis_payload.USER_W;

// check configuration
if (DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (m_axis_payload.DATA_W != DATA_W)
    $fatal(0, "Error: Interface DATA_W parameter mismatch (instance %m)");

if (!s_axis_payload.KEEP_EN || !m_axis_payload.KEEP_EN)
    $fatal(0, "Error: Interfaces require KEEP_EN (instance %m)");

if (!s_axis_payload.USER_EN || !m_axis_payload.USER_EN)
    $fatal(0, "Error: Interfaces require USER_EN (instance %m)");

if (s_axis_cmd.DATA_W < 17)
    $fatal(0, "Error: Command input must be at least 17 bits wide (instance %m)");

typedef enum logic [1:0] {
    STATE_CMD,
    STATE_PASS,
    STATE_EMPTY,
    STATE_DRAIN
} state_t;

state_t state_reg = STATE_CMD, state_next;

// payload bytes still to come, and whether the payload has gone wrong
logic [15:0] len_rem_reg = '0, len_rem_next;
logic bad_reg = 1'b0, bad_next;

wire        cmd_drop = s_axis_cmd.tdata[16];
wire [15:0] cmd_len = s_axis_cmd.tdata[15:0];

// valid bytes in this input word; tkeep is contiguous from lane 0
wire [2:0] in_keep = s_axis_payload.tkeep[3] ? 3'd4 :
                     s_axis_payload.tkeep[2] ? 3'd3 :
                     s_axis_payload.tkeep[1] ? 3'd2 : 3'd1;

// bytes past tkeep become the pad, as zeros
wire [31:0] in_data = s_axis_payload.tdata & {{8{s_axis_payload.tkeep[3]}}, {8{s_axis_payload.tkeep[2]}},
                                              {8{s_axis_payload.tkeep[1]}}, {8{s_axis_payload.tkeep[0]}}};

logic s_axis_cmd_tready;
logic s_axis_payload_tready;

assign s_axis_cmd.tready = s_axis_cmd_tready;
assign s_axis_payload.tready = s_axis_payload_tready;

logic [31:0]       m_axis_payload_tdata;
logic [3:0]        m_axis_payload_tkeep;
logic              m_axis_payload_tvalid;
logic              m_axis_payload_tlast;
logic [USER_W-1:0] m_axis_payload_tuser;

assign m_axis_payload.tdata  = m_axis_payload_tdata;
assign m_axis_payload.tkeep  = m_axis_payload_tkeep;
assign m_axis_payload.tstrb  = m_axis_payload.tkeep;
assign m_axis_payload.tvalid = m_axis_payload_tvalid;
assign m_axis_payload.tlast  = m_axis_payload_tlast;
assign m_axis_payload.tid    = '0;
assign m_axis_payload.tdest  = '0;
assign m_axis_payload.tuser  = m_axis_payload_tuser;

always_comb begin
    state_next = state_reg;

    len_rem_next = len_rem_reg;
    bad_next = bad_reg;

    s_axis_cmd_tready = 1'b0;
    s_axis_payload_tready = 1'b0;

    m_axis_payload_tdata = in_data;
    m_axis_payload_tkeep = 4'b1111;
    m_axis_payload_tvalid = 1'b0;
    m_axis_payload_tlast = 1'b0;
    m_axis_payload_tuser = '0;

    case (state_reg)
        STATE_CMD: begin
            // the next message's payload: pass it, or stand in for a missing
            // one, or drain it
            s_axis_cmd_tready = 1'b1;

            if (s_axis_cmd.tvalid) begin
                len_rem_next = cmd_len;
                bad_next = 1'b0;

                if (cmd_drop) begin
                    state_next = cmd_len != 0 ? STATE_DRAIN : STATE_CMD;
                end else begin
                    state_next = cmd_len != 0 ? STATE_PASS : STATE_EMPTY;
                end
            end
        end
        STATE_PASS: begin
            // the payload, every beat whole, with zeros past tkeep on the last
            s_axis_payload_tready = m_axis_payload.tready;

            m_axis_payload_tvalid = s_axis_payload.tvalid;
            m_axis_payload_tlast = s_axis_payload.tlast;

            if (s_axis_payload.tlast) begin
                // the payload ends exactly where the command said, and was
                // not aborted
                m_axis_payload_tuser = USER_W'(bad_reg || len_rem_reg != 16'(in_keep) || s_axis_payload.tuser[0]);
            end

            if (s_axis_payload.tvalid && s_axis_payload.tready) begin
                len_rem_next = len_rem_reg - 16'(in_keep);

                if (s_axis_payload.tlast) begin
                    state_next = STATE_CMD;
                end else if (len_rem_reg <= 16'd4 || in_keep != 3'd4) begin
                    // more payload than the command said, or a short word
                    // before the last
                    bad_next = 1'b1;
                end
            end
        end
        STATE_EMPTY: begin
            // a beat with no bytes, ending the frame on the header
            m_axis_payload_tdata = '0;
            m_axis_payload_tkeep = 4'b0000;
            m_axis_payload_tvalid = 1'b1;
            m_axis_payload_tlast = 1'b1;

            if (m_axis_payload.tready) begin
                state_next = STATE_CMD;
            end
        end
        STATE_DRAIN: begin
            // a dropped message's payload, to its end
            s_axis_payload_tready = 1'b1;

            if (s_axis_payload.tvalid && s_axis_payload.tlast) begin
                state_next = STATE_CMD;
            end
        end
        default: begin
            state_next = STATE_CMD;
        end
    endcase
end

always_ff @(posedge clk) begin
    state_reg <= state_next;

    len_rem_reg <= len_rem_next;
    bad_reg <= bad_next;

    if (rst) begin
        state_reg <= STATE_CMD;
        bad_reg <= 1'b0;
    end
end

endmodule

`resetall

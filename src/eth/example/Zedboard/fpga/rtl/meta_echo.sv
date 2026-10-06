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
 * Metadata echo
 *
 * Test fixture standing in for minerva's consumer: turns each receive
 * metadata block from minerva_rx_parse into the transmit metadata for a reply.
 * The reply is in the board's own stream, {cfg_local_mac, UniqueID 0}, goes to
 * the talker of the request's stream, and carries the message fields
 * unchanged.  An error report, with flags set, gets no reply.  The payload goes
 * around this module, unchanged.
 */
module meta_echo
(
    input  wire logic         clk,
    input  wire logic         rst,

    /*
     * Receive metadata, from minerva_rx_parse
     */
    taxi_axis_if.snk          s_axis_meta,

    /*
     * Transmit metadata, to minerva_tx
     */
    taxi_axis_if.src          m_axis_meta,

    /*
     * Configuration
     */
    input  wire logic [47:0]  cfg_local_mac
);

// check configuration
if (s_axis_meta.DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (m_axis_meta.DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

typedef enum logic [0:0] {
    STATE_REQUEST,
    STATE_REPLY
} state_t;

state_t state_reg = STATE_REQUEST, state_next;

// the request word coming in, then the reply word going out
logic [2:0] ptr_reg = '0, ptr_next;

// the request's words: format, flags and payload_len; the talker's stream;
// sv and sequence_num; and the message's two quadlets
logic [31:0] req_0_reg = '0, req_0_next;
logic [63:0] stream_id_reg = '0, stream_id_next;
logic [31:0] req_3_reg = '0, req_3_next;
logic [31:0] req_4_reg = '0, req_4_next;
logic [31:0] req_5_reg = '0, req_5_next;

// the reply: the request's fields in the board's stream, then the talker of
// the request's stream as the destination
logic [31:0] reply_word;

always_comb begin
    case (ptr_reg)
        3'd0: reply_word = req_0_reg;
        3'd1: reply_word = cfg_local_mac[47:16];
        3'd2: reply_word = {cfg_local_mac[15:0], 16'h0000};
        3'd3: reply_word = req_3_reg;
        3'd4: reply_word = req_4_reg;
        3'd5: reply_word = req_5_reg;
        3'd6: reply_word = stream_id_reg[63:32];
        default: reply_word = {stream_id_reg[31:16], 16'h0000};
    endcase
end

logic        s_axis_meta_tready_int;
logic        m_axis_meta_tvalid_int;
logic        m_axis_meta_tlast_int;

assign s_axis_meta.tready = s_axis_meta_tready_int;

assign m_axis_meta.tdata  = reply_word;
assign m_axis_meta.tkeep  = '1;
assign m_axis_meta.tstrb  = m_axis_meta.tkeep;
assign m_axis_meta.tvalid = m_axis_meta_tvalid_int;
assign m_axis_meta.tlast  = m_axis_meta_tlast_int;
assign m_axis_meta.tid    = '0;
assign m_axis_meta.tdest  = '0;
assign m_axis_meta.tuser  = '0;

always_comb begin
    state_next = state_reg;

    ptr_next = ptr_reg;
    req_0_next = req_0_reg;
    stream_id_next = stream_id_reg;
    req_3_next = req_3_reg;
    req_4_next = req_4_reg;
    req_5_next = req_5_reg;

    s_axis_meta_tready_int = 1'b0;
    m_axis_meta_tvalid_int = 1'b0;
    m_axis_meta_tlast_int = 1'b0;

    case (state_reg)
        STATE_REQUEST: begin
            // take in the six request words
            s_axis_meta_tready_int = 1'b1;

            if (s_axis_meta.tvalid && s_axis_meta.tready) begin
                ptr_next = ptr_reg + 1;

                case (ptr_reg)
                    3'd0: req_0_next = s_axis_meta.tdata;
                    3'd1: stream_id_next[63:32] = s_axis_meta.tdata;
                    3'd2: stream_id_next[31:0] = s_axis_meta.tdata;
                    3'd3: req_3_next = s_axis_meta.tdata;
                    3'd4: req_4_next = s_axis_meta.tdata;
                    3'd5: req_5_next = s_axis_meta.tdata;
                    default: ptr_next = ptr_reg;
                endcase

                if (s_axis_meta.tlast) begin
                    ptr_next = '0;

                    // a whole block that is not an error report gets a reply
                    if (ptr_reg == 3'd5 && req_0_reg[23:16] == 8'd0) begin
                        state_next = STATE_REPLY;
                    end
                end
            end
        end
        STATE_REPLY: begin
            // the eight reply words
            m_axis_meta_tvalid_int = 1'b1;
            m_axis_meta_tlast_int = ptr_reg == 3'd7;

            if (m_axis_meta.tready) begin
                ptr_next = ptr_reg + 1;

                if (ptr_reg == 3'd7) begin
                    ptr_next = '0;
                    state_next = STATE_REQUEST;
                end
            end
        end
        default: begin
            state_next = STATE_REQUEST;
        end
    endcase
end

always_ff @(posedge clk) begin
    state_reg <= state_next;

    ptr_reg <= ptr_next;
    req_0_reg <= req_0_next;
    stream_id_reg <= stream_id_next;
    req_3_reg <= req_3_next;
    req_4_reg <= req_4_next;
    req_5_reg <= req_5_next;

    if (rst) begin
        state_reg <= STATE_REQUEST;
        ptr_reg <= '0;
    end
end

endmodule

`resetall

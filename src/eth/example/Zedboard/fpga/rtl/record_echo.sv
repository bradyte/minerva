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
 * Record echo
 *
 * Test fixture standing in for minerva's consumer: turns each record from
 * minerva_rx_parse into a reply record for minerva_tx_deparse.  The reply is
 * in the board's own stream, {cfg_local_mac, UniqueID 0}, goes to the talker
 * of the request's stream, and carries the message fields and the payload
 * unchanged.
 *
 * Truncated messages must already be gone: tuser is not examined.
 */
module record_echo
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

localparam ID_W = s_axis_eth_rx.ID_W;
localparam DEST_W = s_axis_eth_rx.DEST_W;

// check configuration
if (s_axis_eth_rx.DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (m_axis_eth_tx.DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (!s_axis_eth_rx.KEEP_EN || !m_axis_eth_tx.KEEP_EN)
    $fatal(0, "Error: Interfaces require KEEP_EN (instance %m)");

typedef enum logic [1:0] {
    STATE_RECORD,
    STATE_REPLY,
    STATE_PAYLOAD
} state_t;

state_t state_reg = STATE_RECORD, state_next;

// the record word coming in, then the reply word going out
logic [2:0] ptr_reg = '0, ptr_next;

// the request's record and sideband, and whether the record was the whole
// packet
logic [63:0]       stream_id_reg = '0, stream_id_next;
logic [31:0]       rec_2_reg = '0, rec_2_next;
logic [31:0]       rec_3_reg = '0, rec_3_next;
logic              rec_last_reg = 1'b0, rec_last_next;
logic [ID_W-1:0]   tid_reg = '0, tid_next;
logic [DEST_W-1:0] tdest_reg = '0, tdest_next;

// the reply record: the board's stream, the message fields, then the talker
// of the request's stream as the destination
logic [31:0] reply_word;

always_comb begin
    case (ptr_reg)
        3'd0: reply_word = cfg_local_mac[47:16];
        3'd1: reply_word = {cfg_local_mac[15:0], 16'h0000};
        3'd2: reply_word = rec_2_reg;
        3'd3: reply_word = rec_3_reg;
        3'd4: reply_word = stream_id_reg[63:32];
        default: reply_word = {stream_id_reg[31:16], 16'h0000};
    endcase
end

logic        s_axis_eth_rx_tready_int;
logic [31:0] m_axis_eth_tx_tdata_int;
logic [3:0]  m_axis_eth_tx_tkeep_int;
logic        m_axis_eth_tx_tvalid_int;
logic        m_axis_eth_tx_tlast_int;

assign s_axis_eth_rx.tready = s_axis_eth_rx_tready_int;

assign m_axis_eth_tx.tdata  = m_axis_eth_tx_tdata_int;
assign m_axis_eth_tx.tkeep  = m_axis_eth_tx_tkeep_int;
assign m_axis_eth_tx.tstrb  = m_axis_eth_tx.tkeep;
assign m_axis_eth_tx.tvalid = m_axis_eth_tx_tvalid_int;
assign m_axis_eth_tx.tlast  = m_axis_eth_tx_tlast_int;
assign m_axis_eth_tx.tid    = tid_reg;
assign m_axis_eth_tx.tdest  = tdest_reg;
assign m_axis_eth_tx.tuser  = '0;

always_comb begin
    state_next = state_reg;

    ptr_next = ptr_reg;
    stream_id_next = stream_id_reg;
    rec_2_next = rec_2_reg;
    rec_3_next = rec_3_reg;
    rec_last_next = rec_last_reg;
    tid_next = tid_reg;
    tdest_next = tdest_reg;

    s_axis_eth_rx_tready_int = 1'b0;
    m_axis_eth_tx_tdata_int = reply_word;
    m_axis_eth_tx_tkeep_int = 4'b1111;
    m_axis_eth_tx_tvalid_int = 1'b0;
    m_axis_eth_tx_tlast_int = 1'b0;

    case (state_reg)
        STATE_RECORD: begin
            // take in the four record words
            s_axis_eth_rx_tready_int = 1'b1;

            if (s_axis_eth_rx.tvalid && s_axis_eth_rx.tready) begin
                ptr_next = ptr_reg + 1;

                case (ptr_reg[1:0])
                    2'd0: begin
                        stream_id_next[63:32] = s_axis_eth_rx.tdata;
                        tid_next = s_axis_eth_rx.tid;
                        tdest_next = s_axis_eth_rx.tdest;
                    end
                    2'd1: stream_id_next[31:0] = s_axis_eth_rx.tdata;
                    2'd2: rec_2_next = s_axis_eth_rx.tdata;
                    default: rec_3_next = s_axis_eth_rx.tdata;
                endcase

                if (ptr_reg == 3'd3) begin
                    ptr_next = '0;
                    rec_last_next = s_axis_eth_rx.tlast;
                    state_next = STATE_REPLY;
                end else if (s_axis_eth_rx.tlast) begin
                    // shorter than a record
                    ptr_next = '0;
                end
            end
        end
        STATE_REPLY: begin
            // the six reply record words, while the payload waits
            m_axis_eth_tx_tvalid_int = 1'b1;
            m_axis_eth_tx_tlast_int = ptr_reg == 3'd5 && rec_last_reg;

            if (m_axis_eth_tx.tready) begin
                ptr_next = ptr_reg + 1;

                if (ptr_reg == 3'd5) begin
                    ptr_next = '0;
                    state_next = rec_last_reg ? STATE_RECORD : STATE_PAYLOAD;
                end
            end
        end
        STATE_PAYLOAD: begin
            // the payload, unchanged
            s_axis_eth_rx_tready_int = m_axis_eth_tx.tready;
            m_axis_eth_tx_tdata_int = s_axis_eth_rx.tdata;
            m_axis_eth_tx_tkeep_int = s_axis_eth_rx.tkeep;
            m_axis_eth_tx_tvalid_int = s_axis_eth_rx.tvalid;
            m_axis_eth_tx_tlast_int = s_axis_eth_rx.tlast;

            if (s_axis_eth_rx.tvalid && s_axis_eth_rx.tready && s_axis_eth_rx.tlast) begin
                state_next = STATE_RECORD;
            end
        end
        default: begin
            state_next = STATE_RECORD;
        end
    endcase
end

always_ff @(posedge clk) begin
    state_reg <= state_next;

    ptr_reg <= ptr_next;
    stream_id_reg <= stream_id_next;
    rec_2_reg <= rec_2_next;
    rec_3_reg <= rec_3_next;
    rec_last_reg <= rec_last_next;
    tid_reg <= tid_next;
    tdest_reg <= tdest_next;

    if (rst) begin
        state_reg <= STATE_RECORD;
        ptr_reg <= '0;
    end
end

endmodule

`resetall

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
 * Test fixture: rebuilds each ABB message from the record minerva_rx_parse
 * sends and returns it to minerva_tx_deparse, alone in an NTSCF PDU and
 * addressed to the MacAddress in its stream_id.  The headers come only from
 * the record and constants, so an echo identical to the request shows the
 * record is complete.  Stands in for minerva's consumer.
 *
 * Truncated messages must already be gone: tuser is not examined.
 */
module record_echo #
(
    parameter logic [15:0] ETHERTYPE = 16'h22F0
)
(
    input  wire logic  clk,
    input  wire logic  rst,

    /*
     * Record, then payload, from minerva_rx_parse
     */
    taxi_axis_if.snk   s_axis_eth_rx,

    /*
     * Prefixed PDU, to minerva_tx_deparse
     */
    taxi_axis_if.src   m_axis_eth_tx
);

// check configuration
if (s_axis_eth_rx.DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (m_axis_eth_tx.DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (!s_axis_eth_rx.KEEP_EN)
    $fatal(0, "Error: Input requires KEEP_EN (instance %m)");

localparam logic [7:0] SUBTYPE_NTSCF = 8'h82;
localparam logic [6:0] ACF_MSG_TYPE_ABB = 7'h0E;

typedef enum logic [1:0] {
    STATE_RECORD,
    STATE_HDR,
    STATE_PAYLOAD
} state_t;

state_t state_reg = STATE_RECORD, state_next;

// the record word coming in, then the header word going out
logic [2:0] ptr_reg = '0, ptr_next;

// the record, and whether it was the whole packet
logic [63:0] stream_id_reg = '0, stream_id_next;
logic [31:0] rec_2_reg = '0, rec_2_next;
logic [31:0] rec_3_reg = '0, rec_3_next;
logic rec_last_reg = 1'b0, rec_last_next;

// record word 2
wire [7:0]  sequence_num = rec_2_reg[31:24];
wire        mtv = rec_2_reg[23];
wire [10:0] byte_bus_id = rec_2_reg[22:12];
wire        sv = rec_2_reg[11];
wire [10:0] payload_len = rec_2_reg[10:0];

// the pad takes the payload to a whole quadlet
wire [1:0]  pad = 2'd0 - payload_len[1:0];
wire [10:0] msg_bytes = 11'd8 + payload_len + 11'(pad);

// NTSCF word 0 and ABB word 0, as quadlets
wire [31:0] ntscf_0 = {SUBTYPE_NTSCF, sv, 3'd0, 1'b0, msg_bytes, sequence_num};
wire [31:0] abb_0 = {ACF_MSG_TYPE_ABB, msg_bytes[10:2], pad, mtv, 2'b00, byte_bus_id};

// a quadlet in wire order: its most significant byte goes first, in lane 0
function automatic logic [31:0] wire_order(input logic [31:0] q);
    return {q[7:0], q[15:8], q[23:16], q[31:24]};
endfunction

// the prefix for minerva_tx_deparse, then the headers
logic [31:0] hdr_word;

always_comb begin
    case (ptr_reg)
        3'd0: hdr_word = wire_order(stream_id_reg[63:32]);
        3'd1: hdr_word = wire_order({stream_id_reg[31:16], ETHERTYPE});
        3'd2: hdr_word = wire_order(ntscf_0);
        3'd3: hdr_word = wire_order(stream_id_reg[63:32]);
        3'd4: hdr_word = wire_order(stream_id_reg[31:0]);
        3'd5: hdr_word = wire_order(abb_0);
        default: hdr_word = wire_order(rec_3_reg);
    endcase
end

// bytes past tkeep are the pad, restored as zeros
wire [31:0] keep_mask = {{8{s_axis_eth_rx.tkeep[3]}}, {8{s_axis_eth_rx.tkeep[2]}},
                         {8{s_axis_eth_rx.tkeep[1]}}, {8{s_axis_eth_rx.tkeep[0]}}};

logic        s_axis_eth_rx_tready_int;
logic [31:0] m_axis_eth_tx_tdata_int;
logic        m_axis_eth_tx_tvalid_int;
logic        m_axis_eth_tx_tlast_int;

assign s_axis_eth_rx.tready = s_axis_eth_rx_tready_int;

assign m_axis_eth_tx.tdata  = m_axis_eth_tx_tdata_int;
assign m_axis_eth_tx.tkeep  = 4'b1111;
assign m_axis_eth_tx.tstrb  = m_axis_eth_tx.tkeep;
assign m_axis_eth_tx.tvalid = m_axis_eth_tx_tvalid_int;
assign m_axis_eth_tx.tlast  = m_axis_eth_tx_tlast_int;
assign m_axis_eth_tx.tid    = '0;
assign m_axis_eth_tx.tdest  = '0;
assign m_axis_eth_tx.tuser  = '0;

always_comb begin
    state_next = state_reg;

    ptr_next = ptr_reg;
    stream_id_next = stream_id_reg;
    rec_2_next = rec_2_reg;
    rec_3_next = rec_3_reg;
    rec_last_next = rec_last_reg;

    s_axis_eth_rx_tready_int = 1'b0;
    m_axis_eth_tx_tdata_int = hdr_word;
    m_axis_eth_tx_tvalid_int = 1'b0;
    m_axis_eth_tx_tlast_int = 1'b0;

    case (state_reg)
        STATE_RECORD: begin
            // take in the four record words
            s_axis_eth_rx_tready_int = 1'b1;

            if (s_axis_eth_rx.tvalid && s_axis_eth_rx.tready) begin
                ptr_next = ptr_reg + 1;

                case (ptr_reg[1:0])
                    2'd0: stream_id_next[63:32] = s_axis_eth_rx.tdata;
                    2'd1: stream_id_next[31:0] = s_axis_eth_rx.tdata;
                    2'd2: rec_2_next = s_axis_eth_rx.tdata;
                    default: rec_3_next = s_axis_eth_rx.tdata;
                endcase

                if (ptr_reg == 3'd3) begin
                    ptr_next = '0;
                    rec_last_next = s_axis_eth_rx.tlast;
                    state_next = STATE_HDR;
                end else if (s_axis_eth_rx.tlast) begin
                    // shorter than a record
                    ptr_next = '0;
                end
            end
        end
        STATE_HDR: begin
            // the prefix and the rebuilt headers, while the payload waits
            m_axis_eth_tx_tvalid_int = 1'b1;
            m_axis_eth_tx_tlast_int = ptr_reg == 3'd6 && rec_last_reg;

            if (m_axis_eth_tx.tready) begin
                ptr_next = ptr_reg + 1;

                if (ptr_reg == 3'd6) begin
                    ptr_next = '0;
                    state_next = rec_last_reg ? STATE_RECORD : STATE_PAYLOAD;
                end
            end
        end
        STATE_PAYLOAD: begin
            // the payload, in wire order already, with its pad back in place
            s_axis_eth_rx_tready_int = m_axis_eth_tx.tready;
            m_axis_eth_tx_tdata_int = s_axis_eth_rx.tdata & keep_mask;
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

    if (rst) begin
        state_reg <= STATE_RECORD;
        ptr_reg <= '0;
    end
end

endmodule

`resetall

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
 * Minerva TX deparser
 *
 * The mirror of minerva_rx_parse: from each metadata block it builds the
 * header of a frame carrying one ABB message in an NTSCF PDU, and sends a
 * command telling minerva_tx_gate what to do with that message's payload.  A
 * block that fails its checks gives no header, and its command drops the
 * payload.
 */
module minerva_tx_deparse
(
    input  wire logic         clk,
    input  wire logic         rst,

    /*
     * Metadata input, one block per message
     */
    taxi_axis_if.snk          s_axis_meta,

    /*
     * Header output
     */
    taxi_axis_if.src          m_axis_hdr,

    /*
     * Payload command output: {drop, len}
     */
    taxi_axis_if.src          m_axis_cmd,

    /*
     * Configuration
     */
    input  wire logic [47:0]  cfg_local_mac
);

localparam DATA_W = s_axis_meta.DATA_W;
localparam CMD_W = m_axis_cmd.DATA_W;

// check configuration
if (DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (m_axis_hdr.DATA_W != DATA_W)
    $fatal(0, "Error: Interface DATA_W parameter mismatch (instance %m)");

if (!m_axis_hdr.KEEP_EN)
    $fatal(0, "Error: Header output requires KEEP_EN (instance %m)");

if (!s_axis_meta.LAST_EN)
    $fatal(0, "Error: Metadata input requires LAST_EN (instance %m)");

if (CMD_W < 17)
    $fatal(0, "Error: Command output must be at least 17 bits wide (instance %m)");

typedef enum logic [15:0] {
    ETHERTYPE_AVTP = 16'h22F0
} ethertype_t;

typedef enum logic [7:0] {
    SUBTYPE_NTSCF = 8'h82
} subtype_t;

typedef enum logic [6:0] {
    ACF_MSG_TYPE_ABB = 7'h0E
} acf_msg_type_t;

// the largest payload an untagged frame holds
localparam logic [15:0] MAX_PAYLOAD_LEN = 16'd1480;

typedef enum logic [0:0] {
    STATE_IDLE,
    STATE_HDR
} state_t;

state_t state_reg = STATE_IDLE, state_next;

// the header word going out; word 8 is the last two bytes
logic [3:0] ptr_reg = '0, ptr_next;

// the source address, taken as the header began
logic [47:0] src_mac_reg = '0, src_mac_next;

// two metadata slots, filled from the input and read in turn; a slot is ok
// if its block was exactly eight words
logic [31:0] meta_slot_reg[2][8] = '{default: '{default: '0}};
logic        meta_slot_ok_reg[2] = '{default: 1'b0};

logic [1:0] meta_wr_slot_reg = '0, meta_wr_slot_next;
logic [1:0] meta_rd_slot_reg = '0, meta_rd_slot_next;
// the word being written; 8 means the block is longer than eight words
logic [3:0] meta_wr_ptr_reg = '0, meta_wr_ptr_next;
logic meta_wr;
logic meta_done;

wire meta_empty = meta_wr_slot_reg == meta_rd_slot_reg;
wire meta_full_next = meta_wr_slot_next == (meta_rd_slot_next ^ 2'b10);

logic s_axis_meta_tready_reg = 1'b0;

assign s_axis_meta.tready = s_axis_meta_tready_reg;

// the block in the slot being read
wire [31:0] meta_blk[8];

assign meta_blk = meta_slot_reg[meta_rd_slot_reg[0]];

wire [7:0]  format = meta_blk[0][31:24];
wire [7:0]  flags = meta_blk[0][23:16];
wire [15:0] meta_len = meta_blk[0][15:0];
wire [63:0] stream_id = {meta_blk[1], meta_blk[2]};
wire        sv = meta_blk[3][31];
wire [7:0]  sequence_num = meta_blk[3][30:23];
wire        mtv = meta_blk[4][13];
wire [10:0] byte_bus_id = meta_blk[4][10:0];
wire [31:0] abb_1 = meta_blk[5];
wire [47:0] dst_mac = {meta_blk[6], meta_blk[7][31:16]};

wire meta_ok = meta_slot_ok_reg[meta_rd_slot_reg[0]] && format == SUBTYPE_NTSCF && flags == 0
    && meta_len <= MAX_PAYLOAD_LEN;

// the pad takes the payload to a whole quadlet; one message fills the PDU
wire [10:0] payload_len = meta_len[10:0];
wire [1:0]  pad = 2'd0 - payload_len[1:0];
wire [10:0] msg_bytes = 11'd8 + payload_len + 11'(pad);

// NTSCF word 0 and ABB word 0, as quadlet values
wire [31:0] ntscf_0 = {SUBTYPE_NTSCF, sv, 3'd0, 1'b0, msg_bytes, sequence_num};
wire [31:0] abb_0 = {ACF_MSG_TYPE_ABB, msg_bytes[10:2], pad, mtv, 2'b00, byte_bus_id};

function automatic logic [31:0] swab32(input logic [31:0] q);
    return {q[7:0], q[15:8], q[23:16], q[31:24]};
endfunction

logic [31:0] hdr_word;

always_comb begin
    case (ptr_reg)
        4'd0: hdr_word = swab32(dst_mac[47:16]);
        4'd1: hdr_word = swab32({dst_mac[15:0], src_mac_reg[47:32]});
        4'd2: hdr_word = swab32(src_mac_reg[31:0]);
        4'd3: hdr_word = swab32({ETHERTYPE_AVTP, ntscf_0[31:16]});
        4'd4: hdr_word = swab32({ntscf_0[15:0], stream_id[63:48]});
        4'd5: hdr_word = swab32(stream_id[47:16]);
        4'd6: hdr_word = swab32({stream_id[15:0], abb_0[31:16]});
        4'd7: hdr_word = swab32({abb_0[15:0], abb_1[31:16]});
        default: hdr_word = swab32({abb_1[15:0], 16'd0});
    endcase
end

// the command for the payload of the block being read
logic        m_axis_cmd_tvalid_reg = 1'b0, m_axis_cmd_tvalid_next;
logic        m_axis_cmd_drop_reg = 1'b0, m_axis_cmd_drop_next;
logic [15:0] m_axis_cmd_len_reg = '0, m_axis_cmd_len_next;

assign m_axis_cmd.tdata  = CMD_W'({m_axis_cmd_drop_reg, m_axis_cmd_len_reg});
assign m_axis_cmd.tkeep  = '1;
assign m_axis_cmd.tstrb  = m_axis_cmd.tkeep;
assign m_axis_cmd.tvalid = m_axis_cmd_tvalid_reg;
assign m_axis_cmd.tlast  = 1'b1;
assign m_axis_cmd.tid    = '0;
assign m_axis_cmd.tdest  = '0;
assign m_axis_cmd.tuser  = '0;

logic [31:0] m_axis_hdr_tdata_reg = '0, m_axis_hdr_tdata_next;
logic [3:0]  m_axis_hdr_tkeep_reg = '0, m_axis_hdr_tkeep_next;
logic        m_axis_hdr_tvalid_reg = 1'b0, m_axis_hdr_tvalid_next;
logic        m_axis_hdr_tlast_reg = 1'b0, m_axis_hdr_tlast_next;

assign m_axis_hdr.tdata  = m_axis_hdr_tdata_reg;
assign m_axis_hdr.tkeep  = m_axis_hdr_tkeep_reg;
assign m_axis_hdr.tstrb  = m_axis_hdr.tkeep;
assign m_axis_hdr.tvalid = m_axis_hdr_tvalid_reg;
assign m_axis_hdr.tlast  = m_axis_hdr_tlast_reg;
assign m_axis_hdr.tid    = '0;
assign m_axis_hdr.tdest  = '0;
assign m_axis_hdr.tuser  = '0;

// store metadata
always_comb begin
    meta_wr_slot_next = meta_wr_slot_reg;
    meta_wr_ptr_next = meta_wr_ptr_reg;
    meta_wr = 1'b0;
    meta_done = 1'b0;

    if (s_axis_meta.tvalid && s_axis_meta.tready) begin
        if (meta_wr_ptr_reg != 4'd8) begin
            meta_wr = 1'b1;
            meta_wr_ptr_next = meta_wr_ptr_reg + 1;
        end

        if (s_axis_meta.tlast) begin
            meta_done = 1'b1;
            meta_wr_ptr_next = '0;
            meta_wr_slot_next = meta_wr_slot_reg + 1;
        end
    end
end

// build headers
always_comb begin
    state_next = state_reg;

    ptr_next = ptr_reg;
    src_mac_next = src_mac_reg;

    meta_rd_slot_next = meta_rd_slot_reg;

    m_axis_cmd_tvalid_next = m_axis_cmd_tvalid_reg && !m_axis_cmd.tready;
    m_axis_cmd_drop_next = m_axis_cmd_drop_reg;
    m_axis_cmd_len_next = m_axis_cmd_len_reg;

    m_axis_hdr_tdata_next = m_axis_hdr_tdata_reg;
    m_axis_hdr_tkeep_next = m_axis_hdr_tkeep_reg;
    m_axis_hdr_tvalid_next = m_axis_hdr_tvalid_reg && !m_axis_hdr.tready;
    m_axis_hdr_tlast_next = m_axis_hdr_tlast_reg;

    case (state_reg)
        STATE_IDLE: begin
            // a block is ready, and the command output is free
            if (!meta_empty && (!m_axis_cmd_tvalid_reg || m_axis_cmd.tready)) begin
                m_axis_cmd_tvalid_next = 1'b1;
                m_axis_cmd_drop_next = !meta_ok;
                m_axis_cmd_len_next = meta_len;

                if (meta_ok) begin
                    src_mac_next = cfg_local_mac;
                    ptr_next = '0;
                    state_next = STATE_HDR;
                end else begin
                    // no header, so the block is done
                    meta_rd_slot_next = meta_rd_slot_reg + 1;
                end
            end
        end
        STATE_HDR: begin
            // header words 0 to 7, then the last two bytes in lanes 0 and 1
            if (!m_axis_hdr_tvalid_reg || m_axis_hdr.tready) begin
                m_axis_hdr_tdata_next = hdr_word;
                m_axis_hdr_tkeep_next = ptr_reg == 4'd8 ? 4'b0011 : 4'b1111;
                m_axis_hdr_tvalid_next = 1'b1;
                m_axis_hdr_tlast_next = ptr_reg == 4'd8;
                ptr_next = ptr_reg + 1;

                if (ptr_reg == 4'd8) begin
                    meta_rd_slot_next = meta_rd_slot_reg + 1;
                    state_next = STATE_IDLE;
                end
            end
        end
        default: begin
            state_next = STATE_IDLE;
        end
    endcase
end

always_ff @(posedge clk) begin
    state_reg <= state_next;

    ptr_reg <= ptr_next;
    src_mac_reg <= src_mac_next;

    meta_wr_slot_reg <= meta_wr_slot_next;
    meta_rd_slot_reg <= meta_rd_slot_next;
    meta_wr_ptr_reg <= meta_wr_ptr_next;

    // take metadata while a slot will be free
    s_axis_meta_tready_reg <= !meta_full_next;

    if (meta_wr) begin
        meta_slot_reg[meta_wr_slot_reg[0]][meta_wr_ptr_reg[2:0]] <= s_axis_meta.tdata;
    end

    if (meta_done) begin
        meta_slot_ok_reg[meta_wr_slot_reg[0]] <= meta_wr_ptr_reg == 4'd7;
    end

    m_axis_cmd_tvalid_reg <= m_axis_cmd_tvalid_next;
    m_axis_cmd_drop_reg <= m_axis_cmd_drop_next;
    m_axis_cmd_len_reg <= m_axis_cmd_len_next;

    m_axis_hdr_tdata_reg <= m_axis_hdr_tdata_next;
    m_axis_hdr_tkeep_reg <= m_axis_hdr_tkeep_next;
    m_axis_hdr_tvalid_reg <= m_axis_hdr_tvalid_next;
    m_axis_hdr_tlast_reg <= m_axis_hdr_tlast_next;

    if (rst) begin
        state_reg <= STATE_IDLE;
        ptr_reg <= '0;
        meta_wr_slot_reg <= '0;
        meta_rd_slot_reg <= '0;
        meta_wr_ptr_reg <= '0;
        s_axis_meta_tready_reg <= 1'b0;
        m_axis_cmd_tvalid_reg <= 1'b0;
        m_axis_hdr_tvalid_reg <= 1'b0;
    end
end

endmodule

`resetall

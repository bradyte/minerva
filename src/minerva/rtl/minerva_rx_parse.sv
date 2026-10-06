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
 * Minerva RX parser
 *
 * The mirror of minerva_tx_deparse: it parses each frame from Ethernet down to
 * its ABB messages, and gives a metadata block for each and, when the message
 * has a payload, the payload.  A frame that fails its checks gives a block
 * with error flags, or one on the discard route, and no payload.
 */
module minerva_rx_parse #
(
    // accept a single VLAN tag ahead of the ethertype
    parameter logic VLAN_EN = 1'b1
)
(
    input  wire logic  clk,
    input  wire logic  rst,

    /*
     * Frame input, from the MAC
     */
    taxi_axis_if.snk   s_axis_mac_rx,

    /*
     * Metadata output, one block per message
     */
    taxi_axis_if.src   m_axis_meta,

    /*
     * Payload output, when the metadata announces one
     */
    taxi_axis_if.src   m_axis_payload
);

localparam DATA_W = s_axis_mac_rx.DATA_W;
localparam DEST_W = m_axis_meta.DEST_W;
localparam USER_W = m_axis_payload.USER_W;

// check configuration
if (DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (m_axis_meta.DATA_W != DATA_W || m_axis_payload.DATA_W != DATA_W)
    $fatal(0, "Error: Interface DATA_W parameter mismatch (instance %m)");

if (!s_axis_mac_rx.KEEP_EN || !m_axis_payload.KEEP_EN)
    $fatal(0, "Error: Interfaces require KEEP_EN (instance %m)");

if (!m_axis_meta.LAST_EN)
    $fatal(0, "Error: Metadata output requires LAST_EN (instance %m)");

if (!m_axis_meta.DEST_EN || !m_axis_payload.DEST_EN)
    $fatal(0, "Error: Outputs require DEST_EN (instance %m)");

if (m_axis_payload.DEST_W != DEST_W)
    $fatal(0, "Error: Interface DEST_W parameter mismatch (instance %m)");

if (!m_axis_payload.USER_EN)
    $fatal(0, "Error: Payload output requires USER_EN (instance %m)");

typedef enum logic [15:0] {
    ETHERTYPE_AVTP = 16'h22F0,
    ETHERTYPE_VLAN_C = 16'h8100,
    ETHERTYPE_VLAN_S = 16'h88A8
} ethertype_t;

typedef enum logic [7:0] {
    SUBTYPE_NTSCF = 8'h82
} subtype_t;

typedef enum logic [6:0] {
    ACF_MSG_TYPE_ABB = 7'h0E
} acf_msg_type_t;

// routes on tdest
localparam logic [DEST_W-1:0] ROUTE_CONSUMER = DEST_W'(0);
localparam logic [DEST_W-1:0] ROUTE_DISCARD = DEST_W'(1);

// flags in metadata word 0
localparam logic [7:0] FLAG_ERR_EMPTY = 8'h01;
localparam logic [7:0] FLAG_ERR_LEN = 8'h02;
localparam logic [7:0] FLAG_ERR_TRUNC = 8'h04;

typedef enum logic [3:0] {
    STATE_ETH,
    STATE_VLAN,
    STATE_AVTP,
    STATE_NTSCF_1,
    STATE_NTSCF_2,
    STATE_ACF,
    STATE_ABB_1,
    STATE_META,
    STATE_PAYLOAD,
    STATE_SKIP,
    STATE_DROP
} state_t;

state_t state_reg = STATE_ETH, state_next;

// words of the L2 header consumed
logic [1:0] ptr_reg = '0, ptr_next;

// bytes of ACF messages still to come in the NTSCF payload
logic [10:0] data_rem_reg = '0, data_rem_next;
// quadlets still to come in the current message
logic [8:0] msg_rem_reg = '0, msg_rem_next;
// pad bytes at the end of the current ABB message
logic [1:0] pad_reg = '0, pad_next;

// metadata fields
logic [7:0]  format_reg = '0, format_next;
logic        sv_reg = 1'b0, sv_next;
logic [7:0]  seq_num_reg = '0, seq_num_next;
logic [63:0] stream_id_reg = '0, stream_id_next;
logic [31:0] acf_q0_reg = '0, acf_q0_next;
logic [31:0] abb_1_reg = '0, abb_1_next;
logic [10:0] payload_len_reg = '0, payload_len_next;

// the block to load into a slot, and the state to go on to
logic [7:0]        meta_flags_reg = '0, meta_flags_next;
logic [10:0]       meta_len_reg = '0, meta_len_next;
logic [DEST_W-1:0] meta_route_reg = '0, meta_route_next;
state_t            meta_ret_reg = STATE_ETH, meta_ret_next;
logic              meta_trunc_reg = 1'b0, meta_trunc_next;

// two metadata slots, filled by the parser and read out in turn
logic [31:0]       meta_slot_reg[2][6] = '{default: '{default: '0}};
logic [DEST_W-1:0] meta_slot_dest_reg[2] = '{default: '0};

logic [1:0] meta_wr_slot_reg = '0, meta_wr_slot_next;
logic [1:0] meta_rd_slot_reg = '0, meta_rd_slot_next;
logic [2:0] meta_rd_ptr_reg = '0, meta_rd_ptr_next;
logic meta_wr;
logic meta_rd;

wire meta_empty = meta_wr_slot_reg == meta_rd_slot_reg;
wire meta_full = meta_wr_slot_reg == (meta_rd_slot_reg ^ 2'b10);

// a metadata block requested by this cycle's transfer
logic              meta_req;
logic [7:0]        meta_req_flags;
logic [10:0]       meta_req_len;
logic [DEST_W-1:0] meta_req_route;
state_t            meta_req_ret;
logic              meta_req_trunc;

// realignment: the previous word's top two bytes
logic [15:0] shift_reg = '0;
wire [31:0] shifted = {s_axis_mac_rx.tdata[15:0], shift_reg};

// the shifted word as a 1722 quadlet
wire [31:0] quad = {shifted[7:0], shifted[15:8], shifted[23:16], shifted[31:24]};

wire [15:0] ethertype = {s_axis_mac_rx.tdata[7:0], s_axis_mac_rx.tdata[15:8]};

// valid bytes in this input word; tkeep is contiguous from lane 0
wire [2:0] in_keep = s_axis_mac_rx.tkeep[3] ? 3'd4 :
                     s_axis_mac_rx.tkeep[2] ? 3'd3 :
                     s_axis_mac_rx.tkeep[1] ? 3'd2 : 3'd1;

// a shifted word is whole only if the word in holds its last two bytes
wire in_whole = !s_axis_mac_rx.tlast || in_keep >= 3'd2;

// AVTP common header, in AVTP word 0
wire [7:0] avtp_subtype = quad[31:24];
wire [2:0] avtp_version = quad[22:20];

// ACF common header and the first ABB fields, in ACF word 0
wire [6:0]  acf_msg_type = quad[31:25];
wire [8:0]  acf_msg_len = quad[24:16];
wire [10:0] acf_msg_bytes = {acf_msg_len, 2'b00};
wire [1:0]  acf_pad = quad[15:14];
wire [10:0] acf_payload_len = acf_msg_bytes - 11'd8 - 11'(acf_pad);

// NTSCF payload left once this message is done
wire [10:0] acf_data_rem = data_rem_reg - acf_msg_bytes;

// the message fits in the NTSCF payload, and an ABB message also holds its
// header and pad
wire acf_fits = acf_msg_bytes <= data_rem_reg;
wire acf_abb_ok = acf_fits && acf_msg_bytes >= 11'd8 + 11'(acf_pad);

// handle ethertype
state_t eth_type_state;

always_comb begin
    case (ethertype)
        ETHERTYPE_VLAN_C, ETHERTYPE_VLAN_S: eth_type_state = VLAN_EN ? STATE_VLAN : STATE_DROP;
        ETHERTYPE_AVTP: eth_type_state = STATE_AVTP;
        default: eth_type_state = STATE_DROP;
    endcase
end

logic s_axis_mac_rx_tready_reg = 1'b0, s_axis_mac_rx_tready_next;

// internal datapath
logic [31:0]       m_axis_payload_tdata_int;
logic [3:0]        m_axis_payload_tkeep_int;
logic              m_axis_payload_tvalid_int;
logic              m_axis_payload_tready_int_reg = 1'b0;
logic              m_axis_payload_tlast_int;
logic [USER_W-1:0] m_axis_payload_tuser_int;
wire               m_axis_payload_tready_int_early;

assign s_axis_mac_rx.tready = s_axis_mac_rx_tready_reg;

always_comb begin
    state_next = state_reg;

    ptr_next = ptr_reg;
    data_rem_next = data_rem_reg;
    msg_rem_next = msg_rem_reg;
    pad_next = pad_reg;

    format_next = format_reg;
    sv_next = sv_reg;
    seq_num_next = seq_num_reg;
    stream_id_next = stream_id_reg;
    acf_q0_next = acf_q0_reg;
    abb_1_next = abb_1_reg;
    payload_len_next = payload_len_reg;

    meta_flags_next = meta_flags_reg;
    meta_len_next = meta_len_reg;
    meta_route_next = meta_route_reg;
    meta_ret_next = meta_ret_reg;
    meta_trunc_next = meta_trunc_reg;

    meta_wr_slot_next = meta_wr_slot_reg;
    meta_wr = 1'b0;

    // by default a request is an error report to the consumer, then back to
    // the start of a frame
    meta_req = 1'b0;
    meta_req_flags = '0;
    meta_req_len = '0;
    meta_req_route = ROUTE_CONSUMER;
    meta_req_ret = STATE_ETH;
    meta_req_trunc = 1'b0;

    s_axis_mac_rx_tready_next = 1'b0;

    m_axis_payload_tdata_int = shifted;
    m_axis_payload_tkeep_int = 4'b1111;
    m_axis_payload_tvalid_int = 1'b0;
    m_axis_payload_tlast_int = 1'b0;
    m_axis_payload_tuser_int = '0;

    case (state_reg)
        STATE_ETH: begin
            // words 0 to 2 are addresses; the ethertype decides at word 3
            s_axis_mac_rx_tready_next = 1'b1;

            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                ptr_next = ptr_reg + 1;

                if (ptr_reg == 2'd0) begin
                    // a new frame
                    format_next = '0;
                    sv_next = 1'b0;
                    seq_num_next = '0;
                    stream_id_next = '0;
                    acf_q0_next = '0;
                    abb_1_next = '0;
                end

                if (s_axis_mac_rx.tlast) begin
                    // too short to be anything
                    ptr_next = '0;
                    meta_req = 1'b1;
                    meta_req_route = ROUTE_DISCARD;
                end else if (ptr_reg == 2'd3) begin
                    if (eth_type_state == STATE_DROP) begin
                        meta_req = 1'b1;
                        meta_req_route = ROUTE_DISCARD;
                        meta_req_ret = STATE_DROP;
                    end else begin
                        state_next = eth_type_state;
                    end
                end
            end
        end
        STATE_VLAN: begin
            // the inner ethertype, in the lanes the outer one used
            s_axis_mac_rx_tready_next = 1'b1;

            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                if (s_axis_mac_rx.tlast || eth_type_state != STATE_AVTP) begin
                    // too short, a second tag, or another ethertype
                    meta_req = 1'b1;
                    meta_req_route = ROUTE_DISCARD;
                    meta_req_ret = s_axis_mac_rx.tlast ? STATE_ETH : STATE_DROP;
                end else begin
                    state_next = STATE_AVTP;
                end
            end
        end
        STATE_AVTP: begin
            // AVTP common header and the first NTSCF fields
            s_axis_mac_rx_tready_next = 1'b1;

            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                data_rem_next = quad[18:8];

                if (in_whole) begin
                    format_next = avtp_subtype;
                    sv_next = quad[23];
                    seq_num_next = quad[7:0];
                end

                if (!in_whole || avtp_subtype != SUBTYPE_NTSCF || avtp_version != 3'd0) begin
                    // not NTSCF, or not known to be
                    meta_req = 1'b1;
                    meta_req_route = ROUTE_DISCARD;
                    meta_req_ret = s_axis_mac_rx.tlast ? STATE_ETH : STATE_DROP;
                end else if (s_axis_mac_rx.tlast) begin
                    meta_req = 1'b1;
                    meta_req_flags = FLAG_ERR_TRUNC;
                end else begin
                    state_next = STATE_NTSCF_1;
                end
            end
        end
        STATE_NTSCF_1: begin
            s_axis_mac_rx_tready_next = 1'b1;

            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                if (in_whole) begin
                    stream_id_next[63:32] = quad;
                end

                if (s_axis_mac_rx.tlast) begin
                    meta_req = 1'b1;
                    meta_req_flags = FLAG_ERR_TRUNC;
                end else begin
                    state_next = STATE_NTSCF_2;
                end
            end
        end
        STATE_NTSCF_2: begin
            s_axis_mac_rx_tready_next = 1'b1;

            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                if (in_whole) begin
                    stream_id_next[31:0] = quad;
                end

                if (in_whole && data_rem_reg == 0) begin
                    // no ACF messages
                    meta_req = 1'b1;
                    meta_req_flags = FLAG_ERR_EMPTY;
                    meta_req_ret = s_axis_mac_rx.tlast ? STATE_ETH : STATE_DROP;
                end else if (s_axis_mac_rx.tlast) begin
                    meta_req = 1'b1;
                    meta_req_flags = FLAG_ERR_TRUNC;
                end else begin
                    state_next = STATE_ACF;
                end
            end
        end
        STATE_ACF: begin
            // ACF common header and the first ABB fields
            s_axis_mac_rx_tready_next = 1'b1;

            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                acf_q0_next = in_whole ? quad : '0;
                abb_1_next = '0;
                payload_len_next = acf_payload_len;
                pad_next = acf_pad;
                msg_rem_next = acf_msg_len - 9'd1;
                data_rem_next = acf_data_rem;

                if (!in_whole) begin
                    meta_req = 1'b1;
                    meta_req_flags = FLAG_ERR_TRUNC;
                end else if (acf_msg_type == ACF_MSG_TYPE_ABB) begin
                    if (!acf_abb_ok) begin
                        meta_req = 1'b1;
                        meta_req_flags = FLAG_ERR_LEN;
                        meta_req_ret = s_axis_mac_rx.tlast ? STATE_ETH : STATE_DROP;
                    end else if (s_axis_mac_rx.tlast) begin
                        meta_req = 1'b1;
                        meta_req_flags = FLAG_ERR_TRUNC;
                    end else begin
                        state_next = STATE_ABB_1;
                    end
                end else if (acf_msg_len == 0 || !acf_fits) begin
                    meta_req = 1'b1;
                    meta_req_flags = FLAG_ERR_LEN;
                    meta_req_ret = s_axis_mac_rx.tlast ? STATE_ETH : STATE_DROP;
                end else if (acf_msg_len != 9'd1) begin
                    // any other message is skipped by its length
                    if (s_axis_mac_rx.tlast) begin
                        meta_req = 1'b1;
                        meta_req_flags = FLAG_ERR_TRUNC;
                    end else begin
                        state_next = STATE_SKIP;
                    end
                end else begin
                    // one that is only this quadlet is already done
                    acf_q0_next = '0;

                    if (acf_data_rem == 0) begin
                        state_next = s_axis_mac_rx.tlast ? STATE_ETH : STATE_DROP;
                    end else if (s_axis_mac_rx.tlast) begin
                        meta_req = 1'b1;
                        meta_req_flags = FLAG_ERR_TRUNC;
                    end else begin
                        state_next = STATE_ACF;
                    end
                end
            end
        end
        STATE_ABB_1: begin
            // the second ABB quadlet is metadata word 5 as it stands
            s_axis_mac_rx_tready_next = 1'b1;

            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                abb_1_next = in_whole ? quad : '0;
                msg_rem_next = msg_rem_reg - 1;

                meta_req = 1'b1;

                if (s_axis_mac_rx.tlast && (!in_whole || msg_rem_reg != 9'd1)) begin
                    // the frame ended before the payload started
                    meta_req_flags = FLAG_ERR_TRUNC;
                end else begin
                    meta_req_len = payload_len_reg;

                    if (msg_rem_reg != 9'd1) begin
                        meta_req_ret = STATE_PAYLOAD;
                    end else if (s_axis_mac_rx.tlast) begin
                        meta_req_trunc = data_rem_reg != 0;
                    end else begin
                        meta_req_ret = data_rem_reg != 0 ? STATE_ACF : STATE_DROP;
                    end
                end
            end
        end
        STATE_META: begin
            // the block goes into a slot while the input waits
            if (!meta_full) begin
                meta_wr = 1'b1;
                meta_wr_slot_next = meta_wr_slot_reg + 1;
                acf_q0_next = '0;
                abb_1_next = '0;

                if (meta_trunc_reg) begin
                    // the frame ended with a message, before
                    // ntscf_data_length did
                    meta_flags_next = FLAG_ERR_TRUNC;
                    meta_len_next = '0;
                    meta_trunc_next = 1'b0;
                end else begin
                    s_axis_mac_rx_tready_next = meta_ret_reg == STATE_PAYLOAD ? m_axis_payload_tready_int_early : 1'b1;
                    state_next = meta_ret_reg;
                end
            end
        end
        STATE_PAYLOAD: begin
            // one shifted word out per word in
            s_axis_mac_rx_tready_next = m_axis_payload_tready_int_early;

            m_axis_payload_tdata_int = shifted;
            m_axis_payload_tvalid_int = s_axis_mac_rx.tvalid && s_axis_mac_rx.tready;

            if (msg_rem_reg == 9'd1) begin
                // the last quadlet, less its pad
                m_axis_payload_tkeep_int = 4'b1111 >> pad_reg;
                m_axis_payload_tlast_int = 1'b1;
            end

            if (s_axis_mac_rx.tlast && (msg_rem_reg != 9'd1 || !in_whole)) begin
                // the frame ended before the payload did; send what arrived
                m_axis_payload_tkeep_int = in_whole ? 4'b1111 : 4'b0111;
                m_axis_payload_tlast_int = 1'b1;
                m_axis_payload_tuser_int = USER_W'(1);
            end

            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                msg_rem_next = msg_rem_reg - 1;

                if (s_axis_mac_rx.tlast) begin
                    if (msg_rem_reg == 9'd1 && in_whole && data_rem_reg != 0) begin
                        // the message ended with the frame, before
                        // ntscf_data_length did
                        meta_req = 1'b1;
                        meta_req_flags = FLAG_ERR_TRUNC;
                    end else begin
                        s_axis_mac_rx_tready_next = 1'b1;
                        state_next = STATE_ETH;
                    end
                end else if (msg_rem_reg == 9'd1) begin
                    s_axis_mac_rx_tready_next = 1'b1;
                    state_next = data_rem_reg != 0 ? STATE_ACF : STATE_DROP;
                end
            end
        end
        STATE_SKIP: begin
            // a message of another type, skipped by its length
            s_axis_mac_rx_tready_next = 1'b1;

            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                msg_rem_next = msg_rem_reg - 1;

                if (msg_rem_reg == 9'd1 && in_whole) begin
                    // the message is done
                    acf_q0_next = '0;
                end

                if (s_axis_mac_rx.tlast) begin
                    if (msg_rem_reg != 9'd1 || !in_whole || data_rem_reg != 0) begin
                        meta_req = 1'b1;
                        meta_req_flags = FLAG_ERR_TRUNC;
                    end else begin
                        state_next = STATE_ETH;
                    end
                end else if (msg_rem_reg == 9'd1) begin
                    state_next = data_rem_reg != 0 ? STATE_ACF : STATE_DROP;
                end
            end
        end
        STATE_DROP: begin
            s_axis_mac_rx_tready_next = 1'b1;

            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready && s_axis_mac_rx.tlast) begin
                state_next = STATE_ETH;
            end
        end
        default: begin
            state_next = STATE_ETH;
        end
    endcase

    if (meta_req) begin
        // hold the input while the block is loaded
        meta_flags_next = meta_req_flags;
        meta_len_next = meta_req_len;
        meta_route_next = meta_req_route;
        meta_ret_next = meta_req_ret;
        meta_trunc_next = meta_req_trunc;
        s_axis_mac_rx_tready_next = 1'b0;
        state_next = STATE_META;
    end
end

// read out metadata, a slot at a time
logic [31:0]       m_axis_meta_tdata_reg = '0;
logic              m_axis_meta_tvalid_reg = 1'b0, m_axis_meta_tvalid_next;
logic              m_axis_meta_tlast_reg = 1'b0;
logic [DEST_W-1:0] m_axis_meta_tdest_reg = '0;

assign m_axis_meta.tdata  = m_axis_meta_tdata_reg;
assign m_axis_meta.tkeep  = '1;
assign m_axis_meta.tstrb  = m_axis_meta.tkeep;
assign m_axis_meta.tvalid = m_axis_meta_tvalid_reg;
assign m_axis_meta.tlast  = m_axis_meta_tlast_reg;
assign m_axis_meta.tid    = '0;
assign m_axis_meta.tdest  = m_axis_meta_tdest_reg;
assign m_axis_meta.tuser  = '0;

always_comb begin
    meta_rd_slot_next = meta_rd_slot_reg;
    meta_rd_ptr_next = meta_rd_ptr_reg;
    meta_rd = 1'b0;

    m_axis_meta_tvalid_next = m_axis_meta_tvalid_reg && !m_axis_meta.tready;

    if (!meta_empty && (!m_axis_meta_tvalid_reg || m_axis_meta.tready)) begin
        meta_rd = 1'b1;
        m_axis_meta_tvalid_next = 1'b1;
        meta_rd_ptr_next = meta_rd_ptr_reg + 1;

        if (meta_rd_ptr_reg == 3'd5) begin
            meta_rd_ptr_next = '0;
            meta_rd_slot_next = meta_rd_slot_reg + 1;
        end
    end
end

always_ff @(posedge clk) begin
    state_reg <= state_next;

    ptr_reg <= ptr_next;
    data_rem_reg <= data_rem_next;
    msg_rem_reg <= msg_rem_next;
    pad_reg <= pad_next;

    format_reg <= format_next;
    sv_reg <= sv_next;
    seq_num_reg <= seq_num_next;
    stream_id_reg <= stream_id_next;
    acf_q0_reg <= acf_q0_next;
    abb_1_reg <= abb_1_next;
    payload_len_reg <= payload_len_next;

    meta_flags_reg <= meta_flags_next;
    meta_len_reg <= meta_len_next;
    meta_route_reg <= meta_route_next;
    meta_ret_reg <= meta_ret_next;
    meta_trunc_reg <= meta_trunc_next;

    meta_wr_slot_reg <= meta_wr_slot_next;
    meta_rd_slot_reg <= meta_rd_slot_next;
    meta_rd_ptr_reg <= meta_rd_ptr_next;

    s_axis_mac_rx_tready_reg <= s_axis_mac_rx_tready_next;

    if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
        shift_reg <= s_axis_mac_rx.tdata[31:16];
    end

    if (meta_wr) begin
        meta_slot_reg[meta_wr_slot_reg[0]][0] <= {format_reg, meta_flags_reg, 5'd0, meta_len_reg};
        meta_slot_reg[meta_wr_slot_reg[0]][1] <= stream_id_reg[63:32];
        meta_slot_reg[meta_wr_slot_reg[0]][2] <= stream_id_reg[31:0];
        meta_slot_reg[meta_wr_slot_reg[0]][3] <= {sv_reg, seq_num_reg, 23'd0};
        meta_slot_reg[meta_wr_slot_reg[0]][4] <= acf_q0_reg;
        meta_slot_reg[meta_wr_slot_reg[0]][5] <= abb_1_reg;
        meta_slot_dest_reg[meta_wr_slot_reg[0]] <= meta_route_reg;
    end

    m_axis_meta_tvalid_reg <= m_axis_meta_tvalid_next;

    if (meta_rd) begin
        m_axis_meta_tdata_reg <= meta_slot_reg[meta_rd_slot_reg[0]][meta_rd_ptr_reg];
        m_axis_meta_tlast_reg <= meta_rd_ptr_reg == 3'd5;
        m_axis_meta_tdest_reg <= meta_slot_dest_reg[meta_rd_slot_reg[0]];
    end

    if (rst) begin
        state_reg <= STATE_ETH;
        ptr_reg <= '0;
        meta_trunc_reg <= 1'b0;
        meta_wr_slot_reg <= '0;
        meta_rd_slot_reg <= '0;
        meta_rd_ptr_reg <= '0;
        shift_reg <= '0;
        s_axis_mac_rx_tready_reg <= 1'b0;
        m_axis_meta_tvalid_reg <= 1'b0;
    end
end

// output datapath logic
logic [31:0]       m_axis_payload_tdata_reg  = '0;
logic [3:0]        m_axis_payload_tkeep_reg  = '0;
logic              m_axis_payload_tvalid_reg = 1'b0, m_axis_payload_tvalid_next;
logic              m_axis_payload_tlast_reg  = 1'b0;
logic [USER_W-1:0] m_axis_payload_tuser_reg  = '0;

logic [31:0]       temp_m_axis_payload_tdata_reg  = '0;
logic [3:0]        temp_m_axis_payload_tkeep_reg  = '0;
logic              temp_m_axis_payload_tvalid_reg = 1'b0, temp_m_axis_payload_tvalid_next;
logic              temp_m_axis_payload_tlast_reg  = 1'b0;
logic [USER_W-1:0] temp_m_axis_payload_tuser_reg  = '0;

// datapath control
logic store_axis_int_to_output;
logic store_axis_int_to_temp;
logic store_axis_temp_to_output;

assign m_axis_payload.tdata  = m_axis_payload_tdata_reg;
assign m_axis_payload.tkeep  = m_axis_payload_tkeep_reg;
assign m_axis_payload.tstrb  = m_axis_payload.tkeep;
assign m_axis_payload.tvalid = m_axis_payload_tvalid_reg;
assign m_axis_payload.tlast  = m_axis_payload_tlast_reg;
assign m_axis_payload.tid    = '0;
assign m_axis_payload.tdest  = ROUTE_CONSUMER;
assign m_axis_payload.tuser  = m_axis_payload_tuser_reg;

// enable ready input next cycle if output is ready or the temp reg will not be filled on the next cycle (output reg empty or no input)
assign m_axis_payload_tready_int_early = m_axis_payload.tready || (!temp_m_axis_payload_tvalid_reg && (!m_axis_payload_tvalid_reg || !m_axis_payload_tvalid_int));

always_comb begin
    // transfer sink ready state to source
    m_axis_payload_tvalid_next = m_axis_payload_tvalid_reg;
    temp_m_axis_payload_tvalid_next = temp_m_axis_payload_tvalid_reg;

    store_axis_int_to_output = 1'b0;
    store_axis_int_to_temp = 1'b0;
    store_axis_temp_to_output = 1'b0;

    if (m_axis_payload_tready_int_reg) begin
        // input is ready
        if (m_axis_payload.tready || !m_axis_payload_tvalid_reg) begin
            // output is ready or currently not valid, transfer data to output
            m_axis_payload_tvalid_next = m_axis_payload_tvalid_int;
            store_axis_int_to_output = 1'b1;
        end else begin
            // output is not ready, store input in temp
            temp_m_axis_payload_tvalid_next = m_axis_payload_tvalid_int;
            store_axis_int_to_temp = 1'b1;
        end
    end else if (m_axis_payload.tready) begin
        // input is not ready, but output is ready
        m_axis_payload_tvalid_next = temp_m_axis_payload_tvalid_reg;
        temp_m_axis_payload_tvalid_next = 1'b0;
        store_axis_temp_to_output = 1'b1;
    end
end

always_ff @(posedge clk) begin
    m_axis_payload_tvalid_reg <= m_axis_payload_tvalid_next;
    m_axis_payload_tready_int_reg <= m_axis_payload_tready_int_early;
    temp_m_axis_payload_tvalid_reg <= temp_m_axis_payload_tvalid_next;

    // datapath
    if (store_axis_int_to_output) begin
        m_axis_payload_tdata_reg <= m_axis_payload_tdata_int;
        m_axis_payload_tkeep_reg <= m_axis_payload_tkeep_int;
        m_axis_payload_tlast_reg <= m_axis_payload_tlast_int;
        m_axis_payload_tuser_reg <= m_axis_payload_tuser_int;
    end else if (store_axis_temp_to_output) begin
        m_axis_payload_tdata_reg <= temp_m_axis_payload_tdata_reg;
        m_axis_payload_tkeep_reg <= temp_m_axis_payload_tkeep_reg;
        m_axis_payload_tlast_reg <= temp_m_axis_payload_tlast_reg;
        m_axis_payload_tuser_reg <= temp_m_axis_payload_tuser_reg;
    end

    if (store_axis_int_to_temp) begin
        temp_m_axis_payload_tdata_reg <= m_axis_payload_tdata_int;
        temp_m_axis_payload_tkeep_reg <= m_axis_payload_tkeep_int;
        temp_m_axis_payload_tlast_reg <= m_axis_payload_tlast_int;
        temp_m_axis_payload_tuser_reg <= m_axis_payload_tuser_int;
    end

    if (rst) begin
        m_axis_payload_tvalid_reg <= 1'b0;
        m_axis_payload_tready_int_reg <= 1'b0;
        temp_m_axis_payload_tvalid_reg <= 1'b0;
    end
end

endmodule

`resetall

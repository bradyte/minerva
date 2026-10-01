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
 * Parses Ethernet, including one optional VLAN tag, then AVTP, NTSCF, ACF and
 * ABB, and emits one packet per ABB message: a four-word record of header
 * values, then the payload.  The format code goes out on tid and the route on
 * tdest.  Other ACF messages are skipped, and frames it cannot parse are
 * dropped.
 *
 * A frame that ends inside a payload ends that packet with tuser set.  One
 * that ends anywhere else before a message is complete gives nothing for it.
 *
 * Bad frames must already be gone: tuser is not examined, so the MAC's RX
 * FIFO needs DROP_BAD_FRAME.
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
     * Message output: record, then payload
     */
    taxi_axis_if.src   m_axis_eth_rx
);

localparam DATA_W = s_axis_mac_rx.DATA_W;
localparam ID_W = m_axis_eth_rx.ID_W;
localparam DEST_W = m_axis_eth_rx.DEST_W;

// check configuration
if (DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (m_axis_eth_rx.DATA_W != DATA_W)
    $fatal(0, "Error: Interface DATA_W parameter mismatch (instance %m)");

if (!s_axis_mac_rx.KEEP_EN || !m_axis_eth_rx.KEEP_EN)
    $fatal(0, "Error: Interfaces require KEEP_EN (instance %m)");

if (!m_axis_eth_rx.ID_EN)
    $fatal(0, "Error: Output requires ID_EN (instance %m)");

if (!m_axis_eth_rx.DEST_EN)
    $fatal(0, "Error: Output requires DEST_EN (instance %m)");

if (!m_axis_eth_rx.USER_EN)
    $fatal(0, "Error: Output requires USER_EN (instance %m)");

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

// demux port for each routed ethertype
localparam logic [DEST_W-1:0] ROUTE_AVTP = DEST_W'(0);

// format code for each record layout
localparam logic [ID_W-1:0] FORMAT_ABB = ID_W'(0);

typedef enum logic [3:0] {
    STATE_ETH,
    STATE_VLAN,
    STATE_AVTP,
    STATE_NTSCF_1,
    STATE_NTSCF_2,
    STATE_ACF,
    STATE_ABB_1,
    STATE_RECORD,
    STATE_PAYLOAD,
    STATE_SKIP,
    STATE_DROP
} state_t;

state_t state_reg = STATE_ETH, state_next;

// words of the L2 header consumed, then the record word being sent
logic [1:0] ptr_reg = '0, ptr_next;
logic [DEST_W-1:0] route_reg = '0, route_next;

// bytes of ACF messages still to come in the NTSCF payload
logic [10:0] data_rem_reg = '0, data_rem_next;
// quadlets still to come in the current message
logic [8:0] msg_rem_reg = '0, msg_rem_next;
// pad bytes at the end of the current ABB message
logic [1:0] pad_reg = '0, pad_next;
// the frame ended with the message, so there is nothing left to drop
logic frame_end_reg = 1'b0, frame_end_next;

// record fields
logic [63:0] stream_id_reg = '0, stream_id_next;
logic [7:0]  seq_num_reg = '0, seq_num_next;
logic        sv_reg = 1'b0, sv_next;
logic        mtv_reg = 1'b0, mtv_next;
logic [10:0] byte_bus_id_reg = '0, byte_bus_id_next;
logic [10:0] payload_len_reg = '0, payload_len_next;
logic [31:0] abb_1_reg = '0, abb_1_next;

// the header is 14 or 18 bytes, both two past a word boundary, so holding two
// bytes back from each word puts the payload at lane 0
logic [15:0] shift_reg = '0;
wire [31:0] shifted = {s_axis_mac_rx.tdata[15:0], shift_reg};

// the shifted word as a 1722 quadlet: lane 0 is first on the wire, so it is
// the most significant byte, and a field at bit offset o of width w is
// quad[31-o -: w]
wire [31:0] quad = {shifted[7:0], shifted[15:8], shifted[23:16], shifted[31:24]};

// the ethertype is lanes 0 and 1 of word 3, or of word 4 when a tag is
// present; lane 0 is first on the wire, so it is the most significant byte
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

// ACF common header and the first ABB fields, in ACF word 0; the message
// length is in quadlets, header included
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

// handle ethertype: the route table
state_t eth_type_state;
logic [DEST_W-1:0] eth_type_route;

always_comb begin
    eth_type_state = STATE_DROP;
    eth_type_route = ROUTE_AVTP;

    case (ethertype)
        ETHERTYPE_VLAN_C, ETHERTYPE_VLAN_S: begin
            eth_type_state = VLAN_EN ? STATE_VLAN : STATE_DROP;
        end
        ETHERTYPE_AVTP: begin
            eth_type_state = STATE_AVTP;
            eth_type_route = ROUTE_AVTP;
        end
        default: begin
            eth_type_state = STATE_DROP;
        end
    endcase
end

// record words, sent in order
logic [31:0] record_word;

always_comb begin
    case (ptr_reg)
        2'd0: record_word = stream_id_reg[63:32];
        2'd1: record_word = stream_id_reg[31:0];
        2'd2: record_word = {seq_num_reg, mtv_reg, byte_bus_id_reg, sv_reg, payload_len_reg};
        default: record_word = abb_1_reg;
    endcase
end

logic        s_axis_mac_rx_tready_int;
logic [31:0] m_axis_eth_rx_tdata_int;
logic [3:0]  m_axis_eth_rx_tkeep_int;
logic        m_axis_eth_rx_tvalid_int;
logic        m_axis_eth_rx_tlast_int;
logic        m_axis_eth_rx_tuser_int;

assign s_axis_mac_rx.tready = s_axis_mac_rx_tready_int;

assign m_axis_eth_rx.tdata  = m_axis_eth_rx_tdata_int;
assign m_axis_eth_rx.tkeep  = m_axis_eth_rx_tkeep_int;
assign m_axis_eth_rx.tstrb  = m_axis_eth_rx.tkeep;
assign m_axis_eth_rx.tvalid = m_axis_eth_rx_tvalid_int;
assign m_axis_eth_rx.tlast  = m_axis_eth_rx_tlast_int;
assign m_axis_eth_rx.tid    = FORMAT_ABB;
assign m_axis_eth_rx.tdest  = route_reg;
assign m_axis_eth_rx.tuser  = m_axis_eth_rx_tuser_int;

always_comb begin
    state_next = state_reg;

    ptr_next = ptr_reg;
    route_next = route_reg;
    data_rem_next = data_rem_reg;
    msg_rem_next = msg_rem_reg;
    pad_next = pad_reg;
    frame_end_next = frame_end_reg;

    stream_id_next = stream_id_reg;
    seq_num_next = seq_num_reg;
    sv_next = sv_reg;
    mtv_next = mtv_reg;
    byte_bus_id_next = byte_bus_id_reg;
    payload_len_next = payload_len_reg;
    abb_1_next = abb_1_reg;

    s_axis_mac_rx_tready_int = 1'b1;
    m_axis_eth_rx_tdata_int = record_word;
    m_axis_eth_rx_tkeep_int = 4'b1111;
    m_axis_eth_rx_tvalid_int = 1'b0;
    m_axis_eth_rx_tlast_int = 1'b0;
    m_axis_eth_rx_tuser_int = 1'b0;

    case (state_reg)
        STATE_ETH: begin
            // words 0 to 2 are addresses; the ethertype decides at word 3
            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                ptr_next = ptr_reg + 1;

                if (s_axis_mac_rx.tlast) begin
                    ptr_next = '0;
                    state_next = STATE_ETH;
                end else if (ptr_reg == 2'd3) begin
                    route_next = eth_type_route;
                    state_next = eth_type_state;
                end
            end
        end
        STATE_VLAN: begin
            // the tag control information went by at word 3, so the inner
            // ethertype sits where the outer one did
            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                if (s_axis_mac_rx.tlast) begin
                    ptr_next = '0;
                    state_next = STATE_ETH;
                end else begin
                    // one tag only, so a second one is dropped
                    route_next = eth_type_route;
                    state_next = eth_type_state == STATE_VLAN ? STATE_DROP : eth_type_state;
                end
            end
        end
        STATE_AVTP: begin
            // AVTP common header and the first NTSCF fields; only version 0
            // NTSCF is parsed
            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                sv_next = quad[23];
                data_rem_next = quad[18:8];
                seq_num_next = quad[7:0];

                if (s_axis_mac_rx.tlast) begin
                    ptr_next = '0;
                    state_next = STATE_ETH;
                end else if (avtp_subtype == SUBTYPE_NTSCF && avtp_version == 3'd0) begin
                    state_next = STATE_NTSCF_1;
                end else begin
                    state_next = STATE_DROP;
                end
            end
        end
        STATE_NTSCF_1: begin
            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                stream_id_next[63:32] = quad;

                if (s_axis_mac_rx.tlast) begin
                    ptr_next = '0;
                    state_next = STATE_ETH;
                end else begin
                    state_next = STATE_NTSCF_2;
                end
            end
        end
        STATE_NTSCF_2: begin
            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                stream_id_next[31:0] = quad;

                if (s_axis_mac_rx.tlast) begin
                    ptr_next = '0;
                    state_next = STATE_ETH;
                end else if (data_rem_reg == 0) begin
                    // no ACF messages
                    state_next = STATE_DROP;
                end else begin
                    state_next = STATE_ACF;
                end
            end
        end
        STATE_ACF: begin
            // ACF common header and the first ABB fields; every length check
            // resolves here, before anything is sent
            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                mtv_next = quad[13];
                byte_bus_id_next = quad[10:0];
                payload_len_next = acf_payload_len;
                pad_next = acf_pad;
                msg_rem_next = acf_msg_len - 9'd1;
                data_rem_next = acf_data_rem;

                if (s_axis_mac_rx.tlast) begin
                    ptr_next = '0;
                    state_next = STATE_ETH;
                end else if (acf_msg_type == ACF_MSG_TYPE_ABB) begin
                    state_next = acf_abb_ok ? STATE_ABB_1 : STATE_DROP;
                end else if (acf_msg_len != 0 && acf_fits) begin
                    // any other message is skipped by its length; one that is
                    // only this quadlet is already done
                    if (acf_msg_len != 9'd1) begin
                        state_next = STATE_SKIP;
                    end else begin
                        state_next = acf_data_rem != 0 ? STATE_ACF : STATE_DROP;
                    end
                end else begin
                    state_next = STATE_DROP;
                end
            end
        end
        STATE_ABB_1: begin
            // the second ABB quadlet is record word 3 as it stands
            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                abb_1_next = quad;
                ptr_next = '0;
                msg_rem_next = msg_rem_reg - 1;
                frame_end_next = s_axis_mac_rx.tlast;

                if (s_axis_mac_rx.tlast && (!in_whole || msg_rem_reg != 9'd1)) begin
                    // the frame ended inside this quadlet or before the
                    // payload, so nothing is sent
                    state_next = STATE_ETH;
                end else begin
                    state_next = STATE_RECORD;
                end
            end
        end
        STATE_RECORD: begin
            // the record goes out while the input waits
            s_axis_mac_rx_tready_int = 1'b0;
            m_axis_eth_rx_tvalid_int = 1'b1;
            m_axis_eth_rx_tlast_int = ptr_reg == 2'd3 && msg_rem_reg == 0;

            if (m_axis_eth_rx.tready) begin
                ptr_next = ptr_reg + 1;

                if (ptr_reg == 2'd3) begin
                    ptr_next = '0;

                    if (msg_rem_reg != 0) begin
                        state_next = STATE_PAYLOAD;
                    end else if (frame_end_reg) begin
                        state_next = STATE_ETH;
                    end else begin
                        state_next = data_rem_reg != 0 ? STATE_ACF : STATE_DROP;
                    end
                end
            end
        end
        STATE_PAYLOAD: begin
            // one shifted word out per word in; the payload stays in wire
            // order
            s_axis_mac_rx_tready_int = m_axis_eth_rx.tready;
            m_axis_eth_rx_tdata_int = shifted;
            m_axis_eth_rx_tvalid_int = s_axis_mac_rx.tvalid;

            if (msg_rem_reg == 9'd1) begin
                // the last quadlet, less its pad
                m_axis_eth_rx_tkeep_int = 4'b1111 >> pad_reg;
                m_axis_eth_rx_tlast_int = 1'b1;
            end

            if (s_axis_mac_rx.tlast && (msg_rem_reg != 9'd1 || !in_whole)) begin
                // the frame ended before the message did; send what arrived
                m_axis_eth_rx_tkeep_int = in_whole ? 4'b1111 : 4'b0111;
                m_axis_eth_rx_tlast_int = 1'b1;
                m_axis_eth_rx_tuser_int = 1'b1;
            end

            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                msg_rem_next = msg_rem_reg - 1;

                if (s_axis_mac_rx.tlast) begin
                    ptr_next = '0;
                    state_next = STATE_ETH;
                end else if (msg_rem_reg == 9'd1) begin
                    state_next = data_rem_reg != 0 ? STATE_ACF : STATE_DROP;
                end
            end
        end
        STATE_SKIP: begin
            // a message of another type, skipped by its length
            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
                msg_rem_next = msg_rem_reg - 1;

                if (s_axis_mac_rx.tlast) begin
                    ptr_next = '0;
                    state_next = STATE_ETH;
                end else if (msg_rem_reg == 9'd1) begin
                    state_next = data_rem_reg != 0 ? STATE_ACF : STATE_DROP;
                end
            end
        end
        STATE_DROP: begin
            if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready && s_axis_mac_rx.tlast) begin
                ptr_next = '0;
                state_next = STATE_ETH;
            end
        end
        default: begin
            state_next = STATE_ETH;
        end
    endcase
end

always_ff @(posedge clk) begin
    state_reg <= state_next;

    ptr_reg <= ptr_next;
    route_reg <= route_next;
    data_rem_reg <= data_rem_next;
    msg_rem_reg <= msg_rem_next;
    pad_reg <= pad_next;
    frame_end_reg <= frame_end_next;

    stream_id_reg <= stream_id_next;
    seq_num_reg <= seq_num_next;
    sv_reg <= sv_next;
    mtv_reg <= mtv_next;
    byte_bus_id_reg <= byte_bus_id_next;
    payload_len_reg <= payload_len_next;
    abb_1_reg <= abb_1_next;

    if (s_axis_mac_rx.tvalid && s_axis_mac_rx.tready) begin
        shift_reg <= s_axis_mac_rx.tdata[31:16];
    end

    if (rst) begin
        state_reg <= STATE_ETH;
        ptr_reg <= '0;
        route_reg <= '0;
        frame_end_reg <= 1'b0;
        shift_reg <= '0;
    end
end

endmodule

`resetall

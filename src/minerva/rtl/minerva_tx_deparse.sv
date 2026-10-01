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
 * The mirror of minerva_rx_parse: each input packet is a six-word record,
 * then the payload, and comes out as one frame carrying it as a single ABB
 * message in an NTSCF PDU.  The record is the RX record with the destination
 * address added in words 4 and 5; cfg_local_mac is the source.  Record words
 * are values; the payload follows from lane 0 in wire order, and the pad that
 * takes it to a whole quadlet goes out as zeros.
 *
 * A record with an unknown format or route, or one that does not match its
 * payload, is dropped before anything is sent.  A payload that ends short or
 * long, or tuser at tlast, ends the frame with tuser set, so the MAC's TX FIFO
 * drops it (TX_DROP_BAD_FRAME).  The MAC pads short frames.
 */
module minerva_tx_deparse
(
    input  wire logic         clk,
    input  wire logic         rst,

    /*
     * Message input: record, then payload
     */
    taxi_axis_if.snk          s_axis_eth_tx,

    /*
     * Frame output, to the MAC
     */
    taxi_axis_if.src          m_axis_mac_tx,

    /*
     * Configuration
     */
    input  wire logic [47:0]  cfg_local_mac
);

localparam DATA_W = s_axis_eth_tx.DATA_W;
localparam ID_W = s_axis_eth_tx.ID_W;
localparam DEST_W = s_axis_eth_tx.DEST_W;
localparam USER_W = m_axis_mac_tx.USER_W;

// check configuration
if (DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (m_axis_mac_tx.DATA_W != DATA_W)
    $fatal(0, "Error: Interface DATA_W parameter mismatch (instance %m)");

if (!s_axis_eth_tx.KEEP_EN || !m_axis_mac_tx.KEEP_EN)
    $fatal(0, "Error: Interfaces require KEEP_EN (instance %m)");

if (!s_axis_eth_tx.ID_EN)
    $fatal(0, "Error: Input requires ID_EN (instance %m)");

if (!s_axis_eth_tx.DEST_EN)
    $fatal(0, "Error: Input requires DEST_EN (instance %m)");

if (!s_axis_eth_tx.USER_EN || !m_axis_mac_tx.USER_EN)
    $fatal(0, "Error: Interfaces require USER_EN (instance %m)");

localparam logic [15:0] ETHERTYPE_AVTP = 16'h22F0;
localparam logic [7:0] SUBTYPE_NTSCF = 8'h82;
localparam logic [6:0] ACF_MSG_TYPE_ABB = 7'h0E;

// demux port for each routed ethertype
localparam logic [DEST_W-1:0] ROUTE_AVTP = DEST_W'(0);

// format code for each record layout
localparam logic [ID_W-1:0] FORMAT_ABB = ID_W'(0);

// the largest payload an untagged frame holds: 1500 less the NTSCF and ABB
// headers
localparam logic [10:0] MAX_PAYLOAD_LEN = 11'd1480;

typedef enum logic [2:0] {
    STATE_RECORD,
    STATE_HDR,
    STATE_PAYLOAD,
    STATE_FLUSH,
    STATE_DROP
} state_t;

state_t state_reg = STATE_RECORD, state_next;

// the record word coming in, then the header word going out
logic [2:0] ptr_reg = '0, ptr_next;

// the record, and the source address taken as it began
logic [63:0] stream_id_reg = '0, stream_id_next;
logic [31:0] rec_2_reg = '0, rec_2_next;
logic [31:0] abb_1_reg = '0, abb_1_next;
logic [47:0] dst_mac_reg = '0, dst_mac_next;
logic [47:0] src_mac_reg = '0, src_mac_next;

// payload bytes still to come, and whether the frame ends marked bad
logic [10:0] len_rem_reg = '0, len_rem_next;
logic bad_reg = 1'b0, bad_next;

// the two bytes of the previous word that go out in lanes 0 and 1 of the next
logic [15:0] shift_reg = '0, shift_next;

// record word 2
wire [7:0]  sequence_num = rec_2_reg[31:24];
wire        mtv = rec_2_reg[23];
wire [10:0] byte_bus_id = rec_2_reg[22:12];
wire        sv = rec_2_reg[11];
wire [10:0] payload_len = rec_2_reg[10:0];

// the pad takes the payload to a whole quadlet; one message fills the PDU
wire [1:0]  pad = 2'd0 - payload_len[1:0];
wire [10:0] msg_bytes = 11'd8 + payload_len + 11'(pad);

// NTSCF word 0 and ABB word 0, as quadlet values
wire [31:0] ntscf_0 = {SUBTYPE_NTSCF, sv, 3'd0, 1'b0, msg_bytes, sequence_num};
wire [31:0] abb_0 = {ACF_MSG_TYPE_ABB, msg_bytes[10:2], pad, mtv, 2'b00, byte_bus_id};

// a quadlet in wire order: its most significant byte goes first, in lane 0
function automatic logic [31:0] wire_order(input logic [31:0] q);
    return {q[7:0], q[15:8], q[23:16], q[31:24]};
endfunction

// the header words before the payload
logic [31:0] hdr_word;

always_comb begin
    case (ptr_reg)
        3'd0: hdr_word = wire_order(dst_mac_reg[47:16]);
        3'd1: hdr_word = wire_order({dst_mac_reg[15:0], src_mac_reg[47:32]});
        3'd2: hdr_word = wire_order(src_mac_reg[31:0]);
        3'd3: hdr_word = wire_order({ETHERTYPE_AVTP, ntscf_0[31:16]});
        3'd4: hdr_word = wire_order({ntscf_0[15:0], stream_id_reg[63:48]});
        3'd5: hdr_word = wire_order(stream_id_reg[47:16]);
        3'd6: hdr_word = wire_order({stream_id_reg[15:0], abb_0[31:16]});
        default: hdr_word = wire_order({abb_0[15:0], abb_1_reg[31:16]});
    endcase
end

// valid bytes in this input word; tkeep is contiguous from lane 0
wire [2:0] in_keep = s_axis_eth_tx.tkeep[3] ? 3'd4 :
                     s_axis_eth_tx.tkeep[2] ? 3'd3 :
                     s_axis_eth_tx.tkeep[1] ? 3'd2 : 3'd1;

// bytes past tkeep become the pad, as zeros
wire [31:0] in_data = s_axis_eth_tx.tdata & {{8{s_axis_eth_tx.tkeep[3]}}, {8{s_axis_eth_tx.tkeep[2]}},
                                             {8{s_axis_eth_tx.tkeep[1]}}, {8{s_axis_eth_tx.tkeep[0]}}};

logic s_axis_eth_tx_tready_reg = 1'b0, s_axis_eth_tx_tready_next;

// internal datapath
logic [31:0]       m_axis_mac_tx_tdata_int;
logic [3:0]        m_axis_mac_tx_tkeep_int;
logic              m_axis_mac_tx_tvalid_int;
logic              m_axis_mac_tx_tready_int_reg = 1'b0;
logic              m_axis_mac_tx_tlast_int;
logic [USER_W-1:0] m_axis_mac_tx_tuser_int;
wire               m_axis_mac_tx_tready_int_early;

assign s_axis_eth_tx.tready = s_axis_eth_tx_tready_reg;

always_comb begin
    state_next = state_reg;

    ptr_next = ptr_reg;

    stream_id_next = stream_id_reg;
    rec_2_next = rec_2_reg;
    abb_1_next = abb_1_reg;
    dst_mac_next = dst_mac_reg;
    src_mac_next = src_mac_reg;

    len_rem_next = len_rem_reg;
    bad_next = bad_reg;
    shift_next = shift_reg;

    s_axis_eth_tx_tready_next = 1'b0;

    m_axis_mac_tx_tdata_int = hdr_word;
    m_axis_mac_tx_tkeep_int = 4'b1111;
    m_axis_mac_tx_tvalid_int = 1'b0;
    m_axis_mac_tx_tlast_int = 1'b0;
    m_axis_mac_tx_tuser_int = '0;

    case (state_reg)
        STATE_RECORD: begin
            // take in the six record words; every check resolves at word 5,
            // before anything is sent
            s_axis_eth_tx_tready_next = 1'b1;

            if (s_axis_eth_tx.tvalid && s_axis_eth_tx.tready) begin
                ptr_next = ptr_reg + 1;

                case (ptr_reg)
                    3'd0: begin
                        stream_id_next[63:32] = s_axis_eth_tx.tdata;
                        src_mac_next = cfg_local_mac;
                    end
                    3'd1: stream_id_next[31:0] = s_axis_eth_tx.tdata;
                    3'd2: begin
                        rec_2_next = s_axis_eth_tx.tdata;
                        len_rem_next = s_axis_eth_tx.tdata[10:0];
                    end
                    3'd3: abb_1_next = s_axis_eth_tx.tdata;
                    3'd4: dst_mac_next[47:16] = s_axis_eth_tx.tdata;
                    default: dst_mac_next[15:0] = s_axis_eth_tx.tdata[31:16];
                endcase

                if (ptr_reg == 3'd0 && (s_axis_eth_tx.tid != FORMAT_ABB || s_axis_eth_tx.tdest != ROUTE_AVTP)) begin
                    // an unknown format or route
                    ptr_next = '0;
                    state_next = s_axis_eth_tx.tlast ? STATE_RECORD : STATE_DROP;
                end else if (ptr_reg == 3'd5) begin
                    ptr_next = '0;

                    if (payload_len > MAX_PAYLOAD_LEN || (payload_len == 0) != s_axis_eth_tx.tlast
                            || (s_axis_eth_tx.tlast && s_axis_eth_tx.tuser[0])) begin
                        // too long for a frame, a payload that is missing or
                        // not expected, or aborted
                        state_next = s_axis_eth_tx.tlast ? STATE_RECORD : STATE_DROP;
                    end else begin
                        // the header goes out while the input waits
                        s_axis_eth_tx_tready_next = 1'b0;
                        bad_next = 1'b0;
                        state_next = STATE_HDR;
                    end
                end else if (s_axis_eth_tx.tlast) begin
                    // shorter than a record
                    ptr_next = '0;
                end
            end
        end
        STATE_HDR: begin
            // header words 0 to 7, from the record and constants
            if (m_axis_mac_tx_tready_int_reg) begin
                m_axis_mac_tx_tvalid_int = 1'b1;
                ptr_next = ptr_reg + 1;

                if (ptr_reg == 3'd7) begin
                    ptr_next = '0;

                    // the last two bytes of ABB word 1 go out ahead of the
                    // payload, in lanes 0 and 1
                    shift_next = {abb_1_reg[7:0], abb_1_reg[15:8]};

                    if (payload_len != 0) begin
                        s_axis_eth_tx_tready_next = m_axis_mac_tx_tready_int_early;
                        state_next = STATE_PAYLOAD;
                    end else begin
                        state_next = STATE_FLUSH;
                    end
                end
            end
        end
        STATE_PAYLOAD: begin
            // one word out per word in, two bytes behind the input, as fast
            // as the output takes them
            s_axis_eth_tx_tready_next = m_axis_mac_tx_tready_int_early;

            m_axis_mac_tx_tdata_int = {in_data[15:0], shift_reg};
            m_axis_mac_tx_tvalid_int = s_axis_eth_tx.tvalid && s_axis_eth_tx.tready;

            if (s_axis_eth_tx.tvalid && s_axis_eth_tx.tready) begin
                shift_next = in_data[31:16];
                len_rem_next = len_rem_reg - 11'd4;

                if (s_axis_eth_tx.tlast) begin
                    // the payload ends exactly where the record said, and was
                    // not aborted
                    if (len_rem_reg != 11'(in_keep) || s_axis_eth_tx.tuser[0]) begin
                        bad_next = 1'b1;
                    end

                    s_axis_eth_tx_tready_next = 1'b0;
                    state_next = STATE_FLUSH;
                end else if (len_rem_reg <= 11'd4 || in_keep != 3'd4) begin
                    // more payload than the record said, or a short word
                    // before the last
                    bad_next = 1'b1;
                end
            end
        end
        STATE_FLUSH: begin
            // the last two bytes, marked bad if the payload did not match
            m_axis_mac_tx_tdata_int = {16'd0, shift_reg};
            m_axis_mac_tx_tkeep_int = 4'b0011;
            m_axis_mac_tx_tlast_int = 1'b1;
            m_axis_mac_tx_tuser_int = USER_W'(bad_reg);

            if (m_axis_mac_tx_tready_int_reg) begin
                m_axis_mac_tx_tvalid_int = 1'b1;
                s_axis_eth_tx_tready_next = 1'b1;
                state_next = STATE_RECORD;
            end
        end
        STATE_DROP: begin
            s_axis_eth_tx_tready_next = 1'b1;

            if (s_axis_eth_tx.tvalid && s_axis_eth_tx.tready && s_axis_eth_tx.tlast) begin
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
    abb_1_reg <= abb_1_next;
    dst_mac_reg <= dst_mac_next;
    src_mac_reg <= src_mac_next;

    len_rem_reg <= len_rem_next;
    bad_reg <= bad_next;
    shift_reg <= shift_next;

    s_axis_eth_tx_tready_reg <= s_axis_eth_tx_tready_next;

    if (rst) begin
        state_reg <= STATE_RECORD;
        ptr_reg <= '0;
        bad_reg <= 1'b0;
        s_axis_eth_tx_tready_reg <= 1'b0;
    end
end

// output datapath logic
logic [31:0]       m_axis_mac_tx_tdata_reg  = '0;
logic [3:0]        m_axis_mac_tx_tkeep_reg  = '0;
logic              m_axis_mac_tx_tvalid_reg = 1'b0, m_axis_mac_tx_tvalid_next;
logic              m_axis_mac_tx_tlast_reg  = 1'b0;
logic [USER_W-1:0] m_axis_mac_tx_tuser_reg  = '0;

logic [31:0]       temp_m_axis_mac_tx_tdata_reg  = '0;
logic [3:0]        temp_m_axis_mac_tx_tkeep_reg  = '0;
logic              temp_m_axis_mac_tx_tvalid_reg = 1'b0, temp_m_axis_mac_tx_tvalid_next;
logic              temp_m_axis_mac_tx_tlast_reg  = 1'b0;
logic [USER_W-1:0] temp_m_axis_mac_tx_tuser_reg  = '0;

// datapath control
logic store_axis_int_to_output;
logic store_axis_int_to_temp;
logic store_axis_temp_to_output;

assign m_axis_mac_tx.tdata  = m_axis_mac_tx_tdata_reg;
assign m_axis_mac_tx.tkeep  = m_axis_mac_tx_tkeep_reg;
assign m_axis_mac_tx.tstrb  = m_axis_mac_tx.tkeep;
assign m_axis_mac_tx.tvalid = m_axis_mac_tx_tvalid_reg;
assign m_axis_mac_tx.tlast  = m_axis_mac_tx_tlast_reg;
assign m_axis_mac_tx.tid    = '0;
assign m_axis_mac_tx.tdest  = '0;
assign m_axis_mac_tx.tuser  = m_axis_mac_tx_tuser_reg;

// enable ready input next cycle if output is ready or the temp reg will not be filled on the next cycle (output reg empty or no input)
assign m_axis_mac_tx_tready_int_early = m_axis_mac_tx.tready || (!temp_m_axis_mac_tx_tvalid_reg && (!m_axis_mac_tx_tvalid_reg || !m_axis_mac_tx_tvalid_int));

always_comb begin
    // transfer sink ready state to source
    m_axis_mac_tx_tvalid_next = m_axis_mac_tx_tvalid_reg;
    temp_m_axis_mac_tx_tvalid_next = temp_m_axis_mac_tx_tvalid_reg;

    store_axis_int_to_output = 1'b0;
    store_axis_int_to_temp = 1'b0;
    store_axis_temp_to_output = 1'b0;

    if (m_axis_mac_tx_tready_int_reg) begin
        // input is ready
        if (m_axis_mac_tx.tready || !m_axis_mac_tx_tvalid_reg) begin
            // output is ready or currently not valid, transfer data to output
            m_axis_mac_tx_tvalid_next = m_axis_mac_tx_tvalid_int;
            store_axis_int_to_output = 1'b1;
        end else begin
            // output is not ready, store input in temp
            temp_m_axis_mac_tx_tvalid_next = m_axis_mac_tx_tvalid_int;
            store_axis_int_to_temp = 1'b1;
        end
    end else if (m_axis_mac_tx.tready) begin
        // input is not ready, but output is ready
        m_axis_mac_tx_tvalid_next = temp_m_axis_mac_tx_tvalid_reg;
        temp_m_axis_mac_tx_tvalid_next = 1'b0;
        store_axis_temp_to_output = 1'b1;
    end
end

always_ff @(posedge clk) begin
    m_axis_mac_tx_tvalid_reg <= m_axis_mac_tx_tvalid_next;
    m_axis_mac_tx_tready_int_reg <= m_axis_mac_tx_tready_int_early;
    temp_m_axis_mac_tx_tvalid_reg <= temp_m_axis_mac_tx_tvalid_next;

    // datapath
    if (store_axis_int_to_output) begin
        m_axis_mac_tx_tdata_reg <= m_axis_mac_tx_tdata_int;
        m_axis_mac_tx_tkeep_reg <= m_axis_mac_tx_tkeep_int;
        m_axis_mac_tx_tlast_reg <= m_axis_mac_tx_tlast_int;
        m_axis_mac_tx_tuser_reg <= m_axis_mac_tx_tuser_int;
    end else if (store_axis_temp_to_output) begin
        m_axis_mac_tx_tdata_reg <= temp_m_axis_mac_tx_tdata_reg;
        m_axis_mac_tx_tkeep_reg <= temp_m_axis_mac_tx_tkeep_reg;
        m_axis_mac_tx_tlast_reg <= temp_m_axis_mac_tx_tlast_reg;
        m_axis_mac_tx_tuser_reg <= temp_m_axis_mac_tx_tuser_reg;
    end

    if (store_axis_int_to_temp) begin
        temp_m_axis_mac_tx_tdata_reg <= m_axis_mac_tx_tdata_int;
        temp_m_axis_mac_tx_tkeep_reg <= m_axis_mac_tx_tkeep_int;
        temp_m_axis_mac_tx_tlast_reg <= m_axis_mac_tx_tlast_int;
        temp_m_axis_mac_tx_tuser_reg <= m_axis_mac_tx_tuser_int;
    end

    if (rst) begin
        m_axis_mac_tx_tvalid_reg <= 1'b0;
        m_axis_mac_tx_tready_int_reg <= 1'b0;
        temp_m_axis_mac_tx_tvalid_reg <= 1'b0;
    end
end

endmodule

`resetall

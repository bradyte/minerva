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
 * Minerva L2 stack - RX parser
 *
 * Removes the L2 header, including one optional VLAN tag, and routes the
 * payload by ethertype.  The route goes out on tdest, for a taxi_axis_demux
 * with TDEST_ROUTE set, and the payload starts at lane 0.  Frames whose
 * ethertype is not in the route table, or that end inside the header, are
 * dropped.
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
    taxi_axis_if.snk   s_axis,

    /*
     * Payload output, route on tdest
     */
    taxi_axis_if.src   m_axis
);

localparam DATA_W = s_axis.DATA_W;
localparam DEST_W = m_axis.DEST_W;

// check configuration
if (DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (m_axis.DATA_W != DATA_W)
    $fatal(0, "Error: Interface DATA_W parameter mismatch (instance %m)");

if (!s_axis.KEEP_EN || !m_axis.KEEP_EN)
    $fatal(0, "Error: Interfaces require KEEP_EN (instance %m)");

if (!m_axis.DEST_EN)
    $fatal(0, "Error: Output requires DEST_EN (instance %m)");

typedef enum logic [15:0] {
    ETHERTYPE_AVTP = 16'h22F0,
    ETHERTYPE_VLAN_C = 16'h8100,
    ETHERTYPE_VLAN_S = 16'h88A8,
    ETHERTYPE_PTP = 16'h88F7
} ethertype_t;

// demux port for each routed ethertype
localparam logic [DEST_W-1:0] ROUTE_AVTP = DEST_W'(0);
localparam logic [DEST_W-1:0] ROUTE_PTP  = DEST_W'(1);

typedef enum logic [2:0] {
    STATE_HDR,
    STATE_VLAN,
    STATE_PASS,
    STATE_FLUSH,
    STATE_DROP
} state_t;

state_t state_reg = STATE_HDR, state_next;

// words consumed since start of frame, held once the header is done
logic [2:0] ptr_reg = '0, ptr_next;
logic [1:0] flush_keep_reg = '0, flush_keep_next;
logic [DEST_W-1:0] route_reg = '0, route_next;

// the header is 14 or 18 bytes, both two past a word boundary, so holding two
// bytes back from each word puts the payload at lane 0
logic [15:0] shift_reg = '0;
wire [31:0] shifted = {s_axis.tdata[15:0], shift_reg};

// the ethertype is lanes 0 and 1 of word 3, or of word 4 when a tag is
// present; lane 0 is first on the wire, so it is the most significant byte
wire [15:0] ethertype = {s_axis.tdata[7:0], s_axis.tdata[15:8]};

// valid bytes in this input word; tkeep is contiguous from lane 0
wire [2:0] in_keep = s_axis.tkeep[3] ? 3'd4 :
                     s_axis.tkeep[2] ? 3'd3 :
                     s_axis.tkeep[1] ? 3'd2 : 3'd1;

// a final word of 3 or 4 bytes leaves bytes behind in the shift register
wire [2:0] out_keep_last = in_keep >= 3'd2 ? 3'd4 : 3'd3;
wire tail_pending = in_keep >= 3'd3;

// route table
logic route_hit;
logic [DEST_W-1:0] route;

always_comb begin
    route_hit = 1'b1;
    route = ROUTE_AVTP;

    case (ethertype)
        ETHERTYPE_AVTP: route = ROUTE_AVTP;
        ETHERTYPE_PTP:  route = ROUTE_PTP;
        default:        route_hit = 1'b0;
    endcase
end

wire is_vlan = VLAN_EN && (ethertype == ETHERTYPE_VLAN_C || ethertype == ETHERTYPE_VLAN_S);

logic        s_axis_tready_int;
logic [31:0] m_axis_tdata_int;
logic [3:0]  m_axis_tkeep_int;
logic        m_axis_tvalid_int;
logic        m_axis_tlast_int;

assign s_axis.tready = s_axis_tready_int;

assign m_axis.tdata  = m_axis_tdata_int;
assign m_axis.tkeep  = m_axis_tkeep_int;
assign m_axis.tstrb  = m_axis.tkeep;
assign m_axis.tvalid = m_axis_tvalid_int;
assign m_axis.tlast  = m_axis_tlast_int;
assign m_axis.tid    = '0;
assign m_axis.tdest  = route_reg;
assign m_axis.tuser  = '0;

wire s_beat = s_axis.tvalid && s_axis.tready;

always_comb begin
    state_next = state_reg;

    ptr_next = ptr_reg;
    flush_keep_next = flush_keep_reg;
    route_next = route_reg;

    s_axis_tready_int = 1'b1;
    m_axis_tdata_int = shifted;
    m_axis_tkeep_int = 4'b1111;
    m_axis_tvalid_int = 1'b0;
    m_axis_tlast_int = 1'b0;

    case (state_reg)
        STATE_HDR: begin
            // words 0 to 2 are addresses; the ethertype decides at word 3
            if (s_beat) begin
                ptr_next = ptr_reg + 1;

                if (s_axis.tlast) begin
                    ptr_next = '0;
                    state_next = STATE_HDR;
                end else if (ptr_reg == 3'd3) begin
                    if (is_vlan) begin
                        state_next = STATE_VLAN;
                    end else if (route_hit) begin
                        route_next = route;
                        state_next = STATE_PASS;
                    end else begin
                        state_next = STATE_DROP;
                    end
                end
            end
        end
        STATE_VLAN: begin
            // the tag control information went by at word 3, so the inner
            // ethertype sits where the outer one did
            if (s_beat) begin
                if (s_axis.tlast) begin
                    ptr_next = '0;
                    state_next = STATE_HDR;
                end else if (route_hit) begin
                    route_next = route;
                    state_next = STATE_PASS;
                end else begin
                    state_next = STATE_DROP;
                end
            end
        end
        STATE_PASS: begin
            // one shifted word out per word in
            s_axis_tready_int = m_axis.tready;
            m_axis_tvalid_int = s_axis.tvalid;

            if (s_axis.tvalid && s_axis.tlast) begin
                m_axis_tkeep_int = 4'((1 << out_keep_last) - 1);
                m_axis_tlast_int = !tail_pending;
            end

            if (s_beat && s_axis.tlast) begin
                ptr_next = '0;
                if (tail_pending) begin
                    flush_keep_next = 2'(in_keep - 3'd2);
                    state_next = STATE_FLUSH;
                end else begin
                    state_next = STATE_HDR;
                end
            end
        end
        STATE_FLUSH: begin
            // the bytes the shift register still holds after tlast
            s_axis_tready_int = 1'b0;
            m_axis_tdata_int = {16'd0, shift_reg};
            m_axis_tkeep_int = flush_keep_reg == 2'd2 ? 4'b0011 : 4'b0001;
            m_axis_tvalid_int = 1'b1;
            m_axis_tlast_int = 1'b1;

            if (m_axis.tready) begin
                state_next = STATE_HDR;
            end
        end
        STATE_DROP: begin
            if (s_beat && s_axis.tlast) begin
                ptr_next = '0;
                state_next = STATE_HDR;
            end
        end
        default: begin
            state_next = STATE_HDR;
        end
    endcase
end

always_ff @(posedge clk) begin
    state_reg <= state_next;

    ptr_reg <= ptr_next;
    flush_keep_reg <= flush_keep_next;
    route_reg <= route_next;

    if (s_beat) begin
        shift_reg <= s_axis.tdata[31:16];
    end

    if (rst) begin
        state_reg <= STATE_HDR;
        ptr_reg <= '0;
        flush_keep_reg <= '0;
        route_reg <= '0;
        shift_reg <= '0;
    end
end

endmodule

`resetall

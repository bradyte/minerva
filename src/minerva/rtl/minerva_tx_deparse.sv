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
 * Minerva L2 stack - TX deparser
 *
 * Builds the L2 header in front of a payload.  Each input packet starts with
 * an 8 byte prefix in wire order, the destination address then the ethertype,
 * and the payload follows from byte 8.  LOCAL_MAC goes in between as the
 * source address, which moves the payload two bytes against the word
 * boundary.
 *
 * A packet that ends inside the prefix is closed out with tuser set, so the
 * MAC's TX FIFO drops it (TX_DROP_BAD_FRAME).  The MAC pads short frames.
 */
module minerva_tx_deparse #
(
    // source address of every frame
    parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01
)
(
    input  wire logic  clk,
    input  wire logic  rst,

    /*
     * Payload input, destination and ethertype prefixed
     */
    taxi_axis_if.snk   s_axis,

    /*
     * Frame output, to the MAC
     */
    taxi_axis_if.src   m_axis
);

localparam DATA_W = s_axis.DATA_W;
localparam USER_W = m_axis.USER_W;

// check configuration
if (DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (m_axis.DATA_W != DATA_W)
    $fatal(0, "Error: Interface DATA_W parameter mismatch (instance %m)");

if (!s_axis.KEEP_EN || !m_axis.KEEP_EN)
    $fatal(0, "Error: Interfaces require KEEP_EN (instance %m)");

typedef enum logic [2:0] {
    STATE_DST,
    STATE_DST_SRC,
    STATE_SRC,
    STATE_PAYLOAD,
    STATE_FLUSH
} state_t;

state_t state_reg = STATE_DST, state_next;

logic [1:0] flush_keep_reg = '0, flush_keep_next;

// the top two bytes of the previous input word, which go out in the low half
// of the next output word
logic [15:0] shift_reg = '0;
wire [31:0] shifted = {s_axis.tdata[15:0], shift_reg};

// valid bytes in this input word; tkeep is contiguous from lane 0
wire [2:0] in_keep = s_axis.tkeep[3] ? 3'd4 :
                     s_axis.tkeep[2] ? 3'd3 :
                     s_axis.tkeep[1] ? 3'd2 : 3'd1;

// a final word of 3 or 4 bytes leaves bytes behind in the shift register
wire [2:0] out_keep_last = in_keep >= 3'd2 ? 3'd4 : 3'd3;
wire tail_pending = in_keep >= 3'd3;

logic        s_axis_tready_int;
logic [31:0] m_axis_tdata_int;
logic [3:0]  m_axis_tkeep_int;
logic        m_axis_tvalid_int;
logic        m_axis_tlast_int;
logic        m_axis_tuser_int;

assign s_axis.tready = s_axis_tready_int;

assign m_axis.tdata  = m_axis_tdata_int;
assign m_axis.tkeep  = m_axis_tkeep_int;
assign m_axis.tstrb  = m_axis.tkeep;
assign m_axis.tvalid = m_axis_tvalid_int;
assign m_axis.tlast  = m_axis_tlast_int;
assign m_axis.tid    = '0;
assign m_axis.tdest  = '0;
assign m_axis.tuser  = USER_W'(m_axis_tuser_int);

wire s_beat = s_axis.tvalid && s_axis.tready;

always_comb begin
    state_next = state_reg;

    flush_keep_next = flush_keep_reg;

    s_axis_tready_int = 1'b0;
    m_axis_tdata_int = shifted;
    m_axis_tkeep_int = 4'b1111;
    m_axis_tvalid_int = 1'b0;
    m_axis_tlast_int = 1'b0;
    m_axis_tuser_int = 1'b0;

    case (state_reg)
        STATE_DST: begin
            // destination bytes 0 to 3 pass straight through; a tlast here
            // cuts the prefix short, so the frame is closed out as bad
            s_axis_tready_int = m_axis.tready;
            m_axis_tdata_int = s_axis.tdata;
            m_axis_tvalid_int = s_axis.tvalid;
            m_axis_tlast_int = s_axis.tlast;
            m_axis_tuser_int = s_axis.tlast;

            if (s_beat && !s_axis.tlast) begin
                state_next = STATE_DST_SRC;
            end
        end
        STATE_DST_SRC: begin
            // destination bytes 4 and 5, then source bytes 0 and 1; the
            // ethertype waits in the shift register until the source is out
            s_axis_tready_int = m_axis.tready;
            m_axis_tdata_int = {LOCAL_MAC[39:32], LOCAL_MAC[47:40], s_axis.tdata[15:0]};
            m_axis_tvalid_int = s_axis.tvalid;
            m_axis_tlast_int = s_axis.tlast;
            m_axis_tuser_int = s_axis.tlast;

            if (s_beat) begin
                state_next = s_axis.tlast ? STATE_DST : STATE_SRC;
            end
        end
        STATE_SRC: begin
            // source bytes 2 to 5, inserted, so nothing is consumed
            m_axis_tdata_int = {LOCAL_MAC[7:0], LOCAL_MAC[15:8], LOCAL_MAC[23:16], LOCAL_MAC[31:24]};
            m_axis_tvalid_int = 1'b1;

            if (m_axis.tready) begin
                state_next = STATE_PAYLOAD;
            end
        end
        STATE_PAYLOAD: begin
            // the ethertype, then the payload two bytes behind the input
            s_axis_tready_int = m_axis.tready;
            m_axis_tvalid_int = s_axis.tvalid;

            if (s_axis.tvalid && s_axis.tlast) begin
                m_axis_tkeep_int = 4'((1 << out_keep_last) - 1);
                m_axis_tlast_int = !tail_pending;
            end

            if (s_beat && s_axis.tlast) begin
                if (tail_pending) begin
                    flush_keep_next = 2'(in_keep - 3'd2);
                    state_next = STATE_FLUSH;
                end else begin
                    state_next = STATE_DST;
                end
            end
        end
        STATE_FLUSH: begin
            // the bytes the shift register still holds after tlast
            m_axis_tdata_int = {16'd0, shift_reg};
            m_axis_tkeep_int = flush_keep_reg == 2'd2 ? 4'b0011 : 4'b0001;
            m_axis_tvalid_int = 1'b1;
            m_axis_tlast_int = 1'b1;

            if (m_axis.tready) begin
                state_next = STATE_DST;
            end
        end
        default: begin
            state_next = STATE_DST;
        end
    endcase
end

always_ff @(posedge clk) begin
    state_reg <= state_next;

    flush_keep_reg <= flush_keep_next;

    if (s_beat) begin
        shift_reg <= s_axis.tdata[31:16];
    end

    if (rst) begin
        state_reg <= STATE_DST;
        flush_keep_reg <= '0;
        shift_reg <= '0;
    end
end

endmodule

`resetall

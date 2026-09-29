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
 * AVTP echo
 *
 * Test fixture: returns every AVTP payload from minerva_rx_parse to
 * minerva_tx_deparse, prefixed with DST_MAC and ETHERTYPE.  Stands in for the
 * consumer.
 */
module avtp_echo #
(
    parameter logic [47:0] DST_MAC = 48'hFF_FF_FF_FF_FF_FF,
    parameter logic [15:0] ETHERTYPE = 16'h22F0
)
(
    input  wire logic  clk,
    input  wire logic  rst,

    /*
     * AVTP payload, from minerva_rx_parse
     */
    taxi_axis_if.snk   s_axis_eth_rx,

    /*
     * Prefixed payload, to minerva_tx_deparse
     */
    taxi_axis_if.src   m_axis_eth_tx
);

// check configuration
if (s_axis_eth_rx.DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

if (m_axis_eth_tx.DATA_W != 32)
    $fatal(0, "Error: Interface width must be 32 (instance %m)");

typedef enum logic [1:0] {
    STATE_PREFIX_0,
    STATE_PREFIX_1,
    STATE_PAYLOAD
} state_t;

state_t state_reg = STATE_PREFIX_0, state_next;

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
assign m_axis_eth_tx.tid    = '0;
assign m_axis_eth_tx.tdest  = '0;
assign m_axis_eth_tx.tuser  = '0;

always_comb begin
    state_next = state_reg;

    s_axis_eth_rx_tready_int = 1'b0;
    m_axis_eth_tx_tdata_int = s_axis_eth_rx.tdata;
    m_axis_eth_tx_tkeep_int = 4'b1111;
    m_axis_eth_tx_tvalid_int = 1'b0;
    m_axis_eth_tx_tlast_int = 1'b0;

    case (state_reg)
        STATE_PREFIX_0: begin
            // destination bytes 0 to 3, once a payload is waiting
            m_axis_eth_tx_tdata_int = {DST_MAC[23:16], DST_MAC[31:24], DST_MAC[39:32], DST_MAC[47:40]};
            m_axis_eth_tx_tvalid_int = s_axis_eth_rx.tvalid;

            if (s_axis_eth_rx.tvalid && m_axis_eth_tx.tready) begin
                state_next = STATE_PREFIX_1;
            end
        end
        STATE_PREFIX_1: begin
            // destination bytes 4 and 5, then the ethertype
            m_axis_eth_tx_tdata_int = {ETHERTYPE[7:0], ETHERTYPE[15:8], DST_MAC[7:0], DST_MAC[15:8]};
            m_axis_eth_tx_tvalid_int = 1'b1;

            if (m_axis_eth_tx.tready) begin
                state_next = STATE_PAYLOAD;
            end
        end
        STATE_PAYLOAD: begin
            // the payload, unchanged
            s_axis_eth_rx_tready_int = m_axis_eth_tx.tready;
            m_axis_eth_tx_tdata_int = s_axis_eth_rx.tdata;
            m_axis_eth_tx_tkeep_int = s_axis_eth_rx.tkeep;
            m_axis_eth_tx_tvalid_int = s_axis_eth_rx.tvalid;
            m_axis_eth_tx_tlast_int = s_axis_eth_rx.tlast;

            if (s_axis_eth_rx.tvalid && m_axis_eth_tx.tready && s_axis_eth_rx.tlast) begin
                state_next = STATE_PREFIX_0;
            end
        end
        default: begin
            state_next = STATE_PREFIX_0;
        end
    endcase
end

always_ff @(posedge clk) begin
    state_reg <= state_next;

    if (rst) begin
        state_reg <= STATE_PREFIX_0;
    end
end

endmodule

`resetall

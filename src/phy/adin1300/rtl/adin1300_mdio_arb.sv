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
 * MDIO command arbiter
 *
 * Shares one taxi_mdio_master between command sources, source 0 highest
 * priority.
 */
module adin1300_mdio_arb #
(
    parameter S_COUNT = 2
)
(
    input  wire logic  clk,
    input  wire logic  rst,

    /*
     * Command sources
     */
    taxi_axis_if.snk   s_axis_cmd[S_COUNT],
    taxi_axis_if.src   m_axis_rd_data[S_COUNT],

    /*
     * MDIO master
     */
    taxi_axis_if.src   m_axis_cmd,
    taxi_axis_if.snk   s_axis_rd_data
);

localparam CL_S_COUNT = $clog2(S_COUNT);

taxi_axis_arb_mux #(
    .S_COUNT(S_COUNT),
    .UPDATE_TID(1'b0),
    .ARB_ROUND_ROBIN(1'b0),
    .ARB_LSB_HIGH_PRIO(1'b1)
)
cmd_mux_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(s_axis_cmd),
    .m_axis(m_axis_cmd)
);

// rd_data carries no tid, so ownership is latched from the command handshake
wire [S_COUNT-1:0] cmd_grant;

for (genvar n = 0; n < S_COUNT; n = n + 1) begin : grant
    assign cmd_grant[n] = s_axis_cmd[n].tvalid && s_axis_cmd[n].tready;
end

logic [CL_S_COUNT-1:0] owner_reg = '0;

always_ff @(posedge clk) begin
    for (int n = 0; n < S_COUNT; n = n + 1) begin
        if (cmd_grant[n]) begin
            owner_reg <= CL_S_COUNT'(n);
        end
    end

    if (rst) begin
        owner_reg <= '0;
    end
end

taxi_axis_demux #(
    .M_COUNT(S_COUNT),
    .TID_ROUTE(1'b0),
    .TDEST_ROUTE(1'b0)
)
rd_demux_inst (
    .clk(clk),
    .rst(rst),
    .s_axis(s_axis_rd_data),
    .m_axis(m_axis_rd_data),
    .enable(1'b1),
    .drop(1'b0),
    .select(owner_reg)
);

endmodule

`resetall

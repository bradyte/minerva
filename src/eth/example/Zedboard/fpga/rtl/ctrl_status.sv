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
 * Control and status
 *
 * Counts the MAC event strobes, drives the LEDs, and exposes two controls:
 * the receive delay tap and a single-shot MDIO request.  A VIO reaches it
 * today; a register file replaces that later.
 *
 * The VIO is absent under SIM, where every control reads as its idle value.
 */
module ctrl_status #
(
    parameter logic SIM = 1'b0
)
(
    input  wire logic         clk,
    input  wire logic         rst,

    output wire logic [7:0]   led,

    /*
     * Status
     */
    input  wire logic         phy_present,
    input  wire logic         phy_id_done,
    input  wire logic [4:0]   phy_addr,
    input  wire logic [31:0]  phy_id,
    input  wire logic         phy_irq,
    input  wire logic [1:0]   link_speed,

    /*
     * MAC event strobes, counted here
     */
    input  wire logic         rx_good,
    input  wire logic         rx_bad_fcs,
    input  wire logic         rx_bad_frame,
    input  wire logic         tx_good,

    /*
     * Receive delay tap
     */
    output wire logic [4:0]   idelay_value,
    output wire logic         idelay_load,

    /*
     * MDIO request port
     */
    output wire logic [4:0]   req_phy_addr,
    output wire logic [4:0]   req_reg_addr,
    output wire logic [15:0]  req_wr_data,
    output wire logic         req_wr,
    output wire logic         req_go,
    input  wire logic [15:0]  req_rd_data,
    input  wire logic         req_busy
);

wire idelay_go;

logic [15:0] rx_good_cnt_reg = '0;
logic [15:0] rx_bad_fcs_cnt_reg = '0;
logic [15:0] rx_bad_frame_cnt_reg = '0;
logic [15:0] tx_good_cnt_reg = '0;

if (SIM) begin : no_vio

    assign req_phy_addr = '0;
    assign req_reg_addr = '0;
    assign req_wr_data = '0;
    assign req_wr = 1'b0;
    assign req_go = 1'b0;
    assign idelay_value = '0;
    assign idelay_go = 1'b0;

end else begin : vio

    vio_0
    vio_inst (
        .clk(clk),
        .probe_in0(req_rd_data),
        .probe_in1(req_busy),
        .probe_in2(phy_present),
        .probe_in3(phy_id_done),
        .probe_in4(phy_addr),
        .probe_in5(phy_id),
        .probe_in6(link_speed),
        .probe_in7(rx_good_cnt_reg),
        .probe_in8(rx_bad_fcs_cnt_reg),
        .probe_in9(rx_bad_frame_cnt_reg),
        .probe_in10(tx_good_cnt_reg),
        .probe_in11(phy_irq),
        .probe_out0(req_phy_addr),
        .probe_out1(req_reg_addr),
        .probe_out2(req_wr_data),
        .probe_out3(req_wr),
        .probe_out4(req_go),
        .probe_out5(idelay_value),
        .probe_out6(idelay_go)
    );

end

// VAR_LOAD needs a one-cycle LD pulse; the VIO holds a level
logic idelay_go_d_reg = 1'b0;
logic idelay_ld_reg = 1'b0;

always_ff @(posedge clk) begin
    idelay_go_d_reg <= idelay_go;
    idelay_ld_reg <= idelay_go && !idelay_go_d_reg;

    if (rst) begin
        idelay_go_d_reg <= 1'b0;
        idelay_ld_reg <= 1'b0;
    end
end

assign idelay_load = idelay_ld_reg;

always_ff @(posedge clk) begin
    if (rx_good)      rx_good_cnt_reg <= rx_good_cnt_reg + 1;
    if (rx_bad_fcs)   rx_bad_fcs_cnt_reg <= rx_bad_fcs_cnt_reg + 1;
    if (rx_bad_frame) rx_bad_frame_cnt_reg <= rx_bad_frame_cnt_reg + 1;
    if (tx_good)      tx_good_cnt_reg <= tx_good_cnt_reg + 1;

    if (rst) begin
        rx_good_cnt_reg <= '0;
        rx_bad_fcs_cnt_reg <= '0;
        rx_bad_frame_cnt_reg <= '0;
        tx_good_cnt_reg <= '0;
    end
end

assign led = {phy_present, phy_id_done, rx_good_cnt_reg != 0, phy_addr};

endmodule

`resetall

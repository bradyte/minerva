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
 * Single MDIO transaction on request
 *
 * Turns a held request into one clause 22 read or write.  Driven by the VIO in
 * dig_top.
 */
module adin1300_mdio_cmd (
    input  wire logic         clk,
    input  wire logic         rst,

    input  wire logic [4:0]   req_phy_addr,
    input  wire logic [4:0]   req_reg_addr,
    input  wire logic [15:0]  req_wr_data,
    input  wire logic         req_wr,
    input  wire logic         req_go,

    output wire logic [15:0]  rd_data,
    output wire logic         busy,

    taxi_axis_if.src          m_axis_cmd,
    taxi_axis_if.snk          s_axis_rd_data
);

localparam logic [1:0] MDIO_ST_C22 = 2'b01;
localparam logic [1:0] MDIO_OP_WR  = 2'b01;
localparam logic [1:0] MDIO_OP_RD  = 2'b10;

typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_REQ,
    STATE_RSP
} state_t;

state_t state_reg = STATE_IDLE, state_next;

logic [4:0]  phy_addr_reg = '0, phy_addr_next;
logic [4:0]  reg_addr_reg = '0, reg_addr_next;
logic [15:0] wr_data_reg = '0, wr_data_next;
logic        wr_reg = 1'b0, wr_next;
logic [15:0] rd_data_reg = '0, rd_data_next;
logic        cmd_valid_reg = 1'b0, cmd_valid_next;

// req_go is a level held by the VIO, so act on its rising edge only
logic go_d_reg = 1'b0;
wire  go_pulse = req_go && !go_d_reg;

assign m_axis_cmd.tdata  = {MDIO_ST_C22, wr_reg ? MDIO_OP_WR : MDIO_OP_RD,
                            phy_addr_reg, reg_addr_reg, 2'b00, wr_data_reg};
assign m_axis_cmd.tkeep  = '1;
assign m_axis_cmd.tstrb  = m_axis_cmd.tkeep;
assign m_axis_cmd.tvalid = cmd_valid_reg;
assign m_axis_cmd.tlast  = 1'b1;
assign m_axis_cmd.tid    = '0;
assign m_axis_cmd.tdest  = '0;
assign m_axis_cmd.tuser  = '0;

assign s_axis_rd_data.tready = 1'b1;

assign rd_data = rd_data_reg;
assign busy = state_reg != STATE_IDLE;

always_comb begin
    state_next = state_reg;

    phy_addr_next = phy_addr_reg;
    reg_addr_next = reg_addr_reg;
    wr_data_next = wr_data_reg;
    wr_next = wr_reg;
    rd_data_next = rd_data_reg;
    cmd_valid_next = cmd_valid_reg && !m_axis_cmd.tready;

    case (state_reg)
        STATE_IDLE: begin
            if (go_pulse) begin
                phy_addr_next = req_phy_addr;
                reg_addr_next = req_reg_addr;
                wr_data_next = req_wr ? req_wr_data : 16'd0;
                wr_next = req_wr;
                cmd_valid_next = 1'b1;
                state_next = STATE_REQ;
            end
        end
        STATE_REQ: begin
            if (cmd_valid_reg && m_axis_cmd.tready) begin
                state_next = wr_reg ? STATE_IDLE : STATE_RSP;
            end
        end
        STATE_RSP: begin
            if (s_axis_rd_data.tvalid) begin
                rd_data_next = s_axis_rd_data.tdata[15:0];
                state_next = STATE_IDLE;
            end
        end
        default: begin
            state_next = STATE_IDLE;
        end
    endcase
end

always_ff @(posedge clk) begin
    state_reg <= state_next;

    phy_addr_reg <= phy_addr_next;
    reg_addr_reg <= reg_addr_next;
    wr_data_reg <= wr_data_next;
    wr_reg <= wr_next;
    rd_data_reg <= rd_data_next;
    cmd_valid_reg <= cmd_valid_next;

    go_d_reg <= req_go;

    if (rst) begin
        state_reg <= STATE_IDLE;
        cmd_valid_reg <= 1'b0;
        rd_data_reg <= '0;
        go_d_reg <= 1'b0;
    end
end

endmodule

`resetall

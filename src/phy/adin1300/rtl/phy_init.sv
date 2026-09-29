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
 * ADIN1300 initialization
 *
 * Runs once at power-up, then parks.  Owns the PHY reset, scans the MDIO
 * address space for the PHY identity, then writes init_data to the PHY it
 * found.
 */
module phy_init #
(
    parameter logic [15:0] PHY_ID_1 = 16'h0283,
    parameter logic [15:0] PHY_ID_2 = 16'hBC30,
    parameter RESET_LOW_CYCLES = 12500,
    parameter RESET_WAIT_CYCLES = 625000
)
(
    input  wire logic         clk,
    input  wire logic         rst,

    /*
     * MDIO master command and read-data streams
     */
    taxi_axis_if.src          m_axis_cmd,
    taxi_axis_if.snk          s_axis_rd_data,

    /*
     * PHY reset, active low
     */
    output wire logic         phy_reset_n,

    /*
     * Result
     */
    output wire logic [4:0]   phy_addr,
    output wire logic         phy_present,
    output wire logic [31:0]  phy_id,
    output wire logic         done
);

localparam CNT_W = $clog2(RESET_WAIT_CYCLES+1);

/*

MDIO frames, in the command format taxi_mdio_master takes:

[31:30] ST            01 clause 22, 00 clause 45
[29:28] OP            clause 22: 01 write, 10 read
                      clause 45: 00 address, 01 write, 11 read
[27:23] PHYAD/PRTAD   filled in with the address the scan found
[22:18] REGAD/DEVAD
[15:0]  data, or the register address of a clause 45 address frame

A clause 45 register is reached with an address frame then a write frame to
the same device.

*/

function [31:0] c22_rd(input [4:0] regad);
    c22_rd = {2'b01, 2'b10, 5'd0, regad, 2'b00, 16'd0};
endfunction

function [31:0] c22_wr(input [4:0] regad, input [15:0] data);
    c22_wr = {2'b01, 2'b01, 5'd0, regad, 2'b00, data};
endfunction

function [31:0] c45_addr(input [4:0] devad, input [15:0] addr);
    c45_addr = {2'b00, 2'b00, 5'd0, devad, 2'b00, addr};
endfunction

function [31:0] c45_wr(input [4:0] devad, input [15:0] data);
    c45_wr = {2'b00, 2'b01, 5'd0, devad, 2'b00, data};
endfunction

localparam logic [4:0] REG_PHY_ID_1 = 5'h02;
localparam logic [4:0] REG_PHY_ID_2 = 5'h03;
localparam logic [4:0] REG_IRQ_MASK = 5'h18;

// the ADIN1300 subsystem and PHY core extended registers
localparam logic [4:0] DEVAD_EMI = 5'h1E;

// init_data ROM
localparam INIT_DATA_LEN = 3;
localparam PTR_W = INIT_DATA_LEN > 1 ? $clog2(INIT_DATA_LEN) : 1;

logic [31:0] init_data [INIT_DATA_LEN-1:0];

initial begin
    // GE_RGMII_CFG (reset 0x0E07): clear RX_ID_EN, the fabric supplies the
    // receive clock delay
    init_data[0] = c45_addr(DEVAD_EMI, 16'hFF23);
    init_data[1] = c45_wr(DEVAD_EMI, 16'h0E03);
    // IRQ_MASK: HW_IRQ_EN and LNK_STAT_CHNG_IRQ_EN, so INT_N asserts on a link
    // change and holds until IRQ_STATUS (0x19) is read
    init_data[2] = c22_wr(REG_IRQ_MASK, 16'h0005);
end

typedef enum logic [2:0] {
    STATE_RESET_LOW,
    STATE_RESET_WAIT,
    STATE_REQ_ID1,
    STATE_RSP_ID1,
    STATE_REQ_ID2,
    STATE_RSP_ID2,
    STATE_INIT,
    STATE_DONE
} state_t;

state_t state_reg = STATE_RESET_LOW, state_next;

logic [CNT_W-1:0] count_reg = '0, count_next;
logic [PTR_W-1:0] init_ptr_reg = '0, init_ptr_next;
logic [4:0]  addr_reg = '0, addr_next;
logic [15:0] id1_reg = '0, id1_next;
logic [15:0] id2_reg = '0, id2_next;
logic        present_reg = 1'b0, present_next;
logic        phy_reset_n_reg = 1'b0, phy_reset_n_next;

logic [31:0] cmd_frame;
logic        cmd_valid_reg = 1'b0, cmd_valid_next;

assign m_axis_cmd.tdata  = {cmd_frame[31:28], addr_reg, cmd_frame[22:0]};
assign m_axis_cmd.tkeep  = '1;
assign m_axis_cmd.tstrb  = m_axis_cmd.tkeep;
assign m_axis_cmd.tvalid = cmd_valid_reg;
assign m_axis_cmd.tlast  = 1'b1;
assign m_axis_cmd.tid    = '0;
assign m_axis_cmd.tdest  = '0;
assign m_axis_cmd.tuser  = '0;

assign s_axis_rd_data.tready = 1'b1;

assign phy_reset_n = phy_reset_n_reg;
assign phy_addr    = addr_reg;
assign phy_present = present_reg;
assign phy_id      = {id1_reg, id2_reg};
assign done        = state_reg == STATE_DONE;

always_comb begin
    state_next = state_reg;

    count_next = count_reg;
    init_ptr_next = init_ptr_reg;
    addr_next = addr_reg;
    id1_next = id1_reg;
    id2_next = id2_reg;
    present_next = present_reg;
    phy_reset_n_next = phy_reset_n_reg;
    cmd_valid_next = cmd_valid_reg && !m_axis_cmd.tready;

    cmd_frame = c22_rd(REG_PHY_ID_1);

    case (state_reg)
        STATE_RESET_LOW: begin
            phy_reset_n_next = 1'b0;
            if (count_reg == CNT_W'(RESET_LOW_CYCLES)) begin
                count_next = '0;
                phy_reset_n_next = 1'b1;
                state_next = STATE_RESET_WAIT;
            end else begin
                count_next = count_reg + 1;
            end
        end
        STATE_RESET_WAIT: begin
            if (count_reg == CNT_W'(RESET_WAIT_CYCLES)) begin
                count_next = '0;
                cmd_valid_next = 1'b1;
                state_next = STATE_REQ_ID1;
            end else begin
                count_next = count_reg + 1;
            end
        end
        STATE_REQ_ID1: begin
            cmd_frame = c22_rd(REG_PHY_ID_1);
            if (cmd_valid_reg && m_axis_cmd.tready) begin
                state_next = STATE_RSP_ID1;
            end
        end
        STATE_RSP_ID1: begin
            cmd_frame = c22_rd(REG_PHY_ID_1);
            if (s_axis_rd_data.tvalid) begin
                id1_next = s_axis_rd_data.tdata[15:0];
                if (s_axis_rd_data.tdata[15:0] == PHY_ID_1) begin
                    cmd_valid_next = 1'b1;
                    state_next = STATE_REQ_ID2;
                end else if (addr_reg == 5'd31) begin
                    state_next = STATE_DONE;
                end else begin
                    addr_next = addr_reg + 1;
                    cmd_valid_next = 1'b1;
                    state_next = STATE_REQ_ID1;
                end
            end
        end
        STATE_REQ_ID2: begin
            cmd_frame = c22_rd(REG_PHY_ID_2);
            if (cmd_valid_reg && m_axis_cmd.tready) begin
                state_next = STATE_RSP_ID2;
            end
        end
        STATE_RSP_ID2: begin
            cmd_frame = c22_rd(REG_PHY_ID_2);
            if (s_axis_rd_data.tvalid) begin
                id2_next = s_axis_rd_data.tdata[15:0];
                present_next = s_axis_rd_data.tdata[15:0] == PHY_ID_2;
                if (s_axis_rd_data.tdata[15:0] == PHY_ID_2) begin
                    init_ptr_next = '0;
                    cmd_valid_next = 1'b1;
                    state_next = STATE_INIT;
                end else begin
                    state_next = STATE_DONE;
                end
            end
        end
        STATE_INIT: begin
            // one init_data entry per command
            cmd_frame = init_data[init_ptr_reg];
            if (cmd_valid_reg && m_axis_cmd.tready) begin
                if (init_ptr_reg == PTR_W'(INIT_DATA_LEN-1)) begin
                    state_next = STATE_DONE;
                end else begin
                    init_ptr_next = init_ptr_reg + 1;
                    cmd_valid_next = 1'b1;
                end
            end
        end
        STATE_DONE: begin
            state_next = STATE_DONE;
        end
        default: begin
            state_next = STATE_RESET_LOW;
        end
    endcase
end

always_ff @(posedge clk) begin
    state_reg <= state_next;

    count_reg <= count_next;
    init_ptr_reg <= init_ptr_next;
    addr_reg <= addr_next;
    id1_reg <= id1_next;
    id2_reg <= id2_next;
    present_reg <= present_next;
    phy_reset_n_reg <= phy_reset_n_next;
    cmd_valid_reg <= cmd_valid_next;

    if (rst) begin
        state_reg <= STATE_RESET_LOW;
        count_reg <= '0;
        init_ptr_reg <= '0;
        addr_reg <= '0;
        id1_reg <= '0;
        id2_reg <= '0;
        present_reg <= 1'b0;
        phy_reset_n_reg <= 1'b0;
        cmd_valid_reg <= 1'b0;
    end
end

endmodule

`resetall

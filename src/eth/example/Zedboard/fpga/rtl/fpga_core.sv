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
 * FPGA core logic
 *
 * Looped-back MAC on the ADIN1300: every received frame is sent straight back
 * out, unmodified.
 */
module fpga_core #
(
    // simulation (set to avoid vendor primitives)
    parameter logic SIM = 1'b0,
    // vendor ("GENERIC", "XILINX", "ALTERA")
    parameter string VENDOR = "XILINX",
    // device family
    parameter string FAMILY = "zynq"
)
(
    /*
     * Clock: 125 MHz
     * Synchronous reset
     */
    input  wire logic        clk,
    input  wire logic        rst,

    /*
     * GPIO
     */
    output wire logic [7:0]  led,

    /*
     * Ethernet: 1000BASE-T RGMII
     */
    input  wire logic        phy_rx_clk,
    input  wire logic [3:0]  phy_rxd,
    input  wire logic        phy_rx_ctl,
    output wire logic        phy_tx_clk,
    output wire logic [3:0]  phy_txd,
    output wire logic        phy_tx_ctl,

    output wire logic        phy_reset_n,
    input  wire logic        phy_int_n,
    input  wire logic        phy_mdio_i,
    output wire logic        phy_mdio_o,
    output wire logic        phy_mdio_t,
    output wire logic        phy_mdc,

    output wire logic [4:0]  phy_rx_idelay_value,
    output wire logic        phy_rx_idelay_load
);

// PHY management
wire [4:0]  phy_addr;
wire        phy_present;
wire [31:0] phy_id;
wire        phy_id_done;

wire [4:0]  vio_phy_addr;
wire [4:0]  vio_reg_addr;
wire [15:0] vio_wr_data;
wire        vio_wr;
wire        vio_go;
wire [15:0] vio_rd_data;
wire        vio_busy;

phy_management
phy_management_inst (
    .clk(clk),
    .rst(rst),

    .phy_mdio_i(phy_mdio_i),
    .phy_mdio_o(phy_mdio_o),
    .phy_mdio_t(phy_mdio_t),
    .phy_mdc(phy_mdc),
    .phy_reset_n(phy_reset_n),

    .phy_addr(phy_addr),
    .phy_present(phy_present),
    .phy_id(phy_id),
    .phy_id_done(phy_id_done),

    .req_phy_addr(vio_phy_addr),
    .req_reg_addr(vio_reg_addr),
    .req_wr_data(vio_wr_data),
    .req_wr(vio_wr),
    .req_go(vio_go),
    .req_rd_data(vio_rd_data),
    .req_busy(vio_busy)
);

// Ethernet MAC, looped back
//
// One interface on both sides of the MAC: the RX FIFO drives it and the TX
// FIFO consumes it.  The logic side runs 32 bits wide; the FIFOs convert from
// the 8 bit GMII side.
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1)) axis_eth();
taxi_axis_if #(.DATA_W(96), .KEEP_W(1), .ID_W(8)) axis_tx_cpl();
taxi_axis_if #(.DATA_W(16), .KEEP_W(1), .KEEP_EN(0), .LAST_EN(0), .USER_EN(1), .USER_W(1), .ID_EN(1), .ID_W(8)) axis_stat();

wire [1:0] link_speed;
wire       tx_fifo_good_frame;
wire       rx_error_bad_frame;
wire       rx_error_bad_fcs;
wire       rx_fifo_good_frame;

taxi_eth_mac_1g_rgmii_fifo #(
    .SIM(SIM),
    .VENDOR(VENDOR),
    .FAMILY(FAMILY),
    // the PHY delays the transmit clock, so the fabric adds none
    .USE_CLK90(1'b0),
    .STAT_EN(1'b0),
    .TX_FIFO_DEPTH(4096),
    .TX_FRAME_FIFO(1),
    .RX_FIFO_DEPTH(4096),
    .RX_FRAME_FIFO(1)
)
eth_mac_inst (
    .gtx_clk(clk),
    .gtx_clk90(clk),
    .gtx_rst(rst),
    .logic_clk(clk),
    .logic_rst(rst),

    /*
     * Transmit interface (AXI stream)
     */
    .s_axis_tx(axis_eth),
    .m_axis_tx_cpl(axis_tx_cpl),

    /*
     * Receive interface (AXI stream)
     */
    .m_axis_rx(axis_eth),

    /*
     * RGMII interface
     */
    .rgmii_rx_clk(phy_rx_clk),
    .rgmii_rxd(phy_rxd),
    .rgmii_rx_ctl(phy_rx_ctl),
    .rgmii_tx_clk(phy_tx_clk),
    .rgmii_txd(phy_txd),
    .rgmii_tx_ctl(phy_tx_ctl),

    /*
     * Statistics
     */
    .stat_clk(clk),
    .stat_rst(rst),
    .m_axis_stat(axis_stat),

    /*
     * Status
     */
    .tx_error_underflow(),
    .tx_fifo_overflow(),
    .tx_fifo_bad_frame(),
    .tx_fifo_good_frame(tx_fifo_good_frame),
    .rx_error_bad_frame(rx_error_bad_frame),
    .rx_error_bad_fcs(rx_error_bad_fcs),
    .rx_fifo_overflow(),
    .rx_fifo_bad_frame(),
    .rx_fifo_good_frame(rx_fifo_good_frame),
    .link_speed(link_speed),

    /*
     * Configuration
     */
    .cfg_tx_pad_en(1'b1),
    .cfg_tx_min_pkt_len(8'd60-1),
    .cfg_tx_max_pkt_len(16'd1518-1),
    .cfg_tx_ifg(8'd12),
    .cfg_tx_enable(1'b1),
    .cfg_rx_max_pkt_len(16'd1518-1),
    .cfg_rx_enable(1'b1)
);

// Completions and statistics have no consumer yet
taxi_axis_null_snk
tx_cpl_null_inst (
    .s_axis(axis_tx_cpl)
);

taxi_axis_null_snk
stat_null_inst (
    .s_axis(axis_stat)
);

// Control and status
ctrl_status #(
    .SIM(SIM)
)
ctrl_status_inst (
    .clk(clk),
    .rst(rst),

    .led(led),

    .phy_present(phy_present),
    .phy_id_done(phy_id_done),
    .phy_addr(phy_addr),
    .phy_id(phy_id),
    .link_speed(link_speed),

    .rx_good(rx_fifo_good_frame),
    .rx_bad_fcs(rx_error_bad_fcs),
    .rx_bad_frame(rx_error_bad_frame),
    .tx_good(tx_fifo_good_frame),

    .idelay_value(phy_rx_idelay_value),
    .idelay_load(phy_rx_idelay_load),

    .req_phy_addr(vio_phy_addr),
    .req_reg_addr(vio_reg_addr),
    .req_wr_data(vio_wr_data),
    .req_wr(vio_wr),
    .req_go(vio_go),
    .req_rd_data(vio_rd_data),
    .req_busy(vio_busy)
);

endmodule

`resetall

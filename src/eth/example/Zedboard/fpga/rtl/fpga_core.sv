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
 * Minerva L2 stack on the ADIN1300 MAC.  Received AVTP payloads are echoed back
 * to broadcast from LOCAL_MAC; every other frame is dropped in the parser.
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
     * UART: 921600 bps, 8N1
     */
    input  wire logic        uart_rxd,
    output wire logic        uart_txd,

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

// XFCP
taxi_axis_if #(.DATA_W(8), .USER_EN(1), .USER_W(1)) xfcp_ds(), xfcp_us();

taxi_xfcp_if_uart #(
    .TX_FIFO_DEPTH(512),
    .RX_FIFO_DEPTH(512)
)
xfcp_if_uart_inst (
    .clk(clk),
    .rst(rst),

    /*
     * UART interface
     */
    .uart_rxd(uart_rxd),
    .uart_txd(uart_txd),

    /*
     * XFCP downstream interface
     */
    .xfcp_dsp_ds(xfcp_ds),
    .xfcp_dsp_us(xfcp_us),

    /*
     * Configuration
     */
    .prescale(16'(125000000/921600))
);

taxi_axis_if #(.DATA_W(8), .USER_EN(1), .USER_W(1)) xfcp_sw_ds[1](), xfcp_sw_us[1]();

taxi_xfcp_switch #(
    .XFCP_ID_STR("Zedboard"),
    .XFCP_EXT_ID(0),
    .XFCP_EXT_ID_STR("Taxi example"),
    .PORTS($size(xfcp_sw_us))
)
xfcp_sw_inst (
    .clk(clk),
    .rst(rst),

    /*
     * XFCP upstream port
     */
    .xfcp_usp_ds(xfcp_ds),
    .xfcp_usp_us(xfcp_us),

    /*
     * XFCP downstream ports
     */
    .xfcp_dsp_ds(xfcp_sw_ds),
    .xfcp_dsp_us(xfcp_sw_us)
);

taxi_axis_if #(.DATA_W(16), .KEEP_W(1), .KEEP_EN(0), .LAST_EN(0), .USER_EN(1), .USER_W(1), .ID_EN(1), .ID_W(10)) axis_mac_stat();

taxi_xfcp_mod_stats #(
    .XFCP_ID_STR("Statistics"),
    .XFCP_EXT_ID(0),
    .XFCP_EXT_ID_STR(""),
    .STAT_COUNT_W(64),
    .STAT_PIPELINE(2)
)
xfcp_stats_inst (
    .clk(clk),
    .rst(rst),

    /*
     * XFCP upstream port
     */
    .xfcp_usp_ds(xfcp_sw_ds[0]),
    .xfcp_usp_us(xfcp_sw_us[0]),

    /*
     * Statistics increment input
     */
    .s_axis_stat(axis_mac_stat)
);

// PHY management
wire [4:0]  phy_addr;
wire        phy_present;
wire [31:0] phy_id;
wire        phy_id_done;
wire        phy_irq;

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
    .phy_int_n(phy_int_n),

    .phy_addr(phy_addr),
    .phy_present(phy_present),
    .phy_id(phy_id),
    .phy_id_done(phy_id_done),
    .phy_irq(phy_irq),

    .req_phy_addr(vio_phy_addr),
    .req_reg_addr(vio_reg_addr),
    .req_wr_data(vio_wr_data),
    .req_wr(vio_wr),
    .req_go(vio_go),
    .req_rd_data(vio_rd_data),
    .req_busy(vio_busy)
);

// Ethernet MAC
//
// The logic side runs 32 bits wide; the FIFOs convert from the 8 bit GMII side.
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1)) axis_mac_rx();
taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1)) axis_mac_tx();
taxi_axis_if #(.DATA_W(96), .KEEP_W(1), .ID_W(8)) axis_tx_cpl();

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
    .STAT_EN(1),
    .STAT_TX_LEVEL(1),
    .STAT_RX_LEVEL(1),
    .STAT_ID_BASE(0),
    .STAT_UPDATE_PERIOD(1024),
    .STAT_STR_EN(1),
    .STAT_PREFIX_STR("BASET"),
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
    .s_axis_tx(axis_mac_tx),
    .m_axis_tx_cpl(axis_tx_cpl),

    /*
     * Receive interface (AXI stream)
     */
    .m_axis_rx(axis_mac_rx),

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
    .m_axis_stat(axis_mac_stat),

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
    // maximum lengths include the FCS and allow one 802.1Q tag
    .cfg_tx_pad_en(1'b1),
    .cfg_tx_min_pkt_len(8'd60-1),
    .cfg_tx_max_pkt_len(16'd1522-1),
    .cfg_tx_ifg(8'd12),
    .cfg_tx_enable(1'b1),
    .cfg_rx_max_pkt_len(16'd1522-1),
    .cfg_rx_enable(1'b1)
);

// Completions have no consumer yet
taxi_axis_null_snk
tx_cpl_null_inst (
    .s_axis(axis_tx_cpl)
);

// Minerva L2 stack, with the AVTP echo standing in for the consumer
localparam logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;

taxi_axis_if #(.DATA_W(32), .DEST_EN(1), .DEST_W(1)) axis_eth_rx();
taxi_axis_if #(.DATA_W(32)) axis_eth_tx();

minerva_rx_parse
minerva_rx_parse_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_mac_rx(axis_mac_rx),
    .m_axis_eth_rx(axis_eth_rx)
);

avtp_echo
avtp_echo_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_eth_rx(axis_eth_rx),
    .m_axis_eth_tx(axis_eth_tx)
);

minerva_tx_deparse #(
    .LOCAL_MAC(LOCAL_MAC)
)
minerva_tx_deparse_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_eth_tx(axis_eth_tx),
    .m_axis_mac_tx(axis_mac_tx)
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
    .phy_irq(phy_irq),
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

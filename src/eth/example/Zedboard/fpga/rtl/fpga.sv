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
 * FPGA top-level module
 *
 * Zedboard + EVAL-ADIN1300FMCZ
 */
module fpga #
(
    // simulation (set to avoid vendor primitives)
    parameter logic SIM = 1'b0,
    // vendor ("GENERIC", "XILINX", "ALTERA")
    parameter string VENDOR = "XILINX",
    // device family - "zynq" selects the BUFG branch, which is required here
    parameter string FAMILY = "zynq"
)
(
    /*
     * Clock and reset
     */
    input  wire logic        clk_100mhz,
    input  wire logic        reset,

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
    inout  wire logic        phy_mdio,
    output wire logic        phy_mdc
);

// RGMII receive delay tap: the measured eye centre
localparam PHY_RX_IDELAY = 12;

// Clock and reset

// Internal 125 MHz clock
wire clk_mmcm_out;
wire clk_int;
wire rst_int;

wire clk_200mhz_mmcm_out;
wire clk_200mhz_int;

wire mmcm_rst = reset;
wire mmcm_locked;
wire mmcm_clkfb;

// MMCM instance
MMCME2_BASE #(
    // 100 MHz input
    .CLKIN1_PERIOD(10.0),
    // 100 MHz input / 1 = 100 MHz PFD (range 10 MHz to 450 MHz)
    .DIVCLK_DIVIDE(1),
    // 100 MHz PFD * 10 = 1000 MHz VCO (range 600 MHz to 1200 MHz)
    .CLKFBOUT_MULT_F(10),
    .CLKFBOUT_PHASE(0),
    // 1000 MHz VCO / 8 = 125 MHz, 0 degrees
    .CLKOUT0_DIVIDE_F(8),
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKOUT0_PHASE(0),
    // Not used
    .CLKOUT1_DIVIDE(1),
    .CLKOUT1_DUTY_CYCLE(0.5),
    .CLKOUT1_PHASE(0),
    // 1000 MHz VCO / 5 = 200 MHz, 0 degrees
    .CLKOUT2_DIVIDE(5),
    .CLKOUT2_DUTY_CYCLE(0.5),
    .CLKOUT2_PHASE(0),
    // Not used
    .CLKOUT3_DIVIDE(1),
    .CLKOUT3_DUTY_CYCLE(0.5),
    .CLKOUT3_PHASE(0),
    // Not used
    .CLKOUT4_DIVIDE(1),
    .CLKOUT4_DUTY_CYCLE(0.5),
    .CLKOUT4_PHASE(0),
    // Not used
    .CLKOUT5_DIVIDE(1),
    .CLKOUT5_DUTY_CYCLE(0.5),
    .CLKOUT5_PHASE(0),
    // Not used
    .CLKOUT6_DIVIDE(1),
    .CLKOUT6_DUTY_CYCLE(0.5),
    .CLKOUT6_PHASE(0),

    // optimized bandwidth
    .BANDWIDTH("OPTIMIZED"),
    // don't wait for lock during startup
    .STARTUP_WAIT("FALSE")
)
clk_mmcm_inst (
    // 100 MHz input
    .CLKIN1(clk_100mhz),
    // direct clkfb feeback
    .CLKFBIN(mmcm_clkfb),
    .CLKFBOUT(mmcm_clkfb),
    .CLKFBOUTB(),
    // 125 MHz, 0 degrees
    .CLKOUT0(clk_mmcm_out),
    .CLKOUT0B(),
    // Not used
    .CLKOUT1(),
    .CLKOUT1B(),
    // 200 MHz, 0 degrees
    .CLKOUT2(clk_200mhz_mmcm_out),
    .CLKOUT2B(),
    // Not used
    .CLKOUT3(),
    .CLKOUT3B(),
    // Not used
    .CLKOUT4(),
    // Not used
    .CLKOUT5(),
    // Not used
    .CLKOUT6(),
    // reset input
    .RST(mmcm_rst),
    // don't power down
    .PWRDWN(1'b0),
    // locked output
    .LOCKED(mmcm_locked)
);

BUFG
clk_bufg_inst (
    .I(clk_mmcm_out),
    .O(clk_int)
);

BUFG
clk_200mhz_bufg_inst (
    .I(clk_200mhz_mmcm_out),
    .O(clk_200mhz_int)
);

taxi_sync_reset #(
    .N(4)
)
sync_reset_inst (
    .clk(clk_int),
    .rst(~mmcm_locked),
    .out(rst_int)
);

wire uart_rxd_int;

taxi_sync_signal #(
    .WIDTH(1),
    .N(2)
)
sync_signal_inst (
    .clk(clk_int),
    .in(uart_rxd),
    .out(uart_rxd_int)
);

// Build timestamp, written into the bitstream by BITSTREAM.CONFIG.USR_ACCESS
wire [31:0] build_id;

USR_ACCESSE2
usr_access_inst (
    .CFGCLK(),
    .DATA(build_id),
    .DATAVALID()
);

// IODELAY elements for RGMII interface to PHY
// VAR_LOAD so the tap can be re-swept from the IDELAY_TAP register
wire [3:0] phy_rxd_int;
wire       phy_rx_ctl_int;
wire [4:0] phy_rx_idelay_value;
wire       phy_rx_idelay_load;

IDELAYCTRL
idelayctrl_inst (
    .REFCLK(clk_200mhz_int),
    .RST(rst_int),
    .RDY()
);

for (genvar n = 0; n < 4; n = n + 1) begin : phy_rxd_idelay_bit

    IDELAYE2 #(
        .IDELAY_TYPE("VAR_LOAD"),
        .IDELAY_VALUE(PHY_RX_IDELAY),
        .REFCLK_FREQUENCY(200.0)
    )
    idelay_inst (
        .IDATAIN(phy_rxd[n]),
        .DATAOUT(phy_rxd_int[n]),
        .DATAIN(1'b0),
        .C(clk_int),
        .CE(1'b0),
        .INC(1'b0),
        .CINVCTRL(1'b0),
        .CNTVALUEIN(phy_rx_idelay_value),
        .CNTVALUEOUT(),
        .LD(phy_rx_idelay_load),
        .LDPIPEEN(1'b0),
        .REGRST(1'b0)
    );

end

IDELAYE2 #(
    .IDELAY_TYPE("VAR_LOAD"),
    .IDELAY_VALUE(PHY_RX_IDELAY),
    .REFCLK_FREQUENCY(200.0)
)
phy_rx_ctl_idelay (
    .IDATAIN(phy_rx_ctl),
    .DATAOUT(phy_rx_ctl_int),
    .DATAIN(1'b0),
    .C(clk_int),
    .CE(1'b0),
    .INC(1'b0),
    .CINVCTRL(1'b0),
    .CNTVALUEIN(phy_rx_idelay_value),
    .CNTVALUEOUT(),
    .LD(phy_rx_idelay_load),
    .LDPIPEEN(1'b0),
    .REGRST(1'b0)
);

// MDIO tristate
wire phy_mdio_i;
wire phy_mdio_o;
wire phy_mdio_t;

IOBUF
phy_mdio_iobuf (
    .I(phy_mdio_o),
    .IO(phy_mdio),
    .O(phy_mdio_i),
    .T(phy_mdio_t)
);

fpga_core #(
    .SIM(SIM),
    .VENDOR(VENDOR),
    .FAMILY(FAMILY)
)
core_inst (
    /*
     * Clock: 125 MHz
     * Synchronous reset
     */
    .clk(clk_int),
    .rst(rst_int),

    .build_id(build_id),

    /*
     * GPIO
     */
    .led(led),

    /*
     * UART: 921600 bps, 8N1
     */
    .uart_rxd(uart_rxd_int),
    .uart_txd(uart_txd),

    /*
     * Ethernet: 1000BASE-T RGMII
     */
    .phy_rx_clk(phy_rx_clk),
    .phy_rxd(phy_rxd_int),
    .phy_rx_ctl(phy_rx_ctl_int),
    .phy_tx_clk(phy_tx_clk),
    .phy_txd(phy_txd),
    .phy_tx_ctl(phy_tx_ctl),
    .phy_reset_n(phy_reset_n),
    .phy_int_n(phy_int_n),
    .phy_mdio_i(phy_mdio_i),
    .phy_mdio_o(phy_mdio_o),
    .phy_mdio_t(phy_mdio_t),
    .phy_mdc(phy_mdc),

    .phy_rx_idelay_value(phy_rx_idelay_value),
    .phy_rx_idelay_load(phy_rx_idelay_load)
);

endmodule

`resetall

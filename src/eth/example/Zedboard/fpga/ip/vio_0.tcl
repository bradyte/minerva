# SPDX-License-Identifier: MIT
#
# Copyright (c) 2026 Tom Brady
#
# Authors:
# - Tom Brady
#

create_ip -name vio -vendor xilinx.com -library ip -module_name vio_0

# probe_in : 0 rd_data  1 busy  2 phy_present  3 scan done  4 phy_addr
#            5 phy_id  6 link_speed  7 rx_good_cnt  8 rx_bad_fcs_cnt
#            9 rx_bad_frame_cnt  10 tx_good_cnt
# probe_out: 0 phy_addr[4:0]  1 reg_addr[4:0]  2 wr_data[15:0]  3 wr  4 go
#            5 idelay_value[4:0]  6 idelay_go
#            idelay_value starts at the built-in tap, so a load without a
#            new value keeps the measured eye centre
set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN {11} \
    CONFIG.C_PROBE_IN0_WIDTH {16} \
    CONFIG.C_PROBE_IN1_WIDTH {1} \
    CONFIG.C_PROBE_IN2_WIDTH {1} \
    CONFIG.C_PROBE_IN3_WIDTH {1} \
    CONFIG.C_PROBE_IN4_WIDTH {5} \
    CONFIG.C_PROBE_IN5_WIDTH {32} \
    CONFIG.C_PROBE_IN6_WIDTH {2} \
    CONFIG.C_PROBE_IN7_WIDTH {16} \
    CONFIG.C_PROBE_IN8_WIDTH {16} \
    CONFIG.C_PROBE_IN9_WIDTH {16} \
    CONFIG.C_PROBE_IN10_WIDTH {16} \
    CONFIG.C_NUM_PROBE_OUT {7} \
    CONFIG.C_PROBE_OUT0_WIDTH {5} \
    CONFIG.C_PROBE_OUT1_WIDTH {5} \
    CONFIG.C_PROBE_OUT2_WIDTH {16} \
    CONFIG.C_PROBE_OUT3_WIDTH {1} \
    CONFIG.C_PROBE_OUT4_WIDTH {1} \
    CONFIG.C_PROBE_OUT5_WIDTH {5} \
    CONFIG.C_PROBE_OUT6_WIDTH {1} \
    CONFIG.C_PROBE_OUT0_INIT_VAL {0x00} \
    CONFIG.C_PROBE_OUT1_INIT_VAL {0x02} \
    CONFIG.C_PROBE_OUT5_INIT_VAL {0x0C} \
] [get_ips vio_0]

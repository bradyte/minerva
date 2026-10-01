<!---
Markdown description for SystemRDL register map.

Don't override. Generated from: zedboard_regs
  - zedboard_regs.rdl
-->

## zedboard_regs address map

- Absolute Address: 0x0
- Base Offset: 0x0
- Size: 0x1106

|Offset|Identifier|    Name   |
|------|----------|-----------|
|0x1000|   diag   |Diagnostics|
|0x1100|    net   |  Network  |

## diag register file

- Absolute Address: 0x1000
- Base Offset: 0x1000
- Size: 0xE

|Offset| Identifier |       Name       |
|------|------------|------------------|
|  0x0 |   SCRATCH  |      Scratch     |
|  0x1 | BUILD_ID_0 |     Build ID     |
|  0x2 | BUILD_ID_1 |     Build ID     |
|  0x3 | BUILD_ID_2 |     Build ID     |
|  0x4 | BUILD_ID_3 |     Build ID     |
|  0x5 | PHY_STATUS |    PHY status    |
|  0x6 |  PHY_ADDR  |    PHY address   |
|  0x7 |  MDIO_REG  |   MDIO register  |
|  0x8 |MDIO_WDATA_0|  MDIO write data |
|  0x9 |MDIO_WDATA_1|  MDIO write data |
|  0xA |  MDIO_CTRL |   MDIO control   |
|  0xB |MDIO_RDATA_0|  MDIO read data  |
|  0xC |MDIO_RDATA_1|  MDIO read data  |
|  0xD | IDELAY_TAP |Receive IDELAY tap|

### SCRATCH register

- Absolute Address: 0x1000
- Base Offset: 0x0
- Size: 0x1

<p>Read back what was written, to check the bus end to end.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |  rw  | 0x0 |  — |

### BUILD_ID_0 register

- Absolute Address: 0x1001
- Base Offset: 0x1
- Size: 0x1

<p>Bitstream build timestamp from USR_ACCESSE2, BUILD_ID_0 = bits 7:0.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |   r  |  —  |  — |

### BUILD_ID_1 register

- Absolute Address: 0x1002
- Base Offset: 0x2
- Size: 0x1

<p>Bitstream build timestamp from USR_ACCESSE2, BUILD_ID_0 = bits 7:0.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |   r  |  —  |  — |

### BUILD_ID_2 register

- Absolute Address: 0x1003
- Base Offset: 0x3
- Size: 0x1

<p>Bitstream build timestamp from USR_ACCESSE2, BUILD_ID_0 = bits 7:0.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |   r  |  —  |  — |

### BUILD_ID_3 register

- Absolute Address: 0x1004
- Base Offset: 0x4
- Size: 0x1

<p>Bitstream build timestamp from USR_ACCESSE2, BUILD_ID_0 = bits 7:0.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |   r  |  —  |  — |

### PHY_STATUS register

- Absolute Address: 0x1005
- Base Offset: 0x5
- Size: 0x1

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |  present |   r  |  —  |  — |
|  1 | init_done|   r  |  —  |  — |
|  2 |    irq   |   r  |  —  |  — |

#### present field

<p>The startup scan found the PHY.</p>

#### init_done field

<p>The startup sequence has finished; with present = 0 the scan found no PHY.</p>

#### irq field

<p>INT_N, latched by the PHY until IRQ_STATUS (0x19) is read.</p>

### PHY_ADDR register

- Absolute Address: 0x1006
- Base Offset: 0x6
- Size: 0x1

<p>MDIO address found by the startup scan; MDIO requests use it.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 4:0|   addr   |   r  |  —  |  — |

### MDIO_REG register

- Absolute Address: 0x1007
- Base Offset: 0x7
- Size: 0x1

<p>Clause 22 register number for the next MDIO request.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 4:0| reg_addr |  rw  | 0x0 |  — |

### MDIO_WDATA_0 register

- Absolute Address: 0x1008
- Base Offset: 0x8
- Size: 0x1

<p>Taken only when MDIO_CTRL.go is written.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |  rw  | 0x0 |  — |

### MDIO_WDATA_1 register

- Absolute Address: 0x1009
- Base Offset: 0x9
- Size: 0x1

<p>Taken only when MDIO_CTRL.go is written.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |  rw  | 0x0 |  — |

### MDIO_CTRL register

- Absolute Address: 0x100A
- Base Offset: 0xA
- Size: 0x1

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
|  0 |    go    |  rw  | 0x0 |  — |
|  1 |   write  |  rw  | 0x0 |  — |
|  7 |   busy   |   r  |  —  |  — |

#### go field

<p>Write 1 to start the request.</p>

#### write field

<p>1 for a write, 0 for a read.</p>

#### busy field

<p>The request is in progress.</p>

### MDIO_RDATA_0 register

- Absolute Address: 0x100B
- Base Offset: 0xB
- Size: 0x1

<p>Read data from the last MDIO request, valid once busy clears.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |   r  |  —  |  — |

### MDIO_RDATA_1 register

- Absolute Address: 0x100C
- Base Offset: 0xC
- Size: 0x1

<p>Read data from the last MDIO request, valid once busy clears.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |   r  |  —  |  — |

### IDELAY_TAP register

- Absolute Address: 0x100D
- Base Offset: 0xD
- Size: 0x1

<p>RGMII receive delay, 0-31 taps of about 78 ps; a write loads it.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 4:0|    tap   |  rw  | 0xC |  — |

## net register file

- Absolute Address: 0x1100
- Base Offset: 0x1100
- Size: 0x6

|Offset| Identifier|   Name  |
|------|-----------|---------|
|  0x0 |LOCAL_MAC_0|Local MAC|
|  0x1 |LOCAL_MAC_1|Local MAC|
|  0x2 |LOCAL_MAC_2|Local MAC|
|  0x3 |LOCAL_MAC_3|Local MAC|
|  0x4 |LOCAL_MAC_4|Local MAC|
|  0x5 |LOCAL_MAC_5|Local MAC|

### LOCAL_MAC_0 register

- Absolute Address: 0x1100
- Base Offset: 0x0
- Size: 0x1

<p>The device's MAC address, LOCAL_MAC_0 = bits 7:0. It resets to 02:00:00:00:00:01.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |  rw  | 0x1 |  — |

### LOCAL_MAC_1 register

- Absolute Address: 0x1101
- Base Offset: 0x1
- Size: 0x1

<p>The device's MAC address, LOCAL_MAC_0 = bits 7:0. It resets to 02:00:00:00:00:01.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |  rw  | 0x0 |  — |

### LOCAL_MAC_2 register

- Absolute Address: 0x1102
- Base Offset: 0x2
- Size: 0x1

<p>The device's MAC address, LOCAL_MAC_0 = bits 7:0. It resets to 02:00:00:00:00:01.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |  rw  | 0x0 |  — |

### LOCAL_MAC_3 register

- Absolute Address: 0x1103
- Base Offset: 0x3
- Size: 0x1

<p>The device's MAC address, LOCAL_MAC_0 = bits 7:0. It resets to 02:00:00:00:00:01.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |  rw  | 0x0 |  — |

### LOCAL_MAC_4 register

- Absolute Address: 0x1104
- Base Offset: 0x4
- Size: 0x1

<p>The device's MAC address, LOCAL_MAC_0 = bits 7:0. It resets to 02:00:00:00:00:01.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |  rw  | 0x0 |  — |

### LOCAL_MAC_5 register

- Absolute Address: 0x1105
- Base Offset: 0x5
- Size: 0x1

<p>The device's MAC address, LOCAL_MAC_0 = bits 7:0. It resets to 02:00:00:00:00:01.</p>

|Bits|Identifier|Access|Reset|Name|
|----|----------|------|-----|----|
| 7:0|   data   |  rw  | 0x2 |  — |

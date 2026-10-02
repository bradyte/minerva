# Building and programming — Linux host

How this host builds the Zedboard design and loads it, and what to replicate
on another machine. Board facts are in `board.md`.

```
host                     link                                    Zedboard
Vivado 2025.1   --USB-->  USB-JTAG J17 (on-board)    --JTAG-->   Zynq PL (fpga.bit)
/dev/ttyACM0    <-USB->   Pi Debug Probe <-UART-> Pmod JA <-->   Zynq PL (XFCP)
enp0s31f6       <-RJ45->  ADIN1300 FMC card          <-RGMII->   Zynq PL (MAC)
```

Only the JTAG path is needed to program; the UART and Ethernet links check
the running design. The EVAL-ADIN1300FMCZ sits on the FMC-LPC connector with
Vadj (J18) at 2.5 V.

## Host toolchain

| Item | This host | Notes |
|---|---|---|
| OS | Ubuntu 22.04.5 LTS, kernel 6.8.0, x86-64 | |
| Vivado | 2025.1 at `/tools/Xilinx/2025.1` | `fpga.xpr` is written by 2025.1; `syn/rgmii_tx_clk.tcl` relies on `set_max_delay -reset_path` as checked on 2025.1 |
| Older Vivado | 2023.2 at `/tools/Xilinx/Vivado/2023.2` | Not used; skip it |
| Shell hook | `~/.bashrc`: `viv() { source /tools/Xilinx/2025.1/Vivado/settings64.sh; }` | Vivado is not on `PATH`; run `viv` once per shell |
| Python env | `/home/tom/src/taxi/.venv`, Python 3.10.12 | peakrdl-regblock 1.3.1, peakrdl-markdown 1.0.3, systemrdl-compiler 1.32.2, cocotb 1.9.2 + tox's pins |
| Simulator | Verilator 5.038 at `/opt/verilator-5.038` | Benches only |
| Serial terminal | `picocom` (apt) | Manual UART checks only |

The generated register RTL is committed, so `make` needs only Vivado. The
`.venv` is for regenerating registers, running `xfcp_regs.py`, and benches.

## Cable drivers and permissions

JTAG access comes from udev rules that open the cables to all users
(`MODE 666`); serial access comes from the `dialout` group.

| Rule in `/etc/udev/rules.d` | Installed by | Needed? |
|---|---|---|
| `52-xilinx-digilent-usb.rules` | Vivado cable-driver installer | Yes: the on-board Digilent USB-JTAG (FTDI 0403, manufacturer "Digilent") |
| `52-xilinx-ftdi-usb.rules` | Vivado cable-driver installer | No; harmless |
| `52-xilinx-pcusb.rules` | Vivado cable-driver installer | No; harmless |
| `52-digilent-usb.rules` | `digilent.adept.runtime` deb (with WaveForms) | No; Vivado neither installs nor needs it |
| `51-vna.rules` | NanoVNA | Unrelated |

The installer is
`/tools/Xilinx/2025.1/Vivado/data/xicom/cable_drivers/lin64/install_script/install_drivers/install_drivers`,
run as root. Its Digilent step only copies the rule, and skips it if a file of
that name exists.

The Debug Probe needs no custom rule: it is a CDC-ACM port, `/dev/ttyACM0`,
owned by `dialout`. `echo_test.py` opens an `AF_PACKET` raw socket, so it runs
under `sudo`. The wired NIC here is `enp0s31f6`.

## Build

`make` in `fpga/fpga` builds `fpga.bit` for `xc7z020clg484-1`. The `Makefile`
lists sources and constraints; taxi's `../common/vivado.mk` writes and runs
the Tcl, one batch-mode Vivado call each:

1. `create_project.tcl` → `fpga.xpr` (rewritten whenever the `Makefile` changes).
2. `run_synth.tcl` → `synth_1`, 4 jobs.
3. `run_impl.tcl` → `impl_1`, 4 jobs, plus the two utilization reports.
4. `generate_bit.tcl` → `fpga.bit`, `.bin`, `.ltx`, `.xsa`, symlinked into the
   build directory and copied to `rev/fpga_revNNN.*` from 100 up.

No Vivado IP and no config Tcl. `syn/fpga.xdc` sets `CFGBVS VCCO`,
`CONFIG_VOLTAGE 3.3` and `USR_ACCESS TIMESTAMP`, which the `BUILD_ID` register
reads back.

Everything in `fpga/fpga/` but the `Makefile` is gitignored, `rev/` included;
copy `rev/` by hand to keep old bitstreams. Taxi sources come through the
`fpga/lib/taxi` symlink to the repo root, which the clone must keep.

Regenerate registers only when `fpga/rdl/zedboard_regs.rdl` changes: `make` in
`fpga/rdl` with the `.venv` active.

## Program

`make program` loads `fpga.bit` into the PL over JTAG. The load is volatile; a
power cycle clears it. A stale `fpga.bit` is rebuilt first. It writes and runs
`program.tcl`:

| Tcl | Does |
|---|---|
| `open_hw_manager` | Starts the hardware manager |
| `connect_hw_server` | localhost:3121, launching `hw_server` if needed |
| `open_hw_target` | First JTAG cable found |
| `get_hw_devices xc7z*`, first | The Zynq (skips the ARM DAP) |
| `refresh_hw_device -update_hw_probes false` | Reads the device, no debug probes |
| `PROGRAM.FILE {fpga.bit}`, `program_hw_devices` | Loads the PL |

The cable is micro-USB J17 (PROG). J14 is the PS UART and is unused. The
design is PL-only: no PS instance, FSBL or boot image, and nothing uses
`fpga.bin` or `fpga.xsa`.

## Runtime management link

XFCP on a PL UART, 921600 8N1, no flow control, through a Raspberry Pi Debug
Probe on Pmod JA (the board has no PL-side USB-UART).

| Probe | Pmod | FPGA | Constraint |
|---|---|---|---|
| TX | JA1 | Y11, `uart_rxd` | LVCMOS33, pull-up |
| RX | JA2 | AA11, `uart_txd` | LVCMOS33, slow, 8 mA |
| GND | JA ground | | |

| Script (`fpga/utils`) | Runs with | Does |
|---|---|---|
| `xfcp_stats.py` | System Python, stdlib only | MAC counters |
| `xfcp_regs.py` | `.venv` (`systemrdl-compiler`) | Register read/write |
| `echo_test.py <iface>` | `sudo`, system Python | ABB echo over raw Ethernet |

Both XFCP scripts default to `-p /dev/ttyACM0`. Only one program can hold the
port; an open `picocom` eats XFCP replies.

## Porting checklist

- [ ] Install Vivado 2025.1 to `/tools/Xilinx/2025.1`.
      Check: `ls /tools/Xilinx/2025.1/Vivado/settings64.sh`.
- [ ] Add `viv()` to `~/.bashrc`. Check: `viv && vivado -version` shows v2025.1.
- [ ] Run the cable-driver installer as root, then
      `sudo udevadm control --reload-rules && sudo udevadm trigger`.
      Check: `ls /etc/udev/rules.d/52-xilinx-*`.
- [ ] `sudo usermod -aG dialout $USER`, log out and in. Check: `id`.
- [ ] Clone the repo. Check: `ls -l src/eth/example/Zedboard/fpga/lib/taxi`
      is a symlink.
- [ ] Recreate `.venv` with the versions above, and Verilator 5.038.
- [ ] `viv`, then `make` in `fpga/fpga`. Check: `fpga.bit` exists, timing met.
- [ ] Connect J17 and power the board. Check: `lsusb` lists a Digilent device.
- [ ] `make program`. Check: no errors; LD7 (PHY present) and LD6 (PHY ID
      read) light.
- [ ] Connect the Debug Probe. Check: `xfcp_regs.py` reads a `BUILD_ID` that
      matches the build time.
- [ ] Connect the FMC RJ45 to the wired NIC. Check:
      `sudo ./echo_test.py <iface> -c 1000` loses and corrupts nothing.

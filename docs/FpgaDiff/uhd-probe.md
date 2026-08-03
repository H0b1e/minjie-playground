# UHD Waveform Probe (On-Chip Waveform Capture)

This document describes how to capture on-FPGA waveforms with the UVHS UHD
(Hardware Debug) feature on the U2.2 / VU19P_X4 flow, and how to view them.

Use this when DiffTest misbehaves and serial output plus host-side logs are
not enough to localize the problem (reset sequencing, AXI hang, difftest
stream back-pressure, ...).

## Architecture

UHD captures probed signals into a dedicated DDR4 daughter card per probed
FPGA. Constraints that shape the build:

- The capture DDR **must** sit on that FPGA's **FMC3** slot (the DME pins are
  hard-wired to FMC3).
- f2 has only one DDR slot (F2_FMC3), which the SoC AXI2DDR controller used in
  the non-UHD build. So for the probe build the SoC DDR controller is pinned
  to **b0.f0** (`script/partition.tcl`); `bind_system` attaches it to the
  **F0_FMC3** PDDR4DME card and the SoC memory AXI crosses f2<->f0 over the
  inter-FPGA TDM links. UHD takes F2_FMC3.
- Both F0_FMC0 and F0_FMC3 physically hold PDDR4DME cards (verified with
  `query -daughter_card`); F1_FMC3 also has one, unused by this build.
- CPU + PCIe EP stay pinned on f2 (PCIe GT/pads are wired to f2), UART on f1.

Resource budgets (per probed FPGA, silently dropped when exceeded):

| Resource | Limit |
|----------|-------|
| Probe total width | 35 stations x 512 bit = 17920 bit |
| Trigger groups | 16 groups x 256 bit |
| Capture bandwidth | 102 Gbps total across stations |

## Build-Time Setup

All compile-side pieces live in `env-scripts/fpga_diff/uvhs/`:

| File | Role |
|------|------|
| `Makefile` | `UVHS_ENABLE_PROBE_NET ?= 1` knob, exported to fe/be. Set to 0 for the non-UHD build (SoC DDR back on F2_FMC3) |
| `script/probe.tcl` | fe-stage `probe_net`/`trigger_net` registration: 55 signals in 3 clock domains (sys_clk_i, inter_soc_clk, difftest_pcie_clock) + trigger groups `uvhs_lite`, `uvhs_bar0`, `uvhs_bar0_sys` |
| `script/partition.tcl` | The f0/f1/f2 cell pinning described above; skipped when the knob is off |
| `script/backend_run.tcl` | Already contains `trigger_probe -check` (before `sweep_design`) and `trigger_probe -group` (after `transform_clock`) - without these, fe/be pass but nothing is captured |

Build and extract the runtime DB as usual:

```bash
cd env-scripts/fpga_diff/uvhs
make fe && make be          # ~35 min; check logs/backend_run.log for [UHD] lines
make rtdb                   # extracts hw.dat -> ../runtime/rtdb_test (uvsim.db included)
```

`extract_rtdb.sh -all` also bundles `hw.dat/Uvd/uvsim.db` (the elaborated
design database used for the RTL hierarchy view) into `rtdb_test/Uvd/`.
Re-run `make rtdb` and re-sync `rtdb_test` to the run host after any fe change.

## Runtime Flow

All run-host commands run in `env-scripts/fpga_diff/runtime/` (on 19p-rt this
is `~/runtime`; its home is local disk, so sync `rtdb_test`, `Makefile`, and
`user_script/` after changes):

```bash
make query-cards   # EEPROM daughter-card inventory, no download (slot check)
make uhd           # download + arm trigger + capture + upload + wavegen
make wave          # open uvd: hierarchy + waveform + all probe signals (X11)
```

`make uhd` waits up to 420 s in `trigger -status -wait`; start the host
workload (19p-host: driver + fpga-host) within that window. The default
trigger fires on the first C2H `tvalid` beat, i.e. when the difftest result
stream starts. Artifacts land in `u2_work_dir/UHD/uvhs_uhd/` (`UvData.usdb`
plus raw bins) and `u2_work_dir/test.sg`.

### Gated clocks (RTM-103)

`trigger -set -condition` refuses to run while a capture station samples a
clock the runtime DB does not know. Two such clocks exist in this design and
are declared in `hw_run_uhd.tcl` before `trigger -set`:

| Gated clock | Frequency | Origin |
|-------------|-----------|--------|
| `core_def/SOC_CLK_CTRL_UVin_u_bufgce/O` | 11.0592 MHz | `inter_soc_clk` = BUFGCE-gated sys_clk_i |
| `core_def/xdma_ep_i/TO_DIFFTEST_PCIE_CLK` | 125 MHz | XDMA user clock (blackbox pin) |

If probe.tcl ever drops the inter_soc_clk/pcie domains (sys_clk-only), these
declarations can go away.

### Trigger conditions (`user_script/uhd_setting.ini`)

Group names must match `trigger_net -group` in probe.tcl. The final condition
ORs the listed groups; currently only `uvhs_lite` (first C2H tvalid beat).
`difftest_stream_enable_pcie` is commented out on purpose: it rises earlier
and would fire the trigger before any data-path activity.

### Window tuning (depth / position)

The capture is a fixed-length window; the trigger point sits at `position`
percent of it:

```text
depth    = window length in samples (5 ns per sample, 200 MHz timebase)
           1M -> 5 ms, 10M -> 50 ms (current default)
position = trigger location in % (5 = 5% pre-trigger history, 95% post)
```

Host software latency (BAR0 enable -> first C2H DMA read) is millisecond
scale; with a 5 ms window centered at 50% the first `tready` beat is easy to
miss, which looks like a stuck stream but is not. Verify the effective split
via `triggertime/stoptime` in the wavegen log.

### Capturing a backdoor-loaded boot (`UVHS_FW_BIN`)

When the workload is staged into DDR through the UVHS memory backdoor instead
of the PCIe H2C path (see [workflow.md - UVHS DDR Backdoor
Load](./workflow.md#uvhs-ddr-backdoor-load-uvhs_fw_bin)), combine it with the
capture in one run:

```bash
make uhd UVHS_FW_BIN=<image.bin>
```

`hw_run_uhd.tcl` arms the trigger **before** sourcing
`user_script/ddr_backdoor.tcl`, so the `writemem` staging and the subsequent
CPU boot from DDR offset 0 both fall inside the capture window. With the
default `uvhs_lite` trigger (first C2H tvalid beat) the trigger only fires if
the booted image actually reaches difftest traffic; to watch the boot itself,
switch the ini condition to an earlier event (e.g. `mem_core_arvalid = 1`).
The `.bin` must be on 19p-rt's local disk.

## Viewing (`make wave`)

```bash
uvd -d ./rtdb_test/Uvd/uvsim.db \
    -usdb ./u2_work_dir/UHD/uvhs_uhd/UvData.usdb \
    --wses ./u2_work_dir/test.sg
```

| Option | Effect |
|--------|--------|
| `-d uvsim.db` | Left pane shows the full RTL hierarchy (not just probed scopes) |
| `-usdb UvData.usdb` | Waveform data from the last capture |
| `--wses test.sg` | Wave window pre-loads all probed signals (written by `query -capture -sgfile` in `hw_run_uhd.tcl`) |

Without `--wses`, expand `fpga_top_debug -> core_def (-> U_CPU_TOP)` in the
scope tree and add signals manually. The three top-level entries
(`0`, `TO_DIFFTEST_PCIE_CLK`, `clk6_p`) are a constant and the station
sampling clocks, not missing data.

## Current Probe Set (55 signals, 266 bit)

| Domain / clock | Contents |
|----------------|----------|
| sys_clk_i | resets (`sys_rstn_io`, `cpu_rstn_io`), `xdma_link_up`, legacy cfg AXI-Lite, BAR0 debug readback mux (`uvhs_debug_*`) |
| inter_soc_clk (11 MHz) | `U_CPU_TOP` internals: `mem_core_*` AXI read channel, difftest endpoint handshake, nutcore `backend.io_in_0_valid` / `io_in_0_bits_cf_pc` (PC) |
| difftest_pcie_clock (125 MHz) | difftest startup FSM, stream enable, C2H AXIS handshake, `XDMA_AXI_LITE_*`, `diff2axis.io_axis_*` |

Bring-up shortlist: `xdma_link_up`, both resets, `difftest_stream_enable_pcie`,
`mem_core_arvalid/arready/araddr`, `io_in_0_bits_cf_pc`, `_endpoint_step`.

Not probed (add to probe.tcl + rebuild if needed): C2H/H2C `tdata[255:0]` /
`tkeep[31:0]` payload, H2C (`from_host_axis_*`) direction.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `RTM-103` on `trigger -set -condition` | station uses a gated/blackbox clock | declare it: `trigger -set -gatedclk <name> -frequency <f> -polarity H` (exact names in the error table) |
| Waveform shows only `0`, `TO_DIFFTEST_PCIE_CLK`, `clk6_p` | looking at the top scope | signals live under `fpga_top_debug/core_def/...`; or use `--wses test.sg` |
| `tvalid=1` but `tready` always 0 | capture window shorter than host read latency (not a stuck stream) | larger `-depth`, smaller `-position`; verify host program actually reads C2H |
| Some probed signals missing | probe width over 17920 bit/FPGA, silently dropped | `query -capture` sums station bits vs declared; trim probe list |
| fe/be clean, nothing captured | `trigger_probe -check`/`-group` missing in be | see `script/backend_run.tcl` |
| PAR-028 `Probe-Group` insufficient | no PDDR4DME on that FPGA's FMC3 | assemble a card on FMC3 of every probed FPGA |

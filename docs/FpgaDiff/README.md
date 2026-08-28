# FPGA DiffTest Documentation

This directory contains the FPGA DiffTest workflow and guides for `minjie-playground`.

## Flow Overview

```text
XiangShan / NutShell Verilog
  -> top-level difftest generates release / fpga-host
  -> env-scripts/fpga_diff generates Vivado bitstream
  -> NEMU generates reference SO
  -> workload-builder compiles workloads
  -> Bin2ddr generates DDR txt for the JTAG fallback/debug path
  -> optional JTAG stages a raw boot image in BRAM-backed boot flash
  -> FPGA: write bitstream, reset cpu
  -> fpga-host loads the workload through XDMA H2C by default, then starts DiffTest
```

## Common Artifacts

| Path | Contents |
|------|----------|
| `build/release/` | XiangShan release tarballs, unpacked releases, `latest-<design>.path`, `latest-<design>.name` |
| `build/build-log/` | XiangShan and shared-stage logs for `verilog`, `release`, `host`, `bit`, `nemu`, `workload` |
| `NutShell/build/rtl/` | NutShell FPGA DiffTest Verilog from `make nutshell-verilog` |
| `NutShell/build/release/` | NutShell release tarballs from `make nutshell-release` |
| `build/run-log/` | `run_host` runtime logs |
| `ready-to-run/<nemu-config>/` | NEMU reference SO |
| `ready-to-run/<design>-<target>/` | Workload `.bin` for H2C loading, plus Bin2ddr `.txt` for JTAG DDR loading |
| `bitstream/<design>-<time>/` | Bitstream bundle with `.bit`, `.ltx`, and release directory |
| `jobs/<job-id>/` | Debug notes, logs, and summaries for multi-step investigations |

## Document Index

| Document | Contents |
|----------|----------|
| [repro-guide.md](./repro-guide.md) | Simple step-by-step bring-up across 19p-rt (bitstream + serial) and 19p-host (XDMA DiffTest), with reboot recovery and the build-on-host rule |
| [workflow.md](./workflow.md) | End-to-end flow with optional parameters and per-step examples |
| [layout.md](./layout.md) | Project directory structure, component roles, output directories |
| [workload.md](./workload.md) | Workload compilation for AM and Linux |
| [troubleshooting.md](./troubleshooting.md) | Common issues and debugging approaches: XDMA/PCIe, host hangs, packet errors, DiffTest mismatches |
| [xdma.md](./xdma.md) | XDMA driver build, install, load script, systemd service, troubleshooting |
| [debug-flow.md](./debug-flow.md) | Structured debug flow for multi-step FPGA DiffTest investigations |
| [fpga-host-build.md](./fpga-host-build.md) | Building `fpga-host` on the run host: the `-static`/SIGFPE, AVX-512/SIGILL, and glibc traps, plus the no-sudo recipe |
| [uhd-probe.md](./uhd-probe.md) | UHD on-chip waveform capture: DDR remap to f0, probe/trigger build knobs, runtime capture (`make uhd`), and uvd viewing with full RTL hierarchy (`make wave`) |
| [vp1902-handover.md](./vp1902-handover.md) | VP1902 migration handover: staged DDR/PCIe IPs, board-input checklist, RTL integration deltas, board-binding rework, known risks |

## Suggested Reading

1. [layout.md](./layout.md) — Understand the repository structure
2. [workflow.md](./workflow.md) — Follow the end-to-end build and run flow
3. [workload.md](./workload.md) — Customize workload generation
4. [troubleshooting.md](./troubleshooting.md) — Diagnose common failures
5. [debug-flow.md](./debug-flow.md) — Organize longer debugging sessions

For DiffTest internals (hardware pipeline, software checkers, config letters), see [`difftest/docs/`](../../difftest/docs/README.md).

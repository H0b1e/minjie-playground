# Workflow

This document describes the end-to-end FPGA DiffTest flow. Each step lists optional parameters first, then a matching example.

## Common Placeholders

- `<DESIGN>`: top-level design target such as `xiangshan` or `nutshell`
- `<XS_CONFIG>`: XiangShan config used for `make verilog xiangshan`
- `<VIVADO_REMOTE>`: remote machine used for Vivado synthesis and implementation
- `<FPGA_REMOTE>`: remote FPGA host
- `<NEMU_CONFIG>`: NEMU defconfig name
- `<TARGET>`: workload-builder target such as `linux/hello` or `am/hello`
- `<WORKLOAD_TAG>`: workload output directory name, typically `<DESIGN>-$(subst /,-,$(TARGET))`
- `<REMOTE_ROOT>`: remote repository path, typically `/path/to/minjie-playground`
- `<BIT_TAG>`: bitstream bundle directory name under `bitstream/`
- `<BOOTRAM_BIN>`: raw boot image to stage in the JTAG boot flash

## Step 1: Generate Verilog

### Optional Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `DIFFTEST_CONFIG` | `ESBIFDU` | DiffTest config letters |
| `DIFFTEST_EXCLUDE` | empty | Comma-separated exclude list, such as `Vec` |
| `JOBS` | `16` | Parallel compilation jobs |
| `XS_CONFIG` | `FpgaDiffDefaultConfig` | XiangShan config used for `xiangshan` builds |

### Example

```sh
export DESIGN=<DESIGN>

make clean $DESIGN
make verilog $DESIGN
```

Output: Verilog files under `<design>/build/`.

### NutShell Flow

NutShell must use its real nested `difftest` Git worktree; do not replace it with a symbolic link. Check out DiffTest commit `36062fbd54579220e8aff92bc820e2fd3e749539` in `NutShell/difftest`, then run these parent targets from the repository root:

```sh
make nutshell-verilog
make nutshell-release
```

They use `BOARD=fpgadiff`, `CORE=inorder`, and `DIFFTEST_CONFIG=ESBIFDU`. Verilog and logs are written below `NutShell/build/`; `nutshell-release` creates `NutShell/build/release/` automatically and writes the release tarball there. The release script also keeps its unpacked staging directory below `NutShell/`.

To compile `fpga-host` on the FPGA host machine instead of the build machine, pack the release's difftest source and generated headers into a self-contained tarball:

```sh
make nutshell-host-pkg FPGA_HOST_HOME=$PWD/NutShell/<tag>
# copy NutShell/build/release/fpga-host-pkg.tar.gz to the FPGA host, then:
tar -xzf fpga-host-pkg.tar.gz -C <workdir> && cd <workdir> && ./build.sh
```

`build.sh` needs only `make`, `g++` (>= 10, C++20), and the zlib/zstd development headers on the FPGA host; the binary lands at `<workdir>/build/fpga-host`.

For the XiangShan OpenLLC flow, use `XS_CONFIG=FpgaDiffKMHV2Config`.
For a no-vector XiangShan build, explicitly pass `DIFFTEST_EXCLUDE=Vec`.

## Step 2: Create Release

### Optional Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `RELEASE_SUFFIX` | current `HHMMSS` | Suffix appended to the release name |

### Example

```sh
make release $DESIGN

export RELEASE_PATH=$(cat build/release/latest-$DESIGN.path)
export RELEASE_NAME=$(cat build/release/latest-$DESIGN.name)
```

Output:

```text
build/release/$RELEASE_NAME/
build/release/latest-$DESIGN.path
build/release/latest-$DESIGN.name
```

## Step 3: Build FPGA Host

### Optional Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `FPGA_HOST_HOME` | none | Release directory used to build `fpga-host` |
| `FPGA_HOST_ARGS` | `RELEASE=1 FPGA=1 DIFFTEST_PERFCNT=1` | Additional host build arguments |
| `USE_XDMA_H2C` | `1` | Build `fpga-host` with XDMA H2C workload loading. Set to `0` for the legacy external JTAG DDR load path |

### Example

```sh
make host $DESIGN FPGA_HOST_HOME=$RELEASE_PATH
```

Output: `$RELEASE_PATH/build/fpga-host`

The default host build enables `CONFIG_USE_XDMA_H2C`, so `fpga-host` writes the workload image to DDR through `/dev/xdma0_h2c_0`. This H2C path does not program the FPGA boot flash.
The legacy JTAG DDR loader is still available by rebuilding the host with `USE_XDMA_H2C=0`.

## Step 4: Generate Bitstream

### Optional Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `REMOTE` | empty | Remote host for Vivado execution |
| `REMOTE_DIR` | repository root | Repository path on the remote host |
| `REMOTE_ENV` | `source ~/.bash_profile &&` | Remote environment setup command |
| `BIT_SRC_DIR` | latest release | Release directory used for synthesis |
| `SUFFIX` | empty | Suffix appended to the Vivado project directory name |
| `BIT_TAG` | `<design>-<timestamp>` | Bitstream bundle directory name under `bitstream/` |
| `CHI_DIR` | empty | Extra CHI glue RTL/header directory for external NoC CHI wrappers |

### Example

```sh
make bit \
  $DESIGN \
  REMOTE=<VIVADO_REMOTE> \
  REMOTE_DIR=/path/to/minjie-playground

export BIT_TAG=<BIT_TAG>
```

Output:

```text
bitstream/$BIT_TAG/
bitstream/$BIT_TAG/$RELEASE_NAME/
bitstream/$BIT_TAG/*.bit
bitstream/$BIT_TAG/*.ltx
```

Set `CHI_DIR` only for flows that use an external CHI-interface NoC. The
OpenLLC flow does not need `CHI_DIR`.

`env-scripts/fpga_diff` defaults `DDR_RANK_WIDTH=2`, selecting the 16GB two-rank DDR configuration:
a 34-bit DDR AXI address, the `MTA16ATF2G64HZ-2G3` memory part, and `ddr_rank1.xdc`.
This physical DDR configuration is independent of the `RAM_SIZE` passed to `fpga-host` below.

## Step 5: Build NEMU Reference

### Optional Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `NEMU_CONFIG` | `riscv64-xs-ref_defconfig` | NEMU defconfig used to build the reference SO |

### Example

```sh
export NEMU_CONFIG=<NEMU_CONFIG>
make nemu NEMU_CONFIG=$NEMU_CONFIG
```

Output: `ready-to-run/$NEMU_CONFIG/riscv64-nemu-interpreter-so`

## Step 6: Build Workload

### Optional Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `TARGET` | `linux/hello` | Workload-builder target |
| `WORKLOAD_DTB` | `xiangshan-fpga-noAIA.dtb` | Linux DTB used before Bin2ddr |
| `AM_ARCH` | inferred from `DESIGN` | AM ISA/platform selection |

### Example

```sh
export TARGET=<TARGET>
export WORKLOAD_TAG=<WORKLOAD_TAG>

make workload $DESIGN TARGET=$TARGET
```

Output:

```text
ready-to-run/$WORKLOAD_TAG/$WORKLOAD_TAG.bin
ready-to-run/$WORKLOAD_TAG/$WORKLOAD_TAG.txt
```

AM and Linux workload details are described separately in [workload.md](./workload.md).

## Step 7: Sync to FPGA Host

### Optional Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `<FPGA_REMOTE>` | none | Remote FPGA host |
| `<REMOTE_ROOT>` | `/path/to/minjie-playground` | Repository path on the FPGA host |

### Example

```sh
export REMOTE_ROOT=/path/to/minjie-playground

ssh <FPGA_REMOTE> "mkdir -p $REMOTE_ROOT/bitstream $REMOTE_ROOT/ready-to-run"
rsync -a --delete bitstream/$BIT_TAG/ <FPGA_REMOTE>:$REMOTE_ROOT/bitstream/$BIT_TAG/
rsync -a --delete ready-to-run/ <FPGA_REMOTE>:$REMOTE_ROOT/ready-to-run/
```

## Step 8: Write Bitstream and Run

### Optional Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `REMOTE` | empty | Remote execution target |
| `REMOTE_DIR` | repository root | Repository path on the remote target |
| `FPGA_BIT_HOME` | none | Bitstream bundle directory |
| `WORKLOAD` | none | Workload directory containing `.bin` and `.txt` |
| `DIFF` | empty | NEMU SO path for diff mode |
| `HOST` | $FPGA_BIT_HOME/*/build/fpga-host | Explicit `fpga-host` path override |
| `RAM_SIZE` | `16GB` for XiangShan; `2GB` for NutShell | Forwarded as `--ram-size=$(RAM_SIZE)` |
| `RANDOM_MEM` | `1` | Set to `1` to pass `--random-mem --seed=$(SEED)` |
| `SEED` | `1234` | Random DDR initialization seed when `RANDOM_MEM=1` |
| `RUN_HOST_ARGS` | derived from `DIFF`, `WORKLOAD`, `RAM_SIZE`, `RANDOM_MEM`, `SEED` | Full argument list passed to `fpga-host` |

### Example

```sh
export BIT_ROOT=$REMOTE_ROOT/bitstream/$BIT_TAG

make write_bitstream \
  REMOTE=<FPGA_REMOTE> \
  REMOTE_DIR=$REMOTE_ROOT \
  FPGA_BIT_HOME=$BIT_ROOT

make run_host \
  REMOTE=<FPGA_REMOTE> \
  REMOTE_DIR=$REMOTE_ROOT \
  FPGA_BIT_HOME=$BIT_ROOT \
  WORKLOAD=$REMOTE_ROOT/ready-to-run/$WORKLOAD_TAG \
  DIFF=$REMOTE_ROOT/ready-to-run/$NEMU_CONFIG/riscv64-nemu-interpreter-so
```

`run_host` auto-finds `fpga-host` under `FPGA_BIT_HOME` and picks the `.bin` and `.txt` inside `WORKLOAD`.

With `USE_XDMA_H2C=1` (the default), the host writes only the workload `.bin` to DDR through XDMA H2C before releasing the CPU. It does not write the FPGA boot flash.

With `USE_XDMA_H2C=0`, the host write DDR with external `FPGA_DDR_LOAD_CMD`:

```sh
make write_jtag_ddr \
  REMOTE=<FPGA_REMOTE> \
  REMOTE_DIR=$REMOTE_ROOT \
  FPGA_BIT_HOME=$BIT_ROOT \
  WORKLOAD=$REMOTE_ROOT/ready-to-run/$WORKLOAD_TAG
```

### JTAG DDR Fallback / Debug Path

`write_jtag_ddr` is kept for manual debugging and for host builds made with `USE_XDMA_H2C=0`; normal `run_host` uses H2C for DDR loading.

### UVHS DDR Backdoor Load (`UVHS_FW_BIN`)

A third load path, used by the UVHS runtime flow in
`env-scripts/fpga_diff/runtime/` (the `uv_shell` scripts on 19p-rt, not the
fpga-host path above). It writes the image through the UVHS memory backdoor
(`writemem`) instead of XDMA H2C or JTAG — no host-side PCIe traffic is needed,
which makes it useful when the PCIe/difftest path itself is the thing under
test.

```sh
cd env-scripts/fpga_diff/runtime
make backdoor UVHS_FW_BIN=<image.bin>   # download + backdoor write + boot
make run      UVHS_FW_BIN=<image.bin>   # same flow via the plain "run" target
make uhd      UVHS_FW_BIN=<image.bin>   # backdoor write + UHD capture of the boot
```

How it works (`user_script/ddr_backdoor.tcl`, sourced by both
`hw_run_download.tcl` and `hw_run_uhd.tcl` when `UVHS_FW_BIN` is set; empty by
default, so plain `make run`/`make uhd` are unaffected):

- The image is staged at **DDR offset 0** (CPU-visible base `0x8000_0000`)
  while the CPU reset (`rstn_sw5`) is still held; the script then releases it
  and the CPU boots from the staged image.
- `writemem` addresses count 32-byte DDR words (query `-ddr` Width = 256), so
  the payload is zero-padded **in place** to a 32-byte multiple first.
- To verify the write landed, read the range back in the **same session**
  (see below) — a fresh `uv_shell` session finds the FPGA image already
  torn down. Note the CPU boots right after the write, so verify quickly or
  pick a region the boot code does not overwrite.
- In the `make uhd` form the UHD trigger is armed *before* the backdoor write,
  so the capture window covers the CPU booting from this image.
- The `.bin` must live on 19p-rt's **local disk** (`~/runtime` is not NFS).

For ad-hoc reads (crash forensics, signature readout, cross-checking an H2C
load) the readmem must happen in the **same live session** that downloaded
the design — `uv_shell` tears down the FPGA image on exit, so a later batch
session has nothing to read. Three ways to do it:

**1. Interactive session (hang forensics).** `make run` does not exit
`uv_shell` when the script finishes — the session stays at the `hspRun>`
prompt (the PCIe host side needs it alive anyway). Read whenever needed
(e.g. after the serial goes silent):

```tcl
hspRun> source ./user_script/hw_run_download.tcl    # download + release resets
hspRun> set ::env(UVHS_RD_ADDR) 0x80340000          # start byte address
hspRun> set ::env(UVHS_RD_SIZE) 0x10000             # bytes to read
hspRun> set ::env(UVHS_RD_OUT)  logbuf.bin
hspRun> source ./user_script/ddr_read.tcl
```

`user_script/ddr_read.tcl` converts CPU byte addresses to the 32-byte DDR
word range `readmem` expects and subtracts the `0x8000_0000` base for you, so
addresses can be copied straight from the vmlinux symbol table. Relative
`UVHS_RD_OUT` paths land in the uv_shell workdir (`u2_work_dir/`); absolute
paths also work.

**2. Embedded in a batch flow (read at a deterministic point).** Source the
same snippet from `hw_run_uhd.tcl` / `hw_run_download.tcl` at the point of
interest, e.g. dump memory when the trigger times out:

```tcl
set trigger_tag [trigger -status -wait 1 -timeout 420 -tclobj]
if {<trigger did not fire>} {
    source ./user_script/ddr_read.tcl
}
```

Export the knobs before launching uv_shell (`UVHS_RD_ADDR=... make uhd`, with
a matching `export` line in the Makefile), or `set ::env(...)` directly in
the hw_run script.

**3. Raw one-line `readmem` (no script).** At the `hspRun>` prompt, if you
already think in 32-byte DDR words:

```tcl
readmem -rtl fpga_top_debug.core_def.U_UVHS_UVW_AXI4_TO_DDR4\[1023:0\] -hex -file head.txt
```

Knobs for `ddr_read.tcl` (ways 1 and 2):

| Variable | Default | Description |
|----------|---------|-------------|
| `UVHS_RD_ADDR` | `0` | Start **byte** address; >= `0x8000_0000` is treated as CPU-visible and the DDR base is subtracted |
| `UVHS_RD_SIZE` | `0x8000` | Bytes to read |
| `UVHS_RD_OUT` | `ddr_readback.bin` | Output file (`.txt` when `UVHS_RD_HEX=1`) |
| `UVHS_RD_HEX` | `0` | `1` = hex text, one 256-bit word per line (~2x size inflation — keep `UVHS_RD_SIZE` small) |

Typical recipes: verify a backdoor write (`UVHS_RD_ADDR=0
UVHS_RD_SIZE=<image size>`, then `cmp`); kernel panic (`UVHS_RD_ADDR=<log_buf
physical address>`); cross-check the H2C load path (`UVHS_RD_ADDR=0x80000000
UVHS_RD_SIZE=0x1000` and inspect the image header).

### JTAG Boot Flash Path

For designs that require a boot image in flash, write it through JTAG after every `write_bitstream`.

```sh
make write_jtag_flash \
  REMOTE=<FPGA_REMOTE> \
  REMOTE_DIR=$REMOTE_ROOT \
  FPGA_BIT_HOME=$BIT_ROOT \
  WORKLOAD=<BOOTRAM_BIN>
```

## Next Steps

- For repository structure, see [layout.md](./layout.md).
- For workload customization, see [workload.md](./workload.md).
- If something fails, see [troubleshooting.md](./troubleshooting.md).
- For longer investigations, see [debug-flow.md](./debug-flow.md).

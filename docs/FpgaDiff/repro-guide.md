# FPGA DiffTest Reproduction Guide (19p-rt + 19p-host)

Step-by-step bring-up for the Hejian UVHS NutShell diff-test. The design is
split across **two hosts** that share one FPGA board:

| Host | Role | Connected to board via |
|------|------|------------------------|
| `19p-rt` | Programs the bitstream; hosts the serial console | JTAG download + UART (`/dev/ttyUSB0`) |
| `19p-host` | Runs `fpga-host`: loads the workload over XDMA H2C and runs DiffTest | PCIe (XDMA) |

> ssh aliases `19p-host` / `19p-rt` are already in `~/.ssh/config`.

---

## 1. Build the bitstream + rtdb (on the Vivado build host)

On the machine with Vivado (the EPYC compile server is fine for *this* step —
it only produces an FPGA bitstream, nothing that runs on the x86 hosts):

```sh
cd env-scripts/fpga_diff/uvhs
make fe          # UVHS synthesis
make be          # UVHS place & route -> bitstream
make rtdb        # extract runtime DB -> ../runtime/rtdb_test/
```

`make rtdb` links `hw.dat` at `fpga_diff/hw.dat` and extracts the runtime
bitstream DB into `fpga_diff/runtime/rtdb_test/`. That `runtime/` tree is what
19p-rt needs.

## 2. Deploy `runtime/` → 19p-rt

19p-rt keeps a local copy (it does not mount the build NFS share), so package
and ship it:

```sh
cd env-scripts/fpga_diff
tar czf runtime.tar.gz runtime
scp runtime.tar.gz 19p-rt:~        # <-- the colon matters! (see note below)
ssh 19p-rt
  tar xzf runtime.tar.gz
  cd runtime
```

> **scp colon gotcha:** `scp runtime.tar.gz 19p-rt` (no colon) copies the file
> to a *local* file named `19p-rt` instead of sending it to the host. Always
> write `19p-rt:` or `19p-rt:~`. (Stray extensionless `19p-host` / `19p-rt`
> files in `fpga_diff/` are exactly this mistake — safe to delete.)

## 3. On 19p-rt: program the bitstream + open the serial console

Open **two windows** on 19p-rt.

**Window 1 — program the bitstream:**

```sh
cd ~/runtime
make run
# == uv_shell -t runtime -d U2 -workdir ./u2_work_dir -script user_script/hw_run_download.tcl
```

**Window 2 — serial console (UART is the 16550 at 115200 baud):**

```sh
sudo minicom -D /dev/ttyUSB0 -b 115200
```

Keep minicom open — NutShell's console output appears here once the CPU is
released.

## 4. Deploy `host/` → 19p-host

```sh
cd env-scripts/fpga_diff
tar czf host.tar.gz host
scp host.tar.gz 19p-host:~         # <-- colon!
ssh 19p-host
  tar xzf host.tar.gz
  cd host
```

`host/ready-to-run/` must contain: `fpga-host.with-uart`,
`riscv64-nemu-interpreter-so`, `xdma-chr.ko`, and
`microbench-riscv64-nutshell.bin` (all built on 19p-host — see the build
section below).

## 5. On 19p-host: load the driver + run DiffTest

```sh
cd ~/host
make check     # verify host/ready-to-run/* + scripts are present
make rescan    # sudo: rescan PCI so the XDMA endpoint (now live after 19p-rt's bitstream download) enumerates
make driver    # sudo: load xdma-chr.ko against the XDMA device, chmod /dev/xdma0_*
make workload  # fpga-host: XDMA H2C workload load + DiffTest
```

If `make check` complains about `XDMA_BDF`, set it to the board's PCI address
(default `0000:01:00.0`); confirm with `lspci | grep -i xilinx` on 19p-host.

On success: `make workload` burns the workload into DDR over XDMA H2C, releases
the CPU, and DiffTest compares DUT (FPGA) against NEMU. The serial console on
19p-rt shows the NutShell boot/test output.

## 6. If something goes wrong: reboot and redo

If the host hangs, the PCIe device vanishes, or `/dev/xdma*` stops responding:

```sh
# on 19p-host:
sudo reboot 19p-host     # (or reboot from the console / BMC)
# after it comes back, re-run the host side in order:
cd ~/host && make check && make rescan && make driver && make workload
```

If the FPGA board also lost its bitstream (power cycle), re-run **step 3**
(`make run` on 19p-rt) before re-running the host side.

---

## How `fpga-host`, the NEMU reference SO, and the workload are built — and why on the host

### The host and the compile server are NOT the same machine

| | 19p-host (run host) | Compile server (EPYC) |
|---|---|---|
| OS / glibc | Ubuntu 22.04 / **glibc 2.35** | glibc **2.43** |
| CPU | Intel i9-12900K (Alder Lake) — AVX2, **no AVX-512** | AMD EPYC — **AVX-512** |

Because the OS **and** the chip differ, anything built on the EPYC and copied to
19p-host fails three independent ways:

| Trap | Symptom | Cause |
|------|---------|-------|
| glibc version wall | `ldd`: "version not found" (`GLIBC_2.42`/`GLIBCXX_3.4.32`) | EPYC binary needs glibc 2.43; 19p-host has 2.35 |
| AVX-512 SIGILL | crashes on launch (`-march=native` on EPYC = AVX-512) | 12900K has no AVX-512 |
| `-static` SIGFPE | exit 136 in `difftest_init` (integer divide-by-zero) | static host `dlopen()`s nemu-so → second libc → split global/TLS state |

**Rule: build `fpga-host`, the NEMU reference SO, AND the workload ON 19p-host itself.** Building on the
actual run host dodges all three traps with no extra flags. Full details (the
no-sudo recipe, the `ldd` / `%zmm` verification) are in
[fpga-host-build.md](./fpga-host-build.md).

### Building `fpga-host` (on 19p-host)

`fpga-host` is the x86 DiffTest host binary, built from the `difftest` sources:

```sh
# on 19p-host, where the difftest source + DCP-matching generated-src are staged:
export CPLUS_INCLUDE_PATH=~/host/build-deps/include LIBRARY_PATH=~/host/build-deps/lib
make -C ~/host/fpga-host-build/difftest fpga-build \
  NOOP_HOME=~/host/fpga-host-build \
  RELEASE=1 FPGA=1 DIFFTEST_PERFCNT=1 USE_XDMA_H2C=1 \
  USE_SERIAL_PORT=1 WITH_CHISELDB=0 WITH_CONSTANTIN=0
cp ~/host/fpga-host-build/build/fpga-host ~/host/ready-to-run/fpga-host.with-uart
```

Link dynamically (never `-static`); `-march=native` on the 12900K yields AVX2
with no AVX-512. Verify: `ldd` shows zero "not found", and
`objdump -d | grep -c %zmm` is `0`. See [fpga-host-build.md](./fpga-host-build.md).

### Building the NEMU reference SO (on 19p-host)

`riscv64-nemu-interpreter-so` is the DiffTest **golden model**: NEMU
(OpenXiangShan/NEMU, branch `no-vec-check`) — a fast RISC-V reference
simulator — compiled as a **shared library** (not an executable). `fpga-host`
`dlopen()`s it and single-steps it in lockstep with the FPGA DUT; any
divergence in architectural state (GPR/CSR/…) is reported as a DiffTest FAIL.
The `.so` exposes the DiffTest C API (`init` / `exec_step` / `regcpy` / …) that
`fpga-host` drives.

Built from the `NEMU/` submodule via the top-level `nemu` target:

```sh
make nemu NEMU_CONFIG=riscv64-xs-ref_defconfig
# == make -C NEMU riscv64-xs-ref_defconfig && make -C NEMU -j
# -> NEMU/build/riscv64-nemu-interpreter-so
# -> ready-to-run/riscv64-xs-ref_defconfig/riscv64-nemu-interpreter-so
cp ready-to-run/riscv64-xs-ref_defconfig/riscv64-nemu-interpreter-so \
   host/ready-to-run/riscv64-nemu-interpreter-so
```

The config `riscv64-xs-ref_defconfig` enables the reference-side DiffTest hooks
(`CONFIG_DIFFTEST`) and the XiangShan/NutShell-compatible ISA/extension set.
`host/Makefile` loads it from the **flat** path
`ready-to-run/riscv64-nemu-interpreter-so` (`FPGA_NEMU_SO`), so the staged copy
sits directly under `host/ready-to-run/`, not in the `<config>/` subdir.

**Build this on 19p-host too.** NEMU compiles with `-march=native -mtune=native`
(`NEMU/Makefile`), so an EPYC-built nemu-so carries AVX-512 (`%zmm`)
instructions that SIGILL the moment `fpga-host` `dlopen()`s them on the 12900K.
(The glibc wall spares it — NEMU needs only `GLIBC_2.14` — but the AVX-512 trap
does not.) Verify the same way as `fpga-host`:
`objdump -d ... | grep -c %zmm` must be `0`.

### Building the workload (microbench, on 19p-host)

The workload is a **bare-metal AM (Abstract Machine)** app, cross-compiled to
RISC-V via the `nexus-am` framework. For NutShell it is built with
`ARCH=riscv64-nutshell` (which selects the 16550 console driver and the
11.0592 MHz baud divisor), using the RISC-V cross-toolchain from the
workload-builder SDK (`riscv64-linux-*`):

```sh
# on 19p-host, with AM_HOME and the riscv64 cross-toolchain set up:
cd <nexus-am>/apps/microbench
make ARCH=riscv64-nutshell CROSS_COMPILE=riscv64-linux-
# -> build/microbench-riscv64-nutshell.bin
cp build/microbench-riscv64-nutshell.bin ~/host/ready-to-run/
```

The output `.bin` is the file `host/Makefile` loads via `WORKLOAD_BIN`
(`ready-to-run/microbench-riscv64-nutshell.bin`). Even though the result is a
RISC-V binary, build it on 19p-host so the build host's toolchain/environment
matches the run host — no cross-host glibc/arch surprises.

---

## See also

- [fpga-host-build.md](./fpga-host-build.md) — the three build traps + full recipe
- [workflow.md](./workflow.md) — end-to-end build/run flow
- [troubleshooting.md](./troubleshooting.md) — runtime issues (XDMA/PCIe, no output, DiffTest mismatches)

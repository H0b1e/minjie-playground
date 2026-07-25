# fpga-host Build Guide

How to build the `fpga-host` DiffTest binary for the Hejian UVHS FPGA DiffTest
platform, and the build-host traps that crash it at runtime if ignored.

## TL;DR

Build `fpga-host` **on the run host itself** (the machine that executes the
diff-test), not on a separate AVX-512 build server, and link it **dynamically**
(never `-static`). That alone avoids all three traps below with no extra flags.

```sh
export CPLUS_INCLUDE_PATH=~/host/build-deps/include LIBRARY_PATH=~/host/build-deps/lib
make -C ~/host/fpga-host-build/difftest fpga-build \
  NOOP_HOME=~/host/fpga-host-build \
  RELEASE=1 FPGA=1 DIFFTEST_PERFCNT=1 USE_XDMA_H2C=1 \
  USE_SERIAL_PORT=1 WITH_CHISELDB=0 WITH_CONSTANTIN=0
# -> ~/host/fpga-host-build/build/fpga-host
# cp to ~/host/ready-to-run/fpga-host.with-uart
```

## Why the build host matters

The NutShell diff-test run host is an Intel Alder Lake i9-12900K on Ubuntu 22.04
(glibc **2.35**). The natural build server is an AMD EPYC (glibc **2.43**, with
AVX-512). A binary built on the EPYC then copied to the 12900K fails for three
independent reasons.

## Trap 1 — `-static` causes SIGFPE in `difftest_init`

`fpga-host` `dlopen()`s the NEMU reference (`riscv64-nemu-interpreter-so`), which
`DT_NEEDED`s libstdc++/libc. A statically linked host pulls in a *second* dynamic
libc/libstdc++ for the `.so`, splitting global/TLS state and triggering a SIGFPE
(exit code `136` = 128 + 8, integer divide-by-zero) inside `difftest_init`.

- **Fix**: link dynamically — `FPGA_LDFLAGS = $(SIM_LDFLAGS) -lpthread -ldl`
  (the upstream default). Do **not** add `-static`.
- The NEMU `.so` only requires `GLIBC_2.14`, so once the host is dynamic and
  glibc-matched, `dlopen` works with a single libc.

## Trap 2 — AVX-512 host produces a binary that SIGILLs on the 12900K

`-march=native` on the EPYC emits AVX-512 (`%zmm`) instructions. The 12900K has
no AVX-512, so the binary crashes with SIGILL immediately on launch.

- **Fix (pick one):**
  - Build on the run host (12900K) — `-march=native` then yields AVX2, no
    AVX-512. **Recommended.**
  - Or build on the EPYC with `FPGA_MARCH=x86-64-v3` (AVX2+FMA+BMI2, no
    AVX-512). Note `-mtune=x86-64-v3` is *invalid* — `-mtune=` accepts only CPU
    names (e.g. `native`, `alderlake`); leave `FPGA_MTUNE` at its `native`
    default.

## Trap 3 — glibc version wall

A binary built against glibc 2.43 (EPYC) records `GLIBC_2.42` / `GLIBCXX_3.4.32`
requirements and will not start on glibc 2.35 (12900K) — `ldd` reports
"version not found". Building on the run host sidesteps this entirely.

## Build recipe (on the run host, no sudo)

The run host lacks `zlib1g-dev` / `libzstd-dev` (and we avoid sudo). Feed the
headers and the lib symlinks via env vars instead of installing packages.

Inputs staged on the run host (`~/host/`):

| Path | Contents |
|------|----------|
| `~/host/fpga-host-build/difftest/` | difftest source + DCP-matching `generated-src` (`CONFIG_DIFFTEST_BATCH_BYTELEN=64`) |
| `~/host/fpga-host-build/build/generated-src/` | generated-src consumed via `NOOP_HOME` (DCP-matched) |
| `~/host/build-deps/include` | zlib/zstd dev headers (glibc-independent, can be copied from any host) |
| `~/host/build-deps/lib` | `libz.so` / `libzstd.so` symlinks → the run host's own runtime `libz.so.1` / `libzstd.so.1` |

```sh
export CPLUS_INCLUDE_PATH=~/host/build-deps/include LIBRARY_PATH=~/host/build-deps/lib
make -C ~/host/fpga-host-build/difftest fpga-build \
  NOOP_HOME=~/host/fpga-host-build \
  RELEASE=1 FPGA=1 DIFFTEST_PERFCNT=1 USE_XDMA_H2C=1 \
  USE_SERIAL_PORT=1 WITH_CHISELDB=0 WITH_CONSTANTIN=0
cp ~/host/fpga-host-build/build/fpga-host ~/host/ready-to-run/fpga-host.with-uart
```

`make fpga-build` = `fpga-clean` + `fpga-host`; use it (not plain `make fpga-host`)
whenever `fpga.mk` or flags change, because the `fpga-host` target depends only
on the `.cpp` sources and will otherwise report "Nothing to be done".

## Verify before trusting

- `ldd ~/host/ready-to-run/fpga-host.with-uart` — must show **zero** "not found".
- `objdump -d ~/host/ready-to-run/fpga-host.with-uart | grep -c %zmm` — must be
  `0` (no AVX-512).
- Runtime: loads the workload via XDMA H2C, prints a clean 115200 serial
  console, and runs DiffTest with no SIGILL/SIGFPE.

## Commit-time check

When refreshing the committed `env-scripts/fpga_diff/host/ready-to-run/fpga-host.with-uart`,
its sha256 **must match** the binary that actually ran the diff-test on the run
host — the run host's copy is the source of truth. An older binary left in the
repo (e.g. an EPYC-built or `-static` artifact) must be overwritten by scp'ing
the verified one back from `19p-host:~/host/ready-to-run/fpga-host.with-uart`
before commit.

## Verified configuration

2026-07-25: this recipe produced `fpga-host.with-uart` (sha256
`89655ce2…`, 148968 B, dynamic, `%zmm` = 0) that ran the full Hejian UVHS
diff-test end-to-end on the 12900K run host — XDMA H2C workload burned, serial
115200 clean, DiffTest PASS.

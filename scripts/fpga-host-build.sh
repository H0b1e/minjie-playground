#!/bin/bash
# Build fpga-host from this self-contained package on the FPGA host machine.
# Requires: make, g++ (>= 10 for C++20), zlib and zstd development headers.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
make -C "$HERE/difftest" fpga-host \
  NOOP_HOME="$HERE" \
  RELEASE=1 FPGA=1 DIFFTEST_PERFCNT=1 USE_XDMA_H2C=1 \
  "$@"
echo "fpga-host built at $HERE/build/fpga-host"

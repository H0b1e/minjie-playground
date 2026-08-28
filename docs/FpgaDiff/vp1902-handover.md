# VP1902 Migration Handover

Status snapshot and task list for migrating the UVHS flow from the VU19P box
to **xcvp1902-vsva6865-2MP-e-S**. Written for whoever picks this up next.

## 1. Where things stand

The VU19P build is the working baseline: UHD waveform capture, DDR backdoor
load (`make run UVHS_FW_BIN=...`), ad-hoc `readmem`, and difftest over XDMA
all work end-to-end (see [uhd-probe.md](./uhd-probe.md) and
[workflow.md](./workflow.md)).

For VP1902, **both hard IPs have been rebuilt, validated, and synthesized**
— but **nothing is wired into the RTL yet**. They are staged in isolation at
`env-scripts/fpga_diff/uvhs/vp1902/` (env-scripts commit `878b2b7`):

| IP | What changed vs VU19P | Status |
|----|----------------------|--------|
| DDR controller | VU19P MIG (`ddr4:2.2` inside `uvw_axi4_to_ddr4`) does not exist on Versal; replaced by the vendor `axi2ddr_soft` profile (soft MC), same frozen contract (256-bit AXI / 34-bit addr / 14-bit id / ECC off), `DC_NAME=UV_APCP_DDR4`. Port delta: `ddr4ip_ddr4_user_clk/rst` outputs removed. | DCP + stub generated, annotation verified |
| PCIe EP | Classic integrated xdma does not exist on Versal; replaced by split-mode xdma 4.2 + `pcie_versal` (CPM) + `pcie_phy_versal` + `gt_quad_base` + BUFGs (vendor support hierarchy), retargeted **Gen3 x4 / 256-bit** to match the old design. Stub delta: top module `xdma_ep` → `xdma_ep_wrapper`, GT pins `pci_exp_*` → `pcie_mgt_grx/gtx[3:0]`, `cpu_rstn` removed. Streams / AXI-Lite / clocks identical. | BD validate clean (`VALIDATE-RC=0`), OOC-synthesized |

Read `vp1902/README.md` first — it has the regeneration commands (Vivado
2025.1.1), the integration checklist, and the leftovers list. The PCIe BD
can be inspected in GUI: `vivado` → `open_project
<nfs>/.../fpga_diff/uvhs/vp1902/pcie/build_prj/xdma_ep_1902/xdma_ep_1902.xpr`
(run `root5.tcl` first if `build_prj/` was deleted).

## 2. Task list (in dependency order)

### Phase A — collect board inputs (blocks everything else)

1. **GT/CPM site for the PCIe link**: `pcie_blk_locn` is the placeholder
   `S0X0Y0` in `vp1902/pcie/build/hier5.tcl`; `select_quad` is forced to
   `GTH_Quad_128` (only legal value at Gen3 on this part). Both must match
   where the new box actually wires the PCIe lanes.
2. **Lane count / rate decision**: current build assumes **Gen3 x4** (parity
   with the old design, unlocks the 256-bit CPM interface). The vendor demo
   ran Gen4 x8 — if the new host cabling is x8/Gen4-capable, revisit
   (`axisten_if_width` becomes 512-bit and the whole data path widens).
3. **Daughter-card inventory of the new box**: which slots hold
   `UV_APCP_DDR4` cards (the DDR stub now binds `toFPGA:<UV_APCP_DDR4>`).
   Run `make query-cards` equivalent (`query -daughter_card`) on the new box.
4. **VP1902 board file name** for `create_system_design -name` (currently
   `VU19P_X4` in `frontend_run.tcl` / `backend_run.tcl`).

### Phase B — RTL / flow integration (mechanical, ~half a day)

Follow the checklist in `vp1902/README.md`; the deltas are:

- `rtl/core_def_xdma.sv`:
  - DDR: delete `.ddr4ip_ddr4_user_clk/rst(...)` (:2366-2367) + wires;
    `init_calib_complete = rstn_sw4` (runtime `initialize` owns calibration).
  - PCIe: `xdma_ep` → `xdma_ep_wrapper`; rename 4 GT connections
    (`pci_exp_rxn/rxp/txn/txp` → `pcie_mgt_grx_n/grx_p/gtx_n/gtx_p`);
    drop `.cpu_rstn(...)`.
- `script/frontend_run.tcl:114`: `set_blackbox -module xdma_ep_wrapper`.
- Stage DCPs/stubs from `vp1902/` into `rtl/soc/` and `rtl/device/pcie/`.
- `Makefile`: `DDR_IP_DIR`/`EXPECTED` guard → vp1902 profile (contract
  unchanged except `PLATFORM_PART` and the ECC field rename
  `DDR_ECC_EN` → `ECC_EN`).
- `script/ip/xdma_ep.tcl` carries part-portable branches (smartconnect /
  quad enums, `93ce5e0`); it does NOT instantiate the Versal CPM/PHY/GT
  companion stack — the canonical VP1902 PCIe build lives in
  `vp1902/pcie/build/`.
- Re-check `script/timing.tcl` (`phy_pclk` 8 ns assumption) and the probe
  gated-clock names in `runtime/user_script/hw_run_uhd.tcl` against the new
  user clock.

### Phase C — board binding files (the explicitly deferred work)

- `script/1B_4F_HGC_assemble.tcl`: daughter-card creation/connection must
  use `UV_APCP_DDR4` for the SoC DDR slots (was `UV_FMCH_PDDR4DME`); UHD
  capture card stays on the probed FPGA's FMC3.
- `script/assign_pin.tcl`: full rework — VU19P and VP1902 pinouts share
  nothing. GT pins (`pcie_mgt_*`), UART, clock inputs, resets.
- `frontend_run.tcl` / `backend_run.tcl`: `create_system_design -name` →
  the VP1902 board file from Phase A.4.

### Phase D — build + bring-up

1. `make fe && make be` (~35 min), then `make rtdb`.
2. Sync `rtdb_test` to the runtime box (its home is **local disk**).
3. `make -C ../runtime run` → driver/difftest from the PCIe host →
   `make uhd` for waveform capture. Existing runtime flows (backdoor,
   `ddr_read.tcl`) need no changes.

## 3. Known risks / open questions

- **MSI interrupts**: `xdma_0/pcie4_cfg_msi` dangles — the vendor support
  hierarchy exposes no MSI boundary pin. Check whether host-side difftest
  depends on `/dev/xdma` MSI events (polling is fine). If needed, add an
  MSI interface to `hier5.tcl`'s hierarchy boundary.
- **Frequency hints are Gen4 values**: `axisten_freq=250`,
  `userclk2_freq=500` in `hier5.tcl` should be 125/250 for Gen3 x4 — fix
  and regenerate before timing closure at be.
- **Vendor hierarchy truncations**: `s_axis_cc_tuser` 81→33 and
  `cfg_interrupt_pending` 8→4 at the hierarchy boundary (qdma-era widths;
  same in the vendor's own demo). Watch during link bring-up.
- **Host side**: same xdma IP family → `/dev/xdma*` driver expected to work
  unchanged (BAR layout bar512c and 256-bit streams preserved), but this is
  unverified on real hardware.

## 4. Environment notes

- **Vivado 2025.1.1** everywhere for IP generation (`~/.config/shell/uvhs.sh`
  sets `XILINX_VIVADO`; now sourced on open01/open03/open05 via `.bashrc`).
- License: the site file `/nfs/tools/xilinx/vivado.dat` covers xcvp1902
  synthesis (verified). `module load license` was **removed** from open03's
  `.bashrc` because it exports an `LM_LICENSE_FILE` full of unreachable
  servers that hangs checkout — if you need VCS/Verdi on open03, load the
  module manually in that shell.
- Build machines: open01/open03/open05 (shared NFS home). Runtime box:
  19p-rt (bitstream + serial, **local disk — rsync `rtdb_test`, `Makefile`,
  `user_script/` after every change**); difftest host: 19p-host.

## 5. Key references

| What | Where |
|------|-------|
| Staged IPs, regen commands, integration checklist, leftovers | `env-scripts/fpga_diff/uvhs/vp1902/README.md` |
| Runtime flows incl. DDR backdoor + readmem | [workflow.md](./workflow.md), `env-scripts/fpga_diff/runtime/README.md` |
| UHD capture guide | [uhd-probe.md](./uhd-probe.md) |
| Vendor PCIe EP reference (Gen4 x8, qdma variant) | `/nfs/tools/uvhs/UV_HGCP_PCIE_EP_2025.06.P5/.../uv_hgcp_pcie_ep_uvhs2_demo_gen4x8/fpga_project/script/run_bd_gen.tcl` |
| Vendor DDR profiles (noc / soft) | `/nfs/tools/uvhs/UVH_2025.06.P5.W1/platform/V1/Prototype/ips/memory/axi2ddr/` |
| Why `axi2ddr_soft` (not `_noc`) | port table comparison in the vp1902 README history / DDR json `CLK_G1` |

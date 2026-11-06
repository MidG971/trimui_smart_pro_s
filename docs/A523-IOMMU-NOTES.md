<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
# A523: the display engine is behind the IOMMU (v15, @0x2010000)

Status: **implemented + HW-validated that the IOMMU binds and the DE RCQ works
through IOVAs — but the panel image is still black** (the frame-clock-out wall is
unchanged; see `A523-DE33-RT-HANDOFF-QUESTION.md` §8). Recorded 2026-11-06.

## Evidence
- Vendor DTB (`trimui_smart_pro_source.dts`): `iommu@2010000 { compatible =
  "allwinner,iommu-v15-sun55iw3"; ... #iommu-cells = <2>; }` and
  `de@5000000 { compatible = "allwinner,display-engine-v350"; iommus = <0x1e 0x05 0x01>; }`
  — the DE is IOMMU **master 5**.
- Mainline `sun55i-a523.dtsi` has no IOMMU node; our port ran the DE without it.
- ut-slayer v0.5 confirms the recipe (patches 0016/0017/0025/0034): node at
  0x2010000, `compatible = "allwinner,sun55i-a523-iommu", "allwinner,sun50i-h616-iommu"`,
  irq SPI 65, `CLK_BUS_IOMMU`, `RST_BUS_IOMMU = 78` at reg 0x7bc bit16 (BGR layout
  like H6/H616: gate bit0, reset bit16), mixer `iommus = <&iommu 5>`. Their 0017 adds
  the A523 (v14+) TLB-prefetch variant: prefetch all masters **plus** the
  "only prefetch valid pages" bits (BIT(16)|BIT(17)) — without prefetch every
  micro-TLB miss stalls the DE fetch pipe and scanout underruns to a dead screen.

## What we ported (patches 0041–0046 in `kernel/patches/`)
- 0041: `sun50i-iommu.c` A523 variant (ported from ut-slayer 0017).
- 0042/0043: `RST_BUS_IOMMU = 78` binding header + CCU reset entry `{0x7bc, BIT(16)}`.
- 0044: SoC dtsi `iommu@2010000` node (with h616 fallback compatible).
- 0045: `iommus = <&iommu 5>;` on `mixer0` in `trimui-de33.dtsi`.
- 0046: `sun55i_de.c` DMA-reach guards skipped when `device_iommu_mapped()`
  (pool/head addresses become IOVAs once the IOMMU is attached; the 0x4b000000
  physical-aperture limit only applies without it).
- `.config`: `CONFIG_SUN50I_IOMMU=y` (the symbol is bool/built-in only).

## HW result (2026-11-06, v7.4-rc1, Image md5 318f2641…, dtb bda04ce9…)
- `sun50i-iommu 2010000.iommu` probes OK; `/sys/kernel/iommu_groups/0/devices/5100000.mixer`.
- DE RCQ pool now allocated via IOVA (RCQ-RB `hw_laddr=ffc00000`), guard no longer trips.
- dmesg shows "TLB invalidation timed out" x4 at probe — the reset line may not fully
  release the SMMU on A523; worth cross-checking against the vendor BSP (open question).
- **Panel still black; `GLB_STS.FRAME_END` still never** — so the IOMMU is necessary
  (vendor DT) but not sufficient; the frame clock-out trigger is still missing.

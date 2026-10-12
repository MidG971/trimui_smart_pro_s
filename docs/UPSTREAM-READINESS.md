<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
<!-- Copyright (C) 2026 Midgy BALON -->

# Upstream-readiness

## Where it stands

The port is split between **small standalone fixes** (submit now) and **larger subsystems**
(gated). The guiding rules are in the linux-sunxi maintainer digest (base on the latest -rc, git
branch + `git send-email`, small per-subsystem series, BSP = register lookup only, keep it terse).

**Submittable now (small, self-contained):** the pinctrl voltage-withstand fix, `mmc-pwrseq`
tolerate-missing-reset, and the `mfd: axp20x` poweroff/restart — all standalone, on a current -rc.

**Gated / coordinate first:**
- **CPU-CCU / cpufreq** — adopt Andre Przywara's A523/T527 CPU-CCU (v3, not yet merged); drop our
  out-of-tree 0014–0020 when it lands. The PLL-lock poll must use
  `readl_relaxed_poll_timeout_atomic()` (merged `clk-for-7.4`) — likely the real big-cluster-hang
  fix. HW results go in as a *report*, not `Tested-by`, unless personally verified.
- **Thermal** — don't submit our own; follow Kalashnikov's A523 THS (two nvmem cells) and add only
  our board's `pwm-fan` cooling-map on top when it merges.
- **Display (DSI/DE33)** — not submission-ready: colour (YUV↔RGB) and the panel-IC **heat** are
  open, and it must land as the *whole chain* (bindings + driver) coordinated with the in-flight
  H616 DE33 rework, not as a reverse-engineered binding ahead of a working driver. A 2026-10-09 HW
  test showed the A523 DE latches via **direct AHB**, so the upstream form drops the BSP RCQ engine.

**Do NOT carry:** the `sunxi_sram_claim()` memory-ordering patch (NAK'd by Jernej as a non-issue).

## Binding / DTS conventions to satisfy (Krzysztof + A733-review)

- Binding **header filename must match the compatible** string.
- Clock/reset **indices are ABI**: start at 0/1, contiguous, no placeholder IDs for unexposed clocks
  (number those only in the driver's private header).
- Per-variant constraints go **inside `allOf:`**, not a bare top-level `if:`; keep compatible enums
  sorted.
- CCU style: `0`-suffix single instances; mark DMA/MMC/NOR-backing bus clocks `CLK_IS_CRITICAL`;
  `const` reset maps; P-only helpers for no-M clocks.
- I2C pin groups: `/omit-if-no-ref/` with `allwinner,pinmux=<2>`, `drive-strength=<10>`,
  `bias-pull-up` — match the upstream `sun55i-a523.dtsi` pattern to avoid duplicate-node conflicts.
- Pinctrl: keep the `interrupts` array on the upstream convention; `.irq_banks` must equal the DT
  interrupt count exactly (a too-small value silently kills GPIO IRQs on the top bank).
- Boot: some A523 clock + PRCM controls are secure-by-default — BL31 must open the security switches
  (in TF-A, not SCMI) before Linux can use them.

## History — the 2026-09 display/PWM scorecard

The display/PWM series was assessed against **v7.1** with `checkpatch.pl` + `dt_binding_check`; the
drivers built and dt-validated, and the gaps were about submission form, not correctness.

| Artifact | checkpatch | dt_binding_check | Notes |
|----------|-----------|------------------|-------|
| `phy-sun55i-dsi-combo.c` | clean | — | |
| `pwm-sun20i.c` | clean | — | greenfield (no D1 PWM-v2 in mainline yet) |
| `panel-trimui-smart-pro-s.c` | clean | — | |
| `allwinner,sun55i-a523-dsi-combo-phy.yaml` | — | clean | |
| `trimui,smart-pro-s-panel.yaml` | — | clean | |
| `allwinner,sun20i-d1-pwm.yaml` | — | clean | closes the pwm "no schema" gap |
| patches 0001–0008 | 0 errors | — | regenerated as git format-patch + Signed-off-by |

Open checkpatch warnings at the time: split each binding hunk into its own patch (0001/0004/0008);
wrap commit bodies ≤75 cols; drop `#`-leading commit-log lines (0004); give 0007's Kconfig a ≥4-line
help paragraph. Bindings live in `kernel/bindings/` and aren't applied to the kernel
`Documentation/` in our build flow, so a plain board `dt-validate` prints benign "no schema" lines.

**TF-A:** mainline has no A523/sun55i platform; we use a real `sun55i_a523` BL31 from Jernej
Škrabec's `a523-v4` branch (not yet in TF-A mainline) — upstream or switch when an A523 plat lands.

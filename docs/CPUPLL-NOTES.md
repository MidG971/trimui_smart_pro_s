<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
<!-- Copyright (C) 2026 Midgy BALON -->

# A523 CPU-PLL clock controller — ADOPTED (CPU-DVFS unblocked)

CPU `cpufreq`/DVFS needs the A523 CPU clock, which mainline does not have. It was
greenfield — until the **ut-slayer / OrangePi-4A** effort
([github.com/ut-slayer/orangepi-4a-mainline](https://github.com/ut-slayer/orangepi-4a-mainline),
Juan Manuel Lopez Carrillo; T527 = same `sun55iw3` die as our A523) wrote a proper
mainline **CPU-CCU driver**. We **adopted it and forward-ported it to v7.2**.

**Status (2026-10): tested on hardware; the upstream direction has shifted.** We first adopted
ut-slayer's CPU-CCU (0015–0020, below), then tested **Andre Przywara's upstream A523/T527 CPU-CCU
(v3)** on silicon: the **little cluster + DSU sweep 408→1416 MHz cleanly** (off the 768 MHz cap), but
the **big cluster hangs at boot** on the first PLL reprogram (parked). ⇒ the plan is to **adopt
Andre's v3** (dropping our out-of-tree 0015–0020, incl. 0019) when it merges, not ship our own. Fresh
lead for the big-cluster hang: poll PLL lock with **`readl_relaxed_poll_timeout_atomic()`** — the
non-atomic macro stalls when timekeeping is suspended during DVFS → freeze (merged `clk-for-7.4`) —
retest the big cluster with it.

**Credits:** the A523/T527 CPU-CCU driver is ut-slayer's / Juan Manuel Lopez Carrillo's work
([`orangepi-4a-mainline`](https://github.com/ut-slayer/orangepi-4a-mainline)), forward-ported
onto the mainline `sunxi-ng` clock framework.

## What we carry (`kernel/patches/0015–0020`, authorship preserved)
Adopted verbatim from ut-slayer (GPL-2.0, `From: Juan Manuel Lopez Carrillo`),
renumbered into our series; they are the SoC-level CPU clock (not the OrangePi
board bits, which we replace with ours):

| ours | theirs | what |
| :--- | :--- | :--- |
| `0015` | 0090 | `drivers/clk/sunxi-ng/ccu-sun55i-a523-cpu.c` (`allwinner,sun55i-a523-cpu-ccu`) + header + Kconfig `SUN55I_A523_CPU_CCU` + Makefile |
| `0016` | 0091 | SoC dtsi node `cpu_ccu: clock-controller@8817000` in `sun55i-a523.dtsi` |
| `0017` | 0093 | reparent the clusters to a safe clock during PLL reprogram |
| `0018` | 0095 | don't touch the unused `pll-cpu0` |
| `0019` | 0097 | **the framework handshake** — adds `CCU_FEATURE_CLEAR_MOD` + a `clear` field to `ccu_common` + the `BIT(26)` update-write in `ccu_mult` (exactly the "mainline doesn't have this, must reimplement" gap this doc flagged) |
| `0020` | 0098 | commit `BIT(26)` in the PLL init sequence |

*Not adopted:* their `0092` (defconfig — we use `kernel/trimui.config`), `0094`
(OrangePi cpu wiring) and `0096` (OrangePi OPP — we have `trimui-cpu-opp.dtsi`).

## Clock model (matches the BSP mine)
`cpu_ccu` @ `0x08817000` provides: `CLK_PLL_CPUL`(0)/`CLK_PLL_CPUB`(1) — the little/big
cluster PLLs — `CLK_PLL_CPU0`(2), and the settable cluster clocks **`CLK_CPUL`(3)**
(cluster0, cpu0-3) / **`CLK_CPUB`(4)** (cluster1, cpu4-7) that `cpufreq-dt` scales.
Register map (PLL_CPU0@0x00, PLL_CPUB@0x0c, CPUB@0x64) matched the earlier BSP mine.

## Our board wiring (done)
- `kernel/trimui.config`: `CONFIG_SUN55I_A523_CPU_CCU=y`.
- `dts/staging/trimui-cpu-opp.dtsi`: `#include <dt-bindings/clock/sun55i-a523-cpu-ccu.h>`;
  cpu0-3 `clocks = <&cpu_ccu CLK_CPUL>`, cpu4-7 `clocks = <&cpu_ccu CLK_CPUB>` (was the
  `CLK_CPU_L/_B` placeholders); OPP tables + `dynamic-power-coefficient` already present.
- The `cpu_ccu` node itself comes from patch `0016` (SoC dtsi), so the board DTS needs
  no cpu-ccu node.

## Remaining
1. ~~Verify the full series co-applies + the board DTB builds~~ **DONE** — `0001–0023`
   co-apply to v7.2-rc3 and the board DTB builds with `trimui-cpu-opp.dtsi` +
   `trimui-thermal.dtsi` included (the CPU-CCU node `0016` is non-overlapping).
2. ~~Big-cluster `cpu-supply`~~ **DONE** — the big-cluster supply is the **axp1530**
   buck @0x36 (`reg_ext_dcdc1` = axp1530 dcdc1), **confirmed on hardware** (0x41 tcs4838
   is absent — our earlier tcs4838 node/patch `0014` was the wrong chip and was dropped).
   `axp1530` is already mainline (`x-powers,axp1530`). Big-cluster `cpu-supply` wired for
   cpu4–7 (`cpu@400` → `reg_ext_dcdc1`). See [ON-DEVICE-FINDINGS](ON-DEVICE-FINDINGS.md).
   Little cluster uses `reg_dcdc1` (axp717 main PMIC).
3. **Little-cluster DVFS: working on HW** (policy0, 408→1416 swept clean on Andre's v3).
4. **Big-cluster DVFS: hangs at boot** (policy4, first big-PLL reprogram) — parked. Next experiment:
   Andre v3 + the `readl_relaxed_poll_timeout_atomic()` PLL-lock fix; pinning it needs a serial-console
   capture (UART pads to be soldered).

## Upstream status
The canonical upstream answer is now **Andre Przywara's A523/T527 CPU-CCU** ([PATCH v3], 2026-09-25) —
**not yet merged** as of 2026-10 (mainline has the main + MCU + PRCM CCU, no CPU CCU). When it lands we
drop our out-of-tree 0015–0020 and reply with HW results (a *report* for the big cluster, a clean
little-cluster result — per the terse-submission guidance). The ut-slayer series (Juan Manuel Lopez
Carrillo, building on minimyth2 / Justin Suess (H728) + Jernej Škrabec (H616)) is what we adopted first
and remains the credit for the local bring-up.

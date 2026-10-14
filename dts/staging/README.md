<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
<!-- Copyright (C) 2026 Midgy BALON -->

# dts/staging — drafts gated on external upstream work

Most fragments here are **NOT** included by the board DTS and **do not build today**.
They capture the verified vendor-DTB facts and the intended mainline wiring for
features whose kernel support is still landing upstream, so they are quick to
finalise the moment the dependency is in our baseline. (Exception: `trimui-gpu-opp.dtsi`
already compiles on our v7.2-rc3 baseline — it is staged only because it is HW-unverified.)

| File | Provides | Blocked on | Drop-in when |
|------|----------|-----------|--------------|
| `trimui-usb3.dtsi` | USB3 host (dwc3) + GMA340 SuperSpeed mux | A523 USB3 CCU clocks + combo-PHY + dwc3 glue | Kalashnikov "[PATCH] a523: add USB3.0 support" series (needs a v2; not in v7.1/v7.2) |
| `trimui-cpu-opp.dtsi` | Per-cluster CPU DVFS (`cpufreq-dt` OPP tables, little 408–1416 / big 408–1800 MHz + commented turbo rows) + `cpu-supply` + dynamic-power-coeff | Nothing external — both former blockers resolved **locally**: CPU-CCU adopted from ut-slayer (`0015-0020`, `&cpu_ccu` CLK_CPUL/CPUB), and the big-cluster CPU supply is **axp1530@0x36** (`&reg_ext_dcdc1`, already mainline `x-powers,axp1530`) — confirmed on HW; our earlier `tcs4838` (patch `0014`) was the wrong chip and was dropped. Builds today. Already board-only (no `-upstream` variant needed — see the file header). | in use now (opt-in `#include`). On HW the **little cluster scales** (408→1416); the **big cluster hangs at boot** (parked). **When the CPU-CCU is upstreamed** — now **Andre Przywara's A523 v3** (not ut-slayer's) — drop `0015-0020` and rebase onto it (watch the `CLK_CPU_*` macro names + compatible) |
| `trimui-gpu-opp.dtsi` | Mali-G57 GPU DVFS (`operating-points-v2`, full vendor ladder 150–888 MHz) | **Nothing upstream** — compiles today; only HW-unverified | anytime; keep a conservative default ceiling (~600 MHz) and validate the top steps on HW. Optional, off the critical path |
| `trimui-thermal.dtsi` | **MOVED to `dts/` (active), 2026-10-14** — it is the live thermal path. Full THS via the ut-slayer driver (`0021-0023`, `sun55i-a523-ths`/`-ths-ddr`): ths sensors, single 20-byte calibration cell, all zones + the `pwm_fan` cooling curve. | nothing — works today with `0021-0023` | **No longer staged**: the Kalashnikov upstream THS did **not** merge into v7.3-rc7 (posted only), so this stays the active DT. HW-proven on 7.3 (5 zones, fan policy). Fan curve tuned 2026-10-14 (active trips 60/72/85 °C + a 50→100 % `cooling-levels` ramp). Now `#include`d by the board DTS. |
| `trimui-thermal-upstream.dtsi` | **FUTURE/post-merge:** just the `pwm_fan` cooling-map layered on the **upstream** `cpu0_thermal`/`cpu4_thermal` zones — the SoC ths0/ths1 + calibration + zones all come from mainline | Kalashnikov A523 THS series merging (v6 posted at 7.3-rc2, **NOT in 7.3-rc7**) | still gated: the THS series is **not** in 7.3-rc7, so keep `trimui-thermal.dtsi`. When it merges: drop `0021-0023`, switch to this (rebase the fan-curve ramp onto the upstream zones). **Build-verified 2026-07-21** against K.'s v5 dtsi. See `docs/THERMAL-DVFS-NOTES.md` |

Each file's header documents what is verified vs. what must be calibrated /
relabelled on hardware or against the final upstream nodes.

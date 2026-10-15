<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
# A523 (Trimui Smart Pro S) mainline MIPI-DSI — the TCON per-frame IRQ blocker (help / insights welcome)

**Date:** 2026-10-15 · **Kernel:** mainline **v7.3-rc7** · **SoC:** Allwinner **A523** (sun55iw3) ·
**Repo:** https://github.com/MidG971/trimui_smart_pro_s

> **TL;DR** — The DE33 pipeline binds and `fb0` is created, but register-level probing shows the
> **TCON-LCD1 is clocked and out-of-reset yet never enabled/configured** (`CTL=0`, `curline=0` → not
> scanning), so there is no scanout, the frame-done IRQ (`5502000.lcd-controller`, GIC 124) stays at
> **count 0**, every DRM `flip_done`/`vblank` times out, and the panel shows only a stale/garbage DDIC
> patch. Clock-gating, reset, and IRQ-index are **ruled out** (see §3b). The panel is an 8080 / TCON
> **CPU-interface** DSI (frame-complete = `TCON0_TRI_FINISH`, not `VBLANK_INT`). **We'd love eyes on
> *why sun4i_tcon's CRTC enable never configures/enables the TCON* on this DE33 setup.** (A `TRI_FINISH
> → drm_crtc_handle_vblank` patch is ready but inert until the TCON actually runs.)

---

## 1. Platform / pipeline

Handheld (Trimui Smart Pro S), A523 + a 720×1280 MIPI-DSI panel (DDIC/COG on the FPC). DE3.5/**DE33**
display engine, modelled on sun50i-h6 + the H616 DE33 work.

```
mixer0 (DE33) → tcon_top[mux 1] → tcon-lcd1 @0x5502000 → dsi1 @0x5508000 (combo-phy) → panel
```

- Panel is driven through the **TCON CPU-interface (8080)** path (`pixel_cpu_trigger`), DSI in
  **non-burst** video (`MIPI_DSI_MODE_VIDEO | MIPI_DSI_MODE_LPM`).
- `tcon_tv0` is disabled (no HDMI on this board) so `tcon-lcd1` is CRTC-0.
- Provisional display driver set (BSP-derived "solve", not upstream-clean yet):
  `kernel/harvest-sun55i-de/drm-display-provisional.patch` + DT fragments.

## 2. What works

- Full pipeline **binds**: mixer0, tcon_top, tcon-lcd1, dsi1, combo-phy, panel all probe; `fb0` is
  created; `sun6i-mipi-dsi … Attached device smart-pro-s-panel`; connector `DSI-1` → `crtc-0` active.
- RCQ pool fixed: the mixer needs a **low `reserved-memory` CMA** (`alloc-ranges 0x43000000`) because
  the DE DMA only reaches ~`0x4b000000`; without it the mixer bind fails `-34`.
- A frame **does reach the panel** via a per-frame CPU-IF trigger loop (an hrtimer re-arms
  `TCON0_CPU_IF TRI_EN` each cycle). So the panel shows an image — but a *held* one.

## 3. The blocker — TCON frame-done IRQ never fires → no vblank/flip completion

Every atomic commit stalls the full 10 s `flip_done` timeout (→ slow boot, held frame):

```
[drm] *ERROR* [CRTC:39:crtc-0] vblank wait timed out
[drm] *ERROR* flip_done timed out
[drm] *ERROR* [PLANE:35:plane-0] commit wait timed out
```

`/proc/interrupts`:

```
476:  0 0 0 0 0 0 0 0  GICv3 124 Level  5502000.lcd-controller
```

The TCON IRQ **never increments**. And the driver's own regmap readback inside `enable_vblank()`
(not `/dev/mem` — `CONFIG_STRICT_DEVMEM=y` here) shows the TCON registers **all-zero at that moment**:

```
SUN4I-VBL: enable_vblank(1) GINT0=0x00000000 TCON0_CTL=0x00000000 CPU_IF=0x00000000   @ t=9.5s
```

…yet the real modeset/`fb0` only lands at **t≈43 s** (the pipeline spends ~34 s in deferred-probe
retries before everything is up).

### Why that matters for an 8080/CPU-IF panel
In TCON CPU-interface mode the TCON signals a completed frame via **`TCON0_TRI_FINISH_INT`**, *not* the
free-scan `VBLANK_INT`. The current IRQ handler only completes DRM vblank/flip on `VBLANK_INT`:

```c
/* sun4i_tcon_handler() */
if (status & (VBLANK_INT(0) | VBLANK_INT(1))) {        /* never set in CPU-IF mode */
        drm_crtc_handle_vblank(&scrtc->crtc);
        sun4i_tcon_finish_page_flip(drm, scrtc);
}
...
if (a523_stock_trigger && (status & TCON0_TRI_FINISH_INT)) {   /* the event we SHOULD get */
        /* re-arms the CPU-IF push, but never tells DRM a frame finished */
}
```

## 3b. Register-level findings (2026-10-15, via an `ioremap` debug module — `/dev/mem` is unreliable here even with `STRICT_DEVMEM=n`)

Read directly from the clocked blocks (kernel `ioremap`+`readl`, corroborated by the driver's own regmap):

```
CCU resets (1 = out-of-reset):  DE=1  DISPLAY0_TOP=1  MIPI_DSI1=1  TCON_LCD1=1   (LVDS1=0, unused/DSI board)
CCU gates:  tcon-lcd1 bus=1, tcon-lcd1 mod @62 MHz (clk_summary)
tcon1 @0x5502000:  CTL(0x40)=0  GINT0(0x04)=0  GINT1(0x08)=0  curline(0xfc)=0
tcon-top @0x5500000 = 0 ;  dsi1 @0x5508000 = 0
```

So the TCON (and tcon-top/dsi1) are **clocked and out of reset, but their registers are all zero** — the
**TCON core is never enabled/configured** (`CTL` bit31 TCON_ENABLE clear, `curline`=0 → not scanning). This
rules out clock-gating, reset, and IRQ-index as causes. tcon0 @0x5501000 is clock-disabled, so scanout isn't
secretly on it either. **The vblank/flip_done timeout is a downstream symptom: a disabled TCON can't scan or
interrupt.** The panel's "white patch" is a stale/garbage DDIC state, never a driven frame.

## 4. Leading hypothesis (revised)

The DE/mixer `mode_set` runs and `fb0` is created, the TCON clock+reset are brought up, but the
**sun4i_tcon CRTC enable never writes the TCON `CTL`/timing** (it stays 0) — so the 8080 CPU-IF scanout is
never actually started on tcon1. (Earlier `enable_vblank` at t=9.5s also saw `CTL=0`, consistent: the TCON is
simply never enabled, not just "vblank armed too early".) Why the atomic_enable / a523_stock_trigger config
path doesn't configure the TCON on 7.3 is the open question — possibly the CRTC↔TCON/encoder binding (the log
prints "Cannot find any crtc or sizes" at t=8.6s) or a DE33 enable-ordering gap.

## 4b. Original leading hypothesis (superseded by §3b/§4)

`enable_vblank()` runs **at t≈9.5 s, before the TCON's `atomic_enable` has configured/clocked it**
(`TCON0_CTL=0`), so the `GINT0 |= TRI_FINISH_ENABLE` write is lost. DRM's vblank refcount then stays
>0, so after the *real* modeset (t≈43 s, TCON now live) `enable_vblank()` is **not called again** →
`TRI_FINISH_ENABLE` is never actually set on the live TCON → the IRQ never fires → `flip_done` never
completes.

(Secondary, not yet excluded: `enable_vblank` targeting the wrong TCON instance — tcon0 @0x5501000 vs
our tcon1 @0x5502000. We can't `devmem`-probe to confirm — `STRICT_DEVMEM` — so a `STRICT_DEVMEM=n`
rebuild or more driver logging is the next step.)

### Candidate fix (built, HW-tested, currently inert)
`kernel/harvest-sun55i-de/vblank-tri-finish.candidate.patch`: drive `drm_crtc_handle_vblank()` +
`sun4i_tcon_finish_page_flip()` from the `TRI_FINISH_INT` branch. Build-verified on v7.3-rc7; deployed
to HW — **no change**, precisely because `TRI_FINISH` never arrives. The fix is necessary but not
sufficient; the gating problem is **arming/raising the TCON IRQ at all**.

### Next steps we're taking
1. Arm `TRI_FINISH_ENABLE` in the TCON **enable/mode_set** path (runs when the TCON is live), not only
   in DRM's `enable_vblank`; and/or force a vblank off→on cycle after the pipeline is up.
2. Rebuild with `STRICT_DEVMEM=n` (or add logging of the TCON base + `GINT0/CTL` at `atomic_enable`) to
   confirm instance + clock/ordering, and watch `/proc/interrupts` for the IRQ to start counting.

## 5. Heat / fractal — resolved understanding (confirms the LP-11 duty hypothesis)

Earlier "fractale + CRT-lines + IC heating" turned out to be **thermal, tied to DSI HS-clock duty**:
mainline holds the DSI HS clock at ~100 % duty between frames; stock parks **LP-11** (~15 %). Observed
on HW: the fractal appears only when the DDIC is **hot**, and **clears as it cools** — the v7.3 path
with a correct RCQ runs the DDIC **cool ("cooler than stock")**, and a fractal we saw was residual heat
carried over from a hot v7.2 session. So: **fractal == hot DDIC; cool DDIC == no fractal.** Parking
LP-11 between frames (to cut HS duty) remains a separate improvement, but heat is no longer the blocker.

## 6. TE (tearing-effect) — checked, not a shortcut here

The panel init enables TE (`DCS 0x35 SET_TEAR_ON`), which would be the natural per-frame sync. But the
**vendor DTS routes no TE pin**: DSI1 is exactly the 10 lanes `PD10–PD19`, with no `te-gpios`, no
`lcd_dsi_te`, and no sunxi `lcd_*` panel config (the `lcd0` node is a stub; the vendor panel config lives
in its kernel/FEX). So **TE is not available as a GPIO IRQ**. It *might* be delivered in-band over the
DSI link — if anyone knows whether `sun6i_mipi_dsi` / the A523 TCON can latch an in-band DSI TE to drive
per-frame sync, that's a lever we'd use. Otherwise the `TRI_FINISH` path is the vblank source.

## 7. Open questions (where fresh insight would help most)

1. **A523/H616/T527 DE33 + TCON-LCD in 8080 CPU-IF mode:** what's the intended per-frame completion IRQ
   for a command/CPU-IF-driven DSI panel, and is `TCON0_TRI_FINISH` the right event to feed
   `drm_crtc_handle_vblank()`?
2. **Why would `GINT0/TCON0_CTL` read 0 right after `enable_vblank`** — is this just DRM calling
   `enable_vblank` before the CRTC `atomic_enable` (a known ordering for some drivers), and what's the
   clean way to (re)arm the frame IRQ once the TCON is live?
3. With `tcon_tv0` disabled and `tcon-lcd1` as CRTC-0, is there a known gotcha in the **CRTC↔TCON vblank
   routing** on the A523 DE33 (e.g. the encoder's `possible_crtcs`, or the tcon-top mux index)?
4. **In-band DSI TE** on `sun6i_mipi_dsi` / A523 — usable for per-frame sync without a GPIO?
5. Anyone on the sister **A133 Smart Pro** (same CPU-IF DSI, per-frame trigger) — how did you wire
   `TRI_FINISH` → vblank cleanly, and did you hit the same "IRQ never fires / enable_vblank too early"?

## 8. Reproducibility

- Base: mainline **v7.3-rc7**. Build recipe + patches + DT: the repo above (`assemble-7.3.sh`,
  `kernel/patches/`, `dts/`, `kernel/harvest-sun55i-de/`).
- Display: `drm-display-provisional.patch` (BSP-derived, not upstream-clean) + `dts/trimui-de33.dtsi`
  (+ low-CMA) + `dts/trimui-de-reconcile.dtsi` + `dts/trimui-panel.dtsi`.
- Deeper driver-level analysis + the candidate patch: `docs/DISPLAY-VBLANK-ANALYSIS.md`,
  `kernel/harvest-sun55i-de/vblank-tri-finish.candidate.patch`.
- On-HW status: boots; Wi-Fi/Tailscale, storage, thermals (5 zones + working pwm-fan), audio/cpufreq
  pending patch rebases; **display = this doc's blocker.** v7.2-rc3 is the HW-proven baseline.

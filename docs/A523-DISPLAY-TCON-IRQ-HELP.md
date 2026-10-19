<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
# A523 (Trimui Smart Pro S) mainline MIPI-DSI — DE/TCON bring-up (help / insights welcome)

**Date:** 2026-10-19 · **Kernel:** mainline **v7.3-rc7** · **SoC:** Allwinner **A523** (sun55iw3) ·
**Repo:** https://github.com/MidG971/trimui_smart_pro_s

> **TL;DR (updated 2026-10-19)** — The blocker this document was originally written about
> (*"the TCON is clocked and out of reset but every register reads zero, `CTL` writes don't stick,
> and the frame IRQ never fires"*) is **solved**. It was never a TCON driver bug: **the display
> stack was powering off the power domain containing its own TCON and DSI.** Nothing in the DT
> claims `PD_VO0`/`PD_VO1`, so when the mixer probed it released pck-600's deferred `sync_state()`,
> which switched off every unclaimed domain in one sweep. Fix: `kernel/patches/0039-*.patch`.
> The TCON is now enabled (`CTL=0x800001d0`), scanning, interrupting, and **every `flip_done`
> completes**. **The remaining problem is narrower: the panel shows backlight only, no image** —
> and the prime suspect is that the per-LCD DISPLL pixel-clock routing (`set_displl()`) has still
> never run. See §5 and §6; that's where fresh eyes would help most.

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
- Provisional display driver set (BSP-derived, not upstream-clean yet):
  `kernel/harvest-sun55i-de/drm-display-provisional.patch` + the DT fragments in `dts/`.

---

## 2. ★ Root cause of the original blocker: a power domain, switched off by its own consumer

### What happens

On the A523 **nothing in the device tree claims the `VI`, `VO0` or `VO1` power domains.** The only
in-tree consumers of pck-600 are the display engine and mixer (`PD_DE`) and GMAC1 (`PD_VO1`, which is
`status = "disabled"` on this board). `tcon_top@5500000`, `tcon1@5502000` and `dsi1@5508000` carry
**no `power-domains` property at all**.

That is harmless right up until the provider's `sync_state()` runs. In
`drivers/pmdomain/core.c`:

```c
void of_genpd_sync_state(struct device_node *np)
{
	list_for_each_entry(genpd, &gpd_list, gpd_list_node) {
		if (genpd->provider == of_fwnode_handle(np)) {
			genpd->stay_on = false;
			genpd_power_off(genpd, false, 0);
```

`genpd_set_stay_on()` marks every domain that is already on at init with `stay_on = true` — that is
what carries bootloader-enabled domains safely past `genpd_power_off_unused()` at `late_initcall`.
`sync_state()` revokes that protection **for every domain of the provider at once**. The mixer is
pck-600's last deferred consumer, so the instant `sun8i-mixer` *probes*, seven domains go down
together — including the ones the display output blocks live in.

Note this is the **platform driver probe**, not the component bind: `sun8i-mixer` does not depend on
`sun4i-drm`, so loading it alone cannot complete the component set, and every clock/reset/register
write in that driver lives in `sun8i_mixer_bind()`. No DE register is touched. That is why the
earlier bisect in this document could pin the collapse on `sun8i_mixer` while the master was not
even loaded — a result that made no sense under any "DE power-up transient" theory.

### The evidence

Paired cold boots, same kernel, same DTB, the only difference being `sun8i-mixer.ko` renamed
`.ko.disabled`:

| boot | mixer | VE | GPU | VI | VO0 | VO1 | DE | NAND | PCIE |
|---|---|---|---|---|---|---|---|---|---|
| mixer present | bound, refcnt 0 | off | off | off | off | off | on | off | off |
| mixer absent | — | **on** | **on** | **on** | **on** | **on** | on | **on** | **on** |

An unpowered block reads back as zero and swallows writes — which is exactly the symptom this
document was built around (`CTL=0`, `GINT0=0`, `curline=0`, `tcon-top = 0`, `dsi1 = 0`).

### The fix

The **vendor device tree marks exactly these three domains `ppu-always-on`** (`pd1_vi@2`,
`pd1_vo0@3`, `pd1_vo1@4`); `pd1_de@5` is deliberately *not* marked. `sun55i-pck600.c` already
supports per-domain flags — the A733 table uses `GENPD_FLAG_ALWAYS_ON` for `GPU_CORE` — so the fix
is three flags:

```c
static const struct sunxi_pck600_pd_desc sun55i_a523_pck600_pds[] = {
	{ "VE", }, { "GPU", },
	{ "VI", GENPD_FLAG_ALWAYS_ON },
	{ "VO0", GENPD_FLAG_ALWAYS_ON },
	{ "VO1", GENPD_FLAG_ALWAYS_ON },
	{ "DE", }, { "NAND", }, { "PCIE", },
};
```

→ `kernel/patches/0039-pmdomain-sunxi-pck600-keep-A523-VI-VO0-VO1-always-on.patch`

**Is pinning them always-on the right shape?** Probably not the *best* one — see §6 Q1. Giving the
TCON/TCON-TOP/DSI nodes real `power-domains` so they claim what they actually use looks more
correct, and we'd rather land that if someone can confirm the domain↔block mapping.

### Before / after on hardware (v7.3-rc7, same tree, same DTB, same modules)

| | before | after patch 0039 |
|---|---|---|
| `TCON0_CTL` | `0x00000000` | **`0x800001d0`** (bit31 `TCON_ENABLE` set) |
| `GINT0` | `0x00000000` | **`0xc8008003`** (armed) |
| tcon IRQ, GIC 124 | **0**, never increments | **547** during boot |
| `flip_done` / vblank timeouts | every commit, 10 s each | **0** |
| `fb0` created at | t ≈ 43 s | **t ≈ 9.55 s** |
| `tcon_curline` (`0xfc`) | `0` (not scanning) | moving: `83390000, 80c30000, a3a60000, …` |
| connector | — | `card1-DSI-1 connected / enabled / 720x1280` |
| side-board 5 V (LED ring, gamepad MCUs, fan) | dead until cold boot | **alive** |

There are **no `*ERROR*` lines in the boot log at all** now.

---

## 3. Why this also killed the side board (same bug, different victim)

On this handheld the same sweep took down a 5 V rail feeding the side board — LED ring, gamepad
MCUs and fan — permanently, until a cold boot. That sent us a long way down the wrong path: it
looked like a *board-level latch* tripped by a DE power-up transient, because re-pulsing the enable
GPIO never recovered it and only a power-cycle did (the bootloader is what turns those domains back
on). Measurements kept coming back clean — no current delta, no AXP fault, every pin and regulator
still reading correct — for the simple reason that nothing had faulted. The kernel had switched a
domain off on purpose.

If you are chasing an Allwinner rail that dies "when the display driver loads" and reads perfectly
healthy in sysfs while dead: check `pm_genpd_summary` before and after the probe.

---

## 4. What works now

- Full pipeline binds: mixer0, tcon_top, tcon-lcd1, dsi1, combo-phy, panel; `fb0` + `card0/1/2`.
- `sun55i_de: mode_set 720x1280`, `enable 720x1280 port2chn_mux=0x80`, `TCON-TOP-DE: mixer=0 tcon=1
  PORT_SEL=0x1`, `SUN4I-TCON-DBG ch0 en=1 dclk=48000000`.
- DSI transmits: `SUN6I-DSI-VID: CTL0=0x00030001 CTL1=0x00000015`, HS clock 288 MHz for a 48 MHz
  pixel clock, non-burst.
- TCON enabled, scanning, interrupting. Backlight on. **Every atomic commit completes** — no more
  10 s stalls, so boot is ~33 s faster.
- RCQ pool: the mixer needs a **low `reserved-memory` CMA** (`alloc-ranges 0x43000000`); the DE DMA
  only reaches ~`0x4b000000`, and without it the mixer bind fails `-34`.

---

## 5. The remaining blocker: backlight only, no image

The panel lights but shows no picture. The pipeline is running, so this is now a much narrower
question than before. The leading suspect:

### `set_displl()` — the per-LCD DISPLL pixel-clock routing — has still never run

```c
	if (tcon->pixel_clk) {
		ret = sun4i_tcon_route_displl(tcon, true);   /* → sun8i_tcon_top_set_displl() */
		...
	}
```

`tcon->pixel_clk` comes from `devm_clk_get_optional(dev, "pixel")`, and the `tcon-lcd1` node has
`clock-names = "ahb", "tcon-ch0"` — **no `"pixel"`** — so it is NULL and the whole routing call is
skipped. No `displl` diagnostic appears anywhere in the boot log.

**And supplying the clock does not work** — we tried. Adding `clock-names += "pixel"` makes
`pixel_clk` non-NULL, so bind enters `sun4i_tcon_route_displl()`, which then fails:

```c
	id = sun4i_tcon_of_get_id_from_port(port);
	if (id < 0 || id > 1)
		return -EINVAL;        /* ← the OF-graph lookup does not resolve to 0/1 */
```

and the error propagates to `goto err_assert_reset`, so **the TCON fails to bind entirely (-5)**.
So the real defect is the **OF-graph id resolution**, not the missing clock; adding the clock just
converts a silent skip into a hard bind failure. We reverted it.

The current code works around all of this by force-opening both DSI datapath gates at tcon-top
bind, instead of routing the DISPLL per-LCD. That is enough to get the TCON scanning and the DSI
transmitting — but it may well not be enough to get real pixel data clocked into the panel, which
would explain backlight-without-image.

### Module parameters currently in effect

`sun4i_tcon.a523_stock_trigger=Y`, `dsi_video_mode=Y`, `keep_active=Y`;
`sun8i_mixer.use_rcq=Y`, `arm_at_target=Y`, `tcon_line_double=Y`, `tcon_curline_phys=0x55020fc`.
The mixer reports `commits=4`, `rcq_status=264`.

### Note on the frame IRQ at idle

The TCON IRQ count is static at idle (547 → 547 over 3 s). That is expected for an 8080/CPU-IF
panel — frames are produced on commit, not free-running — so it is not in itself a fault. It does
mean anything relying on a steady vblank (fbcon damage, for instance) needs the per-frame re-trigger
path. `kernel/harvest-sun55i-de/vblank-tri-finish.candidate.patch` (drive
`drm_crtc_handle_vblank()` + `sun4i_tcon_finish_page_flip()` from `TRI_FINISH_INT`) was previously
inert because `TRI_FINISH` never arrived; **it is now worth re-evaluating**, since the IRQ fires.

---

## 6. Open questions — where fresh insight would help most

1. **Domain ↔ block mapping.** Which pck-600 domain actually contains TCON-LCD0/1, TCON-TOP and the
   DSI host on A523/T527 — `VO0`, `VO1`, or split? We pinned VI/VO0/VO1 always-on because the vendor
   DT does, but the cleaner fix is `power-domains = <&pck600 PD_VOx>` on the consumers. Does anyone
   have the authoritative mapping?
2. **Is this generic to sunxi genpd providers?** Any Allwinner SoC whose DT under-describes domain
   consumers should hit the same `sync_state()` sweep. H616/H6 DE33 users: does
   `pm_genpd_summary` change across your display probe?
3. **`sun4i_tcon_of_get_id_from_port()` on a DE33 tcon-top graph** — why does it fail to resolve
   tcon-lcd1 to id 0/1, and what's the correct graph shape so `set_displl()` can run per-LCD instead
   of force-opening both gates? This is the single most useful thing to fix next.
4. **Backlight but no image with the TCON scanning and the DSI transmitting** — on a CPU-IF/8080
   DSI panel, what else must be configured for pixel data to actually land? Is the DISPLL routing in
   Q3 load-bearing for this, or is it a separate DE→TCON data-path issue?
5. **In-band DSI TE** on `sun6i_mipi_dsi` / A523 — usable for per-frame sync without a GPIO? The
   panel enables TE (`DCS 0x35 SET_TEAR_ON`), but the vendor DTS routes **no TE pin** (DSI1 is
   exactly `PD10–PD19`, no `te-gpios`), so it is not available as a GPIO IRQ.
6. Anyone on the sister **A133 Smart Pro** (same CPU-IF DSI, per-frame trigger) — how did you wire
   `TRI_FINISH` → vblank cleanly?

---

## 7. Heat / fractal — resolved understanding

Earlier "fractal + CRT-lines + IC heating" turned out to be **thermal, tied to DSI HS-clock duty**:
mainline holds the DSI HS clock at ~100 % duty between frames; stock parks **LP-11** (~15 %).
Observed on HW: the fractal appears only when the DDIC is **hot** and clears as it cools. So
**fractal == hot DDIC**. Parking LP-11 between frames remains a worthwhile improvement, but heat is
not the blocker.

---

## 8. Reproducibility

- Base: mainline **v7.3-rc7**. Build recipe + patches + DT: this repo (`kernel/patches/`, `dts/`,
  `kernel/harvest-sun55i-de/`).
- The power-domain fix is `kernel/patches/0039-pmdomain-sunxi-pck600-keep-A523-VI-VO0-VO1-always-on.patch`;
  it applies cleanly to the pristine v7.3-rc7 `drivers/pmdomain/sunxi/sun55i-pck600.c` and is the
  exact source built for the measurements in §2.
- Display: `drm-display-provisional.patch` (BSP-derived, not upstream-clean) + `dts/trimui-de33.dtsi`
  (+ low CMA) + `dts/trimui-de-reconcile.dtsi` + `dts/trimui-panel.dtsi`.
- To reproduce the original failure, simply revert patch 0039 and watch `pm_genpd_summary` across
  `modprobe sun8i_mixer`.
- On-HW status: boots; Wi-Fi/Tailscale, storage, thermals (5 zones + working pwm-fan), audio,
  gamepad, side board all working. **Display: pipeline live, image pending (§5).**

---

## 9. History — superseded analysis (kept for the record)

Earlier revisions of this document pursued, and can now be closed out:

- *"`enable_vblank()` runs before `atomic_enable`, so `TRI_FINISH_ENABLE` is lost"* — plausible, but
  not the cause; `GINT0` is armed correctly once the block has power.
- *"The a523 CPU-IF config path is skipped because `tcon->pixel_clk` is NULL"* — the gating is real
  (§5) but it was **not** why the TCON read zero; the registers were unpowered. Supplying the clock
  breaks bind, see §5.
- *"A DE power-up transient browns out a shared rail / trips a board-level latch"* — wrong. There
  was no transient and no latch; `sync_state()` switched the domains off deliberately.
- *"Display and the side board are mutually exclusive on mainline"* — wrong, and now disproven on
  hardware: both run together.

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
> The TCON is now enabled, scanning, interrupting, and **every `flip_done` completes**.
> Since then the pipeline has been driven to match the vendor's live register capture
> **register for register** — TCON, every DSI sync-timing register, the DE33 top block, and the
> D-PHY including its status register. **★ Later on 2026-10-19:** the panel's `reset-gpios` polarity was wrong
> (§5e) — declared `ACTIVE_HIGH`, it held the DDIC in reset through the whole init. Fixing it
> changed what the panel shows, and for a while we read that as "it displays, now tune the
> image". **That reading did not survive testing.** The DDIC responds to no command in
> either LP or HS, returns `0x00` for every register including its IDs, and a TCON-generated
> solid-black pattern does not darken it. The current best interpretation is that **nothing
> in the DSI stream was being decoded**.
> **★ 2026-10-20 — it decodes. The pixel clock was wrong.** The vendor's own panel node
> gives **62 MHz**, not the 48 MHz we were driving. With the clock corrected the TCON's own
> patterns invert on the glass and the first colour appears, so the link really is decoding.
> What remains is that the transfer starves after a few lines. See §5g.
> See §5 for the register diff and §6 for where fresh eyes would help most.

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

## 5. Where it stands: stock register-for-register, still backlight only

Since the power-domain fix, three further changes have driven the pipeline onto the vendor's
captured values. All are verified live with `kernel/debug/dedump/` (a read-only `ioremap` dump
module — `/dev/mem` returns `EFAULT` for these ranges here even with `CONFIG_STRICT_DEVMEM=n`).

### 5a. The TCON "pixel" clock — and a correction

`tcon->pixel_clk` gates far more than clock routing: it is the master switch for the whole A523
CPU-interface path (`sun4i_tcon.c` lines 675, 731, 738, 745, including the `a523_stock_trigger`
config that writes the TCON `CTL` and the DCLK gate bits). With no `"pixel"` entry in
`clock-names` it is NULL, and most of that code never runs.

Adding it previously made the TCON **fail to bind with `-5`**, and an earlier revision of this
document blamed `sun4i_tcon_of_get_id_from_port()` failing to resolve the TCON id. **That was
wrong.** `-5` is `-EIO`, and the only thing on that path returning `-EIO` is the register
read-back check in `sun8i_tcon_top_set_displl()` — tcon-top was in the powered-off VO domain, so
its writes evaporated. The id resolves fine. With the domains fixed, the clock can go back in:

```
clocks      = <&ccu CLK_BUS_TCON_LCD1>, <&ccu CLK_TCON_LCD1>, <&ccu CLK_TCON_LCD1>;
clock-names = "ahb", "tcon-ch0", "pixel";
```

(`"pixel"` is the same clock as `tcon-ch0`.) `set_displl()` now succeeds —
`LCD1 DISPLL=1 CLK_SRC=00000022 DSI_GATE=00030000` — and the stock-trigger path finally executes.

### 5b. DE33 top channel muxes

`sun55i_de_enable()` pulses a bus reset and *then* read-modify-writes the mux registers, so the
RMW builds on zeros rather than the reset defaults and only its own nibble survives:

| detop | stock | computed by the driver |
|---|---|---|
| `0x28` port→chn | `0x000a9810` | `0x00000080` |
| `0x10` disp→tcon | `0x000032f1` | `0x00003211` (leaves disp1 pointed at our own TCON) |

### 5c. D-PHY analog — the captured values beat the decoded ones

See `kernel/patches/0040-*.patch`. The driver decoded ANA0/ANA4 and the HS_CLK_CONT bit from BSP
source; the capture disagrees, and the hardware sides with the capture — the PHY **status**
register converges on the stock value exactly:

| PHY | stock | decoded | captured |
|---|---|---|---|
| `0x04` TX_CTL | `0x10000000` (bit28) | `0x04000000` (bit26) | `0x10000000` |
| `0x4c` ANA0 | `0x00000077` | `0x00000044` | `0x00000077` |
| `0x5c` ANA4 | `0x84363538` | `0x844635ee` | `0x84363538` |
| `0x0e0` **status** | `0x15c55555` | `0x07700000` | **`0x15c55555`** |

### 5d. Current diff against the capture

Everything with a stock reference now matches: DETOP `000/004/008/010/014/018/01c/028`, PHY
`000/004/010/04c/050/054/058/05c/0e0`, TCON1 `040/044/048/04c/050/054/058/060` with `0x0fc`
(curline) advancing, and DSI1 `000`–`0d0` including every sync-timing register. TCON IRQ runs at
~3300 per boot with **zero** `flip_done` timeouts; `fb0` is 720x1280x32.

Status of the leftovers (updated 2026-10-19):

1. ~~**The RCQ has never been inspected.**~~ **CLOSED 2026-10-19.** `use_rcq` is a live module
   param and the MMIO-direct fallback works: with `use_rcq=N` the hardware read-back
   `hw_laddr=44100000` equals our framebuffer, so both commit paths latch. (The older note
   claiming "AHB never latches" predated the power-domain fix and was an artefact of it.)
   The RCQ was not the problem.
2. ~~**detop `0x018`**~~ **CLOSED 2026-10-19.** Not the layer framebuffer pointer — the real
   one reads back as `0x44100000` through the mixer's MMIO. The stock capture mislabelled it:
   nothing in our driver writes `0x18`, and the vendor's own sun55iw3 map has no `0x8018`
   entry (its neighbour `0x8014` is `DE_VER_CTL`, which also reads identically on both).
3. DSI `0x004` = `0x0a070000` vs stock `0x00020004`; DSI `0x2f4` = `0xf0000000` vs stock
   `0xf0050000`. (TCON1 `0x004` is `GINT0`, interrupt enables — expected to differ.)

### Note on the frame IRQ at idle

The TCON IRQ count is static at idle. That is expected for an 8080/CPU-IF panel — frames are
produced on commit, not free-running — so it is not in itself a fault. It does mean anything
relying on a steady vblank (fbcon damage) needs the per-frame re-trigger path.
`kernel/harvest-sun55i-de/vblank-tri-finish.candidate.patch` was previously inert because
`TRI_FINISH` never arrived; **it is now worth re-evaluating**, since the IRQ fires.

### 5e. ★ Root cause of "backlight only": the panel reset polarity

```
reset-gpios = <&pio 3 22 GPIO_ACTIVE_HIGH>;   /* held the DDIC in reset */
reset-gpios = <&pio 3 22 GPIO_ACTIVE_LOW>;    /* correct */
```

`trimui_panel_prepare()` asserts reset, waits 20 ms, releases, settles 120 ms, then sends the init.
With `ACTIVE_HIGH` that drives PD22 high briefly and then **low for the entire init**, so the DDIC
is held in reset throughout. It ignores every command silently (DCS writes are not acked, so
`accum_err` stays 0 and the panel still attaches), never starts its internal charge pump, and the
liquid crystal never modulates — the backlight passes through uniformly no matter what the DE,
TCON, DSI and PHY are doing.

The tell was one line of `/sys/kernel/debug/gpio`: the panel's reset was the only one on the board
without the `ACTIVE LOW` tag and the only one parked low.

```
gpio-118 (reset) out lo              <- panel PD22
gpio-7   (reset) out hi ACTIVE LOW
gpio-33  (reset) out hi ACTIVE LOW
gpio-37  (reset) out hi ACTIVE LOW
```

**How it was isolated:** not by more register diffing, but with the TCON's own pattern generator.
`TCON0_CTL` bits [2:0] are `src_sel` (`LCD_SRC_DE=0, COLOR_BAR=1, GRAYSCALE=2, BLACK_BY_WHITE=3,
BLACK=4, WHITE=5, GRID=7` in the BSP's `de_lcd.h`; the same field as mainline's
`SUN4I_TCON0_CTL_SRC_SEL_MASK`). Alternating solid white and solid black straight out of the TCON,
at full backlight in a darkened room, produced **zero** change — which exonerated the DE, mixer,
RCQ, layers and framebuffer in a single test and forced the search downstream of the TCON.

**What changed:** before the fix the panel showed backlight only; after it, white with a
visible fine grid, flicker along the right edge, and the DDIC warming. Backlight control
works throughout. We initially read this as "the panel displays, now tune the image" — but
see §5f: the grid is most likely the black matrix visible with the panel driven uniformly
white, and no pixel content has been demonstrated reaching it. The reset fix is still
correct and necessary (the DDIC was held in reset through every init it ever received);
it just is not sufficient.

### 5f. ★ The live blocker: the DDIC decodes nothing

Everything below was measured on hardware with a debug facility added to the panel driver (not
shipped here — it is four module params: send arbitrary DCS, read one byte back, choose LP/HS, and
append DCS to the end of the init. `prepare()` re-runs on every blank→unblank, so experiments cost
seconds rather than a rebuild. Worth re-creating if you are chasing something similar.)

**Commands can only be issued during `prepare()`.** `BASIC_CTL0 (0x010) = 0x00030001` — bit 0
`INST_ST` is permanently set while video streams, and `sun6i_dsi_inst_wait_for_completion()` polls
for it to *clear*, so every transfer attempted during video times out (`-110`) and aborts. This is
expected behaviour, not a fault; disabling the TCON does not free it. The encoder ordering is
correct (`drm_panel_prepare()` → `DSI_START_HSC` → `drm_panel_enable()` → `DSI_START_HSD`), so the
init does go out in the free window.

**In that free window, with `accum_err == 0` on every replay:**

| test | result |
|---|---|
| `mipi_dsi_dcs_read` of `0x04` RDDID, `0xda/0xdb/0xdc` ID1-3, `0x0a`, `0x0c`, `0x05`, `0x45` | `ret 1`, **value `0x00` for every one** |
| `0x28` DISPLAY OFF appended to the init (mandatory DCS) | **no visible change** |
| the entire init re-sent in **HS** instead of LP | **no visible change** |
| TCON pattern generator set to solid **black** (DE out of the path) | **no visible change** |

ID registers are never all-zero on a live DDIC, and eight different commands returning an identical
`0x00` means the host reports a byte while nothing drives the bus. Taken with the black-pattern
result, the conclusion is that the controller is not decoding the link at all — the panel sits at
its power-on white, and artefacts that move when TCON timing is changed are plausibly electrical,
not image content.

**Correction to an earlier claim in this document:** §6 previously said `sun6i_mipi_dsi` is
"TX-only, no LP-RX upstream". That is wrong — `sun6i_dsi_transfer()` handles `MIPI_DSI_DCS_READ`
for `rx_len == 1`. Reads are implemented; here they complete but return nothing, which is a far
more useful diagnostic than not having them.

**Ruled out:** PHY `ANA0 (0x4c)` has no bearing on command delivery (swept `0x44/0x77/0x00/0xff/
0x55/0xcc`, read-back confirmed, no change). DSI lane pinmux is identical to the vendor's
(`PD10`–`PD19`, function `dsi1`). `INST_JUMP_SEL (0x048) = 0x63f07602` matches the stock capture.
DSI `0x2f0`/`0x2f4` are read-only runtime fields — writes bounce off, so the stock values captured
there were snapshots, not configuration.

**On `block_space`:** the A523 trigger hardcodes `(84 << 16)`, i.e. `htotal - hdisplay - 40` in
pixel units, where upstream's `sun4i_tcon0_mode_set_cpu()` scales htotal into DSI byte-clock units
first (`844*24/(4*4) - 760 = 506`). 506 is the better-motivated value and changing it visibly
altered the artefacts — but given the conclusion above, that visible change is **not** evidence
that it fixed anything. Flagged, not claimed.

### 5g. ★ 2026-10-20: the pixel clock was wrong — and the panel decodes

The vendor device tree has a full panel node we had never read in full:
`trimui_smart_pro_source.dts`, `panel_0@0`, `compatible = "allwinner,panel-dsi"`. Its
`display-timings` are:

```
clock-frequency = 0x3b25180 = 62,017,920      (~62 MHz)
hactive 720  hfront 32  hsync 6  hback 18     -> htotal 776
vactive 1280 vfront 16  vsync 2  vback 34     -> vtotal 1332   => 60.0 Hz
```

We were driving **48 MHz / htotal 844 / vtotal 1309 / 43.45 Hz**.

**But only the clock was wrong.** The vendor driver transforms its DT timing into TCON registers
of 844/1309, and the stock register capture agrees — which is what our original porches already
produced:

| TCON reg | stock capture | vendor DT | ours (fixed) |
|---|---|---|---|
| `0x04c` htotal | `0x034b005b` = 844 | 776 | **`0x034b005b`** |
| `0x050` vtotal | `0x0a3a000c` = 1309 | 1332 | **`0x0a3a000c`** |
| `0x054` sync | `0x00030003` = 4/4 | 6/2 | **`0x00030003`** |

So the correct configuration is **the stock porches with the vendor's 62 MHz clock**. 62000 kHz
is used rather than 62017920 because `pll-video0-3x` is 372 MHz and 372/6 = 62.000 MHz exactly;
the TCON rejects a mode the clock tree cannot deliver.

With that in place the whole chain lands on the vendor's operating point for the first time:
`tcon-lcd1 = 62 MHz`, `hs_clk_rate = 372000000`, and the PHY DISPLL programs **N = 124** —
literally the figure this driver's own comment cites as the BSP reference ("n ~= 124 for 372
Mbps"). PLL locked, zero `flip_done` timeouts.

**Result on hardware:** with the correct clock *and* `block_space = 506`, the TCON's internal
patterns **invert on the panel** (white bars on a black source and the reverse) and the first
**colour** ever appears (faint magenta and yellow lines). The link decodes. This retires §5f's
conclusion that nothing was being decoded — that was correct on the evidence then available, and
wrong.

**What remains:** the transfer starves after a few lines at the top. Narrowed so far:
- `block_space` 84 -> 506 extends the decoded region; **700/1000/1266/1600 all plateau**, so the
  inter-packet gap is no longer the limit.
- the per-frame re-trigger is **not** the cause: `retrig_disable=Y`, a 17 ms period and the
  default were visually identical.
- `TRI1 = 0x4ff` confirms all 1280 lines are requested; `TRI2 = 0x013b000a`
  (start_delay 315, trans_start 10) has not been swept yet.

**A bug we shipped, now fixed:** earlier revisions of
`kernel/harvest-sun55i-de/drm-display-provisional.patch` carried a mode of `62000 / 776 / 1332`
while the `a523_trigger` guard in the same patch demanded `48000 / 844 / 1309`. Those can never
both hold, so anyone applying the patch as published had the A523 CPU-IF path rejected at
`mode_set`. The patch now ships 62000 with the stock porches, and the guard no longer pins the
clock or the porches at all (it checks only the active area, which is what the register table
below it actually fixes).

**Open caveat on §5e:** the vendor panel node declares `reset-gpios` with flags `0x00`, i.e.
`GPIO_ACTIVE_HIGH` — what we had before changing it to `ACTIVE_LOW`. The vendor's
`allwinner,panel-dsi` driver has its own `reset-num`/`reset-delay-ms` and may apply its own
polarity convention, so this is not proof the change was wrong, but the rationale in §5e is
weaker than it reads. To be re-settled.

## 6. Open questions — where fresh insight would help most

1. **Domain ↔ block mapping.** Which pck-600 domain actually contains TCON-LCD0/1, TCON-TOP and the
   DSI host on A523/T527 — `VO0`, `VO1`, or split? We pinned VI/VO0/VO1 always-on because the vendor
   DT does, but the cleaner fix is `power-domains = <&pck600 PD_VOx>` on the consumers. Does anyone
   have the authoritative mapping?
2. **Is this generic to sunxi genpd providers?** Any Allwinner SoC whose DT under-describes domain
   consumers should hit the same `sync_state()` sweep. H616/H6 DE33 users: does
   `pm_genpd_summary` change across your display probe?
3. **The DE33 RCQ list** (no longer blocking — see §5d). Still of interest: is there a
   known-good reference for an A523/H616 DE33 RCQ head array and list? We now run with
   `use_rcq=N` proven to work too, so the two can be compared.
4. ★ **A transfer that starves after a few lines (§5g)** — the panel now decodes, but only
   the first lines of each frame arrive. `block_space` past ~506 makes no difference, the
   per-frame re-trigger is not the cause, and `block_num` requests all 1280 lines. On a
   CPU-IF/8080 DSI panel, what else gates how much of a frame actually gets pushed?
5. ~~**detop `0x018`**~~ — closed, see §5d. Not a framebuffer pointer.
6. **In-band DSI TE** on `sun6i_mipi_dsi` / A523 — usable for per-frame sync without a GPIO?
   The panel enables TE (`DCS 0x35 SET_TEAR_ON`) but the vendor DTS routes **no TE pin**
   (DSI1 is exactly `PD10`–`PD19`, no `te-gpios`), so it is not available as a GPIO IRQ.
   (Note: this document previously claimed the host is TX-only. It is not — see §5f.)
7. Anyone on the sister **A133 Smart Pro** (same CPU-IF DSI, per-frame trigger) — how did you wire
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
- The D-PHY analog values are `kernel/patches/0040-phy-sun55i-dsi-combo-use-the-captured-analog-values.patch`,
  likewise verified to apply to the pristine v7.3-rc7 file.
- Every register figure quoted here is reproducible with `kernel/debug/dedump/` — build it against
  the same tree, `insmod` it on the device (it self-unloads) and read `dmesg | grep DEDUMP`, then
  diff against `docs/STOCK-DSI-REGISTERS.md`.
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
- *"The a523 CPU-IF config path is skipped because `tcon->pixel_clk` is NULL"* — the gating was
  real and is now fixed (§5a); it was **not** why the TCON read zero, though. The registers were
  unpowered.
- *"Supplying the `"pixel"` clock breaks the TCON bind, and the cause is
  `sun4i_tcon_of_get_id_from_port()` failing to resolve the id"* — **wrong on the cause**, and
  stated in an earlier revision of this document. The `-5` was `-EIO` from the register read-back
  in `sun8i_tcon_top_set_displl()`, i.e. the unpowered VO domain again. The id resolves correctly
  and the clock is now in the DT (§5a).
- *"A DE power-up transient browns out a shared rail / trips a board-level latch"* — wrong. There
  was no transient and no latch; `sync_state()` switched the domains off deliberately.
- *"Display and the side board are mutually exclusive on mainline"* — wrong, and now disproven on
  hardware: both run together.
- *"The panel displays; what remains is image quality"* — stated here earlier on
  2026-10-19 after the reset-polarity fix changed what the panel shows. Retracted the same
  day: see §5f. The change was real, the interpretation was not.

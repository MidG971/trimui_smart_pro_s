<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
# Trimui Smart Pro S — Mainline Display Bring-up Handoff

Status as of 2026-08-28. Written for an external developer picking up the
MIPI-DSI display bring-up. Everything else on the board (boot, storage,
network, WiFi/BT, audio, input, battery, gamepad) is already working on
mainline; **the display is the last major subsystem**, and it is ~90% done —
this document explains exactly where it stands and what is left.

---

## 1. Hardware

| Item | Detail |
|---|---|
| Device | Trimui Smart Pro S (model TG5050), landscape handheld |
| SoC | Allwinner **A523** (sun55iw3p1), quad Cortex-A55, Mali-G57 (Panfrost) |
| Display engine | **DE33 / "v35x"** (relative of DE2/DE3), driven by a Register Command Queue (RCQ) DMA |
| TCON | TCON-LCD1 (sun4i-family), feeds the DSI |
| DSI host | sun6i instruction-based MIPI-DSI (same IP as A64/A100), 4-lane + combo D-PHY |
| Panel | Sitronix **ST7703** (er68576 module), **720×1280 portrait**, non-burst video mode |

## 2. Software / kernel

- **Base:** Linux **7.2-rc3** (current upstream -rc is 7.2-rc7 — a trivial bump saved for the mainline-submission step).
- The A523 SoC support, the DE33 RCQ backend, the DSI host/PHY, the panel driver, and a set of DT + driver changes are carried as an out-of-tree working set on top of mainline.
- The DE33 RCQ backend (`drivers/gpu/drm/sun4i/sun55i_de.c`) is derived from the community **ut-slayer/orangepi-4a-mainline** port (same SoC, HDMI); it already carries the full RCQ-arm machinery (arm-lock, quiesce, hold-lists, FINISHED-W1C completion + retry, beam-gate).

### Test / debug setup
- Kernel is cross-built on a build host; the device runs a small Debian arm64 bring-up rootfs and is reached over the network (SSH).
- `sun8i_mixer` is **blacklisted at boot** (`modprobe.blacklist=sun8i_mixer`) and loaded by hand so the display pipeline is brought up under control:
  `modprobe sun8i_mixer use_rcq=Y tcon_curline_phys=0x55020fc`
- **`poke_wr`** — a debug sysfs param on `sun4i_tcon` for arbitrary 32-bit MMIO access (STRICT_DEVMEM-proof):
  - read:  `echo "0x05502040" > /sys/module/sun4i_tcon/parameters/poke_wr`  → value in `dmesg` (`POKE-MMIO`)
  - write: `echo "0x05502040 0x81000020" > .../poke_wr`
- `sun8i_mixer` params expose RCQ state: `use_rcq`, `arm_now`, `arm_busy`, `rcq_status`.
- `sun4i_tcon` param `dsi_video_mode` (default `Y`) selects TCON HV free-run vs CPU-IF (`N`).

### The stock "oracle"
The device's original vendor firmware (Allwinner **Longan BSP, kernel 5.15**) lives on the eMMC. Booting it (SD removed) gives `adb` + `devmem` access to the **known-good register state** while the panel is lit. These captures are the ground truth for every fix below:
- `docs/STOCK-DSI-REGISTERS.md` — DSI host + combo-PHY + TCON0 + DE33-top
- `docs/STOCK-TCONTOP-DSIFEED.txt` — tcon-top + TCON0 CPU-IF trigger + DSI feed
- The Allwinner display BSP (`disp2`, `lowlevel_v35x`) is the authoritative source for DE33/TCON/DSI register *semantics* (`de_top.h` `enum de_irq_flag`, `de_lcd.h` `enum __lcd_irq_id_t`, `de_fmt.c`, etc.).

## 3. The pipeline

```
 DRM ─► DE33 mixer (0x5000000) ─► tcon-top (0x5500000) ─► TCON0/LCD1 (0x5502000) ─► DSI host (0x5508000) ─► D-PHY (0x5509000) ─► ST7703 panel
        └ RCQ DMA applies a DRAM                          └ HV free-run OR             └ sun6i DSI, 4-lane,
          shadow of OVL/BLD/FMT                             CPU-IF (8080) trigger        non-burst video mode
          on each frame
```

- **DE33 top** (0x5008000): `GLB_CTL` @0x5008100, `GLB_STS` @0x5008104, `RCQ_CTL` @0x5008110, `OUT_SIZE` @0x5008108, the DE→TCON / channel muxes @0x5008010/24/28.
- Datapath blocks live in the mixer region: **OVL** (layer) @0x51c1000 (phys chan 6), **BLD** (blender) @0x5281000, **FMT** (formatter) @0x5285000. They are applied **only** via the RCQ (direct MMIO writes go to a shadow that does not latch).

## 4. Bring-up journey — blockers solved, in order

### 4a. DSI didn't transmit — SOLVED
`curr_line` was frozen at line 1. Root causes (found via the stock oracle):
1. panel declared `MIPI_DSI_MODE_VIDEO_BURST`; stock runs **non-burst sync-mode** video.
2. wrong panel timing.
3. combo-PHY analog + HS-clock-continuous bit.

Fix: drop `MODE_VIDEO_BURST`; timing `htotal=844, vtotal=1309, hsync=4, vsync=4`; PHY `ANA0=0x77`, `ANA4=0x84363538`, `TX_CTL` HS-clk-cont **bit28**; TCON DSI-video path (`0x03c=1` "normal FIFO", the sync-timing regs). **Result:** DSI transmits valid video, `curr_line` sweeps 0–1309, panel powers up.

### 4b. Framebuffer outside the DE DMA aperture — SOLVED
Every DE datapath register verified correct against the BSP, yet black. **Root cause:** the A523 DE DMA reaches only low DRAM (**~0x43000000–0x4b000000**); the drm_gem_dma scanout buffer landed in high buddy pages (`0x5x–0x6x000000`), outside the aperture → the DE fetched **zeros** → black.
(Stock's layer-fb pointer is "high" too, but stock runs the **IOMMU** which translates it to a reachable page; without the IOMMU our pointer is raw physical and must be low.)

**Fix (ut-slayer patch 0044 recipe):** a `linux,cma-default` reserved-memory CMA pinned in-aperture:
```dts
reserved-memory {
    cma_low: linux,cma {
        compatible = "shared-dma-pool";
        reusable;
        size = <0x0 0x04000000>;                 /* 64 MiB */
        alloc-ranges = <0x0 0x43000000 0x0 0x05000000>;
        linux,cma-default;                        /* ← the key */
    };
};
&mixer0 { memory-region = <&cma_low>; };
```
**Result on HW:** fb `dma_addr = 0x44200000` (in-aperture), the DE fetches real pixels.
**Gotcha for others:** a per-device `memory-region` on the display-engine did **not** work (the write-combine scanout alloc bypassed it), nor did the cmdline `cma=SIZE@BASE`. Only `linux,cma-default` routed the scanout.

### 4c. DE datapath never latched — DE IRQ enables — SOLVED
FB in-aperture + white + DSI transmitting, still black. The RCQ arm never completed (`arm_now=0`); BLD/FMT stayed unlatched.
**Root cause:** the driver wrote `GLB_CTL(0x5008100) = RT_EN (bit0)` only — it never set the DE interrupt enables. BSP `enum de_irq_flag` (GLB_CTL): `FRAME_END=bit4`, `RCQ_FINISH=bit6`, `RCQ_ACCEPT=bit7`. On this hardware the **RCQ_FINISH status** (GLB_STS `0x5008104` **bit2**) only latches when its enable is set, so the driver's polled FINISHED check never tripped → the arm was skipped forever.

**Fix:** `GLB_CTL = RT_EN | FRAME_END | RCQ_FINISH | RCQ_ACCEPT` (**0xD1**), in both GLB_CTL writers (`sun55i_de.c` enable path + `sun8i_mixer.c` DE33 init). No DE IRQ is *requested* anywhere (the driver polls), so no interrupt storm.
**Result on HW:** `arm_now=4`, `rcq_status` shows `RCQ_FINISH`, and the whole datapath latches (OVL `0xff000401`, BLD `0x101`, FMT/BLD/GLOBAL size `0x04ff02cf`). This `.ko` is installed on the device.

### 4d. TCON→DSI pixel FEED — THE CURRENT BLOCKER
Datapath fully latched, fb white + in-aperture, DSI scanning its own timing — still black. The **DSI transmit FIFO** (`0x55082f4`) is **empty** (`0xf0000000`) vs stock's non-zero (`0xf0280000`). **The TCON is not pushing pixels into the DSI**, so the DSI transmits blanks.

Key insight from the stock capture: stock feeds the DSI via the TCON **CPU-IF trigger** and does **not** use the TCON vblank (`GINT0` interrupt-enables = 0; the completion signal is the DE `RCQ_FINISH`, which 4c gives us). Our driver runs the TCON in **HV free-run**, which generates timing but never feeds the FIFO.

**Mechanism proven:** poking stock's CPU-IF feed values onto a running mainline made the FIFO **fill** (`0xf0000000` → `0xf0f10000`). So the feed works with the right values — our `mode_set_cpu` (the CPU-IF path, `dsi_video_mode=N`) simply emits the **wrong** values:

| reg | offset | STOCK (works) | OURS (mode_set_cpu) | note |
|---|---|---|---|---|
| dclk | `0x5502044` | **`0xF0000001`** | `0x80000004` | **div=1 + 4 dclk_en** vs our div=4, 1 en — *the crux (clock)* |
| 3d_fifo | `0x550203c` | `0x00000000` | `0x00000001` | we set it; stock leaves it 0 |
| TCON0_CTL | `0x5502040` | `0x81000020` | `0x81000000` | bit5 |
| CPU_IF | `0x5502060` | `0x10010005` | `0x10010005` | ✅ match |
| TRI0 | `0x5502160` | `0x005402CF` | `0x01f902cf` | block_space differs (size 0x2cf=720 ok) |
| TRI1 | `0x5502164` | `0x024904FF` | `0x006104ff` | high field `0x249` vs `0x061` (num 0x4ff=1280 ok) |
| TRI2 | `0x5502168` | `0x013B000A` | `0x11d3000a` | start_delay `0x13b` vs `0x11d3` |
| tcon-top | `0x550000c/1c/20` | `0x22 / 0x20 / 0x20000` | `0 / 0x01 / 0x10000` | DE→TCON→DSI routing |
| GINT0 | `0x5502004` | `0x00008A02` (en=0) | `0xc8000001` | stock enables **no** TCON IRQ |

**The crux is the dclk clock.** Poking the divider *register* is not enough — the actual clock *rate* stays free-run's, so the pixel clock is mismatched and the feed is erratic (fills one run, empty the next). It must be set correctly in the driver (`clk_set_rate` + the divider constraints + the 4 dclk_en bits).

## 5. Current state

**Working:** boot, network, WiFi/BT/audio/input/battery/gamepad. DSI panel powers up and transmits. DE33 pipeline fully configured **and latched** (arm completes). FB in-aperture and reached by the DE.

**Not working:** the final TCON→DSI pixel feed. In HV free-run the FIFO never fills; stock's CPU-IF feed values fill it when poked, but our `mode_set_cpu` emits wrong values (above), and the erratic dclk clock makes the poke approach unstable.

**In progress:** rewriting `sun4i_tcon.c :: sun4i_tcon0_mode_set_cpu()` to emit stock's CPU-IF configuration properly — the dclk clock (div=1 / 4 dclk_en), `3d_fifo=0`, `TCON0_CTL` bit5, the TRI trigger values, and the tcon-top routing — so that `dsi_video_mode=N` yields datapath-latch **and** feed in one stable modeset.

## 6. Where to look

| File | Role |
|---|---|
| `drivers/gpu/drm/sun4i/sun4i_tcon.c` | TCON timing; `sun4i_tcon0_mode_set_dsi_video` (free-run) + `sun4i_tcon0_mode_set_cpu` (CPU-IF) — **the current work is here** |
| `drivers/gpu/drm/sun4i/sun55i_de.c` | DE33 RCQ backend (datapath, arm, GLB_CTL DE-IRQ fix) |
| `drivers/gpu/drm/sun4i/sun8i_mixer.c/.h` | mixer init + register defs (DE33 GLB_CTL, RCQ status bits) |
| `drivers/gpu/drm/sun4i/sun6i_mipi_dsi.c` | DSI host |
| `drivers/gpu/drm/panel/panel-trimui-smart-pro-s.c` | ST7703 panel (non-burst, timing) |
| `drivers/phy/allwinner/phy-sun55i-dsi-combo.c` | combo D-PHY |
| board DTS `sun55i-a523-trimui-smart-pro-s.dts` | `cma_low`, mixer memory-region |
| `docs/STOCK-DSI-REGISTERS.md`, `docs/STOCK-TCONTOP-DSIFEED.txt` | stock oracle captures |
| Allwinner BSP `.../disp/de/lowlevel_v35x/` | vendor register semantics (de_top.h, de_lcd.h, de_dsi.c, de_fmt.c) |

## 7. Test procedure for the feed fix
1. Build `sun8i-mixer.ko` (+ the tcon changes) on the build host.
2. Cold-boot mainline (warm-reboot is broken — see note), install the module.
3. `echo N > /sys/module/sun4i_tcon/parameters/dsi_video_mode` (CPU-IF), then `modprobe sun8i_mixer use_rcq=Y tcon_curline_phys=0x55020fc`.
4. Verify: `TCON0` regs match the STOCK column; `arm_now > 0`; **DSI FIFO `0x55082f4` non-zero and changing**; fill `/dev/fb0` white → panel lights.

Notes: warm reboot is not yet working (A523 has no PSCI reset; the sunxi watchdog restart is in-tree at priority 200 and the config is built-in — the remaining issue is likely SPL/DRAM re-init on warm reset, diagnosable over serial). Cold-boot is reliable.

## Addendum (2026-08-28, later) — feed fix attempt 1
First `mode_set_cpu` dclk fix (div=1, drop /4, set 4 gate bits, 3d_fifo=0) built + tested on HW:
- The **4 dclk gate bits [31:28]** now set correctly, but the **divider came out 0 not 1** (the clk framework's
  rate math) — needs a direct register write to force `div=1` (`0xF0000001`).
- **`arm_now=0` in pure CPU-IF mode**: the beam-gated RCQ arm needs the TCON curr_line advancing; it does in free-run
  (`arm_now=4`) but stalls in CPU-IF. So the pure-CPU-IF path must also solve the arm/beam-gate.
- **The combined two-phase path works best**: free-run bring-up (datapath latches) → then poke the CPU-IF feed values
  → gives datapath-latch AND FIFO-fill together (a brief picture was seen). Recommended direction: either implement
  the two-phase modeset, or fix the CPU-IF arm stall + force the dclk divider.

## Addendum 2 (2026-08-28) — feed can be sustained, but three intertwined issues remain
Extensive on-HW poking established the full recipe and its remaining problems:
- **The feed CAN be sustained.** Combined path: free-run bring-up (datapath latches) → poke the CPU-IF feed values
  **with the AUTO bit (CPU_IF bit17 = 0x10030005)** → the DSI FIFO stays full (0x55082f4 ≈ 0xf1950000, sustained
  across seconds). Without AUTO the trigger fires once and the FIFO drains. So AUTO gives a continuous trigger.
- **Problem A — the RCQ arm is flaky.** The free-run datapath latch (`arm_now`) is non-deterministic: sometimes 4
  (latched, BLD/FMT applied), sometimes 0 (not). When 0 the DE outputs black and the sustained FIFO just carries
  black → black panel. Likely a race in the RCQ arm because the TCON vblank never fires (arm relies on the hrtimer
  backstop + beam-gate on the TCON curr_line 0x55020fc). Needs a deterministic arm path.
- **Problem B — dclk rate.** Poking `dclk=0xF0000001` (div=1) on the free-run parent gives ~265 MHz (4× the 66 MHz
  pixel clock). `0xF0000004` (div=4, +4 gate bits) keeps 66 MHz. The 4 gate bits [31:28] ARE needed (mainline sets
  only bit31); the divider must stay so the *output* is the pixel clock. Getting this right in the driver (not a
  poke) is required — the clk framework gave div=0 on the first driver attempt.
- **Problem C — AUTO trigger is free-running, not DE-synced.** Stock's CPU_IF is `0x10010005` (no AUTO); its trigger
  is driven per-frame by the DE. Our AUTO trigger free-runs and is not synchronized to the DE frame output, which may
  produce torn/unsynced frames even when the FIFO is full.
**Bottom line:** the mechanism is fully understood; it now needs *driver-side* integration — a deterministic RCQ arm,
the dclk with 4 gate bits at the pixel-clock rate, and ideally a DE-synced CPU-IF trigger (or a validated AUTO one).
This is real driver work across sun4i_tcon.c + sun55i_de.c, iterating with cold-boot tests, not runtime pokes.

## Addendum 3 (2026-08-28, post-lunch) — pipeline proven end-to-end; last piece = feed/transmit rate balance
On a **clean cold-boot** with dclk `0xF0000001` (stock exact), the pipeline moves white pixels **end to end**:
- `arm_now=4` reliably (the earlier flakiness was a degraded 3.4 h poked state, not a code bug).
- DE reads white (OVL LADDR `0x44200000`, fb0=white); TCON scans (curr_line cycles); DSI scans (curr_line cycles);
  FIFO fluctuates/drains (`0xd7`/`0xcd`/`0x4c`) — the DSI is transmitting.
- **Yet the panel is black.** The DSI FIFO **backs up** with stock's DE-driven `CPU_IF=0x10010005` (climbs `0x77`→`0xdf`
  vs stock steady `~0x28`): the DSI drains slower than the TCON feeds → a **rate mismatch** between the TCON dclk feed
  and the DSI HS transmit (D-PHY PLL). The dclk *register* matches stock but the *parent clock rates* likely differ.
**Next:** capture stock's TCON dclk parent + DSI PLL/D-PHY HS rate (CCU / clk_summary on stock), match our DSI HS
bit-rate to the feed so the FIFO balances (~0x28); and verify the panel display-on state. Driver-side CPU-IF recipe:
dclk `0xF0000001`, `3d_fifo=0`, `TCON0_CTL=0x81000020`, `CPU_IF=0x10010005` (no AUTO), TRI `0x005402CF/0x024904FF/
0x013B000A`, tcon-top `0x0c=0x22 / 0x1c=0x20 / 0x20=0x20000`.

## Addendum 4 (2026-08-28) — ROOT CAUSE: DE33 fetches layer from detop 0x5008018 = 0x6d5f4000 (out of aperture)
The panel is black because the DE33 fetches the layer framebuffer from the **detop** register `0x5008018`, which holds
`0x6d5f4000` — the vendor **bootloader splash** address, **outside the DE's physical fetch aperture** (`0x43000000–
0x4b000000`, no IOMMU). Everything else is proven correct:
- Driver allocates the fb **in-aperture** (`gem->dma_addr = 0x44200000`, cma_low) and the RCQ **correctly applies it**
  to the OVL layer block: `RCQ-RB: hw_laddr=44200000 shadow=44200000 hw_attctl=ff000401 use_rcq=1`.
- **But** the driver programs the layer in the `0x5100000` mixer-engine region (`0x51c1010`), which **stock leaves
  all-zero** — this DE33 uses the detop `0x5008000` region for the real layer/output. The driver never writes the
  detop layer address (`0x5008018`), so it keeps the bootloader's `0x6d5f4000`. `0x6d5f4000` is **not** in the driver
  source (grep clean).
- `0x5008018` is RCQ-reloaded, so a runtime poke doesn't stick (verified).
**Fix (driver):** route `gem->dma_addr` into the detop layer-address (`0x5008018`) via the correct RCQ fb-address
block (or a direct detop write), and reconcile the detop map against the stock capture (`docs/STOCK-DSI-REGISTERS.md`,
`0x5008000` block) + BSP `lowlevel_v35x` + ut-slayer `sun55i_de.c`. Also check size `0x5008108` (ours `0x04ff02cf` vs
stock `0x02CF04FF`) and `0x5008010` (ours `0x3211` vs stock `0x32F1`). The `0x5100000` OVL writes may be vestigial here.

## Addendum 5 (2026-08-28) — RETRACT Addendum 4; honest blocker restated
**Addendum 4's "DE33 fetches layer from detop 0x5008018 (out of aperture)" is WRONG and retracted.**
`0x5008018 = 0x6d5f4000` is the RCQ/reserved-mem buffer pointer — **identical on stock and mainline**, so it is not
the layer fb and not a bug. The `PORT2CHN_MUX` lead is also retracted: the driver's `0x80` already routes our single
UI layer (nibble[1]=8 = logic-chn-1 → phys-chn-6); the extra nibbles in stock's value are for unused channels. On-device
mux poke (0x80→0xa980) changed nothing, and that test was invalid anyway (DSI FIFO was empty in the driver's default
HV mode).
**Honest blocker (unchanged):** the DE33 composites a **black** frame although (a) the layer fb is correctly set at OVL
`0x51c1010 = 0x44200000` (in-aperture, cma_low, RCQ-applied — RCQ-RB `hw_laddr=44200000 hw_attctl=ff000401`), (b) the
RCQ works, (c) with the CPU-IF feed recipe the DSI transmits stock-identically. No flip_done/vblank errors logged.
**Where to look next (needs driver-level work, not pokes):** the RCQ reloads *only the framebuffer-address blocks*
(sun55i_de.c comment). The layer ATTR / blender-route / FMT-output config is applied once at commit — verify the DE's
*active* compositing state actually took (dump the RCQ block payload in DRAM the DE applies, vs the MMIO shadow), and
how/whether the layer-ATTR + blender blocks get (re)loaded after `sun55i_de_bus_reset()`. This driver is ut-slayer's
(orangepi-4a-mainline sun55i_de.c) — engaging them / linux-sunxi is a strong path; the DE33 compositing bring-up is
their domain.

## Addendum 6 (2026-08-28) — DSI transmit REPRODUCIBLE; black narrowed to DE layer DMA fetch (not transparency/coherency/address)
### DSI transmit is now a reliable recipe (the earlier feed flakiness solved)
On a CLEAN cold boot: `modprobe sun8i_mixer` → `arm_now=4` reliably → apply the CPU-IF feed by MMIO poke (all plain
MMIO, latch immediately):
- tcon-top: `0x550000c=0x22`, `0x550001c=0x20`, `0x5500020=0x20000`
- TCON0: `0x5502000=0x80000000`(GCTL), `0x550203c=0`(3d_fifo), `0x5502040=0x81000020`(CTL/8080),
  `0x5502044=0xF0000001`(dclk), BASIC `0x5502048=0x02CF04FF/0x550204c=0x034B005B/0x5502050=0x0A3A000C/0x5502054=0x00030003`,
  `0x5502004=0x00008A02`(GINT0)
- ★ **the two pieces I'd been missing:** TRI trigger-timing `0x5502160=0x005402CF / 0x5502164=0x024904FF /
  0x5502168=0x013B000A`, and CPU_IF **with AUTO** `0x5502060=0x10030005` (0x10010005 no-AUTO does NOT fill the FIFO).
Result: DSI FIFO (`0x55082f4`) fluctuates 0x35..0xfd = **DSI transmitting**; DSI+PHY byte-identical to stock.

### Theories RULED OUT this session (with on-device evidence)
- **Transparent layer — NO.** Set blender BG = RED in the driver (`de_bg_color=0xffff0000`, active `0x5281088=0x00ff0000`).
  With DSI transmitting + white fb, panel is **BLACK, not red**. A transparent layer would show the red BG. So the layer
  is **OPAQUE** (it covers the BG) but its content is **black**.
- **Coherency — NO.** Wrote white via both `dd`(write()) and `mmap`+`msync` (coherent) → still black.
- **Address mismatch — NO.** DRM state: exactly one framebuffer (fb-42, fbcon = `/dev/fb0`), `dma_addr=0x44200000`,
  size 3686400 = the DE layer address `0x51c1010` exactly. Same buffer.
- **attctl ALPHA_MODE detail:** driver computes `attctl=0xff000403` (global-alpha bit set — confirmed by an added DBG
  print), but the hardware register reads `0xff000401` (bit1 dropped). So the DE33's alpha-mode field is not at bit1
  where the driver assumes (reserved) — but the red-BG test proves the layer is opaque regardless, so this is a detail,
  not the bug. BSP `sunxi_display2.h`: alpha_mode 0=pixel/1=global/2=mixed (matches driver intent).

### ★ NARROWED ROOT CAUSE: the DE composites the layer OPAQUE but its DMA fetch returns BLACK
The buffer at `0x44200000` holds white (written via two coherent paths, confirmed same buffer), the DE's layer addr =
`0x44200000`, the layer is opaque and composited — yet the output is black. => the DE33 **layer DMA fetch is not
delivering the framebuffer content** (reads black/zero). MBUS clock is on (`0x5008008=1`). Next suspects: a missing
layer fetch-enable / OVL_PARA win-size / fetch DMA underrun, or the fetch reading the wrong stride/format.
### In-flight test (awaiting cold boot): driver fills the committed plane's `gem->vaddr` white (coherent) + reads back
the first pixel at commit. WHITE on panel => fetch works (the `/dev/fb0` write path was the culprit); BLACK => the DE
DMA fetch is genuinely broken.
### NOTE: the deployed sun8i-mixer.ko carries DIAGNOSTIC edits to REVERT before any commit: `de_bg_color=0xffff0000`
(red), the one-shot `DBG linear attctl` print, and the `DBG FILL` gem-buffer memset+readback.

## Addendum 7 (2026-08-28) — PROVEN: the DE layer DMA fetch returns black (buffer verified white by the driver itself)
Definitive test: added a driver hook that fills the committed plane's buffer white via its own coherent `gem->vaddr`
and reads back the first pixel at commit. On a clean boot it logged:
`DBG FILL dma=0x0000000044200000 first=ffffffff` — i.e. the DRIVER wrote white to `0x44200000` and read white back.
That IS the DE's layer address (`0x51c1010=0x44200000`). With the DSI transmitting (feed recipe) and `arm_now=4`, the
panel is **BLACK** (re-confirmed twice, incl. an independent mmap+msync white fill). So:
★★★ The DE33 **layer DMA fetch does not deliver the framebuffer content** — buffer holds white, DE reads black.
Full fetch geometry verified CORRECT and live: ATTCTL `0xff000401`(en/opaque/fmt4), MBSIZE `0x04ff02cf`,
MBCOOR `0`, PITCH `0xb40`, TOP_LADDR `0x44200000`, OVL_PARA HADDR `0`, **WIN_SIZE `0x04ff02cf`**, DS `0`.
DE detop: RESET=1, CLK=1, MBUS_CLK=1 (all un-gated). GLB_STS `0x5008104=0x111`.
### Last test in this session (result = the next thing to record): disabled the UI layer (poke BLD PIPE_EN
`0x5281000=0`, stuck) so the blender emits its RED background (`0x5281088=0x00ff0000`), DSI transmitting.
- If panel shows **RED** → the whole output path (blender→FMT→tcon-top→TCON→DSI→panel) works; the bug is isolated to
  the **layer DMA fetch/MBUS read of cma_low**.
- If **BLACK** → a stage *after* the blender (FMT/output) is zeroing everything.
### Where to look next (fetch is the prime suspect): the DE MBUS master's access to the cma_low reserved region
(`0x44000000-0x47ffffff`) — verify dma-ranges (dma_addr==phys for the mixer), MBUS access-control/QoS for the DE
master port, and whether the v35x layer-fetch DMA (distinct from the RCQ DMA) has its own reach limit or an enable the
driver misses. Also re-check the FMT block (`0x5285000`) for a CSC/limit that could clip. Everything else is proven.
### DIAGNOSTIC edits still in the deployed sun8i-mixer.ko to REVERT before commit: `de_bg_color=0xffff0000`(red),
the `DBG linear attctl` print, and the `DBG FILL` gem-buffer memset+readback.

## Addendum 8 (2026-08-29) — disable-pipe + BG=white poke = still BLACK → fetch-vs-output-stage now AMBIGUOUS
Resumed on a clean cold boot (module + feed recipe, DSI transmitting, `DBG FILL first=ffffffff` = buffer white).
Test: poked BLD `PIPE_EN 0x5281000=0` (layer off) then BG `0x5281088=0x00ffffff` (white). Both pokes HELD
(stable across reads; `arm_now` steady at 4 = RCQ not re-arming). **Panel still BLACK.**
Two readings, and a plain poke can't decide between them:
  (a) **pokes ARE live** (arm stable, values held) → the blender is emitting solid white yet nothing reaches the
      panel ⇒ the **OUTPUT STAGE (FMT `0x5285000` / DE→tcon-top→TCON) zeros everything** — and Addendum 7's
      "layer DMA fetch" conclusion would be only part of the story (the output stage kills even the background).
  (b) **pokes are NOT live** (the DE composites from an RCQ-latched state, MMIO ≠ active) → the layer stayed
      enabled/opaque and every poke test here was moot; Addendum 7 (fetch returns black) still holds.
★ DECIDER (next session, driver-side = reliable, not pokes): in `sun55i_de_layer_update` set BLD `PIPE_EN=0` AND
`de_bg_color=0x00ffffff` (white) via `de_blk_write` so the RCQ applies them. Rebuild → cold-boot → feed →
look: **WHITE = output path works** (so the real bug is the layer DMA fetch, Addendum 7) ; **BLACK = the
output/FMT stage is dead** (new direction — audit FMT `0x5285000` CSC/limit/enable vs stock, and the DE→TCON
data path). Note the FIFO stays fed in both cases (it carries whatever the DE emits, black or not).
### Reminder: deployed sun8i-mixer.ko still has the diagnostic edits to REVERT before commit (red BG, DBG
attctl print, DBG FILL memset+readback).

## Addendum 9 (2026-08-30) — ★ CORRECTION: the OUTPUT STAGE is dead, not the layer fetch
Reliable driver-side decider (RCQ-applied, not pokes): forced BLD `PIPE_EN=0` + `de_bg_color=0xffffffff` (white) in
the driver, rebuilt, clean cold boot, feed applied. Verified live: `0x5281000=0` (pipe off), `0x5281088=0x00ffffff`
(white BG), `arm_now=4`, DSI transmitting. The blender is emitting a SOLID WHITE frame through the RCQ — **panel BLACK.**
⇒ The DE **output is black regardless of what the blender composites** (layer OR background). So the layer DMA fetch
(Addendum 7) was a **red herring** — the output would be black even with a perfect fetch. The break is downstream of
the blender: the **FMT output formatter (`0x5285000`)** or the blender→FMT→DE-out→tcon-top handoff. The DSI FIFO stays
fed (it carries the DE's black pixels), so data flows — it's just black. Addendum 7's "fetch" conclusion is RETRACTED
as the root cause; it may still be a real secondary bug but it is not why the screen is black.
### NEXT: audit the FMT block `0x5285000` (LIMIT_Y/C0/C1, SIZE, out_ctl/csc/enable) live vs the driver's intent and vs
stock (docs/STOCK-DSI-REGISTERS.md DE dump); also the blender CK/out_ctl (`SUN55I_BLD_CK_OUT_CTL`) and whether the DE
real-time output to tcon-top is actually enabled. Everything up to the blender output is now the suspect surface.

## Addendum 10 (2026-08-30) — ★★ LEADING HYPOTHESIS: wrong datapath region (DE33 scans 0x5008000, driver drives 0x5100000)
FMT is fine (live: CTL=0/RGB, SIZE 0x04ff02cf, LIMIT 0x0fff0000 full, 8-bit/444) — so Addendum 9's "FMT" suspect is
cleared. The real pattern, consistent with the whole session:
- Our `0x5100000` mixer-engine datapath (OVL 0x51c1000 / BLD 0x5281000 / FMT 0x5285000) is **verified correct**, RCQ
  applies it (arm_now=4), yet a driver-forced **solid-white blender never reaches the panel** (Addendum 9).
- **Stock's `0x5100000` region is ALL ZERO while displaying** (docs/STOCK-DSI-REGISTERS.md). Stock's entire display
  config lives at **`0x5008000`** (fb addr 0x5008018, blend 0x5008060, alpha 0x5008080/88, size 0x5008108, mux 0x5008028).
- OUR live `0x5008000`: blend/alpha MATCH stock, but **fb addr 0x5008018=0x6d5f4000 is the stale bootloader splash
  addr (OUT of the DE fetch aperture; should be our 0x44200000), size 0x5008108=0x04ff02cf vs stock 0x02CF04FF,
  mux 0x5008028=0x80 vs stock 0xA9810.**
⇒ **The DE33 almost certainly scans out from the `0x5008000` datapath, NOT the `0x5100000` mixer-engine the driver
programs.** That single fact explains: why nothing we ever poked/committed on 0x5100000 changed the output; why a
solid-white blender is still black; why the buffer-fill "fetch" test (Addendum 7) was black (the DE fetches
0x5008018=0x6d5f4000, not our 0x44200000). 0x5008018 does NOT stick to a poke → a **separate DE33 RCQ/reload**
(bootloader-seeded, unmanaged by our driver) likely keeps rewriting the 0x5008000 datapath.

### ⚠ FLIP-FLOP HISTORY (do not re-litigate blindly): Addendum 4 first proposed "DE33 fetches from detop 0x5008018";
Addendum 5 RETRACTED it (claimed 0x5008018 = RCQ buffer, "same on both"). That retraction was likely WRONG — the
value is the same on both because it's the shared **bootloader splash fb**, and stock actively uses it (via IOMMU
IOVA) while we leave it stale. Addendum 10 resurrects Addendum 4 with the added evidence that the ENTIRE 0x5100000
datapath (not just the addr) is inert for output, and that 0x5008000 carries stock-matching blend/alpha.

### ★ NEXT (the crux — needs BSP/architecture, not pokes): from `/root/trimui-display/aw-bsp-drivers` (de_rtmx.c /
de_top.c / de_ovl for v35x/de352) determine how the BSP drives the `0x5008000` datapath — is there a mixer-engine↔de33
**output-source select**, a **second (de33) RCQ** whose head/blocks target 0x5008000, and where the layer fb addr /
size / mux actually get written. The fix is to make our driver program the `0x5008000` datapath (fb=0x44200000 in-ap,
size=0x02CF04FF, mux=0xA9810, …) the way stock does — OR to flip the output select so `0x5100000` drives the panel.
Confirm cheaply by booting stock (eMMC) and re-reading `0x5100000` (expect all-zero) + full `0x5008000`.
### Diagnostic edits still in the .ko to revert: forced pipe-off, white de_bg_color, DBG attctl print, DBG FILL.

## Addendum 11 (2026-08-30) — BSP DIVE results (lowlevel_v35x): regions CONFIRMED correct; Addenda 9&10 corrected; clean next test
Source: `/root/trimui-display/aw-bsp-drivers/.../disp2/disp/de/lowlevel_v35x/de35x/` (de_top.[ch], de_rtmx.c, de_bld.[ch], de_bld_type.h).
### Register map — our driver's regions are RIGHT (Addendum 10 "wrong region" RETRACTED):
- `DE_TOP_REG_OFFSET=0x8000`, **`DE_TOP_REG_SIZE=0x0220`** → DE_TOP = 0x5008000..0x5008220. So 0x5008018/28/108 are DE_TOP
  control regs, NOT layer/blender data (kills "0x5008018=fb addr" from Addenda 4&10; Addendum 5 was right it's DE_TOP).
- `DE_CHN_OFFSET(chn)=0x100000+0x20000*chn`; chn6 = 0x51C0000, `CHN_OVL_OFFSET=0x1000` → OVL 0x51C1000 ✓ (our OVL_BASE).
- `DE_DISP_OFFSET(disp)=0x280000+0x20000*disp`; disp0 blender(+0x1000)=0x5281000 ✓, FMT(+0x5000)=0x5285000 ✓.
- DE_TOP regs: DE2TCON_MUX=0x8010, DE_VER_CTL=0x8014, **CHN_MUX(VCH2CORE=UCH2CORE)=0x8024**, PORT2CHN_MUX(disp)=0x8028+disp*4,
  BUF_DEPTH=0x8050(=0x6000 ✓), RTMX_GLB_CTL=0x8100, GLB_STS=0x8104, **RTMX_OUT_SIZE=0x8108**, AUTO_CLK=0x810C, RCQ_CTL=0x8110.
  So our 0x5008108=RTMX_OUT_SIZE (ours 0x04ff02cf portrait vs stock 0x02CF04FF landscape = just orientation).
### Blender semantics (de_bld_type.h `bld_en_ctl_reg`): bit0-5 = pipeN_fcolor_en, bit8-13 = pipeN_en. Our PIPE_EN=0x101
= pipe0_en(bit8) + pipe0_fcolor_en(bit0) — MATCHES the BSP (`de_bld_set_pipe_ctl`: dwval=0x1 | enable<<(i+8)). So our
blender pipe-enable is correct. ⇒ **Addendum 9's `PIPE_EN=0` decider is INVALID** (it turned OFF pipe0 entirely; the
"black" there proves nothing). DISP post-proc all OFF (gamma/dither/deband/drc/ksc=0), FMT correct, de2tcon disp0→tcon1.
### ★ CLEAN NEXT TEST (the real decider — do first next session): use the per-pipe FILL COLOR
(`de_bld_set_pipe_fcolor`: pipe0_fcolor_en=1 + `pipe0 fcolor` reg = **0x5281004** = white 0x00ffffff), pipe0_en=1, via
the DRIVER (RCQ). Blender then emits solid white with **NO layer fetch**. WHITE on panel ⇒ output path
(blender→FMT→DISP→tcon-top→TCON→DSI) works and the bug is the LAYER FETCH/coverage (revives Addendum 7); BLACK ⇒
the DISP→TCON output is genuinely dead. Either way it's unambiguous (BSP-supported path, unlike the pipe-off test).
### Secondary BSP diffs to try if fill-color=white works (i.e. fetch is the bug): (1) CHN_MUX 0x5008024 — BSP
`de_top_reset_chn2core_mux` writes 0xffffffff (disconnect ALL) then connects the active chn; OURS reads 0x0 (leaves
unused channels connected to disp0) — set it BSP-style. (2) port2uchn: BSP nibble[port]=phy_chn+2; confirm our
logic-chn/port + BLD_ROUT chain feeds pipe0 from phys6. (3) recheck uch2core field for phys6→disp0.
### On-device #2 (deferred, next session): boot stock eMMC, re-read 0x5100000 (per Addendum 10 it was "all zero" — but
the BSP says 0x5100000 IS the channels, so that capture likely read a control sub-region; re-verify).

## Addendum 12 (2026-08-30) — BSP blender/OVL model resolved; fill-color test reinterpreted; disable-layer test staged
Offline BSP dive (lowlevel_v35x/de35x de_bld.c/de_ovl.c/de_rtmx.c), device offline:
### Blender model:
- `pipe.en` bits: bit0-5 = pipeN_**fcolor**_en, bit8-13 = pipeN_en. `de_bld_set_pipe_ctl` always sets bit0 (`dwval=0x1`).
- **pipe0's fcolor = the per-pipe BACKGROUND behind the channel** — `de_rtmx_mgr_apply` does
  `de_bld_set_pipe_fcolor(disp,0, bg_color|0xFF000000)`. The layer composites OVER it via SRCOVER (0x03010301,
  which our driver matches). ⇒ my fill-color test (pipe0 fcolor=white, layer enabled → BLACK) just means the
  **opaque layer covers the white fill** — consistent with Addendum 7 (opaque layer fetching black), NOT proof the
  output stage is dead. (Corrects the tentative Addendum-9 reading.)
### OVL layer apply (`de_ovl_u_apply_lay`): layer enabled via ctl EN bit `0x1`; ctl = EN | (alpha_mode<<1) |
  (mode==BUFFER?0:0x10) | (fmt<<8) | (premul<<16) | (alpha<<24). Our live attctl `0xff000401` = EN|fmt4|alpha0xff,
  alpha_mode=0(pixel), buffer mode = **matches the BSP formula exactly**. There is **NO channel-level layer_en_cnt
  register** (it's a SW count) — so nothing missing there; the layer IS correctly enabled.
### Fetch mystery stands: layer enabled + addr `0x51c1010=0x44200000` correct + buffer verified white (DBG FILL
  readback ffffffff) + **no dma-ranges in the display DT path** (DE DMA addr == physical) — yet the DE reads black.
### ★ STAGED (built, ready to deploy when device online): disable-layer test — `sun8i-mixer.ko` md5 **0195413a...**
  forces OVL `ATTCTL=0` (layer off) so pipe0 emits its white fcolor **unobstructed**, no fetch. Deploy → cold-boot →
  feed → look: **WHITE = the whole output path works ⇒ bug is the layer DMA FETCH (Addendum 7 confirmed)**;
  **BLACK = the DISP→TCON output stage is genuinely dead**. This is the clean output-vs-fetch decider.
### Diagnostic edits in the staged .ko to REVERT before commit: forced layer-off, pipe0 white fcolor, red de_bg_color,
  DBG FILL memset+readback, DBG attctl print.

## Addendum 13 (2026-08-30) — disable-layer test: BLACK; the DE composites black regardless of config
Clean cold boot, disable-layer module (arm=4). The driver's `ATTCTL=0` edit was a no-op (de_blk_write dirties only on
CHANGE, fresh shadow=0 → 0-write ignored → register kept the bootloader's enabled 0xff000401). Forced it by POKE:
`0x51c1000=0` HELD (stable across reads, arm_now=4 steady = RCQ not re-arming, so the poke IS the active value). With
the layer disabled + pipe0 fcolor=white (verified applied `0x5281004=0xffffffff`) + bg=red + DSI transmitting → **panel
BLACK** (neither white fill nor red bg shows).
### ★ THE PATTERN (every reliable+poke test, this session): white fb, white pipe fcolor, red/white bg, layer enabled,
layer disabled — ALL produce BLACK. The RCQ DOES apply config (fcolor landed in the register), yet the DE's composited
output is BLACK regardless. The DSI transmits it byte-identical to stock (D-PHY status 0x15c55555) — black pixels. So
the DE33 **compositing/output emits black independent of the blender/layer/fcolor/bg content**.
### Remaining hypotheses (register-level analysis exhausted): (a) a DISP/blender/RTMX **output enable** the driver
misses (RT_EN is set in RTMX_GLB_CTL=0xd1, but a per-DISP or blender-output enable may be absent); (b) the RTMX→DISP
datapath isn't actually flowing composited pixels (routing/handshake) even though the muxes read plausibly; (c) the
RCQ applies the register BLOCKS but the DE's compositing reads a different/zeroed active state for some blocks (partial
decoupling — but the fcolor DID apply, arguing against full decoupling).
### ★ RECOMMENDATION: this is the ut-slayer/orangepi-4a `sun55i_de.c` RCQ driver's domain (DE33 compositing bring-up).
The register regions/routing/formats are all verified BSP-correct; the failure is in getting the composited frame to
emit non-black. Strong point to engage ut-slayer / linux-sunxi with this handoff. Reliable in-house next step if
continuing: fix the disable-layer edit to write a DIRTYING EN=0 value (attctl & ~EN) to confirm output-stage-dead via
the RCQ (not poke); and add a driver dump of the RCQ DRAM block payloads vs MMIO to test hypothesis (c).
### Diagnostic edits in the deployed .ko to revert before commit: forced ATTCTL (no-op 0), pipe0 white fcolor, red
de_bg_color, DBG FILL, DBG attctl print.

## Addendum 14 (2026-08-31) — ★★★ CONCRETE ROOT-CAUSE LEAD: OVL_LAY0 ATTCTL never applies (LADDR in same block does)
Added a driver debug at the layer ATTCTL write. On a clean cold boot (arm=4), with the disable-layer edit
(`de_blk_write(lay, ATTCTL, attctl & ~EN)` = 0xff000402):
- `DBG attctl wrote=ff000402 shadow=ff000402 stagedirty=1` — the write REACHED the shadow AND marked the block dirty.
- The stage_dirty→arms_left=2 transfer EXISTS (sun55i_de.c ~1420-1427) → head->dirty=1 → block should be applied.
- **`use_rcq=N` (AHB mode)** — the CPU word-by-word apply (`if (!use_rcq && de->mmio)` ~1653: `for w<size/4 writel`),
  which the code comment says "reaches all registers" (unlike the A523 RCQ DMA that "does not apply the BLD blocks").
- YET hardware ATTCTL (0x51c1000) stays **0xff000401** (EN=1, the stale/bootloader value; NOT our 0xff000402), while
  **LADDR (0x51c1010, offset 0x10 of the SAME OVL_LAY0 block) DOES apply = 0x44200000 (our value)** and MBSIZE (0x04)
  too. So within one dirty block, offsets 0x04/0x10 apply but **offset 0x00 (ATTCTL) does not**, and its EN bit is
  forced on.
### ⇒ The driver cannot change the layer's ATTCTL (enable/fmt/alpha). This is the strongest candidate yet for WHY the
DE composites black regardless of config: the layer's compositing/enable state is stuck at a stale value; only the
fb-address gets updated. Every "black" result (Addenda 7-13) is consistent with this.
### FIX LEADS (ut-slayer RCQ/apply backend — sun55i_de.c): (1) the per-flip fb-address reload (flip_min, line 339
"reloads ONLY the framebuffer-address blocks") may re-write/re-enable ATTCTL from a stale copy, or an arm/commit
ORDER issue means the full-reload arms fire before the plane commit stages ATTCTL and arms_left drains before a
re-apply — instrument the actual writel to 0x51c1000 in the AHB apply loop and the arm timing. (2) Test `use_rcq=1`
vs `0` (the earlier RCQ-RB showed use_rcq=1; now N). (3) Check whether OVL_LAY0's head reg_offset/size or a separate
fb-address head overlaps and clobbers offset 0x00. This is now a localized apply-path bug, not a mystery.
### Deployed .ko (md5 29593fae) has the debug + all prior diag edits — revert before any commit.

## Addendum 15 (2026-08-31) — REVISION: ATTCTL applies but is re-enabled; CORE = DE scanout reads black from cma_low
Corrects Addendum 14. The AHB-apply debug (in the arm loop) proved the ATTCTL DOES get written: `DBG AHB OVL_LAY0
dirty=1 sh_attctl=ff000402 hw_before=ff000401 -> ff000402` across successive applies. But a **competing DIRECT hw
writer** sets it back to 0xff000401 (enabled) in a gap where the only logged event is a shadow-only commit — it is NOT
a de_blk_write (all OVL_LAY0 ATTCTL writes are lines 1248/1338/1363 = 0 / attctl&~EN / 0; none write 0xff000403), NOT
the RCQ DMA (use_rcq=N so the RCQ path/rcq_kicked branch is skipped), NOT the AHB apply. Net: the layer ends up
**ENABLED (0xff000401)** — which is correct for normal display — so the ATTCTL fight is a SIDE ISSUE, not the black.
### ★★★ CORE (unchanged, now sharper): in AHB mode the **layer-fetch is the DE's ONLY DRAM read** (no RCQ DMA). The
enabled layer at 0x51c1010=0x44200000 fetches **BLACK**, while the driver's own DBG FILL memset+readback of gem->vaddr
(same buffer) reads **WHITE**. Same physical address, CPU sees white, DE-MBUS sees black. No dma-ranges (DE addr==phys),
DETOP_MBUS_CLK on (0x5008008=1), buffer white. => the DE33 **scanout/layer DMA is not delivering the framebuffer** —
either the DE MBUS master can't read the cma_low reserved region (0x44000000-0x47ffffff), or the scanout fetch isn't
issuing. Note: the RCQ head sits at 0x6d5f4000 (general RAM) — the aperture picture (0x43-0x4b) may be wrong/irrelevant.
### RECOMMENDATION: this is a DE33 scanout-DMA/MBUS issue in ut-slayer's sun55i_de.c backend + possibly A523 MBUS
master config — beyond register poking. handoff.md (Add 1-15) is a complete record. Concrete open leads for them:
(1) DE-MBUS master access to cma_low vs general RAM (try fb in general RAM / a different reserved region; verify the
A523 MBUS master enable/priority for the DE scanout port); (2) the direct competing ATTCTL writer (find it if the
scanout is fixed and the layer must be toggled). Deployed .ko md5 d36d867c has debug+diag edits to revert.

## Addendum 16 (2026-08-31) — SWING RESULT: fb-region/aperture DEFINITIVELY ruled out
Tested the MBUS-access/region theory by trying to relocate the framebuffer out of cma_low. Findings:
1. **fb follows the mixer's memory-region, NOT the default CMA.** Adding a separate high `cma-high`
   node with `linux,cma-default` did NOT move the fb — it stayed at 0x44100000 (DBG FILL dma). The
   scanout dumb buffer AND the RCQ pool both allocate from the **mixer node's memory-region (cma_low)**;
   the old comment "scanout draws from the default CMA" is wrong. They are tied; can't split via cma-default.
2. **Moving cma_low high (0x60000000) hard-fails the DE bind** (sun55i_de.c:638 guard, DE_DMA_MAX=0x4b000000,
   returns -ERANGE). The guard comment records it EMPIRICALLY: the A523 DE MBUS wedges above ~0x4b000000
   (silent boot hang). So the fb **cannot** be placed high — not merely untested.
3. Net: the fb at 0x44100000 is **already inside** the DE's reachable window (<0x4b000000), CPU-verified
   white (DBG FILL readback), yet the scanout composites BLACK. => **region/placement is NOT the cause.**
### Remaining open probe (cheap, no rebuild): in AHB mode (use_rcq=N) the scanout is the DE's ONLY MBUS
DRAM read, so nothing independently proves the DE MBUS reads DRAM at all. Toggle `use_rcq=1` so the RCQ
DMA must read the (low, in-reach) pool over MBUS: poke a reg to a wrong value, force a commit+arm, re-read
— if it snaps back to our value the DE-MBUS reads DRAM fine (=> scanout-black is scanout/compositing-specific,
not MBUS), if it stays wrong the DE-MBUS read path itself is dead. Either way it isolates MBUS vs scanout.
DTS reverted to clean single cma_low (bak restored); clean bringup.dtb redeployed (next cold-boot).

## Addendum 17 (2026-08-31) — LAST DATA POINT: DE-MBUS read path WORKS (RCQ proven)
use_rcq=1 probe: baseline layer addr 0x51c1010=0x44100000 → poked to 0x0 (confirmed) → forced commit
(fb0 blank/unblank; arm_now 5→10, RCQ DMA ran) → re-read = **0x44100000**. The RCQ DMA read the (low,
in-reach) command pool from DRAM over MBUS and re-applied the layer address register. => **the DE MBUS
DRAM-read path is functional.** So the scanout's black is NOT "DE can't read DRAM".
### FINAL ISOLATION (Add 15+16+17): DE inits (arm=5), panel attaches, DSI transmits stock-identical,
RCQ/AHB apply reaches every register, DE-MBUS reads DRAM (RCQ proven), fb is in-reach (0x44100000 <
0x4b000000, the empirical DE reach) and CPU-verified WHITE (DBG FILL readback) — **yet the scanout
composites BLACK.** Defect is in the DE33 scanout LAYER-FETCH-CONFIG (format/stride/offset/fetch-enable)
or the COMPOSITING/blend path, NOT memory placement, MBUS, region, coherency, address, or FMT-passthrough.
=> ENGAGE ut-slayer (sun55i_de.c author). Distilled report: docs/DISPLAY-UTSLAYER-REPORT.md.

## Addendum 18 (2026-11-25) — offline session: intel sweep + BSP enable-path trace; device DOWN (UART soldering), paused
### External intel status (checked 2026-11-25 ~13:35 UTC)
- linux-sunxi email sent 2026-11-24 (`linux-sunxi-post-EMAIL.txt`): **no reply yet**.
- ut-slayer/Juan Manuel: **patches still not delivered** (last contact: email 11-10, GitHub issue MidG971/trimui_smart_pro_s#2 on 11-14 "I can pass you my patches"). His public intel from issue #2: panel runs **DSI video mode**; tcon-top `0x0c=0x22` (TCON clk from PHY PLL); IOMMU bypass in U-Boot; pck600 VI/VO power-domain finding (adapted already). orangepi-4a-mainline last code commit = v0.5 (10-14); only other repo = mesa-panvk-g57.
- Jernej DE33 **v4 series merged to drm-misc-next 2026-11-23** (wens; commits f240bdee… edb16093…). His promised third series (full H616 display pipeline incl. TCON) **not posted yet** — re-check daily.
- GitHub-wide sweep: **no other public mainline A523/T527 DSI display code** (ours is the only one). LarzVader A523 tablets = postmarketOS WIP, no display driver. Armbian PR #11040 (juanesf A523/T527 port) confirms the same low-CMA DE aperture issue on OPi4A (`cma=256M@0-4G` workaround) — validates our cma_low. HDMI only there.
### Local dumps inventory (all present, see docs/)
- `docs/STOCK-DE-DISPLAY-FULLDUMP-2026-10-22.txt` = full working oracle (vendor v1.0.2, panel lit): DE-top 0x5008000-0x821c, mixer-glb, all OVL chn headers, VI0 full + VSU, BLD 64w, FMT, DCSC, TCON-top, TCON-LCD1 96w, DSI 192w (incl 0x2e0/0x2f0), combo-PHY 80w, CCU display-clock regs (0x2001600, 0x2001b00-0xbfc). Missing: stock PLL regs 0x2001000-0x0ff, clk_summary text, SMMU 0x2010000 block.
- Vendor BSP source local at `/home/dio/.trimui-session/bsp` (lowlevel_v35x + disp/).
- `docs/upstream-de33-jernej-v2/` = Jernej DE33 v2 lore mbox + live-detop-2026-09-06 ours-vs-stock table.
### ★ NEW (BSP trace, full detail in docs/BSP-ENABLE-PATH-TRACE.md)
Vendor per-frame loop: TCON **TRI/CNTR IRQ** → `disp_lcd_event_proc` → `disp_al_lcd_tri_start` →
`dsi_tri_start` (HSTX jump table) + `tcon0_tri_start` = **CPU_IF `trigger_start` pulsed EVERY FRAME**
(stock CPU_IF=0x10010005, AUTO clear = manual trigger). Each pulse pulls one DE→TCON→DSI frame;
DE FRAME_END/RCQ_FINISH are the completion. **Our driver never re-pulses the trigger** (one-shot or
HV free-run) — prime suspect for parked DSI FSM (inst 1), stuck video_curr_line, FRAME_END never.
Other BSP facts: DE-top map 0x8000 reset/0x8004 clk/0x8008 mbus/0x8010 de2tcon/0x8024 chn2core/0x8028
port2chn/0x804c async=0 (ver≥2)/0x8050 bufdepth 0x6000/0x8100 GLB_CTL/0x8108 outsize/0x810c autoclk/
0x8110 RCQ kick (0x8114/18 head, 0x811c len); GLB_STS states FRAME_END=bit0, RCQ_FINISH=bit2,
RCQ_ACCEPT=bit3, busy=bit4; 0x800c/0x80e8 are sun60iw2-only no-ops on w3. Size macro (w-1)|((h-1)<<16)
= ours = ut-slayer v0.5 (stock 0x02CF04FF is its 1280x720 landscape pipeline — NOT a bug in ours).
Stock composites primary plane via **VI0/phys chn0** (port2chn=0xA9810, BLD ROUTE=0x00FFFFF0, chn2core=0);
we use UI chn6 (0x80). Stock DSI basic_ctl1=0x15 (ours 0x17, extra bit1). tcon0_open video: tcon_en=1,
dclk_en=0xf, VBLK irq.
### Next probes when device is back (UART done)
1. CPU-IF mode + **per-frame trigger_start pulse from the TCON TRI/vblank IRQ handler**; watch GLB_STS
   bit0 (FRAME_END), DSI 0x2e0/0x2f0, FIFO 0x55082f4 → expect frame clock-out.
2. Optionally align to stock: VI chn0 primary plane; DSI basic_ctl1 0x15.
3. Capture missing stock blocks: CCU PLL 0x2001000-0x0ff, clk_summary, SMMU 0x2010000; our-side live
   full dump while black. Read-only first, warn before visual tests, base64 ≤8 MB chunks, build on
   compiler-rock3b /root/rebase-7.4-rc1 (see DISPLAY-FRAME-CLOCKOUT-PLAN.md checklist).
### Watch-list: ut-slayer patches (email + issue #2 + orangepi-4a-mainline new branches), linux-sunxi
reply to 11-24 mail, Jernej DE33 third series on dri-devel/lore.

## Addendum 19 (2026-11-25/26, post-UART) — logs committed, stock 69 MHz mode found, panel driver updated
- UART soldered; captured `serial_output_trimui251145.log` (3 boots: stock eMMC ×2, then mainline 7.2.0-rc3-dirty from 32GB SD/MMC1). Split + redacted + committed to GH repo main: `6785c30` (mainline SD boot), `5d4acef` (stock eMMC boots; IPs redacted, no serial/MAC). Raw combined log stays local (repo gitignores *.log).
- ★ Stock boot log shows panel er68576 advertises TWO modes and vendor picks **clk 69000 kHz h[720 752 756 844] v[1280 1296 1300 1309]** (60.0 Hz) — NOT the 62 MHz/776×1332 mode we hardcoded (that's the panel's *other* mode, from the vendor DT). fb 3686400 B = 720×1280×4.
- `panel-trimui-smart-pro-s.c` defaults changed to the stock 69 MHz mode (mode_clock=69000, hfp32 hsw4 hbp88, vfp16 vsw4 vbp9; old mode still via module params). Built OK on compiler-rock3b v7.4-rc1: panel-trimui-smart-pro-s.ko 2026-11-25 23:17. (Build quirk fixed en route: CONFIG_REGMAP_SPMI=m double-export broke modpost → set =n; needed `touch drm.c drm_panel.c` to force consistent modpost.)
- Fan-no-chirp / LEDs-off on the SD boot = stale Aug 7.2.0-rc3 image on the SD (`sd-bringup/Image` is Aug 16): pwm_fan.ko vermagic mismatch (boot log line: "section size must match"), no leds-axp20x in 7.2, no pck600 VI/VO fix. Not a HW fault — boot the 7.4-rc1 image instead.
- Watch-list re-checked 2026-11-26: still no ut-slayer patches, no linux-sunxi reply, no Jernej DE33 3rd series.
- Device currently on UART console (old SD image, no network). Next: bring up WiFi/Tailscale on device (see /root/WIFI-SETUP.txt) → deploy 7.4-rc1 Image+dtb+modules → probe matrix: dsi_video_mode=N a523_stock_trigger=1 cpu_trigger_start=1 cpu_if_auto=0; watch GLB_STS bit0 (FRAME_END), DSI 0x2e0/0x2f0, FIFO 0x55082f4, panel visually (warn first).

## Addendum 20 (2026-11-26) — ★ ut-slayer DELIVERED the TrimUI patches (private, do NOT publish before his end-of-month release)
- Email 2026-11-26 01:11 +01:00 "Smart Pro S kernel patches (DSI panel through KMS), 7.2 base" with attachment
  `trimui-smart-pro-s-patches-7.2-20261126.tar.gz` (gmail thread 1a21532031d610b3; connector has no attachment
  download — user to save it locally). Against v7.2.15. Keep his From:/Signed-off-by/copyright. Do NOT push to the
  public repo until he posts the link in ut-slayer/orangepi-4a-mainline#11 after his release.
- ★★ HIS ANSWER to the frame-clock-out question: **the DE was fine; the bug is on the TCON side.** With mainline
  values, the A523 TCON-LCD in DSI/trigger mode never finishes a frame: TRI_FINISH never fires, DSI FIFO stays
  empty (== our symptom exactly). **Patch 0035 = the fix: DCLK /1, block space 84, start delay 315.**
  **Patch 0055 also required: full TCON timings in DSI mode.** These match our stock oracle exactly:
  dclk `0xF0000001` (div=1 + 4 gate bits), TRI0 `0x005402CF` (block_space 0x54=84), TRI2 `0x013B000A` (start_delay 0x13b=315).
- 2026-11-26: SD-card path works: 50G USB card /dev/sdb (GPT, p1=256MB ext4 BRINGUP w/ SPL@128K eGON + files,
  p2=ROOTFS), updated via host (new Image md5 c145b6dc…). BUT the freshly rebuilt 7.4-rc1 Image (27MB vs 55MB
  known-good 5ad3f987…) HANGS at kernel 1.2s on boot → revert to backup_bootfiles_2026-11-16/Image-7.4 (55MB,
  md5 5ad3f987d8785eb458b4ac55e0aaf365) on the card. Modules are config-stable (sun4i-tcon.ko md5 492a2db8…
  identical Nov-06 vs Nov-25 builds). mods.tgz (7.4-matched aic8800 + display modules incl. NEW 69 MHz panel)
  already copied to the card root.
- Panel: stock picks 69000 kHz h[720 752 756 844] v[1280 1296 1300 1309] (committed logs). panel driver defaults
  changed to that mode (built into panel-trimui-smart-pro-s.ko in mods.tgz).

## Addendum 21 (2026-11-26 ~00:30) — ut-slayer fixes PORTED into 7.4-rc1 tree, modules rebuilding
- Read his A-display/B-de-timing patches in full. Our tree already had equivalents of 0011 (DCLK 0xf<<28),
  0013 (tcon-top DSI gate via sun8i_tcon_top_set_displl), 0035+0055 (a523_stock_trigger config table:
  DCLK=(0xf<<28)|1 div field written explicitly as 1, block_space 84, start_delay 315, clk_delay 2,
  BASIC1-3 via dsi_video path), 0036 (de2tcon_mux param), 0018 (panel 69 MHz 844x1309), 0037 horiz
  (hsa=2 hbp=254 hfp=84 hardcoded for trimui panel). MISSING were 0033 (init in command mode) and the
  0037 vblk 4-lane pad; ported into sun6i_mipi_dsi.{c,h} as variant flags init_in_command_mode +
  exact_line_blanking (set on sun55i_a523_mipi_dsi_variant), plus vblk = 4 - frame%4 on 4 lanes.
  Defaults flipped: a523_stock_trigger=true, de2tcon_mux=0x32f1 (stock). Files on compiler-rock3b:
  drivers/gpu/drm/sun4i/{sun6i_mipi_dsi.c,sun6i_mipi_dsi.h,sun4i_tcon.c,sun55i_de.c}.
- BUILD HOST QUIRKS rediscovered: (a) tree ships .cmd_shipped and stale Nov-06 .o files — scp/touch of .c
  does NOT trigger rebuild; had to `rm` the .o/.ko/.cmd for sun4i modules. (b) .config had been clobbered
  (no SUN4I at all) — restored from IKCONFIG extracted out of the known-good Image-7.4
  (backup_bootfiles_2026-11-16/Image-7.4): all display drivers =m, CONFIG_MODVERSIONS off → modules only
  need vermagic 7.4.0-rc1-dirty to load. CONFIG_REGMAP_SPMI=y (built-in) is fine; =m was the modpost breaker.
- Rebuild running (make -j32 modules, /tmp/b6.log). Next: verify vermagic, stage .ko into /tmp/pkg74mod,
  repackage /tmp/pkg74/mods.tgz, revert card Image to 5ad3f987..., SD swap → boot 7.4-rc1 → UART login →
  insmod aic8800 → WiFi → tailscale/SSH → HW-test panel (a523_stock_trigger default Y now).

## Addendum 22 (2026-11-26 ~01:45) — modules rebuilt + card updated, ready for SD swap
- Full rebuild done on compiler-rock3b (had to run `make -k Image modules` to regenerate Module.symvers after
  .config restore; unrelated mlx4/wlcore .cmd files were corrupt, removed). New display .ko all vermagic
  7.4.0-rc1-dirty, strings confirm a523_stock_trigger default Y in sun4i-tcon.ko.
- mods.tgz repacked locally (/tmp/pkg74/mods.tgz, md5 9e7e828c…) with fresh sun4i-tcon / sun6i_mipi_dsi /
  sun8i-mixer / sun8i_tcon_top / sun4i-drm / panel / phy + aic8800 set.
- SD card (50G, /dev/sdb in laptop): /mnt/bringup/Image REVERTED to known-good 5ad3f987d8785eb458b4ac55e0aaf365
  (55MB; the c145b6dc 27MB rebuild hangs at 1.2s), mods.tgz updated, extlinux DEFAULT=trimui-rootfs
  (KERNEL /Image, FDT bringup.dtb, INITRD initramfs-rootfs.cpio.gz, console=ttyS0,115200, switch_root to eMMC Debian).
  Card unmounted, CARD-READY. → user puts card in handheld, power on, watch UART /dev/ttyUSB0 @115200.
- On boot: login root/trimui over UART, mount /dev/mmcblk1p1 (BRINGUP), tar xzf mods.tgz into
  /lib/modules/7.4.0-rc1-dirty/, insmod aic8800_bsp → aic8800_fdrv, wpa_supplicant (WelcomeVillageByCA /
  Passione), dhclient, tailscale up → SSH. Then display HW test (a523_stock_trigger now default Y).

## Addendum 23 (2026-11-26 ~02:00) — 7.4-rc1 booted from card, WiFi half-up, full module set packaged
- Device booted the 50G card (in-device it is mmcblk0: p1=BRINGUP=/boot, p2=ROOTFS=/; games SD=mmcblk2,
  eMMC not enabled in bringup dtb). Kernel 7.4.0-rc1-dirty #7 Nov 16 (known-good 5ad3f987) on card rootfs.
  /boot/mods.tgz was the new one (9e7e828c). UART login root/trimui works over picocom on /dev/ttyUSB0.
- aic8800_bsp.ko loads OK; aic8800_fdrv needs cfg80211+mac80211 (=m in Image config, not on card).
  Packaged FULL dep closure into mods.tgz (md5 ff8eee69, 21 .ko: aic8800×3 + cfg80211/mac80211/rfkill/
  libarc4/crc-ccitt + drm/drm_panel/drm_kms_helper/drm_dma_helper/drm_client_lib + sun4i×5/panel/phy).
  Local copy /tmp/pkg74/mods.tgz. → card to laptop, cp to BRINGUP p1, back to device, reboot, extract,
  insmod rfkill libarc4 crc-ccitt cfg80211 mac80211 aic8800_bsp aic8800_fdrv, wpa_supplicant, dhclient,
  tailscale up → SSH. Then display modules + panel HW test.

## Addendum 24 (2026-11-26 ~02:30, pausing for the night) — 7.4 on-device status, display pipeline ALIVE, card issue
- PORTED ut-slayer 0034/0052/0053 into sun6i_mipi_dsi.c on rock3b (reset pulse before deassert — fixes the
  -110 DCS timeouts; video_start_wait_ms=100 between HSC/HSD; panel_enable_after_video after HSD).
  Rebuilt sun6i_mipi_dsi.ko; deployed over SSH (device had WiFi 192.168.1.93, laptop key added).
- DT fix: tcon1 node had NO "pixel" clock → tcon->pixel_clk was NULL → a523_stock_trigger branch never ran
  (fell into dsi_video HV path; CPU_IF=0). Patched bringup dtb directly (dtc decompile/recompile of
  backup_bootfiles_2026-11-16 bringup.dtb + `clocks += <0x05 0x93>; clock-names += "pixel"`), deployed to
  device /boot. Local copy /tmp/w74/bringup-new.dtb (md5 on device 2ee791c9…). Source dtsi also patched
  (trimui-de-reconcile.dtsi) but the bringup DTS is NOT in the kernel tree — the card dtb is patched by hand.
- RESULT on device (7.4.0-rc1-dirty, before reboot): connector card0-DSI-1 = CONNECTED, mode 720x1280,
  fb0 console switched on, panel attached, mode 69000 kHz htotal 844 vtotal 1309, DCLK /1 = 69 MHz.
  BUT DCS init still timed out (-110) pre-0034, and DSI video engine line=0 fifo=0 (CPU_IF=0 → HV path).
  pwm-sun20i.ko + pwm_bl.ko loaded → /sys/class/backlight/backlight appeared; panel deferred until then
  (cldo1 regulator never registers — only cldo2/cldo4 do; panel probe still succeeded after backlight up).
- REBOOT ISSUE: sysrq reboot while card had pending writes → next boots: `mmc0: error -22 "no support for
  card's volts"` — card latched into 1.8V/UHS state, host drops UHS (1-bit) → rejects. Card removed → U-Boot
  falls back to eMMC = VENDOR TrimUI OS (got 192.168.1.120). Card boots fine in U-Boot (raw read), only
  Linux mmc0 fails. Card health check PENDING (not in laptop yet at pause).
- TODO tomorrow: (1) card in laptop → fsck sdb1/sdb2, re-flash p1 via sd-bringup/flash-coexist.sh with
  Image 5ad3f987 + bringup-new.dtb + new mods.tgz (regenerate: /tmp/pkg74/mods.tgz + pwm-sun20i.ko +
  pwm_bl.ko + sun6i_mipi_dsi.ko(new)); (2) COLD boot (card out, power on, insert? or insert then power on —
  try insert-then-power-on first; if mmc0 -22 again, boot vendor eMMC and hot-insert card in its shell);
  (3) on 7.4: extract mods, insmod all (order: drm drm_kms_helper drm_client_lib drm_panel drm_dma_helper
  crc-ccitt cfg80211 mac80211 rfkill libarc4 pwm-sun20i pwm_bl phy sun8i_tcon_top sun6i_mipi_dsi sun4i-tcon
  sun8i-mixer panel sun4i-drm aic8800_bsp aic8800_fdrv), wifi up, then CHECK dmesg for
  "A523 stock-trigger diagnostic" + DSI line/fifo advancing + TRI_FINISH; ask user what the panel shows.
- ut-slayer patches stay PRIVATE until his end-of-month release (issue #11 link). Reply to his gmail when
  our port is verified.

## Addendum 25 (2026-11-26 10:20) — card re-flashed with full module set incl. pwm-fan
- Card healthy (fsck clean both parts; mods.tgz had been truncated by the crashed reboot — replaced).
- pwm-fan built as MODULE on rock3b (7.4: CONFIG_SENSORS_PWM_FAN=m, hwmon; pwm-fan.ko vermagic
  7.4.0-rc1-dirty, no deps) — no Image rebuild, so no hang risk. dtb has pwm-fan node.
- Card p1 now: Image=5ad3f987 (known-good), bringup.dtb=2ee791c9 (pixel-clock patched),
  mods.tgz=bd0697a8 (24 .ko: prev 21 + new sun6i_mipi_dsi(0034/0052/0053) + pwm-sun20i + pwm_bl +
  pwm-fan). Local: /tmp/pkg74/mods.tgz, /tmp/w74/bringup-new.dtb.
- NOTE: no fan CHIRP expected even with pwm-fan (cooling-level 0 at probe); the module gives
  /sys/class/hwmon fan control + thermal hookup. LEDs stay dark on Debian 7.4 (vendor userspace lights them).

## Addendum 26 (2026-11-26 ~11:40) — full pipeline binds on 7.4, frames still not flowing
- dtb fixes (hand-patched bringup dtb, local /tmp/w74/bringup-new5.dtb md5 666562ba): tcon1 += "pixel" clock
  (CLK_TCON_LCD1), tcon-top compatible += "allwinner,sun55i-a523-tcon-top", reserved-memory linux,cma
  (64MB, alloc-ranges 0x43000000..0x48000000, linux,cma-default; root cells MUST be 2/2), memory-region on
  BOTH display-engine and mixer, assigned-clock-rates CLK_TCON_LCD1 = 414 MHz (0x18cba80).
- sun4i-tcon.ko patched: a523 trigger path now sets dclk = crtc_clock*1000*(bpp/lanes) = 414 MHz (ut-slayer
  0035), DCLK div field 1. mods.tgz on device regenerated (md5 493658d5).
- RESULT: all bind clean (display-engine+mixer assigned linux,cma, tcon-top LCD1 DISPLL=1 CLK_SRC=0x22
  DSI_GATE=0x30000, tcon+dsi bound, drm Initialized, connector card0-DSI-1 connected+enabled 720x1280,
  fbcon 90x80 switched, no oops). DCLK final=414MHz bd=1. CPU_IF=0x10010005, GINT0=0xc8000401,
  CPU_TRI3 int_mode=1 counter_m=4 counter_n=55238.
- STILL BROKEN: TCON irq124 count=0, DSI irq127=0, DSI VID line=0 fifo=0, dbg0xfc=0x20000000 (no FRAME_END),
  "vblank wait timed out"; DCS init still -110 even with 0034 reset pulse. So TRI_FINISH never fires ->
  no frames to panel. Panel visual state unknown (ask user).
- Device: tailscale 100.80.96.57 (midgy971@, auth persisted), LAN 10.200.1.167 (flaky wifi), UART picocom ok.
  Boot cycle: card cold boot works; warm sysrq reboot OK if synced first (else mmc0 -22 card latch).
- Next hypotheses: (a) DCS -110 blocks panel out of sleep -> but shouldn't stop TRI_FINISH; (b) CPU-IF needs
  the DE armed BEFORE trigger (RCQ kicks happen on hrtimer ~65ms — maybe arm ordering/gate); (c) ut-slayer
  0061/0077/0078 (vblank=TRI_FINISH only, cur_line=FRAME_DONE, arm DE on TRI_FINISH) not fully ported;
  (d) compare CPU_IF/TRI regs against stock oracle STOCK-DE-DISPLAY-FULLDUMP-2026-10-22.txt.

## Addendum 27 (2026-11-27, session: DSI -110 root-cause hunt + trigger pacing)

### Live-proven facts (poke via /dev/mem, tools now persistent at /usr/local/bin/poke{,2,3} on device)
- Tools: poke (peek/poke mem), poke2 (DCS w/r with ECC + LPTX/LPRX drive), poke3 (peek/poke + i2c). Built static on compiler-rock3b from /root/poke*.c. Stored on device /usr/local/bin (NOT /tmp — tmpfs dies on reboot).
- DSI host block 0x5508000: **toggling CTL reg 0x000 off(0)→on(0x01010001) clears a stuck INST_ST** (BASIC_CTL0 0x010 bit0). The CCU reset pulse (0034 port) does NOT clear it. -> patched into encoder_enable.
- LP DCS transfer takes **~17 ms** to drain; mainline wait was 5 ms -> every transfer "-110" though it completed. -> timeout raised to 200 ms + paced re-kick (sun6i_dsi_wait_completion_paced, 10x20ms rounds, kicks via dsi->kick_cb).
- DSI FSM is **paced by the TCON CPU-IF frame trigger**: with no frame in flight LP commands starve (INST_ST never clears); with trigger kicks they complete. -> trigger_on_cb (sun4i_tcon_cpu_if_trigger_on) brings TCON GCTL/CTL+CPU_IF up before drm_panel_prepare; kick_cb (sun4i_tcon_cpu_if_kick) pulses CPU_IF TRI_EN|TRIGGER_START only (no DSI retrigger — that aborts in-flight LP cmd).
- phy-sun55i-dsi-combo: CFG_ANA0 was 0x44, stock oracle 0x05509000+0x4c = **0x77** (lptx_setr/setc=7) -> fixed to 0x77. PLL point table 372M (0x27f04583/0x006f1481/0x80032800) confirmed replayed (regs match), PLL lock bit26 set (dbg0 0x07700007).
- Panel: reset=PD22 (gpio118, main pio 0x2000000), power0=cldo4 (AXP717 @i2c-0:0x34, reg **0x9e bit7** — i2c-dev slave busy, kernel owns it), power1=vcc-1v8-io. Backlight works (brightness 50/255). Failed prepare disables supplies + asserts reset (chicken-egg for live probing).
- Fan: pwm-fan hwmon = **/sys/class/hwmon/hwmon2 name "pwmfan"** (not "pwm-fan" — earlier chirp grep failed on that). Chirp: echo 255 > hwmon2/pwm1; sleep; echo 0.
- LEDs: leds-sun50i-a100.ko + led-class-multicolor.ko now on card, load OK but NO /sys/class/leds — driver didn't bind (check deferred/probe; led-controller@2008000 node okay in dts, dmas=<0x19 0x2a>).
- One boot (module d10bc4bf, insmod sun4i-tcon.ko cpu_trigger_start=1 cpu_tri_int=0) got **irq124 (TCON) at 65 Hz** (VBLANK_INT bit15 fired) — frame loop CAN run. Later boots (watchdog-at-modeset / trigger_on variants) got irq124≈0-1.

### Register state (live == stock oracle STOCK-DE-DISPLAY-FULLDUMP-2026-10-22.txt)
- TCON 0x5502000: GCTL=80000000, GINT0 en bits 31/30/27, CTL=81000020, DCLK=0xF0000001 (div1+dclk_en 0xf), BASIC0=02CF04FF, BASIC1=034B005B, BASIC2=0A3A000C, BASIC3=00030003, CPU_IF=10010005(+TRIGGER_START bit1 when kicking), TRI0=005402CF, TRI1=000004FF, TRI2=013B000A, TRI3=0 (stock) — ALL match stock.
- DSI 0x5508000: CTL=01010001, CTL0=00030001, CTL1=00000015, 0x048=63F07602 (HSD jump), 0x060=0A, 0x090=1308703E, 0x098=0000FFFF — match stock. 0x2e0 (vid line)=0 when stuck.
- PHY 0x5509000: GCTL=31, ANA1=80000000, ANA2=0f000012, ANA3=ff040000, ANA4=844635ee, ANA0=77 (fixed), PLL=372M point, COMBO0=0x0b, COMBO2=0x14. match stock.
- Blender 0x5281000: our CTL block @0x80: rout=0x00000001 vs stock **0x00FFFFF0**; outsize @0x8c ours 0x04FF02CF vs stock **0x02CF04FF** (field order swapped: stock=(w-1)<<16|(h-1)). BLD+0x90=03010301 both. -> ut-slayer 0073 not yet ported (port2chn full mux 0x9810, LOGIC_CHN 2/3, ROUT(0,2)).
- DE2TCON detop mux (regmap 5100000.mixer-detop +0x10) = 0x32f1 ✓ (0036 ported).

### Current blocker
Panel init DCS still mostly -110 during prepare (sporadic ret-1 successes now); TRI_FINISH/vblank irq124 ~0 Hz so no frames (screen = backlight only). Next: port 0073 blender layout + check why watchdog loop (cpu_trigger_start=1, TRI3=0, watchdog at enable) doesn't fire irq124 anymore (worked in d10bc4bf boot); possibly trigger_on-at-prepare wedged it. Also 0061/0077/0078 B-group not ported.

### Build/deploy loop (working)
edit /tmp/w74/*.c -> scp to compiler-rock3b /root/rebase-7.4-rc1/... -> rm .o/.ko/.cmd/.mod* -> make -j16 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules -> scp .ko to root@100.80.96.57:/lib/modules/7.4.0-rc1-dirty/ -> tar czf /boot/mods.tgz . -> sync -> echo b > /proc/sysrq-trigger. Load order: drm drm_kms_helper drm_client_lib drm_panel drm_dma_helper crc-ccitt pwm-sun20i pwm_bl pwm-fan led-class-multicolor leds-sun50i-a100 phy-sun55i-dsi-combo sun8i_tcon_top sun6i_mipi_dsi sun4i-tcon sun8i-mixer panel-trimui-smart-pro-s sun4i-drm (+wifi rfkill libarc4 cfg80211 mac80211 aic8800_bsp aic8800_btlpm aic8800_fdrv, wpa_supplicant, dhclient, tailscale up).
Current module md5s on device: sun6i_mipi_dsi.ko 9a394a94, sun4i-tcon.ko b32ca14b, phy 469f360d, panel 4396bda0; mods.tgz regen each deploy. dtb 8b33cca5.

## Addendum 28 (2026-11-27 late session: full reg diff vs stock oracle — pipeline matches, still no TRI_FINISH)

### New modules built+deployed this session
- sun4i-tcon.ko **8be519812586257bc4f8f4d5342b0c39** — TRIGGER_START now PULSED 0→1 in both `sun4i_tcon0_cpu_if_arm` and `sun4i_tcon_cpu_if_kick` (bit1 doesn't self-clear on A523; repeated 1-write is a no-op edge).
- sun6i_mipi_dsi.ko **221ee002970343a465ee5eec262252af** — added full DSI-DUMP/TCON-DUMP pr_info block at end of encoder_enable (regs while pipeline up).
- Loaded via `/root/load-gpu.sh` (persistent on device) with `a523_prepare_trigger=1`, `cpu_trigger_start=1 cpu_tri_int=0`. Device boots, connector `card0-DSI-1` connected 720x1280, fb0 registered, but vblank wait timed out, irq468 (hwirq 124, 5502000.lcd-controller) = **1 total, no frame loop**. Panel prepare: probe reads mostly -110 (one sporadic `cmd 0x05 ret 1`), LP write `ff 87 56 01` fails -110.

### Live register dump vs stock oracle (docs/STOCK-DE-DISPLAY-FULLDUMP-2026-10-22.txt) — TCON 0x5502000
MATCH stock exactly: GCTL 0x80000000, CTL 0x81000020, DCLK 0xF0000001, BASIC0 0x02CF04FF, BASIC1 0x034B005B, BASIC2 0x0A3A000C, BASIC3 0x00030003, TRI0 0x005402CF, TRI1 lo 0x04FF, TRI2 0x013B000A, TRI3 0x00000000 (cpu_tri_int=0 == stock).
DIFF: CPU_IF ours 0x10010007 vs stock 0x10010005 (bit1 TRIGGER_START stuck — pulse leaves it set, no self-clear); GINT0 ours 0x08008001/0xc8008001 vs stock **0x00008A02** (bits 1,9,11,15 = VBLANK_INT(1)? + TRI_FINISH_INT bit11 + ...); IO_TRI ours 0xE0000000 vs stock 0x00000000; 0x1f0 SAFE_PERIOD ours 0 (stock dump didn't cover).

### DSI host 0x5508000 live vs stock — MATCH on every programmed reg
000=01010001, 010=00030001, 014=00000015, 018=00090004, 01c=051D0500, 020=1F, 024-03c, 040=30000002, 044=00310031, 048=63F07602 (JUMP_SEL), 04c=00560001, 054=00310031, 060=0A, 07c=10000009, 080=00010008, 090=1308703E, 098/09C, 0b0-0ec (all blanking/sync packets), 120-138 INST_FUNC, 140=03000002 — ALL == stock.
ONLY DIFF: **0x004 GINT0 ours 0x00020000 vs stock 0x00020004 → stock enables DSI IRQ id 2 = SUN6I_DSI_IRQ_VIDEO_VBLK (BIT(2))**. We never enable it (only flag bit18). 2e0/2f0/2f4 = 0 (no frame running; stock 0x1e6/0x00300000/0xF0380000 mid-frame).

### Interpretation / next steps
1. Registers are now stock-identical except DSI GINT0 bit2 (VIDEO_VBLK irq enable) and TCON GINT0 bits. The frame loop still doesn't start → the trigger source is likely the **DSI VIDEO_VBLK IRQ** (stock paces tri_start from it; our vblk_pace=0 and irq not enabled). Try: enable DSI GINT0 bit2 (VIDEO_VBLK) + route DSI irq 467, set vblk_pace=1 so frame_cb arms on VBLK; or simply write 0x004=0x00020004 at enable. Watch irq467 + irq468.
2. Port 0073 blender (port2chn mux 0x9810, LOGIC_CHN 2/3, ROUT(0,2)); our blender CTL@0x80 rout=0x00000001 vs stock 0x00FFFFF0, outsize@0x8c ours 0x04FF02CF vs stock 0x02CF04FF (field order (w-1)<<16|(h-1)). DE arm-on-TRI_FINISH (0077/0078) still not ported; RCQ-RB kicked=1 rcqsts=0x10 every 72 ms.
3. Panel init -110 persists even with trigger_on at prepare + paced kick; with command-mode init (0033 ported) the first LP write still starves. Once frames flow (step 1), init may succeed.
4. After verified: reply to ut-slayer gmail (thread 1a21532031d610b3). Keep his patches private until his end-of-month release.

Raw dmesg with the DSI-DUMP/TCON-DUMP lines saved at `bringup/dmesg-2026-11-27-dump-addendum28.log` (from device /root via tailscale). Module md5s on device now: sun6i_mipi_dsi.ko 221ee002, sun4i-tcon.ko 8be51981, phy 469f360d, panel 4396bda0; dtb 8b33cca5. Device load script persistent at /root/load-gpu.sh (a523_prepare_trigger=1, cpu_trigger_start=1 cpu_tri_int=0).

### TODO (later): fan not spinning like before
- Not only the chirp but also continuous low-speed spinning (stock behaviour) is missing. hwmon is /sys/class/hwmon/hwmon2 name "pwmfan": chirp = `echo 255 > pwm1; sleep 0.4; echo 0 > pwm1`; low speed = small pwm1 value. Regression vs earlier session — config/how-to is tracked on the GH issue (MidG971/trimui_smart_pro_s). Revisit after display is up.

### TODO (parallel with display work): LEDs
- leds-sun50i-a100.ko + led-class-multicolor.ko load OK but no /sys/class/leds entries — driver not binding (suspect deferred probe, dmas phandle 0x19?). Work this in parallel with the display bring-up, not after.

## Addendum 29 (2026-11-27, device down: fan + LEDs prep done, staged for next boot)

### Source of record found on GH (not issues): `docs/THERMAL-FAN-LED-BRINGUP.md` + `dts/trimui-thermal.dtsi` + `userspace/led-indicator.{sh,service}`
- Fan design: pwm-fan `cooling-levels = <96 128 160 192 224 255>` (6 states, **state 0 = 96 ≈ 37% always-on floor** — the "quietly spinning = device on" signal), thermal zones cpul/cpub with active fan trips 60/72/85 °C mapping to states 1/3/5, step_wise governor (built-in). Boot chirp one-shot (`fan-chirp/fan-boot-chirp.service`) kicks 100% for ~3 s because 96 is at/under stiction from dead stop. THS driver = our tree's sun8i_thermal.c (0021-0023 already applied, CONFIG_SUN8I_THERMAL=m), calibration cell = SID efuse 0x38 len 0x14.
- Root cause of current regression: bringup.dts had **no thermal zones, no THS nodes, and cooling-levels[0]=0** (off) — fan uncontrolled/off. pwm-fan probe sets initial_pwm = cooling_levels[max_state].
- LEDs: sun50i-a100-ledc (LEDS_SUN50I_A100=m) exposes /sys/class/leds/rgb:indicator-{0..16}; needs the DMA controller bound (`dma-controller@3002000`, compatible fallback `allwinner,sun50i-a100-dma` matched by sun6i-dma.c, CONFIG_DMA_SUN6I=m) — without sun6i-dma.ko loaded the LEDC probe defers forever (dmas phandle 0x19). That was our missing-LEDs cause. HW note: only left half of the ring lights (mid-chain break, not driver).

### Staged in /tmp/w74/deploy-fan-leds/ (push when device is back up)
- `bringup-new7.dtb` **md5 3ed47b7ac9d5a60497564d07196fed55** — bringup.dts + sid label + ths_calibration@38 cell + ths@2009400/ths_ddr@200a000 nodes (CLK_BUS_THS=0x7e, CLK_GPADC1=0x7b, CLK_GPADC0=0x7a, RST_BUS_THS=0x30, ccu phandle 0x05) + thermal-zones (cpul/cpub/gpu/npu/ddr) + `pwm_fan` 6-level curve `<0x60 0x80 0xa0 0xc0 0xe0 0xff>`. Verified by decompile.
- `sun6i-dma.ko` md5 7b78b8a9, `sun8i_thermal.ko` md5 7abc0c04 (from compiler tree).
- `load-gpu.sh` updated: sun6i-dma before pwm/leds, sun8i_thermal after pwm-fan.
- `led-indicator.sh/.service`, `fan-boot-chirp.sh/.service` (copied into repo `userspace/` + `fan-chirp/`).
- Deploy when up: scp dtb → /boot, scp .ko → /lib/modules/7.4.0-rc1-dirty/, regen mods.tgz, install scripts to /usr/local/bin + /etc/systemd/system + enable, sync, sysrq reboot. Expect: fan spins ~37% at idle + 3 s chirp at boot; LEDs rgb:indicator-0..16 green low; thermal zones readable.

## Addendum 30 (2026-11-27 ~21:00: fan + LEDs SOLVED, wifi auto at boot, charging pause)

- SD reinserted; stock BOOT0 log had shown `card no is 2` (eMMC only) — after inserting the 50G SD, SPL logs `boot from MMC1` and our kernel boots.
- Deployed bundle from /tmp/w74/deploy-fan-leds/: bringup-new7.dtb (md5 3ed47b7a…) installed as /boot/sun55i-a523-trimui-smart-pro-s-bringup.dtb (old 8b33cca5 backed up at /root/fanled/bringup.dtb.bak); sun6i-dma.ko 7b78b8a9 + sun8i_thermal.ko 7abc0c04 into /lib/modules/7.4.0-rc1-dirty/ + mods.tgz regen; load-gpu.sh updated (sun6i-dma before leds, sun8i_thermal after pwm-fan); led-indicator + fan-boot-chirp services installed to /usr/local/bin + /etc/systemd/system, all enabled.
- VERIFIED LIVE: `sun50i-a100-ledc 2008000.led-controller: Registered 17 LEDs` → /sys/class/leds/rgb:indicator-{0..16}, led-indicator.sh lights them green (bright=64, multi=0 255 0). sun8i_thermal bound: 5 zones (cpub/cpul/gpu/npu/ddr) all read ~41 °C. pwm-fan hwmon2 "pwmfan": probe kicked to max then step_wise governor dropped to **pwm1=96, cooling cur_state=0** = the 37% always-on floor spinning. Fan chirp service will kick 3 s at boot.
- WiFi now automatic at boot: /usr/local/bin/wifi-up.sh + /etc/systemd/system/wifi-up.service (enabled, multi-user.target) — insmods aic8800 stack, wpa_supplicant, dhclient, tailscale up. Verified: SSH 100.80.96.57 reachable without manual steps after reboot.
- Pausing ~30 min for charging; then resume display (VIDEO_VBLK irq / 0073 blender / 0077-0078 arm-on-TRI_FINISH).

## Addendum 31 (2026-11-27 ~21:15: boot automation for modules/fan/leds)

- Root cause of "leds off, fan off" after reboot: modules were only loaded by manually-run /root/load-gpu.sh. Fixed: new **gpu-modules.service** (enabled, multi-user.target) runs /root/load-gpu.sh (now idempotent: insmod ... || true, exit 0; re-insmods dsi/tcon with params). **led-indicator.service** and **fan-boot-chirp.service** now have `After=gpu-modules.service` so they run once pwm-fan/ledc exist. wifi-up.service also enabled (auto tailscale).
- Verified live: gpu-modules/wifi-up/led-indicator all `active`; hwmon2 pwmfan pwm1=96 (37% floor spin, cooling cur_state=0); 17 LEDs present, brightness 64 green. Fan chirp kicks 100% for ~3 s at boot to beat stiction.
- Boot chain: gpu-modules.service → fan-boot-chirp.service + led-indicator.service; wifi-up.service independent. Device charging ~30 min, then resume display.

## Addendum 32 (2026-11-27 ~21:20: LAN access)
- User at home: device reachable directly on LAN as **root@192.168.1.93** (wlan0 DHCP, gw 192.168.1.254; laptop 192.168.1.21 same subnet). Verified `ssh root@192.168.1.93` works. Tailscale 100.80.96.57 still up as fallback. IP is DHCP — if it changes, read it from serial or `tailscale status`/arp.

## Addendum 33 (2026-11-27 ~21:20: REAL root cause of dead LEDs/fan = missing sideboard-5V enable)

- The WS2812 ring AND the fan share the side-board +5V rail gated by GPIO **PK15** (`regulator-5v-en`, vendor dts line ~106, HW-verified note: without it LED ring dark + fan still). Our bringup.dts lacked the node → both dead despite drivers/IRQ/pwm all working (LEDC IRQ 60 fired, PH19 muxed, pwm1=96).
- Fix: added `regulator-5v-en` (gpio = <&pio 10 15 GPIO_ACTIVE_HIGH>, always-on, boot-on) to bringup.dts → **bringup-new8.dtb md5 0a5a3da4dc652390316d449b158cfa3e**, installed as /boot/sun55i-a523-trimui-smart-pro-s-bringup.dtb, rebooted. Now regulator.19 sideboard-5v-en state=enabled; 17 LEDs at brightness 64; fan pwm1=96 cur_state=0. (Physical confirmation by user pending.)
- Also fixed wifi-up.sh exit code (append exit 0) — service now `active`; LAN ssh root@192.168.1.93 auto at boot.
- dtb history: 8b33cca5 (old) → 3ed47b7a (thermal+fan curve) → 0a5a3da4 (adds 5v-en). Backup of 8b33cca5 at /root/fanled/bringup.dtb.bak on device.

## Addendum 34 (2026-11-27 ~21:30: mail scan A523)
- New upstream: `[PATCH v2 0/3] mmc: sunxi: preparation for A523 UHS support` (2026-11-26) — A523 SD UHS-I coming later (clock phases, delay chain, PF bank supply). SD on mmc1 currently default speed; revisit when it lands.
- A523 THS v6 series (7.3-rc2 base) in flight upstream — we already use interim 0021-0023; zones verified ~41 °C.
- No new upstream news on DE33/TCON/DSI — ut-slayer port remains the path for the display.

## Addendum 35 (2026-11-27 ~22:00: BATTERY CHARGING FIXED)

- Symptom: USB online=1 but status "Not charging", V flat, cap stuck. Root cause via regmap debugfs + poke3f (I2C_SLAVE_FORCE build of poke3, on device /usr/local/bin/poke3f): AXP717 REG 0x08 PMU fault had battery under-temp bit set (0x01) because TS pin (REG 0x50=0x02, thermistor enabled) reads cold → charge blocked. REG 0x19 bit1 (charge enable) was already OK.
- Fix: set REG 0x50 bit4 (TS_PIN_DISABLE) → charging started immediately: status=Charging, I≈1.95A, V 3.694→3.703 rising, fault cleared.
- Permanent fix in DT: added `x-powers,no-thermistor;` to battery-power node → bringup-new9.dtb md5 **09bba96b9bc7a50bcdc081b4c55a21a9**, installed as active FDT. Driver then sets TS_PIN_DISABLE at probe.
- Note: mainline axp20x_battery has the same workaround path (ts_disable via x-powers,no-thermistor) for "incorrectly programmed efuse" TS faults.

## Addendum 36 (2026-11-27 ~23:00: display session — 0073/0077/0078 ported, still no frame loop)

- LAN ssh root@192.168.1.93 (auto at boot via wifi-up.service). Battery charging fixed (Addendum 35), committed+pushed as 41160cd.
- FIXED load-gpu.sh bug: the param-less `for m in ...` loop contained sun6i_mipi_dsi/sun4i-tcon, so the parameterized insmods were no-ops → vblk_pace/a523_prepare_trigger/cpu_trigger_start were NEVER actually set before. Rewrote script: loop excludes them, explicit insmod with params after. Verified params read Y/Y/Y now.
- Ported ut-slayer 0073 into sun55i_de.c: OVL_UI_LOGIC_CHN 1→2, full port2chn mux 0x9810 written (live log: port2chn_mux=00009810). sun8i-mixer.ko 1b1fd3d6 → then 61b92994 with 0078.
- Ported 0077 essential: tcon irq handler passes UINT_MAX (FRAME_DONE) to vblank_quirk when tcon->pixel_cpu_trigger (line counter is in bits 27:16 on this TCON, bits 11:0 always 0).
- Ported 0078 essential: sun55i_de vblank_quirk arms immediately on FRAME_DONE (sets de->trigger_mode, no beam gate); do_arm beam gate skipped in trigger_mode. New field in sun55i_de.h.
- Removed TRI_FIFO_FLUSH from cpu_if_kick (was aborting in-flight LP commands).
- Added 1 Hz watchdog debug (WD: GINT0/CPU_IF/dbg_fc) in sun4i_tcon.c retrig timer (vblk_pace branch).
- Module md5s now: sun8i-mixer 61b92994, sun4i-tcon cc5d406e, sun6i_mipi_dsi 221ee002.
- RESULT: still irq471 (TCON) = 1, irq470 (DSI) = 0, line counter (0xfc bits 27:16) moves during prepare then freezes (~line 60), CPU_IF bit1 stuck, GINT0=c8000001 (TRI_FINISH_ENABLE set, flag never fires). Panel prepare still -110 on LP write ff 87 56 01 (some reads ret 1). All TCON/DSI programmed regs == stock oracle.
- HYPOTHESIS: TCON starts a frame on trigger pulse but never completes (no TRI_FINISH) — DE feed or DSI HSD drain missing; DSI INST 0x2f0 parks at instru=1 after failed LP init. Next: make LP init succeed (command-mode init is in; maybe need HSD restart after abort) or check DE RCQ delivery per frame.

## Addendum 37 (2026-11-28 ~00:30-02:00: display — poke-address bug, stock diff, DSI FSM wedge, panel init port)

- **POKE ADDRESS LESSON**: TCON is at 0x05502000, DSI 0x05508000, mixer-top (RCQ/GLB) at **0x05008100** (NOT 0x05100000 — that is the engine block). Wrong addresses land in RAM (0x40000000-0x7fffffff) and return ASCII kernel strings. regmap debugfs (`/sys/kernel/debug/regmap/...`) is always correct. mixer detop=0x05008000, top=0x05008100, display=0x05280000, engine=0x05100000.
- **Full live-vs-stock diff** (923 addrs from STOCK-DE-DISPLAY-FULLDUMP, only 55 differ): DE/TCON/DSI/PHY config all match stock EXCEPT: port2chn live 0x9810 vs stock 0xa9810 (ut-slayer 0073 deliberately 0x9810 — keep his); BLD ROUTE live 0x2 vs stock 0xfffff0; DE size regs live 0x04ff02cf (portrait-correct, v10 fix already in) vs stock 0x02cf04ff (stock fb is landscape 1280x720 pitch 5120); tcon-top 0x1c live 1 vs stock 0x20, 0x20 live 0x30000 vs stock 0x20000; PHY TX_CTL live was bit26, stock bit28 (HS_CLK_CONT=bit28 — now set via module param hs_clk_cont_bit=28); DSI GINT0 0x004 live 0x20000 vs stock 0x20004. TRI1 high bits (stock 0x038904ff) are read-only. DISPLL 0x27f04583/0x006f1481/0x80032800 match (0031 ported OK).
- **Live experiments**: manual TRIGGER_START pulse (CPU_IF 0x10410006→...07) advances TCON line counter ~211 lines then freezes (562→574→…→wrap→223); TRI_FINISH (GINT0 bit11) NEVER fires; with CPU_TRI3 int_mode=1 (0x10000000) TRI_COUNTER (bit10) fires + irq471 increments, still no TRI_FINISH. AUTO bit17 creeps a few lines then freezes. RCQ_STATUS (0x05008104) stuck 0x110 (bit8+BUSY) until manual W1C 0x10d + RCQ_CTL kick → became 0x008 (ACCEPTED), FINISHED (bit2) never. DSI video engine dead: 0x2e0=0, 0x2f0 instru parked, irq470=0.
- **DSI LP command path**: only the FIRST transfer after entering command mode completes; subsequent ones time out (200ms, INST_ST never clears). Alternating success pattern. Fixes applied to /tmp/w74/sun6i_mipi_dsi.c (built md5 e6480eab, deployed): (a) sun6i_dsi_dcs_write_short now WAITS for completion (was returning immediately → next cmd's abort wedged FSM); (b) inst_abort/inst_commit now use raw regmap_write (regmap_update_bits elides no-change writes when INST_ST reads 1). Result: init gets 3-4 commands through (was 1) but still flaky (-110 on 4th+). a523_prepare_trigger toggled 0/1 — no decisive change.
- **Panel driver**: ported ut-slayer **0057** (vendor er68576 init table — starts 0x36 0x14, NO ff 87 56 01 MCS unlock; ends 0x11 wait 50ms + 0x29 wait 120ms) + hand-ported **0058** semantics (powered/configured/asleep flags; unprepare = display-off+sleep-in only, no reset/supply cut; prepare wakes with sleep-out+display-on if configured). panel-trimui-smart-pro-s.ko md5 a24d1317 deployed. **PRIVACY: 0057/0058 are ut-slayer private — do NOT commit to public GH repo until his release; keep in /tmp/w74 only.**
- **load-gpu.sh current** (on device, packed into /boot/mods.tgz): loop without phy/dsi/tcon; then `insmod phy-sun55i-dsi-combo.ko hs_clk_cont_bit=28 ana0_override=0x77 ana4_override=0x84363538`; `insmod sun6i_mipi_dsi.ko a523_prepare_trigger=1`; `insmod sun4i-tcon.ko cpu_trigger_start=1 cpu_tri_int=0 vblk_pace=0 retrig_period_ms=16`; then sun8i-mixer, panel, sun4i-drm.
- **KEY DOC FINDINGS** (docs/a523-display-pistes-v8/v9/v10): stock CPU_TRI3=0, stock GINT0=0x00008A02 (flags VBLK+TRIF+FSYNC set, enables 0) — stock completes frames with TRI3=0 and TRI_FINISH+FSYNC firing, polled. Our CPU_IF bit1 TRIGGER_START never self-clears = trigger request never CONSUMED (acceptance condition unmet) — single root event seen as bit1-stuck + rd_flag-never + no counter IRQ. v10: DE size macro transpose was a real bug, already fixed in our build (live DE size 0x04ff02cf portrait-correct). v10 T3: vendor RCQ kick is per-frame from IRQ path, GLB_CTL 0xd1 matches ours.
- **Current blocker chain**: panel LP init flaky → DDIC may stay in sleep → DSI video FSM parked → TCON trigger never accepted (bit1 stuck) → no TRI_FINISH → vblank wait timed out → backlight only. ut-slayer's tree works cold with same regs, so remaining gap is behavioral in our DSI/TCON driver code (accumulated experiment patches), not register values.
- Next ideas: (1) make LP init reliable — maybe paced wait needs more kicks/longer, or send init via HS (init_hs param exists); (2) diff our sun6i_mipi_dsi.c transfer path against clean 7.2+his-patches to remove experiment cruft; (3) port 0061/0074/0075/0076/full-0078; (4) when TRI_FINISH fires, vblank counting via 0061. Keep his patches private; reply to gmail thread 1a21532031d610b3 only when verified.

## Addendum 38 (2026-11-28 ~later: shutdown/reboot quirk)

- **Observed**: over ssh, `shutdown && exit` powers the device down, but it **reboots a few seconds later** — had to turn it off manually. **Correction: the device was NOT attached to the USB charger** (user), so plain VBUS plug-in boot is ruled out as the confirmed cause. Remaining hypotheses: (a) VBUS from another source (laptop USB cable still connected?), (b) AXP717 wakeup source other than VBUS — RTC alarm or PEK — check wakeup enables (AXP regs ~0x2x, /sys/class/wakeup/*/event_count, /proc/interrupts axp lines) and the boot reason after it happens again, (c) gamepad MCU asserting power-on, (d) u-boot auto-booting again if the kernel exits without a clean PMU poweroff (cmdline has panic=10 — a panic would reboot after 10 s, check dmesg for panic on next occurrence).
- To power off for real: hold the power button; if it still reboots, capture `dmesg | tail` after the unexpected reboot to see the wake reason.
- Note for sessions: `ssh root@192.168.1.93 'echo b > /proc/sysrq-trigger'` reboots are fine (that's intended).

## Addendum 39 (2026-11-28 ~11:00: DISPLAY FRAME LOOP SOLVED AT COLD BOOT 🎉)

- **Working cold boot**: panel init `accum_err=0`, DSI INST 0x2f0=0x00300002 (instru 3 = HSD looping, stock-like), DSI video line counter advancing (DSI-VID line=3,342,1017,...), TCON curline advancing, GINT0=0x08008201 (FSYNC bit9 + VBLANK_INT bit15 firing), irq471 at ~63 Hz, **0 vblank-wait timeouts, 0 flip_done timeouts**. fbcon up on fb0.
- **The three fixes that unlocked it** (all in /tmp/w74 → compiler tree → device):
  1. panel-trimui-smart-pro-s.c: ut-slayer 0057 vendor er68576 init table + 0058 keep-configured semantics + **per-command retry loop (6 attempts) in trimui_panel_replay** — the A523 DSI LP FSM completes a transfer only ~50% of the time, and retries (without abort) get the whole 25-command table through (accum_err=0). PRIVACY: 0057/0058 stay local until ut-slayer's release.
  2. sun6i_mipi_dsi.c: (a) dcs_write_short now WAITS for completion; (b) inst_abort/inst_commit use raw regmap_write (update_bits elides no-change writes when INST_ST reads 1); (c) NO inst_abort on timeout anywhere (the abort permanently wedges the A523 FSM); (d) paced wait extended to 50×20 ms; (e) **after panel enable, re-init the DSI engine cleanly (CTL toggle + inst_init + bank1) before DSI_START_HSD** — this was the key cold-boot fix: the init's LP traffic wedges the FSM and HSD never runs without the re-init. Modules: sun6i_mipi_dsi.ko 65abed34, panel-trimui-smart-pro-s.ko 5104ca5e.
  3. load-gpu.sh: phy-sun55i-dsi-combo.ko with hs_clk_cont_bit=28 (stock TX_CTL bit28, not 26), ana0_override=0x77, ana4_override=0x84363538; a523_prepare_trigger=1; sun4i-tcon cpu_trigger_start=1 cpu_tri_int=0 vblk_pace=0 retrig_period_ms=16.
- Blank/unblank also works as a runtime recovery (re-runs encoder enable; with panel configured, prepare is skipped → clean HSD start).
- Note: this boot came up on Tailscale only (LAN ssh timed out, 192.168.1.93 unreachable) — wifi-up flakiness worth a look.
- Remaining display polish: TRI_FINISH (bit11) still not observed (vblank counted via VBLANK_INT bit15 instead — works); 0061/0074-0076/full-0078 port still pending (frame pacing/tearing); DSI 2e0 stays 0 (video line reg unused in this mode); visual confirmation of actual pixels on the glass pending user check.

## Addendum 40 (2026-11-28 ~11:30: DE size transpose fix — the "no pixels" root cause)

- User confirmed: only backlight, no content, even with the frame loop at 63 Hz. Root cause: **SUN55I_DE_OUT_SIZE was transposed**. v10's claim "BSP = (h-1)<<16|(w-1)" was BACKWARDS: TCON0_BASIC0 has X in bits[27:16] (header-confirmed), and the stock oracle shows the working 720x1280 pipeline uses 0x02cf04ff everywhere (DE-top 0x5008108, BLD out 0x528108c, TCON BASIC0 0x55020048). Our macro produced 0x04ff02cf = 1280x720 into a 720x1280 TCON → no pixels decoded.
- Fix: SUN55I_DE_OUT_SIZE(w,h) = ((w-1)<<16)|(h-1). sun8i-mixer.ko 865a2762 deployed; after reboot all size regs read 0x02cf04ff == stock, 0 vblank/flip timeouts, frame loop at 63 Hz, init replay accum_err=-110 on one command this boot (retry loop mostly works; FSM survived — video engine still started, DSI-VID line advancing).
- Modules now on device: sun8i-mixer 865a2762 (size fix + 0073/0078), sun6i_mipi_dsi 65abed34 (wait/no-abort/raw-edges/re-init-before-HSD), panel 5104ca5e (vendor table + retries).
- Pending: visual confirmation of pixels on the glass (user checking).

## Addendum 41 (2026-11-28 ~12:40: display — big progress, one blocker left)

- **Fixed this session** (all deployed on device, modules in /boot/mods.tgz):
  - **Panel reset polarity**: bringup.dts panel reset-gpios flag was 0x00 (ACTIVE_HIGH); PD22 drives an active-low DDIC reset → panel was held in reset after prepare. Changed to 0x01 (GPIO_ACTIVE_LOW) → bringup-new10.dtb md5 a1933c68, active at /boot. gpio-118 now "out hi ACTIVE LOW" (released).
  - **DE size transpose**: SUN55I_DE_OUT_SIZE was (h-1)<<16|(w-1); correct A523 encoding is (w-1)<<16|(h-1) (same as TCON BASIC0 X-high). Now all size regs = 0x02cf04ff == stock. sun8i-mixer.ko 865a2762.
  - **Panel init**: vendor er68576 table (0057) + 0058 semantics + 20-attempt retry loop with 50 ms spacing in trimui_panel_replay; debug probes gated behind probe_en=0 default. Cold-boot init now accum_err=0 reliably and fast (~1 s). panel .ko 7db28955.
  - **DSI driver** (sun6i_mipi_dsi.ko 65abed34): dcs_write_short waits for completion; inst_abort/commit use raw regmap_write (update_bits elides when INST_ST reads 1); NO inst_abort on timeout anywhere (abort permanently wedges the A523 FSM); paced wait 50×20 ms; after panel enable, full engine re-init (CTL toggle + inst_init + bank1) before DSI_START_HSD.
  - **TCON** (sun4i-tcon.ko b17b0fa8): removed the per-arm DSI inst re-pulse (it wedged the FSM); vblank IRQ handler now re-arms the CPU-IF trigger on VBLANK_INT too (TRI_FINISH never fires on this panel; VBLANK_INT bit15 fires at ~63 Hz).
  - load-gpu.sh: phy hs_clk_cont_bit=28 ana0_override=0x77 ana4_override=0x84363538 (PHY regs now match stock oracle exactly); a523_prepare_trigger=1; tcon cpu_trigger_start=1 cpu_tri_int=0 vblk_pace=0 retrig_period_ms=0 retrig_disable=0.
- **Proven working at cold boot**: panel init clean, DE layer latched (0x051c1000 ATTCTL=ff000403, mbsize 02cf04ff, pitch b40, laddr 44100000), DSI video engine runs right after enable (DSI-VID line advancing, fifo=61440 FULL, INST 0x2f0=0x00300002 instru-3 looping), TCON curline advancing, GINT0=0x08008201, 0 vblank/flip timeouts, fbcon 90x80 on fb0.
- **REMAINING BLOCKER**: the DSI instruction FSM parks ~1 s after boot (2f0→0, 2e0→0, fifo→0) and nothing revives it short of reboot; TCON keeps scanning (trigger re-armed via vblank IRQ + watchdog) but the DSI never transmits again → glass stays at backlight-only. Panel PHY/supplies/reset/DE/TCON/DSI regs all match the stock oracle, so this is behavioral: sustaining the DSI video FSM loop across the idle transition (vblank disabled at ~t=20 when DRM goes idle).
- **Next step**: find why the FSM stops after the first enable (likely the vblank-disable at idle stops the per-frame DSI kick; vendor re-kicks dsi per frame from the counter IRQ). Options: keep a per-frame DSI engine kick from the vblank IRQ that does NOT wedge (maybe full re-init each frame is too heavy — try re-writing JUMP_SEL + INST_ST pulse only), or run the FSM in AUTO/continuous mode (CPU_IF bit17) so it free-runs without per-frame kicks.
- Privacy: 0057/0058-derived code stays local (not committed to public repo) until ut-slayer's release. Our own fixes (size macro, reset polarity, DSI wait/no-abort) are commitable.

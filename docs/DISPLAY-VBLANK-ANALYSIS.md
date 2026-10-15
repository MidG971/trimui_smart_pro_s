<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
# A523 display: the `vblank`/`flip_done` timeout (held-frame) — analysis + candidate fix

**Status:** root-cause analysis (2026-10-14) + the candidate fix **build-verified** (2026-10-15): it applies
clean and compiles/links in a full `make Image modules dtbs` on v7.3-rc7 (EXIT 0, complete Module.symvers,
no modpost errors). Ready-to-apply patch: `kernel/harvest-sun55i-de/vblank-tri-finish.candidate.patch`
(also wired into `assemble-7.3.sh` step 1b). **HW test still pending** — does it clear the flip_done timeouts
and let fbcon/apps animate on the panel.

## Symptom (on 7.3-rc7 HW, and consistent with the 7.2 "held last frame" note)

Once the mixer binds (with the low-CMA `reserved-memory` fix) the panel lights and shows a real image,
but the kernel log repeats:

```
sun4i-drm display-engine: [drm] *ERROR* [CRTC:39:crtc-0] vblank wait timed out
sun4i-drm display-engine: [drm] *ERROR* flip_done timed out
sun4i-drm display-engine: [drm] *ERROR* [PLANE:35:plane-0] commit wait timed out
```

Effects: the first frame latches and *holds* (greyish image + scanlines), per-frame updates never land
(`no flip-on-damage`), and boot is slow (~160 s) because each fbcon/agetty/plymouth atomic commit blocks
the full 10 s `flip_done` timeout before giving up.

## Root cause

The panel is driven in **MIPI-DSI 8080 / TCON CPU-interface** mode (`pixel_cpu_trigger`), not a free-running
RGB scanout. In this mode the TCON raises **`TCON0_TRI_FINISH_INT`** when a pushed frame completes — it does
**not** raise the free-scan **`VBLANK_INT`**. But the IRQ handler only drives DRM's vblank/flip completion on
`VBLANK_INT`:

`drivers/gpu/drm/sun4i/sun4i_tcon.c` → `sun4i_tcon_handler()` (as in `drm-display-provisional.patch`):

```c
/* completes flip_done — but only on the free-scan vblank, which never fires in CPU-IF mode */
if (status & (SUN4I_TCON_GINT0_VBLANK_INT(0) | SUN4I_TCON_GINT0_VBLANK_INT(1))) {
        drm_crtc_handle_vblank(&scrtc->crtc);
        sun4i_tcon_finish_page_flip(drm, scrtc);
}
...
/* the frame-complete IRQ we DO get — re-arms the push, but never tells DRM a frame finished */
if (a523_stock_trigger && !retrig_disable &&
    (status & SUN4I_TCON_GINT0_TCON0_TRI_FINISH_INT)) {
        WRITE_ONCE(tcon->retrig_last_finish, ktime_get());
        if (!retrig_period_ms)
                sun4i_tcon0_cpu_if_arm(tcon);   /* re-trigger the next frame */
}
```

So `drm_crtc_handle_vblank()` is never called → `drm_crtc_send_vblank_event()` never fires → the atomic
helper's `flip_done` completion never signals → **every commit times out**. The TRI_FINISH re-trigger loop
*does* run, which is why the panel keeps a (held) image instead of going black. This is a pre-existing gap,
not a 7.3 regression — it matches the 7.2 "holds last frame, no flip-on-damage" observation.

## Candidate fix (treat TRI_FINISH as the frame-complete/vblank event for the CPU-IF path)

In `sun4i_tcon_handler()`, drive DRM's vblank/flip completion from `TRI_FINISH_INT` too (gated on the A523
CPU-IF path so other TCON users are untouched). Sketch:

```c
if (a523_stock_trigger && !retrig_disable &&
    (status & SUN4I_TCON_GINT0_TCON0_TRI_FINISH_INT)) {
        /* TRI_FINISH == this frame reached the DDIC; tell DRM so flip_done completes */
        drm_crtc_handle_vblank(&scrtc->crtc);
        sun4i_tcon_finish_page_flip(drm, scrtc);

        WRITE_ONCE(tcon->retrig_last_finish, ktime_get());
        if (!retrig_period_ms)
                sun4i_tcon0_cpu_if_arm(tcon);   /* arm the next frame */
}
```

Order matters: complete the *just-finished* frame's vblank/flip **before** re-arming the next push. This
should make `flip_done` complete ~once per pushed frame → no more 10 s timeouts → fbcon/apps can actually
flip → live updates, and boot stops stalling.

### Things to verify on HW (next session)
1. **vblank must be "on" for the CRTC** or `drm_crtc_handle_vblank()` is a no-op / warns. Checked in the
   solve: `sun4i_crtc`'s atomic enable/disable already call `drm_crtc_vblank_on()` / `drm_crtc_vblank_off()`
   (upstream, unchanged), and `enable_vblank` arms `TRI_FINISH_ENABLE` — so vblank **is** registered and on;
   the CRTC simply never receives `handle_vblank` because only `VBLANK_INT` drives it today. This is the
   encouraging part: the plumbing exists, the fix just connects the event we actually get.
2. **No double-count**: confirm `VBLANK_INT` genuinely never fires in CPU-IF mode (expected). If it can,
   guard so a frame isn't handled twice.
3. **Timestamp/seqno sanity**: TRI_FINISH ≈ frame-done is a fine vblank proxy; watch for `drm` warnings
   about vblank time or missed seq.
4. **Rate**: TRI_FINISH fires per pushed frame (~56 fps at the current retrig). That's the effective
   refresh; fine for UI. If it's too fast (DDIC heat), `retrig_period_ms` slow-refresh still applies — but
   note in slow-refresh mode flip_done would then only complete at that slower rate.

### Test plan
- Apply to `drm-display-provisional.patch`, rebuild `sun4i-tcon.ko` (vermagic `7.3.0-rc7-dirty`), deploy +
  depmod + reboot into 7.3.
- Pass: `dmesg` shows **no** `flip_done timed out`; boot is fast again; `/proc/interrupts` TRI_FINISH count
  climbs; `modetest`/an app can flip and the image animates (not just a held frame); fbcon text appears.
- If flip_done still times out: check (1) above (vblank not registered for the CRTC) — the most likely
  follow-up. Cross-reference the A133 Smart Pro work (leow149): same CPU-IF DSI, same per-frame-trigger
  model — their series is the closest upstream precedent for wiring TRI_FINISH → vblank.

## Why this wasn't hit before
The 7.2 bring-up reached "steady image" via the same re-trigger loop and simply never needed live flips
(console was quiet, apps that worked didn't block on vblank). 7.3's fbcon/agetty/plymouth do blocking
atomic commits at boot, which surfaces the missing flip completion as the 10 s stalls.

## Related leads (from `docs/pistes_again.md`, reconciled 2026-10-14)

That doc frames the (now-cured) fractale/heat as a DDIC DC-bias / charge-pump problem. With the panel cool
and showing a real image, those root causes are addressed (the memory-region fix restored valid frame
pushes, so the DDIC is no longer starved/drifting). Two of its leads remain live and bear on the work here:

- **TE (tearing-effect) is enabled but unused — strong alternative/again for the vblank source.** The panel
  init sends `0x35` SET_TEAR_ON, so the panel emits a per-frame TE pulse, but nothing consumes it (no
  `te-gpios` in DT, no TE IRQ, no wait-for-TE). TE is the panel's own "frame done / ready for next" strobe —
  a cleaner vblank/flip source than the host-side TRI_FINISH, and the canonical way to push tearing-free
  frames (wait TE → arm CPU-IF push → TRI_FINISH completes it).
  **TE-GPIO checked (2026-10-15): RULED OUT.** The vendor DTS (`vendor/trimui_smart_pro_source.dts`) routes
  DSI1 (our panel) as exactly the 10 lanes `PD10-PD19` (`dsi1_4lane` pinctrl) with **no extra pin**; there
  are no `te-gpios`, no `lcd_dsi_te`, and no `lcd_*` config (the `lcd0` node is a stub — the vendor panel
  config is in the kernel/FEX, not the DT). The whole PD display bank is accounted for (PD0-9 dsi0 unused,
  PD10-19 dsi1, PD20-21 parallel-RGB only, PD22 reset, PD23 backlight PWM). So **there is no TE GPIO to take
  an IRQ from** → the TRI_FINISH → `drm_crtc_handle_vblank` fix above is THE path. (TE may still be delivered
  *in-band over the DSI link*; if the residual CRT-lines/tearing need it later, that's a TCON/sun6i-dsi
  CPU-IF TE-source *register* question — `lcd_dsi_te` in the BSP — not a GPIO, and separate from fixing
  flip_done.)
- **Porches / AC frame-inversion (CRT-lines).** The panel is `MIPI_DSI_MODE_VIDEO`; the residual greyish
  "CRT lines" may be the LCD not completing AC frame/line inversion within an under-sized vblank. Current
  timing: `htotal 776` (hfp 32 / hsync 6 / hbp 18), `vtotal 1314` (vfp 16 / vsync 2 / vbp 34). Worth trying
  a larger vblank (bump vbp/vfp) on HW once flips land, and cross-checking the stock BSP `disp` porch/VCOM
  and column/frame-inversion registers. (Diagnostic idea from the doc: U-Boot inits the DSI PHY, hand off to
  mainline via `simple-framebuffer` to confirm HW stability independent of the DRM driver.)

NB: the panel's DSI mode is **non-burst** in the solve (`MIPI_DSI_MODE_VIDEO | LPM`, provisional patch) —
the proven setting. The standalone `kernel/drivers/panel-trimui-smart-pro-s.c` copy had a stale
`..._VIDEO_BURST`; synced to non-burst 2026-10-14.

## Related
- `kernel/harvest-sun55i-de/drm-display-provisional.patch` (the solve; `sun4i_tcon_handler`,
  `sun4i_tcon_retrig_timer`, `sun4i_tcon0_cpu_if_arm`)
- `docs/pistes_again.md` (DDIC-level symptom analysis), `docs/DISPLAY-PORT-STATUS.md`, `docs/DE33-ADOPTION-NOTES.md`

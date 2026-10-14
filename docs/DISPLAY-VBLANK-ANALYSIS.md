<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
# A523 display: the `vblank`/`flip_done` timeout (held-frame) — analysis + candidate fix

**Status:** offline source analysis (2026-10-14), no build/HW this round. Candidate fix below is
**unbuilt/untested** — stage for the next session with the compile server + device.

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

## Related
- `kernel/harvest-sun55i-de/drm-display-provisional.patch` (the solve; `sun4i_tcon_handler`,
  `sun4i_tcon_retrig_timer`, `sun4i_tcon0_cpu_if_arm`)
- `docs/DISPLAY-PORT-STATUS.md`, `docs/DE33-ADOPTION-NOTES.md`

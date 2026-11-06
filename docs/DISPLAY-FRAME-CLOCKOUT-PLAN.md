<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
# A523 DE33 display: the frame-clock-out investigation plan (resume here)

Written 2026-11-06. The wall, in one sentence: **the DE-v35x RT engine never clocks a
frame out to the TCON** — `GLB_STS.FRAME_END` never asserts, `RCQ_FINISH` never fires,
in DSI video mode the DSI FSM parks at instruction 1 (`debug_inst 0x2f0=0x00100000`,
`video_curr_line 0x2e0` stuck 0) and in the stock-matching 8080 mode `CPU_IF.rd_flag`
never asserts — even though every driver-controllable register byte-matches the vendor's
working firmware on the same board. Everything below is either DONE (with result) or a
concrete next probe. Device: `trimui-smartpro-s` (Tailscale), build host `compiler-rock3b`
(tree `/root/rebase-7.4-rc1`), warm `reboot` works natively now.

## Current proven state (do not re-derive)
- Everything except the panel image works on v7.4-rc1 (WiFi/BT/gamepad/audio/thermal/USB).
- Deployed and live on device: Image md5 `318f2641…` (IOMMU built-in + axp717_restart),
  dtb `bda04ce9…` (iommu node + mixer iommus), `sun8i-mixer.ko` `35537db1…` (size fix +
  iommu-aware guards), `sun4i-tcon.ko` `492a2db8…` (vblank IRQ stays armed + per-vblank
  `frame_update` under `vblank_update=1`).
- Size registers fixed: `SUN55I_DE_OUT_SIZE` was w/h transposed → now `(h-1)<<16|(w-1)` =
  `0x04ff02cf` for 720×1280, verified live in OVL MBSIZE / BLD sizes / DE-top OUT_SIZE.
- IOMMU bound (group 0 = mixer, master 5), RCQ pool via IOVA `0xffc00000`, no faults.
- fb buffer verified non-zero in DRAM at the layer address; solid-white fb → panel still
  black (2026-11-04). OVL ATTCTL=`0xff000403` (en, XRGB8888 fmt=0x04 — correct per BSP uapi),
  pitch 0xb40, laddr correct, routing (de2tcon 0x32f1, port2chn 0xa9810, tcon-top 0x0c=0x22)
  all match stock/BSP. tcon-top `0x1c`=0x01 is correct (BSP `__de_perh_t`: LCD1=1;
  stock's 0x20 is a de1→TV0 attach — not ours).
- T1: one full arm (gate bypassed) → FRAME_END 0/300 over 60 ms. T2: one dirty RCQ head +
  kick → not applied at kick, applied within 50 ms, ACCEPT 238/250, FINISH 0/250.
  ⇒ RCQ walk applies asynchronously; FRAME_END/RCQ_FINISH are gated on a real frame
  clocking out, not on the DMA.
- BSP answers: RCQ LEN (0x811c) = byte size of head array; no bootstrap kick in
  `de_rtmx_start()`; kicks are per-frame from the manager IRQ apply path; `GLB_CTL=0xd1`
  = vendor runtime IRQ enables. No missing RCQ enablement/sequence.

## DONE / ruled out (don't redo)
- Video vs 8080 mode, AUTO vs manual trigger, TRIGGER_START held vs edge-pulsed (25×),
  CPU_TRI3 counter IRQ (fires, not the gate), blender/fcolor/bg content, white vs
  pattern source, W1C-clear of GLB_STS, tcon-top 0x1c poke, dclk divider poke, IOMMU
  present, register-for-register convergence vs stock oracle (both modes).
- modetest on the device rejects all `-s` syntaxes (can't force commits); /dev/fb0
  writes = 0 DRM commits; idle fbcon disables the TCON vblank IRQ (fixed in our tcon
  patch: `vblank_update=1` keeps it armed).
- No IOMMU/SMMU needed as the *trigger* (bound now, still black). ut-slayer v0.5 diff:
  no frame-completion logic we lack (their board = HDMI/tcon2).
- leow149 A133 port: same panel family; their black-screen causes (SRAM C alias, DE
  clocks in DT, TCON IRQ wiring, panel reset, panel ID) all already handled on ours.

## OPEN hypotheses — the digging list (priority order)
1. **SMMU reset/TLB timeouts**: probe logged "TLB invalidation timed out" ×4 — the
   RST_BUS_IOMMU (0x7bc bit16) may not fully release the v15 SMMU on A523. Cross-check
   the vendor BSP's IOMMU reset (does it reset at all? which reg/bit?), and read the
   SMMU status regs (0x2010000+; clock it first via CLK_BUS_IOMMU — never read unclocked
   MMIO, it freezes the bus). Test: with iommu bound, verify an IOVA→phys mapping works
   (map a known page, read back via /sys/kernel/iommu_groups or a debugfs pin), check
   for fault IRQs (SPI 65) in /proc/interrupts.
2. **DE frame-start from TCON wire**: BSP hunt for a TCON→DE sync/frame-start signal
   beyond de2tcon_mux (check `de_top.h`/`de_lcd.h` for anything like `frame_start`,
   `vsync` input, `de_sync`, async-bridge control 0x804c values per soc_ver — ours=0,
   stock=0; try 0x10 (ver<2 value) as a poke and watch FRAME_END).
3. **DSI FSM stuck at instruction 1 (video mode)**: compare INST_FUNC/INST_LOOP/JUMP
   regs live vs stock *while stock runs video mode* (we only have stock's 8080 capture).
   Boot stock eMMC, capture 0x5508020-0x5508060 + 0x2e0/0x2f0 in video mode if possible,
   or read the vendor BSP `de_dsi.c` video-mode programming for a step we skip
   (e.g. `dsi_set_video_mode`, lane CEN on LP11 = INST_FUNC(0)=0x1f — we keep it, stock
   keeps it; the A523 second instruction bank patch 0026-era already shipped).
4. **8080 rd_flag wall**: with IOMMU now bound, retry the stock 8080 config
   (`a523_stock_trigger=1 cpu_if_auto=0 cpu_tri_int=0` in /etc/modprobe.d, reboot) and
   sample `CPU_IF`/`rd_flag`/TRI_FINISH per frame. Also try `TRI3` counter values from
   the 2026-10-27 oracle (CPU_TRI counter=763) live.
5. **Vendor bootstrap order**: extract from the BSP the exact first-frame sequence
   after `de_rtmx_start()` for command-mode DSI (`disp_al_lcd_tri_start`,
   `dsi_tri_start` = DSI_START_HSTX then `tcon0_tri_start`) and diff against our
   `sun6i_dsi_encoder_enable`/`sun4i_tcon0_mode_set_cpu` ordering step by step.
6. **DE output FIFO / RT-sync debug regs**: dump the DE-top debug region (0x8000-0x8220)
   live vs stock *while a frame is flowing on stock* — look for FIFO level / RT sync
   counters (de_top has DE_DEBUG regs at 0x80e0+). This splits "DE produces but not
   delivered" vs "DE not producing".
7. **Clock tree for the DE→TCON async bridge**: DE 600 MHz → TCON 62 MHz; verify
   `bus-de`, `mixer0`, `tcon-lcd1`, `mipi-dsi1`, `combophy-dsi1` rates in clk_summary
   vs stock's (capture stock clk_summary over adb). A wrong bridge clock could stall
   the frame handoff silently.
8. **ut-slayer / linux-sunxi answers**: issue ut-slayer/orangepi-4a-mainline#11 (filed,
   with IOMMU update comment 6673064915); mail `linux-sunxi@googlegroups.com` with
   `linux-sunxi-post-EMAIL.txt` (short, links this repo's
   `docs/A523-DE33-RT-HANDOFF-QUESTION.md` §8a–8f). Watch both.

## How to run a probe session (checklist)
1. Device up over Tailscale (`ssh root@trimui-smartpro-s`); `reboot` works natively now.
2. Read-only first: `/sys/module/.../parameters/*`, `/proc/interrupts`, clk_summary,
   poke_wr reads of clocked regions only (`echo 0xADDR > /sys/module/sun4i_tcon/parameters/poke_wr`,
   read dmesg `POKE-MMIO`; `dmesg -C` first). NEVER blind-sweep unclocked MMIO.
3. Config switches live in `/etc/modprobe.d/sun4i-tcon.conf` (+ `sun8i-mixer.conf`), need a
   `reboot` to apply (params are set at modprobe/modeset).
4. VISUAL tests: warn the user first, get explicit OK, then look (warn-before-device-test).
5. Binary transfers to the device: base64 **in 8 MB chunks** per file, md5-verify each
   chunk and the assembled file (single-stream base64 over DERP truncates ~33-46 MB).
   `.ko`/small files: single base64 OK. /boot is tight (230 MB) — prune .bak first.
6. Build on `compiler-rock3b`: `cd /root/rebase-7.4-rc1 && make -j32 ARCH=arm64
   CROSS_COMPILE=aarch64-linux-gnu- Image dtbs` (background it; ~5 min) or
   `M=drivers/gpu/drm/sun4i modules` for display modules only.
7. Backups before every tree edit: `cp file /root/file.bak-<tag>`; device rollback =
   extlinux `trimui-7.3` entry.

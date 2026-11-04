# A523 (sun55iw3) DE33 / DE-v35x: the DE never completes a frame to the TCON in command/8080 DSI mode

**Audience:** linux-sunxi, and anyone familiar with the A523/T527 DE-v35x (de352) RCQ / real-time (RT) mixer backend and the `sun55i-a523` TCON-LCD → DSI command-mode path.

**Ask:** every driver-controllable register now matches the vendor's *working* firmware on the **same board**, yet the DE never clocks a frame out to the TCON (`FRAME_END` never asserts, the TCON never asserts `rd_flag`, the DSI FIFO starves). We believe the remaining gap is in the DE↔TCON **real-time frame-start / pull handshake** (we have since ruled out a DSI video-vs-command-mode mismatch — see §4), which is below the level a register diff can resolve. Pointers welcome.

*Updated 2026-11-04: two further decisive data points + one driver bug found & fixed (see §8). Earlier 2026-11-02: re-verified live on **v7.4-rc1** in the stock-matching 8080 config (`CPU_IF=0x10010007`, `CPU_TRI3=0`, `TRIGGER_START` held) — `rd_flag` never asserts across 1024 samples; the TCON0 counter IRQ is now **ruled out** (its `GINT0` bit10 does fire, yet `rd_flag` still never does). The question narrows to Q1/Q3. Earlier 2026-10-30: cross-checked the command-mode trigger sequence against the vendor BSP — added the §4 bullets and sharpened Q3 (the DSI video-vs-command angle is ruled out; the remaining divergence is the TCON0 counter-IRQ pacing).*

---

## 1. Platform & what already works

- SoC: Allwinner **A523** (sun55iw3), DE33 display engine = **DE-v35x / de352**.
- Pipe: `tcon-lcd1 @0x5502000` → `dsi1 @0x5508000` → D-PHY `@0x5509000` → **ER68576-class command-mode DSI panel** (4 lanes, RGB888, portrait 720×1280).
- Mainline drivers in use: `sun4i-tcon` (+ an A523 8080/CPU-IF "stock-trigger" path), `sun6i_mipi_dsi`, and a `sun55i_de` DE33 driver (DE-top via MMIO, blender/format via the RCQ DMA).
- Bring-up is otherwise complete: panel reset-polarity fixed, DCS init executes and is ACKed, D-PHY PLL locks, TCON timing generator runs, DSI FSM reaches HS-data. The panel backlight is on and the DDIC is driven; there is simply **no image** (a static "mush").

## 2. Symptom (one line)

The DE accepts all configuration but **never completes a frame**: `GLB_STS.FRAME_END` (DE `0x5008104` bit0) never asserts, so the TCON's 8080 read never engages (`CPU_IF.rd_flag` never asserts) and the DSI transmit FIFO is permanently starved.

## 3. Register evidence (live mainline vs. same-board stock capture)

Stock values were captured by booting the vendor firmware on the **same unit** and reading MMIO live (`/sys/class/sunxi_dump` + `devmem`), panel lit.

### TCON-LCD1 `@0x5502000` — matches stock, timing generator running

| reg | field | stock | mainline (live) |
|---|---|---|---|
| `0x5502000` GCTL | TCON_EN | `0x80000000` | `0x80000000` ✓ |
| `0x5502040` TCON0_CTL | EN / IF=8080 / src_sel=DE | `0x81000020` | `0x81000020` ✓ |
| `0x5502044` DCLK | gate 0xf / div 1 | `0xf0000001` | `0xf0000001` ✓ |
| `0x5502048/4c/50/54` BASIC0-3 | 720×1280, HT=844, VT=1309, hsw/vsw=4 | match | match ✓ |
| `0x5502060` CPU_IF | MODE_DSI\|flush\|TRI_FIFO_EN\|TRI_EN | `0x10010005` | `0x10010005` (manual) / `0x10010007` while `trigger_start` is pulsed |
| `0x5502160/64/68` CPU_TRI0/1/2 | block 720/1280, start_delay 315 | match | match ✓ |
| `0x55020fc` DEBUG | current_line | sweeps | **sweeps 282→587→910 → timing generator IS running**, no underflow in manual mode |

`CPU_IF.rd_flag` (bit22) and `wr_flag` (bit23): **stock toggles each frame; mainline = 0 across 512 samples @400µs**, even with `TRIGGER_START` (bit1) held set 512/512. The TCON is triggered but never begins the transfer. Re-confirmed live on **v7.4-rc1** in the stock-matching 8080 config (`CPU_IF=0x10010007`, `CPU_TRI3=0`, `TRIGGER_START` held): `rd_flag = 0` across a further 1024 samples.

### DE-top `@0x5008000` — routing/clocks match; FRAME_END never

| reg | stock | mainline (live) |
|---|---|---|
| `0x5008010` DE2TCON_MUX | `0x32f1` | `0x32f1` ✓ |
| `0x500804c` ASYNC_BRIDGE (DE 600 MHz → TCON 62 MHz) | `0x0` (soc_ver≥2) | `0x0` ✓ |
| `0x5008100` GLB_CTL | `0x01` | `0xd1` (= `0x01` + our 3 IRQ-enable bits; vendor sets the same via `de_top_enable_irq`) |
| `0x500810c` AUTO_CLK | `0x1` | `0x1` ✓ |
| `0x5008104` GLB_STS | cycles `0x119/0x19/0x09/0x109` → **FRAME_END(b0)=1 and RCQ_ACCEPT(b3)=1 always set**, BUSY(b4)/RT-active(b8) toggle | cycles `0x008/0x018/0x118` → **RCQ_ACCEPT/BUSY/RT-active toggle, FRAME_END(b0) NEVER, RCQ_FINISH(b2) NEVER** |

### DE datapath (applied via the AHB path, `use_rcq=N`) — correct content present

`OVL UI6 0x51c1000=0xff000403` (en, RGB, 720×1280, fb `@0x44100000`, pitch 2880); blender `BLD_PIPE_EN 0x5281000=0x101`, `BLD_OUT_SIZE 0x528108c=0x02cf04ff` (720×1280), `BLD_IN_SIZE 0x5281008=0x02cf04ff`. So the DE has a correct, composed 720×1280 frame to deliver.

### DSI1 `@0x5508000` — downstream, ready and waiting

FSM parked at instruction 3 = **HSD** (HS data), `dbg_inst 0x55082f0=0x00300002`, line counter `0x55082e0` sweeping (DSI timing free-runs). **FIFO `0x55082f4`: stock `0xf038…` (≈0x38 fed), mainline `0xf0000000` (starved/empty).** D-PHY `ANA0 0x550904c=0x77`, `ANA4 0x550905c=0x84363538` — match stock.

## 4. What we have ruled out (each tested on hardware)

- **Not the trigger value / mode.** `CPU_IF` matches stock byte-for-byte (manual trigger, no AUTO). AUTO (bit17) makes the FIFO fill but only free-runs a flickery non-locked frame; stock does not use it.
- **Not a missing software `TRIGGER_START`.** Asserting it (self-clearing pulse) sets bit1 but it never self-clears and `rd_flag` never asserts.
- **Not `CPU_TRI3` / the TCON0 counter IRQ.** The vendor `tcon0_cfg_mode_tri()` programs `CPU_TRI3.tri_int_mode` (internal counter / TE); we added it (`0x16c`, internal-counter mode). On live v7.4-rc1 the counter *does* fire — `GINT0` bit10 (`TRI_COUNTER_INT`) asserts — yet `rd_flag` still never does. Stock runs with `CPU_TRI3 = 0` (counter off); poking ours to 0 to match is identical — `rd_flag` still never asserts across 256 samples. So the counter IRQ can fire and is **not** the missing piece.
- **Not the blender/content.** With BLD applied (above), `rd_flag`/`FRAME_END` are still 0 — identical to the null-blender state.
- **Not the RCQ enablement sequence.** Vendor `de_rtmx_start()` on sun55iw3 = DE core clk + `de_top_set_ahb_read_mode(1)` (a **no-op** on sun55iw3; conflict-mode only compiles for sun60iw2) + chn-mux + `setup_rcq` head pointer. Our head pointer `0x5008114`, high `0x5008118`, length `0x500811c=0x160`, and head-struct encoding all match the vendor; `de_top_set_clk_gating` is also a no-op on sun55iw3. No RCQ-specific clock/reset exists that we omit.
- **Not a malformed RCQ head.** All 22 heads read valid from DRAM; we additionally fixed a zero-length dirty `DCSC` head (vendor never emits one) — `RCQ_FINISH` still never fires.
- **Not the DE core bring-up order.** We match the vendor sequence — core AHB-reset release (`0x5008000`) → module clock (`0x5008004`) → MBUS clock (`0x5008008`); the historic mainline order (reverse) makes no difference.
- **Not the DSI mode, jump sequence, per-frame re-kick, or trigger order.** The DSI `BASIC_CTL`/`CTL0`/`CTL1` (`0x0`/`0x00030001`/`0x15`, VIDEO_MODE=1) match stock exactly — stock *also* runs the DSI video-mode FSM under the 8080 trigger, so this is **not** a video-vs-command mismatch. Cross-checked against the vendor BSP (`lowlevel_v35x`): our DSI instruction jump table (`HSC→HSD`), the per-frame `INST_ST` 0→1 re-pulse, and the DSI-before-TCON trigger order all match the vendor (`dsi_tri_start` = `dsi_start(DSI_START_HSTX)`, then `tcon0_tri_start`). The counter-IRQ angle is ruled out — see Q3.

## 5. The split-brain (the crux)

- `use_rcq=Y` (RCQ DMA): the frame engine cycles (`RT-active` toggles), `RCQ_ACCEPT` sets, head/shadows are byte-perfect — but **`RCQ_FINISH` never fires**, so the shadow never latches and BLD/FMT stay at reset.
- `use_rcq=N` (AHB CPU-copy): BLD/FMT/OVL are applied correctly — but the engine **never completes a frame** (`FRAME_END`=0, `RT-active` stuck/absent for a completion).

Neither path produces *applied datapath + a completed frame* in the same frame. `RCQ_FINISH`, `FRAME_END`, and the stuck `rd_flag` appear to be **one coupled event**: on this DE the RT mixer has no independent frame timing — it is a pure **slave pulled by the TCON**, and `FRAME_END`/`RCQ_FINISH` only complete when the TCON clocks a full frame out. The TCON never pulls, so nothing completes. A passive CRC monitor on the DE output cannot disambiguate "DE can't produce" from "DE isn't pulled" — they are the same event here.

**Direct evidence (v7.4-rc1, DSI-video mode).** Driving the TCON in plain DSI-video mode (rather than 8080 manual-trigger) makes the TCON *pull* — DRM `flip_done` completes, so this is no longer "the TCON never pulls." Yet still no image, and a **bare manual RCQ kick** isolates why: `writel(1, DE+0x8110)` (= `de_top_set_rcq_update(1)`) with the head list live at `0x44020000`/len `0x160` gives `RCQ_ACCEPT` set for **246/256** samples but **`RCQ_FINISH` = 0/256 and `FRAME_END` = 0/256**. The 22 RCQ heads are well-formed (valid block pointers, lengths, DE reg-offsets `0x281000`/`0x1c1000`/…, `len=0` terminator); in this quiescent capture all are `dirty=0`, so the kicked walk has *nothing to DMA* — and it **still** never asserts `RCQ_FINISH`. So `RCQ_FINISH` is **not** gated on the DMA completing; it appears coupled to the frame actually clocking out — the one thing that never happens. The RT-enable path matches the vendor live (`DE_BUF_DEPTH 0x8050 = 0x6000`, `GLB_CTL 0x8100` bit0, `AUTO_CLK 0x810c = 1`, `ASYNC 0x804c = 0`), so the gap is in the bare DE-v35x RCQ/RT backend, not the driver's setup.

## 6. The questions

1. On the A523/T527 DE-v35x in **command/8080 (CPU-IF)** mode, what makes the DE↔TCON RT handshake actually *start* a frame — i.e. what causes the TCON's `rd_flag` to assert and the DE to clock a frame out — beyond the registers above? Is there an RT frame-start / sync-source wire or enable (TCON→DE) that the mainline path does not set?
2. What is `RCQ_FINISH` (GLB_STS bit2) gated on? We see `RCQ_ACCEPT` but never `FINISH`, with a valid head list and correct pool placement (`@0x44020000`, within DE DMA reach). Is `FINISH` coupled to frame completion (so it cannot fire until the TCON pulls a frame)?
3. The vendor paces command mode off the **TCON0 counter IRQ** (`LCD_IRQ_TCON0_CNTR`, enabled in `tcon0_open()` on the command-mode DSI path); the per-frame `dsi_tri_start`/`tcon0_tri_start` fire from it. On live v7.4-rc1 with the counter enabled, that interrupt (`GINT0` bit10) **does** fire — yet `rd_flag` still never asserts, and the completion interrupts `TRI_FINISH` (bit11) and `FSYNC` (bit9), which stock raises every frame, never do. So the counter IRQ is **not** the gate. What actually makes the 8080 transfer run to completion — raising `rd_flag`, then `TRI_FINISH`/`FSYNC` — when the trigger config already byte-matches stock (including `CPU_TRI3 = 0`)? (The DSI is *not* the mismatch: `BASIC_CTL1`=`0x15`/VIDEO_MODE=1 matches stock, which also runs the DSI video-mode FSM under the 8080 trigger — the panel ends init with DCS `0x35 SET_TEAR_ON` and is TE-paced at ~1 `dsi1` IRQ/frame in both.)

## 8. Update 2026-11-04 — DE produces nothing with src=DE; size-register transpose found & fixed; BSP RCQ bootstrap answered

Three additions from a BSP/source session plus one more live run (v7.4-rc1):

**8a. P0b (the last matrix corner) — negative.** 8080 manual config + AUTO trigger
(`CPU_IF=0x10030007`) + `src_sel=0` (DE content, not the pattern generator) +
per-frame AHB re-arm: DSI FIFO stays `0xf0000000`, `GLB_STS` = `0x100` steady over
minutes (`FRAME_END` b0 never), TCON beam frozen at line 0. Mechanism = a
beam-gate deadlock in our driver (arm waits for the beam in blanking; the beam
needs DE content; DE content needs the arm). Conclusion: **with the DE as source
the RT engine emits no pixel stream even when the read path is live** — only the
TCON pattern generator (`src_sel=1`) has ever put pixels on glass. Combined with
the 2026-10-27 video-mode run (beam swept, `FRAME_END` did fire, FIFO still
starved): the DE can complete frames but they carry no data → fault in the DE
pixel fetch/output, not in trigger/blender/handshake config.

**8b. Real driver bug found and fixed — transposed size registers.** The DE-v35x
size registers are encoded `(height-1)<<16 | (width-1)` (vendor BSP
`de_bld.c de_bld_set_out_size`, `de_ovl.c` mbsize/win_size, `de_fmt.c` size;
identical to mainline `SUN8I_MIXER_SIZE` and to ut-slayer v0.5's
`SUN55I_DE_OUT_SIZE`). Our out-of-tree macro had w/h **swapped**, so for the
portrait 720×1280 panel we programmed `0x02cf04ff` (i.e. 1280×720 landscape) into
OVL MBSIZE, BLD in/out size and DE-top OUT_SIZE, while the fb pitch was 2880
(720×4) — a wrong DRAM offset on every scanline, consistent with 8a (frames
complete but content is garbage/black). Fix: macro corrected to
`(((h)-1)<<16) | ((w)-1)` → `0x04ff02cf` for 720×1280; `sun8i-mixer.ko` rebuilt on
v7.4-rc1 (md5 `0be3fab8fd88c4d5bf51707c92701340`). On-HW test pending (device
offline at the time).

**8c. BSP answers on the RCQ bootstrap** (`lowlevel_v35x/de35x/de_rtmx.c`,
`de_top.c`, `disp_manager.c`): `LEN` (DE+0x811c) is the **byte size of the RCQ head
array** (`alloc_num * sizeof(struct de_rcq_head)` = ×16), not a walk length — our
`0x160` (22 heads) is self-consistent vs vendor `0x6E0` (110 heads; the vendor
simply builds more sub-module blocks). `de_rtmx_start()` sets only the head
pointer/length — there is **no initial kick**; RCQ kicks are per-frame from the
manager apply path in IRQ context (`disp_manager.c` protect/unprotect →
`disp_al_manager_set_rcq_update(disp,1)` → `writel(1, DE+0x8110)`), and
`RCQ_FINISH` is handled as an IRQ with the same `GLB_CTL` enables we use (`0xd1`;
the vendor's live `0x01` capture is just its idle state). So there is no missing
RCQ enablement/sequence on our side; the empty-kick experiment (§5: ACCEPT
246/256, FINISH 0/256) plus 8a says `RCQ_FINISH`/`FRAME_END` are coupled to a
frame actually clocking out — which never happens because the 8080 TCON→DE pull
(`rd_flag`) never starts.

**8d. 2026-11-04 live run (v7.4-rc1, size fix applied, TCON vblank IRQ force-armed,
per-vblank DE re-arm active) — still no image.** Solid-white fb0 (verified in DRAM
at the DE layer address 0x44100000) → panel still black. `GLB_STS.FRAME_END` = 0 in
100+ samples; `RCQ_FINISH` never, even with a per-frame null RCQ kick (RCQ_ACCEPT
toggles, FINISH doesn't). In DSI video mode the DSI FSM is parked at instruction 1
(`debug_inst 0x2f0 = 0x00100000`, `video_curr_line 0x2e0` stuck at 0) vs stock at
instruction 3/HSD with the line sweeping — the TX FIFO fill is only idle/blanking
packets, not pixels; `INST_ST` 0→1 re-pulses don't advance it. DSI CTL/BASIC regs
match stock. So in video mode the DSI never reaches active video; in the stock 8080
command mode the DSI transmits but the TCON→DE pull (`rd_flag`) never starts. Both
walls are the same coupled event: no frame ever clocks out of the DE.

## 7. Reproduce / environment

- Mainline tree **v7.4-rc1** (behaviour identical on v7.3-rc7); DE33 driver `sun55i_de`, A523 8080 path in `sun4i_tcon`. Everything in §3 was re-confirmed live on v7.4-rc1 in the stock-matching 8080 config.
- Same-board stock capture: vendor Longan 5.15, panel lit, MMIO read live. Full dump: `docs/STOCK-DE-DISPLAY-FULLDUMP-2026-10-22.txt`.
- Everything in §3 is reproducible read-only on the running board; the `use_rcq` and trigger knobs are module parameters.

*Prepared from on-hardware measurements; all register values are live reads, not transcribed from a datasheet.*

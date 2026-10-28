# A523 (sun55iw3) DE33 / DE-v35x: the DE never completes a frame to the TCON in command/8080 DSI mode

**Audience:** linux-sunxi, and anyone familiar with the A523/T527 DE-v35x (de352) RCQ / real-time (RT) mixer backend and the `sun55i-a523` TCON-LCD → DSI command-mode path.

**Ask:** every driver-controllable register now matches the vendor's *working* firmware on the **same board**, yet the DE never clocks a frame out to the TCON (`FRAME_END` never asserts, the TCON never asserts `rd_flag`, the DSI FIFO starves). We believe the remaining gap is in the DE↔TCON **real-time frame-start / pull handshake** (and/or a DSI video-vs-command-mode model mismatch), which is below the level a register diff can resolve. Pointers welcome.

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

`CPU_IF.rd_flag` (bit22) and `wr_flag` (bit23): **stock toggles each frame; mainline = 0 across 512 samples @400µs**, even with `TRIGGER_START` (bit1) held set 512/512. The TCON is triggered but never begins the transfer.

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
- **Not the per-frame trigger source.** The vendor `tcon0_cfg_mode_tri()` programs `CPU_TRI3.tri_int_mode` (internal counter / TE). We added it (`0x16c`, internal-counter mode, counter from `htotal*vtotal/4`); the register takes the value but behaviour is unchanged and it generates no interrupts in our driver.
- **Not the blender/content.** With BLD applied (above), `rd_flag`/`FRAME_END` are still 0 — identical to the null-blender state.
- **Not the RCQ enablement sequence.** Vendor `de_rtmx_start()` on sun55iw3 = DE core clk + `de_top_set_ahb_read_mode(1)` (a **no-op** on sun55iw3; conflict-mode only compiles for sun60iw2) + chn-mux + `setup_rcq` head pointer. Our head pointer `0x5008114`, high `0x5008118`, length `0x500811c=0x160`, and head-struct encoding all match the vendor; `de_top_set_clk_gating` is also a no-op on sun55iw3. No RCQ-specific clock/reset exists that we omit.
- **Not a malformed RCQ head.** All 22 heads read valid from DRAM; we additionally fixed a zero-length dirty `DCSC` head (vendor never emits one) — `RCQ_FINISH` still never fires.

## 5. The split-brain (the crux)

- `use_rcq=Y` (RCQ DMA): the frame engine cycles (`RT-active` toggles), `RCQ_ACCEPT` sets, head/shadows are byte-perfect — but **`RCQ_FINISH` never fires**, so the shadow never latches and BLD/FMT stay at reset.
- `use_rcq=N` (AHB CPU-copy): BLD/FMT/OVL are applied correctly — but the engine **never completes a frame** (`FRAME_END`=0, `RT-active` stuck/absent for a completion).

Neither path produces *applied datapath + a completed frame* in the same frame. `RCQ_FINISH`, `FRAME_END`, and the stuck `rd_flag` appear to be **one coupled event**: on this DE the RT mixer has no independent frame timing — it is a pure **slave pulled by the TCON**, and `FRAME_END`/`RCQ_FINISH` only complete when the TCON clocks a full frame out. The TCON never pulls, so nothing completes. A passive CRC monitor on the DE output cannot disambiguate "DE can't produce" from "DE isn't pulled" — they are the same event here.

## 6. The questions

1. On the A523/T527 DE-v35x in **command/8080 (CPU-IF)** mode, what makes the DE↔TCON RT handshake actually *start* a frame — i.e. what causes the TCON's `rd_flag` to assert and the DE to clock a frame out — beyond the registers above? Is there an RT frame-start / sync-source wire or enable (TCON→DE) that the mainline path does not set?
2. What is `RCQ_FINISH` (GLB_STS bit2) gated on? We see `RCQ_ACCEPT` but never `FINISH`, with a valid head list and correct pool placement (`@0x44020000`, within DE DMA reach). Is `FINISH` coupled to frame completion (so it cannot fire until the TCON pulls a frame)?
3. This panel is command-mode (stock ends init with DCS `0x35 SET_TEAR_ON` and is TE-paced, driving the `dsi1` IRQ at 1/frame). Mainline currently runs the DSI as `MIPI_DSI_MODE_VIDEO` while the TCON is in 8080 command-trigger mode. **Is that video-vs-command mismatch the root cause** — must the DSI be a genuine command-mode device, TE-paced, for the TCON pull to engage?

## 7. Reproduce / environment

- Mainline tree based on **v7.3-rc7**; DE33 driver `sun55i_de`, A523 8080 path in `sun4i_tcon`.
- Same-board stock capture: vendor Longan 5.15, panel lit, MMIO read live. Full dump: `docs/STOCK-DE-DISPLAY-FULLDUMP-2026-10-22.txt`.
- Everything in §3 is reproducible read-only on the running board; the `use_rcq` and trigger knobs are module parameters.

*Prepared from on-hardware measurements; all register values are live reads, not transcribed from a datasheet.*

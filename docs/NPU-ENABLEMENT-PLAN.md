<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
<!-- Copyright (C) 2026 Midgy BALON -->

# NPU enablement plan — A523 VeriSilicon VIP9000 (etnaviv + Mesa Teflon)

**Status: NOT STARTED — a post-mainline stretch.** This sketches how to bring up the A523 NPU with the
**open** driver stack and what it's actually good for. It sits *behind* the real open blockers (display
heat/colour, big-cluster DVFS) and must not pull focus from them.

The A523/T527 NPU is a **VeriSilicon VIP9000**, ~**2 TOPS** INT8. It was long filed "dormant / no
mainline driver / out of scope" — that stance is **out of date**: there is a working open route.

## Reference (same die — directly reusable)

[`github.com/defencedog/orangepi4A`](https://github.com/defencedog/orangepi4A) — the OrangePi 4A is the
**same `sun55iw3` die** as our A523, so its NPU work ports directly. It ships **both** driver routes:

- **Open route (what this plan targets):** a patched **`etnaviv`** kernel driver + **Mesa "Teflon"**
  TensorFlow-Lite delegate (`libteflon.so`) — Tomeu Vizoso's open VeriSilicon-NPU stack.
- Vendor blob (avoid for mainline): **VIPCore** (`vipcore.ko`) + **VIPLite** (`libVIPlite.so`).

Built against **Linux 6.18.44** (`NPU_modules_opi4a_6.18.44/`), with demoed workloads on this exact SoC:
MobileNetV1 / SSD-MobileNet, **YOLOX-S @640 ≈ 9.6 FPS**, PP-OCR (DBNet) @1600/2048, SCRFD+MobileFaceNet.
⇒ our job is a **forward-port** of their 6.18.44 work onto our v7.2-rc3 tree, not greenfield RE.

> Pin the exact upstream commit of their etnaviv patch + Teflon build when we start — it is **carried,
> not confirmed upstream** (reproducibility).

## Reality anchor

~2 TOPS, YOLOX-S ~9.6 fps (~100 ms/inference) = **modest**. Real-time per-frame video NN at 720p60 (16 ms
budget) is mostly out of reach; **on-demand** inference is comfortable. This shapes the feature list below.

## Architecture

```
TFLite / LiteRT app  →  libteflon.so (Mesa Teflon, TFLite external delegate)  →  etnaviv (DRM)  →  VIP9000
     INT8 models            userspace                                               kernel          hardware
```

## Part 1 — Kernel: DT node + etnaviv

- **DT node** in `sun55i-a523.dtsi` (the vendor DTB has `npu@7122000`); etnaviv matches `vivante,gc` and
  reads the GC model/features at probe:
  ```dts
  npu: npu@7122000 {
      compatible = "allwinner,sun55i-a523-npu", "vivante,gc";
      reg = <0x07122000 0x..>;               /* VERIFY size + GIC SPI irq from the vendor DTB */
      clocks = <&ccu CLK_NPU>, <&ccu CLK_BUS_NPU>;   /* CLK_NPU=179 is in mainline; VERIFY a bus/MBUS clock */
      clock-names = "core", "bus";
      assigned-clocks = <&ccu CLK_NPU>;
      assigned-clock-rates = <696000000>;    /* vendor OPP: 546 / 696 MHz */
      resets = <&ccu RST_BUS_NPU>;           /* VERIFY in the reset header */
      power-domains = <&pck600 PD_NPU>;       /* VERIFY PD index */
  };
  ```
  Bring it up the **non-destructive** way (dtc decompile → add node → recompile → inject into the deployed
  DTB), as we did for the thermal nodes, before editing the SoC dtsi.
- **etnaviv**: `CONFIG_DRM_ETNAVIV=m` + carry the OrangePi-4A **VIP9000 patch** (the NN/TP-core support
  stock etnaviv lacks). Forward-port 6.18.44 → v7.2-rc3 (expect small API churn).
- **Verify:** load the module → `dmesg` shows `etnaviv … model GC…` and a render/accel node under
  `/dev/dri`. If probe reads all-zero / can't clock the block, suspect the **secure-clock gate** (some
  A523 clocks are secure-by-default — BL31 must write the CCMU security switch non-secure before Linux can
  use them) or a missing bus clock / power-domain.
- **Memory:** etnaviv has its own MMU and uses CMA-backed buffer objects — make sure CMA is sized for the
  model + working set.

## Part 2 — Userspace: Mesa Teflon

- Build **Mesa** (aarch64) with the **etnaviv + Teflon** front-end, carrying the repo's VIP9000 Teflon
  patch → `libteflon.so` (a TFLite external delegate).
- Run via **TFLite / LiteRT**, loading `libteflon.so`. Models must be **INT8-quantized TFLite**.
- **Verify:** run **MobileNetV1 INT8** → confirm the delegate **offloads to the NPU** (not an all-CPU
  fallback) and the latency is in the ballpark of the reference numbers. Read the op-delegation report.

## Part 3 — Bring-up sequence (bottom-up, each step verifiable)

0. Harvest the OrangePi-4A etnaviv patch + NPU DT node + Teflon build (same die).
1. Inject the NPU DT node into the deployed DTB; confirm it probes.
2. Build + load patched etnaviv; confirm `model GC…` + the DRM node.
3. Build + deploy Mesa/Teflon; run MobileNetV1 INT8; confirm NPU offload + perf sanity.
4. Then the app layer (below). **Cheapest proof-of-life = steps 1→3 with MobileNet.**

## Part 4 — What it's actually good for

- ✅ **On-demand OCR "snap-&-translate"** — the flagship. PP-OCR (DBNet) INT8 on the NPU (proven on this
  die) → translate (tiny on-device NMT, or an API when online) → overlay. Hooks onto RetroArch's **AI
  Service** (pause-and-translate). On-demand, so the modest TOPS is fine.
- ✅ **Audio denoise / upsampling** — audio NN models are tiny (1-D, 48 kHz mono), so real-time is easy on
  the NPU at low power; a **DeepFilterNet**-class denoiser could beat our CPU RNNoise for the
  mic-next-to-fan problem, and bandwidth-extension could clean up the 8 kHz **Bluetooth-HFP mic**.
  ⚠ **Op-coverage caveat — check first:** audio models lean on **GRU/LSTM / 1-D conv / complex** ops that
  Teflon's (conv/vision-centric) delegate may **not** accelerate → CPU fallback, defeating the point. Run
  the candidate model through Teflon and read the delegation report *before* committing; if poorly
  delegated, stay on CPU RNNoise or pick a conv-only denoiser.
- 🟡 **Video upscaling / SR** — marginal vs **GPU shaders** (Anime4K / xBRZ / FSR-ish via Panfrost +
  RetroArch) at the 720p panel; NPU SR is better **on-demand** (screenshot / box-art) than per-frame.
- 🔴 **Frame interpolation** — skip. Too heavy at 720p60 on 2 TOPS, and it **adds a frame of input lag**
  (needs frame N+1), which is bad for interactive games.

## Risks / open items

1. etnaviv + Teflon VIP9000 patches are **carried** (OrangePi-4A @ 6.18.44), not confirmed upstream — pin
   the source, forward-port to v7.2-rc3.
2. DT unknowns: a bus/MBUS NPU clock, `RST_BUS_NPU`, `PD_NPU`, the reg size + IRQ (from the vendor DTB).
3. **Secure clock gate** (BL31) — the likely culprit if etnaviv can't reach the NPU.
4. **Teflon op coverage**, especially for audio — the single biggest gate on the denoise idea.
5. CMA / MMU sizing for etnaviv BOs.
6. **Thermal** — the NPU adds heat, and we already have a display-heat problem + always-on fan → keep NPU
   use **on-demand**, not always-on.

## Sequencing

Post-mainline. The kernel DT + etnaviv forward-port is the bulk of the work; the Mesa/Teflon build is
mechanical; the apps are where the payoff is. See the project memory pin for the rationale, and
[`GPU-NOTES.md`](GPU-NOTES.md) for the GPU-shader alternative to NN upscaling.

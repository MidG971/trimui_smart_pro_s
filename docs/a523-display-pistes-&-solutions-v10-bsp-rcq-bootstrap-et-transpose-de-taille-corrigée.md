<!-- SPDX-License-Identifier: (GPL-2.0-only OR MIT) -->
# A523 / Trimui Smart Pro S — Pistes & Solutions (v10, 2026-11-04)

Suite de v9 (2026-11-02). Cette révision est **100% côté build/BSP** (compile server
`compiler-rock3b` up, device `trimui-smartpro-s` offline au moment d'écrire) : elle
ferme T3 (bootstrap RCQ vendor), invalide la piste §4-LEN de v9, et **trouve + corrige
un vrai bug driver** (transpose w/h des registres de taille DE).

## 0. Clôtures de cette révision (ne plus rouvrir)

- **v9 §4 « LEN 0x160 vs stock 0x6E0 » : CLOSED, non-cause.** `de_rtmx_setup_rcq()`
  (BSP `lowlevel_v35x/de35x/de_rtmx.c:165`) appelle
  `de_top_set_rcq_head(disp, phy_addr, alloc_num * sizeof(struct de_rcq_head))` :
  **LEN (0x811c) = taille en OCTETS du tableau de têtes** (16 B/tête), pas une longueur
  de marche. `alloc_num = ((cur_num+1)>>1)<<1` (arrondi pair). Nous : 0x160 = 22 têtes ;
  vendor : 0x6E0 = 110 têtes — le vendor construit simplement ~5× plus de blocs
  (enhance/smbl/cdc/wb/…). Notre LEN est **auto-consistant** ; la divergence de taille
  n'explique pas le deadlock.
- **T3 (bootstrap vendor) : CLOSED.** `de_rtmx_start()` (de_rtmx.c:321) =
  core-clk + `de_top_set_ahb_read_mode(1)` (no-op sun55iw3, confirmé) + chn_mux +
  `de_rtmx_setup_rcq()` qui ne fait **que** poser head-ptr/len — **aucun kick initial**.
  Les kicks RCQ sont **par frame**, depuis le chemin IRQ : `disp_mgr_apply()` →
  protect/unprotect (`disp_manager.c:1103-1110`) → `disp_al_manager_set_rcq_update(disp,1)`
  → `de_top_set_rcq_update()` = `writel(1, DE+0x8110)`. Le vendor gère RCQ_FINISH comme
  **IRQ** (`disp_mgr_rcq_finish_irq_handler`, disp_manager.c:1168) avec les mêmes
  enables GLB_CTL que nous (0xd1 = RT_EN|FRAME_END|RCQ_FINISH|RCQ_ACCEPT ; le 0x01
  capturé chez le stock n'est que l'état idle). Rien ne manque côté séquence
  d'enablement RCQ.
- **P0b (2026-11-02, déjà noté en v9/mémoire) : branche « non » fermée** — AUTO +
  src_sel=0 (DE) : FIFO DSI vide, FRAME_END jamais, beam gelé ligne 0 → le DE ne
  produit **rien** même lu en continu (deadlock de beam-gate : arm ↔ beam ↔ contenu DE).

## 1. ★ BUG DRIVER TROUVÉ + CORRIGÉ : transpose w/h de `SUN55I_DE_OUT_SIZE`

### Preuve BSP (encoding hardware des registres de taille DE-v35x)
- `de_bld.c` `de_bld_set_out_size` : `(width-1) | ((height-1)<<16)`
- `de_ovl.c` mbsize **et** win_size : `(width-1) | ((height-1)<<16)`
- `de_fmt.c` size : `(scn_width-1) | ((scn_height-1)<<16)`
- `de_top.c` RTMX_OUT_SIZE : idem (dump stock 1280x720 = 0x02cf04ff = (720-1)<<16|(1280-1))
- mainline : `SUN8I_MIXER_SIZE(w,h) = ((h-1)<<16 | (w-1))` ; ut-slayer **v0.5**
  `patches/0030` : `SUN55I_DE_OUT_SIZE(w,h) = ((w-1)&0x1fff) | (((h-1)&0x1fff)<<16)` — **correct**.

### Notre arbre (hérité d'un vieux snapshot ut-slayer) avait le macro transposé
```c
-#define SUN55I_DE_OUT_SIZE(w, h)  ((((w)-1)&0x1fff)<<16) | (((h)-1)&0x1fff)   /* FAUX */
+#define SUN55I_DE_OUT_SIZE(w, h)  ((((h)-1)&0x1fff)<<16) | (((w)-1)&0x1fff)   /* BSP-correct */
```
Pour notre mode **portrait 720×1280** l'ancien macro produisait **0x02cf04ff**
(= 1280×720 landscape !) — exactement la valeur observée live sur OVL MBSIZE
(0x51c1004), BLD IN/OUT_SIZE, DE-top OUT_SIZE (0x5008108) — alors que pitch
0xb40 (2880 = 720×4) et le fb sont portrait. ⇒ le DE fetche une surface
« 1280 de large » avec un stride de 720 → offset DRAM faux à chaque scanline →
fetch corrompu/vide. **C'est très probablement la branche v9-D (« frames complétés
mais sans contenu »)** : FRAME_END pouvait vivre (27/10) mais les pixels fetchés
étaient du noir/garbage.

### Correction + build (2026-11-04, compiler-rock3b `/root/rebase-7.4-rc1`)
- Patch appliqué (backup `/root/sun55i_de.c.bak-sizefix-20261103`), un seul macro
  corrigé — couvre mode_set (BLD OUT_SIZE + FMT size), enable (DE-top OUT_SIZE),
  VSU in/out, OVL MBSIZE + WIN_SIZE, BLD pipe in_size. Le chemin AFBD (ligne ~1358)
  était déjà correct. `de_bg_color` = BLACK par défaut dans cet arbre (les vieilles
  edits diag rouge/FILL du .ko 7.3 déployé n'y sont pas).
- `make M=drivers/gpu/drm/sun4i modules` rc=0 → **`sun8i-mixer.ko` md5
  `0be3fab8fd88c4d5bf51707c92701340`** (sun4i-tcon.ko inchangé). Le print de
  debug existant logguera `mode_set 720x1280 size=04ff02cf` au boot → vérif on-device.
- **⚠ PAS encore testé on-device** (device offline). Déploiement : base64-pipe +
  md5-verify (mémoire device-binary-transfer-verify), remplacer
  `/lib/modules/7.4.0-rc1-dirty/.../sun8i-mixer.ko`, reboot, lire
  `size=04ff02cf` dans dmesg + registres live (0x51c1004 / 0x5281008 / 0x528108c /
  0x5008108 = 0x04ff02cf) + **test VISUEL averti** (mémoire warn-before-device-test).

## 2. Ce qui reste ouvert (par ordre)

1. **Test HW du .ko size-fix** (ci-dessus) — si image (même déchirée) : la transpose
   était le mur ; reste le pacing propre (retirer AUTO/hrtimer, pacing stock =
   counter IRQ TCON0 + TE). Si toujours noir : FRAME_END/fetch en amont.
2. **T1** (v9 §3.1) : AHB, un seul re-arm → FRAME_END une seule fois ? (confirme
   « un frame par arm »).
3. **T2** (v9 §3.2) : RCQ, 1 tête dirty + kick → application immédiate ou différée
   à la frontière de frame ? (deadlock RCQ : kick vide ACCEPT 246/256, FINISH 0/256
   déjà prouvé).
4. **Envoi du post linux-sunxi** (brouillon `linux-sunxi-post-DRAFT.txt` +
   `docs/A523-DE33-RT-HANDOFF-QUESTION.md` mis à jour avec P0b + transpose + T3 —
   voir §3 ci-dessous).

## 3. Mises à jour des brouillons d'envoi (faites dans ce workdir)

- `linux-sunxi-post-DRAFT.txt` : ajout P0b (AUTO+src=0 → rien, beam-gate deadlock)
  + bug transpose trouvé/corrigé (détails BSP + md5 du .ko) + réponses T3
  (LEN = octets du tableau de têtes ; pas de kick bootstrap ; kicks par frame depuis
  l'IRQ manager ; GLB_CTL 0xd1 = enables vendor runtime).
- `docs/A523-DE33-RT-HANDOFF-QUESTION.md` : section « Updated 2026-11-04 » avec la même
  matière (le post pointe vers ce doc dans le repo public).

## 4. Faits de contexte vérifiés cette session

- Repo GitHub `MidG971/trimui_smart_pro_s` : 1 issue ouverte (#1 « [hw] Display
  drivers », discussion oct. avec korewaChino —rien de nouveau), 0 PR. Dernier commit
  2026-11-02 (v7.4-rc1 evidence). **Aucun driver A523 display upstream** : torvalds
  master + drm-misc-next = 0 hit `sun55i` dans sun8i_mixer.c/sun4i_tcon.c/
  sun6i_mipi_dsi.c (dtsi SoC existe). ut-slayer v0.5 (6.18.55) a le macro corrigé
  (confirme notre fix) mais reste HDMI/T527 — pas de piste command-mode DSI.
- Device `trimui-smartpro-s` : **offline** (vu il y a ~20 h) au début de session —
  à rallumer pour le test visuel. Build server `compiler-rock3b` : up, arbre 7.4
  `/root/rebase-7.4-rc1` (port complet appliqué, .config présent).

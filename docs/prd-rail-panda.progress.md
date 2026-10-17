---
status: done
prd: docs/prd-rail-panda.md
started: 2026-10-17
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-17 | src/lib/panda.ts (+test) | scene order (wake first), tricks, switch | AC1 |
| 2026-10-17 | src/redesign/RailPanda.tsx, panda.css (+test) | SVG panda, 9 scenes, hides < 96 px, pauses when hidden, reduced motion | AC2 |
| 2026-10-17 | Rail.tsx, ControlScreen.tsx, GridScreen.tsx, App.tsx | busy = any agent working (all workspaces) | AC2 |
| 2026-10-17 | src/styles/tokens.css, SettingsModal.tsx | panda tokens both themes; Appearance switch | AC3 |

## Kararlar
- Busy is global (any workspace), not the scoped agent list — the panda is the whole app's mood.
- `transform-box: fill-box` only on moving parts: on all ellipses it moved the eye patches' static rotate().
- Dev-only `muya:panda-scene` event to screenshot every scene (`import.meta.env.DEV`).
- AC3: Playwright WebKit frames of all 9 scenes dark + light; mock with working agents → wake → chop → stone.

## Dersler

## Revision 2026-10-18 (operator feedback)
- The hand-drawn SVG panda ("ucuza kaçmışsın") and the Blender attempts were dropped. The operator picked two LottieFiles animations in one style: sleeping on bamboo (idle) and playing a game (busy).
- Assets: `src/assets/panda/{sleeping,gaming}.svg`. The 80 embedded PNGs were scaled to 30% and path precision cut to 0.1, which takes 2.0 MB to 1.1 MB (about 210 KB gzipped). Frames compared with the originals: identical. The viewBox was cropped to the drawing.
- Shown as `<img>` (self-animating SVG, no player, no script). Unmounted while the window is hidden. Dark theme: `--panda-halo` light edge.
- Credits in `THIRD_PARTY_LICENSES.txt` (generator updated). Lottie Simple License: commercial use allowed, attribution optional.
- The scene engine (9 CSS scenes, tricks) was removed. The busy/idle signal is unchanged.

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

## Revision 2026-10-18 (b): jointed scenes
- The operator asked for the original scene ideas (rolling, snapping bamboo, tofu, mantı, fart and run) with moving joints, not a sitting pose that only slides ("eklemleri hareketli olmalı"). Rolling must start from a hilltop.
- Five new SVGs in `src/assets/panda/` (bamboo, tofu, manti, fart, roll, 86–169 KB each). The head and face are the gaming panda's original art. The torso and limbs are redrawn in the same style with shoulder, elbow, hip and knee joints. Poses are set by where the paws and feet go, and the joints are solved from that. Everything is pure CSS keyframes, with no script.
- Roll: the panda walks to a hilltop, wobbles, curls into a ball and rolls down without sliding (rotation matches the distance travelled). It sits dizzy with stars, shakes it off and walks away while the camera pans back.
- Rotation (`src/lib/panda.ts` `firstScene` / `nextScene` / `SCENE_MS`):
  - busy = gaming first, then weighted gaming/bamboo/tofu/manti 3 each and fart 1, never the same scene twice in a row.
  - idle = sleeping 3 : roll 1, and roll never twice in a row.
  - A change of mood restarts with that mood's first scene, set during render so there is no wrong-scene frame.
  - The timer runs only while the panda is on screen.
- Tests: picker sequences (pools, no repeats, fart rarer, edges), rotation with fake timers, mood reset.
- Lesson L74: check every view of a demo video frame by frame before sending. WebKit's recordVideo did not repaint the large `<img>`.

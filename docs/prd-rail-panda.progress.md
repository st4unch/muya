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

## Revision 2026-10-18 (c): kung fu + sleep after 5 quiet minutes
- Operator: sleep only when idle and nobody has touched Muya for 5 min. When a prompt is sent, open with kung-fu-panda-style flying moves that snap bamboo, and give it a wide area.
- Three moods (`pandaMood`): busy (any agent working) / idle (awake) / asleep (no work, no key, click, move or scroll for `SLEEP_AFTER_MS` = 5 min).
  - The activity listeners are window capture-phase, so typing in xterm or Monaco counts.
  - The countdown restarts when work stops.
  - The 5 s check runs only while the panda is enabled.
- Pools:
  - busy = kungfu (first) 3, gaming 3, bamboo/tofu/manti 2, fart 1.
  - idle = roll (first) 3, tofu/manti 2.
  - asleep = sleeping.
- `kungfu.svg` is a tall frame (750×1700, about 62×141 px in the rail). The panda leaps up into the rail's empty height without shrinking. If the box is shorter, the top is clipped and the ground action stays visible. The panda wears a red headband with fluttering tails, drawn on the head layer.
- Verified:
  - Frames checked over the whole loop, at large size and at rail size.
  - The mock UI opens with kung fu in dark and light, the image loads, and there are no console errors.
  - Fake-timer tests cover sleep at 5 min, waking on a key press, and staying awake while busy.

## Revision 2026-10-18 (d): kung fu removed
- The operator rejected every hand-drawn version of the kung fu panda: the jointed rig ("kaplumbağa"), a borrowed Lottie rig ("eklemleri kaynıyor"), ball joints ("amatörce"), rubber-hose limbs ("prisma") and a new black-and-white design ("berbat").
- Decision: character art comes only from professional sources (LottieFiles, the operator picks). Muya does the scene logic.
- `kungfu.svg` was removed. busy starts with `gaming` again. The 5-minute sleep rule stays.
- Next: LottieFiles candidates (same creators first) for the operator to choose from.

## Revision 2026-10-18 (e): first LottieFiles (Weblodge) scene, waving
- The operator picked 9 Weblodge animations from LottieFiles: roll, eating noodles, celebrating, waving, fan dance, teaching, travelling, notes, bowing. The purple set was dropped. Started with one sample, "Panda waving" (1509739). Its page says Lottie Simple License (free, commercial use allowed).
- Shipped as Lottie JSON (`src/assets/panda/waving.json`), played by `lottie-web` 5.12.2 (MIT, exact pin) through its light build `lottie_light`:
  - It is the SVG renderer only and has no expression engine. A grep finds no `eval`/`new Function`, so it fits the CSP `script-src 'self'`.
  - The player and the JSON are dynamic imports, about 48 KB + 41 KB gzipped, loaded only while the scene shows. The player is destroyed when the scene goes away.
  - `npm audit --omit=dev`: 0 vulnerabilities. npm needed `NODE_EXTRA_CA_CERTS` pointing at the system keychain export on this machine (TLS interception).
- New component `src/redesign/LottiePanda.tsx`. `RailPanda` shows Lottie scenes through it and SVG scenes as `<img>` like before.
- idle = waving only. The roll scene (hand-drawn) is removed. `nextScene` keeps a mood's only scene instead of returning nothing.
- Dark theme keeps the existing thin `--panda-halo`. The operator compared it with a light disc and a thick outline and chose the current one.
- Verified:
  - Mock UI with idle agents, in dark and light: the waving `<svg>` renders, the arm moves between screenshots, and there are no console errors.
  - Tests: picker, Lottie options (svg/loop/container/data), destroy on scene change. 503/503, `tsc` and `vite build` pass.

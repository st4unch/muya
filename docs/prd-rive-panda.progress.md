---
status: done
prd: docs/prd-rive-panda.md
started: 2026-10-20
---

## Faz Çıktıları
- 17 scenes built and rendered (videos outside the repo); pipeline proven with the Rive CLI 1.6.0.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-20 | src/assets/panda/rive/*.riv | 17 scenes (721 KB), built by tools/panda-studio/build_all.sh | AC1 |
| 2026-10-20 | src/redesign/RivePanda.tsx | lazy Rive lite runtime + bundled wasm; full-artboard canvas in a cropping 62 px box | AC1 AC4 AC5 |
| 2026-10-20 | src/redesign/RailPanda.tsx | scene table (file, artboard size, crop); board on `teacher` | AC1 AC2 |
| 2026-10-20 | src/lib/panda.ts (+tests) | 17-scene union, SCENE_MS, new pools, first scenes | AC2 AC3 |
| 2026-10-20 | src-tauri/tauri.conf.json | CSP `script-src 'self' 'wasm-unsafe-eval'` | AC4 |
| 2026-10-20 | package.json | + @rive-app/canvas-lite 2.44.0, − lottie-web; Lottie json/svg assets and LottiePanda removed | AC6 |
| 2026-10-20 | tools/panda-studio/ | generator, art, render/crop tools, README | — |
| 2026-10-20 | tools/third-party-notices.mjs (+ regenerated notices) | artwork credits for the Rive panda | — |

## Kararlar
- Runtime: `@rive-app/canvas-lite@2.44.0` (MIT, published 2026-09-30, not the 3-day-old 2.45.0); lite = no text/audio/layout, which the scenes do not use.
- The teacher's board stays HTML (no font file to ship, Muya already writes the status there).

## Dersler
- Rive web Layout minX/minY/maxX/maxY bound the canvas area drawn into, not the artboard part shown: cropping = full-artboard canvas inside an overflow-hidden box.
- @rive-app/canvas-lite is CommonJS: under Vite dev the API is the module's `default`.
- Under the app CSP without 'wasm-unsafe-eval' the runtime draws nothing (proved 0/17 vs 17/17 in WebKit with the exact header).

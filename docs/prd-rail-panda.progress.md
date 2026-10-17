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

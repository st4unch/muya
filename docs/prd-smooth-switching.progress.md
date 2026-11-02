---
status: done
prd: docs/prd-smooth-switching.md
started: 2026-11-02
---

## Faz Çıktıları
- Baseline (WebKit, mock, 3 sessions, 24 switches): click → 2nd frame median 95.0 ms, max 117 ms; worst frame median 52 ms.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-11-02 | src/lib/webglRenderer.ts (+test) | `parkWebgl`/`unparkWebgl`, WARM_HIDDEN=6 warm pool, oldest suspended | AC1 |
| 2026-11-02 | src/components/Terminal.tsx (+webgl test) | hide parks, show reuses; no fit/pty_resize while parked in the pool; pty_resize only on a real size change | AC2 |
| 2026-11-02 | src/redesign/terminalHosts.ts (+test) | 140 ms opacity fade on arrival in a slot; getComputedStyle only on a move | AC3 |
| 2026-11-02 | src/index.css, src/App.tsx | `.muya-page-in` page fade, reduced-motion off; pool marked `data-terminal-pool` | AC3 |

## Kararlar
- Found during measurement: the hidden pool (1000×640) refit every parked terminal → 3 pty_resize per switch (each a full Claude redraw in the real app). Parked terminals now keep their on-screen size: 0 per switch.
- After (WebKit, mock dev server, same script): click → 2nd frame median 64-66 ms (baseline 95, −31%); worst frame median 41-46 ms (52). JS per switch is a few ms (Chromium CPU profile); the rest is WebKit layout/paint.
- Fade: Web Animations API on the host (no forced layout), CSS keyframes for pages; both off under Reduce motion. Screens dark + light: terminal text present right after a switch, opacity 1.
- AC5 (real debug build) NOT done: the operator is away (HID idle > 80 min, display asleep).

## Dersler

---
status: done
prd: docs/prd-load-test.md
started: 2026-11-02
---

## Faz Çıktıları
- UI baseline (prod mock bundle, headless WebKit, 10 s each): idle ~92-99 fps at 7/13/25
  sessions; "normal" (8 KB/s per terminal) 20 / 9 / 4 fps; switch p50 226 / 376 / 777 ms;
  input p50 at 25 sessions 346 ms. WebKit RSS 1.2-2.0 GB under load.
- Isolation (13 sessions, dev): visible terminal streaming alone 98 fps; hidden terminals
  streaming 20 fps. Chromium: 60 fps for all. Pool CSS (contain / content-visibility /
  display:none) did not fix it (19-28 fps).
- Plain xterm, 24 hidden instances in WebKit: 50 small writes/s each 40 fps, same bytes in
  5 writes/s each 69 fps → cost is per term.write in WebKit.
- Real app (debug build, fake HOME, 8 stand-in sessions × 64 KB/s): muya ~48% CPU,
  WebContent ~45%, RSS 142 MB + 574 MB; broker list/read p50 7 ms, p95 17-26 ms.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-11-02 | src/mock/installMock.ts | `ptyIds`, `feedPty` helpers; `feed` reuses them | AC1 |
| 2026-11-02 | scripts/loadtest/sample.mjs | ps-based CPU/RSS sampler + percentile | AC1, AC2 |
| 2026-11-03 | scripts/loadtest/ui.mjs, vite.loadtest.config.mjs | UI load test on prod mock bundle | AC1 |
| 2026-11-03 | scripts/loadtest/app.mjs, fake-claude.sh | real-app load test via broker, stand-in claude | AC2 |
| 2026-11-03 | src/components/Terminal.tsx (+webgl test) | hidden tab output held 150 ms, one write; flushed on show/exit | finding |
| 2026-11-03 | .gitignore | `scripts/*` + `!scripts/loadtest/` | AC3 |

## Kararlar
- Display asleep → WKWebView rAF is throttled, so render metrics come from headless
  Playwright WebKit; the real-app test measures the backend (PTY pipeline, broker, CPU/RSS).

- Login zsh runs path_helper after .zshenv: the first run started an installed (old)
  claude on the throwaway HOME. Fixed: PATH also in .zprofile/.zshrc, the test aborts
  unless every session runs the stand-in, cleanup kills the debug app's whole tree.

## Dersler

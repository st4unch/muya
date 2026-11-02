# Load test results — 2026-11-03

How to run: `npm run loadtest` (UI, headless WebKit on the mock app; `--browser chromium`
for comparison) and `npm run loadtest:app` (real app on a throwaway HOME; needs
`npm run dev` and `cargo build`, `--bin src-tauri/target/release/muya` for an optimized
build). Scripts: `scripts/loadtest/`.

## UI (headless WebKit, production mock bundle, 10 s per scenario)

"normal" = every terminal streams ~8 KB/s; "heavy" = visible 1 MB/s, others 64 KB/s.
Before → after holding hidden-tab output (Terminal.tsx `HIDDEN_FLUSH_MS`).

| Sessions | Scenario | fps | frame p95 ms | input p50 ms | switch p50 ms | WebKit RSS MB |
|---|---|---|---|---|---|---|
| 7 | normal | 20 → 62 | 103 → 72 | 5 → 18 | 226 → 164 | 1197 → 1213 |
| 7 | heavy | 14 → 64 | 112 → 72 | 93 → 14 | 220 → 160 | 1299 → 967 |
| 13 | normal | 9 → 29 | 292 → 183 | 10 → 15 | 376 → 379 | 1525 → 1284 |
| 13 | heavy | 9 → 27 | 315 → 185 | 7 → 23 | 402 → 377 | 1337 → 1292 |
| 25 | normal | 4 → 14 | 712 → 378 | 346 → 24 | 777 → 769 | 2020 → 1585 |
| 25 | heavy | 3 → 11 | 715 → 393 | 359 → 20 | 907 → 759 | 1972 → 1436 |

Idle is ~92-99 fps at every size. "After" also pushed about twice as many bytes through
(the page kept up with the generator).

Same page in Chromium (Electron / CEF engine), after the fix: 50-57 fps at 7-25
sessions under load, switch p50 18-24 ms, RSS 0.56-0.95 GB. Headless Chromium rasterizes
in software, so its CPU figure (600-700%) is not comparable.

## Findings
1. **WebKit pays per `term.write`.** Visible terminal streaming alone: 98 fps. Hidden
   terminals streaming: 20 fps. Plain xterm.js, 24 hidden instances: 50 small writes/s
   each → 40 fps, the same bytes in 5 writes/s → 69 fps. Fixed by holding a hidden tab's
   output for 150 ms (flushed on show and on exit).
2. **Still slow at 13+ busy sessions in WebKit** (27-29 fps, switch ~380 ms); Chromium
   stays at 50+ fps. The remaining cost is WebKit itself, not our JS (Chromium profile:
   JS is a few % of the time).
3. **Rust side is not the bottleneck.** Real app, release build, 8 sessions × 64 KB/s:
   muya ~38% CPU, mostly threads blocked in `read` / semaphore waits (`sample`);
   WebContent ~44%. Broker `list_sessions` / `read_session` p50 6-8 ms under load.
4. Pool CSS (`contain`, `content-visibility`, `display:none`) did not help (19-28 fps).

## Caveats
- With the display asleep the real app's webview is throttled; its render cost is
  measured in headless WebKit instead.
- The real-app run restores the dev build's own saved tabs, adding some shells.

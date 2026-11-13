# Large files: measurements and thresholds

Measured 2026-11-13/14 on the operator's Mac (Apple Silicon, headless Chromium for Monaco, the dev
`MuyaNative.app` for Native). Realistic generated files: pretty JSON, a log, TypeScript source,
Markdown, and minified JS on ONE line. Tools: `tools/largefile-perf/` (classic, Playwright) and
`native/app/measure-largefile.sh` (Native). Not verified in a real signed app; see the end.

## Why the old numbers were wrong

| Old | Reality |
|---|---|
| "1 MB is large" | Monaco with every feature on opens 50 MB in 0.4 s. |
| Monaco "just works" up to 20 MB | Monaco silently turns tokenization, folding, bracket matching OFF at **300 000 lines or 20 MB**, whichever comes first. 5 MB of pretty JSON is already 365 000 lines, so it opened with no highlighting at all. |
| 8 MB Rust cap in `read_file` | It refused everything the new policy opens. Raised to 128 MB. |

## Classic (Monaco), every feature on (wrap, minimap, diff, highlighting)

Open = time until the first line is on screen; HL = until colored tokens; type = median key-to-paint.

| File | MB | open ms | HL ms | CPU s (open) | wrap / map / diff ms | type ms | scroll worst frame |
|---|---|---|---|---|---|---|---|
| JSON | 1 | 42 | 69 | 1.4 | 145 / 91 / 131 | 24 | 17 |
| JSON | 5 | 67 | 122 | 3.1 | 108 / 112 / 252 | 16 | 17 |
| JSON | 20 | 186 | 220 | 5.7 | 318 / 230 / 509 | 8 | 1400 (once, see below) |
| JSON | 50 | 434 | 469 | 4.1 | 562 / 490 / 1596 | 3 | 17 |
| JSON | 100 | 813 | 857 | 5.2 | 1443 / – / 2579 | 3 | 33 |
| JSON | 200 | 1611 | 1687 | 7.5 | 3294 / – / 7539 | 3 | 17 |
| TS | 20 | 122 | 150 | 4.7 | 167 / 178 / 258 | 17 | 17 |
| TS | 50 | 236 | 270 | 2.9 | 390 / 327 / 499 | 7 | 17 |
| Markdown | 20 | 168 | 205 | 2.9 | 241 / 210 / 407 | 14 | 17 |
| Markdown | 50 | 336 | 417 | 2.7 | 503 / 377 / 587 | 10 | 17 |
| Log (plain) | 20 | 75 | – | 1.4 | 130 / 157 / 175 | 18 | 17 |
| Log (plain) | 50 | 136 | – | 1.5 | 243 / 276 / 266 | 7 | 17 |
| Log (plain) | 200 | 478 | – | 3.8 | 839 / – / 979 | 6 | 17 |
| one-line JS | 1 | 32 | 155 | 2.7 | 60 / 63 / 249 | 20 | 33 |
| one-line JS | 5 | 38 | – | **9.7** | 85 / 80 / 184 | 17 | 17 |
| one-line JS | 10 | 48 | – | **24.6** | 105 / 80 / 82 | 25 | 317 |
| one-line JS | 50 | 125 | – | **28.2** | 313 / 148 / 232 | **142** | 17 |

Browser memory (all Chromium processes, includes the harness's own copy of the text): 20 MB JSON ≈ 2 GB,
50 MB ≈ 1.6–2.6 GB, 200 MB ≈ 3–3.9 GB. The cost is memory, not time.

Before the fix (Monaco's own cutoff left on): JSON ≥ 5 MB, Markdown ≥ 5 MB and TS ≥ 10 MB opened with no
highlighting (`highlightMs: null` in the first matrix).

Rendered Markdown (marked + DOMPurify + layout, main thread, no way to interrupt): 0.25 MB 112 ms,
1 MB 415 ms, 2 MB 806 ms, 4 MB 1.6 s, 8 MB 3.1 s. Native's renderer: 0.5 MB 0.4 s, 1 MB 0.77 s,
2 MB 1.5 s, 4 MB 2.9 s.

Known hitch: on a 20 MB / 1.3 M-line JSON, scrolling within ~5 s of opening (while Monaco's background
tokenization is still running) stalls one frame for ~1.4 s. Later scrolling is 60 fps. TS 5–10 MB: 0.2–0.4 s.

## Native (NSTextView read-only preview)

Native has NO code editor: `Viewers.swift` is a read-only `NSTextView` preview. There is no highlighting,
minimap, wrap, or diff to turn off; the old limit was a 2 MB read cap plus a 1 MB / 8 MB gate.
NSTextView lays out lazily, so size is cheap; one huge LINE is not.

| File | MB | open+draw ms | CPU s | RSS MB | scroll mid/end ms |
|---|---|---|---|---|---|
| JSON | 3 | 150 | 0.04 | 138 | 6 / 3 |
| JSON | 20 | 190 | 0.08 | 242 | 5 / 3 |
| JSON | 100 | 377 | 0.26 | 706 | 5 / 3 |
| TS | 20 | 415 | 0.32 | 816 | 18 / 14 |
| TS | 100 | 1400 | 1.25 | 1080 | 15 / 11 |
| Log | 20 | 190 | 0.09 | 753 | 14 / 8 |
| Log | 100 | 1335 | 1.17 | 917 | 14 / 12 |
| Markdown (shown as text, over 1 MB) | 100 | 1495 | 1.32 | 1213 | 13 / 11 |
| one line, 0.1 MB | 0.1 | 349 | 0.32 | 175 | 0 / 0 |
| one line, 0.5 MB, **unguarded** | 0.5 | 1205 | 1.28 | 442 | 1 / 1 |
| one line, 1 MB, **unguarded** | 1 | 14979 | 15.0 | 1354 | 19 / 18 |
| one line, 5 MB, **unguarded** | 5 | 77877 | 73.4 | 3548 | 81 / 89 |
| one line, 20 MB, guarded | 20 | 227 | 0.14 | 345 | 2 / 1 |
| one line, 50 MB, guarded | 50 | 345 | 0.27 | 601 | 3 / 1 |

(RSS in the log/TS rows includes a baseline carried over from the earlier rows of the same run.)

## Thresholds (classic and Native, size ones identical)

| Constant | Old | New | Evidence |
|---|---|---|---|
| LARGE (features off, still editable) | 1 MB | **50 MB** | every feature stays interactive to 100 MB; 50 keeps wrap/diff under a second and memory near 2 GB |
| PROMPT ("load anyway") | 8 MB | **128 MB** | 200 MB still opens in 1.6 s but needs ~4 GB in the webview |
| HEAD (after "Open anyway") | 8 MB (Native 2 MB) | **16 MB** | Rust `read_file_prefix` ceiling |
| MD_RENDER_MAX | 512 KB | **1 MB** | rendering is linear, un-interruptible: ≈0.4 s (classic) / 0.8 s (Native) |
| Long line | none (Native: any file ≥ 1 MB was cut every 2000 chars) | classic **2 MB**, Native **200 KB** | engine-specific: Monaco 5 MB one-line = 10 s CPU; NSTextView 1 MB = 13 s |

The long-line limit is the only number that differs, because the two engines break at different points.

Banner (classic) appears only when something is off, and says which limit it is: "over 50.0 MB … highlighting,
minimap, wrap and diff are off … Still editable." or "has a line 3.0 MB long (over 2.0 MB) …".

## Perf gates

- Classic: `npm run perf:largefile` (needs `npx vite --port 1431` running): 20 MB JSON must open in < 1 s,
  highlight in < 2 s, type in < 100 ms median, and show no banner.
- Native: `BUDGET_MS=1500 native/app/measure-largefile.sh "json" "20"` exits 1 if open + first draw is over budget.

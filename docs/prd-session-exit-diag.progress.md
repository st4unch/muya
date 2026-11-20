---
status: active
prd: docs/prd-session-exit-diag.md
---

# Progress: session exit diagnostics (5.0.1)

| Date | Step | Result |
|---|---|---|
| 2026-11-20 | muyad RPC `sessions.tail` + `tail_lines` | `cargo test -p muyad --test rpc the_last_lines_stay_readable_after_the_process_exited` passes |
| 2026-11-20 | `ExitDiagLogic.swift` + `ExitDiagTests.swift` | classification, launch argv, preflight mapping, cache: all pass in `native/app/build.sh test` |
| 2026-11-20 | App: `ExitDiag.swift`, `Store.launchClaude/relaunch/noteExit`, `Tile` exit panel | builds with `-warnings-as-errors` |
| 2026-11-20 | Version 5.0.1 (tauri.conf.json, src-tauri/Cargo.toml + lock, package.json + lock) + CHANGELOG | `scripts/check-version.sh` passes |

## Decisions
- A Claude tab started by Muya runs the command under the login shell with a small wrapper instead of typing it into a shell, because only then does muyad see Claude's exit status. After a clean exit the wrapper `exec`s the login shell, so `/exit` leaves the tab as before.
- Tail comes from muyad's terminal state (visible screen rows, trailing blanks trimmed), not from raw bytes: it is readable text and needs no VT parsing in the app.
- Dev verification note: muyad refuses an orphaned peer that is not responsible for itself, so the dev app must be a live child of the driving script.

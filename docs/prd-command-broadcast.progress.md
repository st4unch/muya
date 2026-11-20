---
status: done
feature: command-broadcast
---

# Progress: Command broadcast

## Phases
- PRD written: `docs/prd-command-broadcast.md`.
- Daemon: `operator_send` (muya-core broker) + RPC `sessions.send_command` (muyad).
- App: header `Command` button replaces `Compact`; dialog + result list; ⌘⇧K; `ThemeIcon.command`; mock handler; debug hooks.
- Tests: 3 muya-core broker tests, 1 muyad rpc test, 7 Swift unit tests (`Tests/CommandTests.swift`).

## Decisions
- Terminal ids as targets, resolved to Claude sessions in the daemon.
- Verbatim typing (no chat wrapper): a slash command must start the line.
- No "Typed by" toast for operator sends; an audit line goes to the debug log.
- State `sent` added next to the four requested ones: slash commands are not reliably visible in the transcript, so claiming `submitted` would be a guess.
- opencode tabs excluded (not Claude sessions for the tracked delivery).

## Verification
- `native/app/build.sh test`: 258 tests, 0 failures (ThemeTests icon count bumped 39 -> 40).
- `cargo test -p muya-core --lib`: 473 passed. `cargo test -p muyad --no-fail-fast`: all pass except `tests/broker.rs` (2 tests), which build `src-tauri` and fail in this worktree on the Tauri build script (environment, unrelated).
- Dev-build screenshots (mock mode, dark + light): button, dialog, pick list, sending, results.
- Not verified: a real Claude session receiving `/compact` through the daemon (no live Claude in this environment).

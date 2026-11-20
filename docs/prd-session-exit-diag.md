# Mini-PRD: Session exit diagnostics and launch preflight (Muya 5.0.1)

## 1. Problem
A Brew upgrade of node left `claude`'s hooks and MCP servers aborting at launch (SIGABRT, missing dylib). In Muya the Claude tab
went dead with no explanation: no exit code, no output, no hint that node was the cause. Muya also never checked that the
toolchain a new tab will use can run at all.

## 2. Scope
1. **Exit panel.** A Claude tab that Muya started (resume, resume-on-launch, restart plan, "Open Claude here") and that ends with a
   non-zero code, a signal, or exit 0 within 10 s of a resume stays open and shows: exit code or signal name, the last ~20 lines of
   output, and the buttons Resume (same command, same folder, fresh tab) and Close.
2. **Preflight (warning only).** When such a tab is launched Muya probes, in the same login shell the tab uses (so the same PATH, also from
   a Finder-launched app with the minimal GUI PATH): `claude --version` (failure: toast with the path tried) and `node -e 0`
   (failure: toast "node is broken - hooks and MCP servers may fail" plus the first stderr line). Each probe has a 2 s limit, runs
   in the background, the result is cached 60 s. It never blocks or delays the launch.
3. Version 5.0.1 and a CHANGELOG entry.

Out of scope: plain shell tabs, tabs the operator types `claude` into by hand (no way to see Claude's exit status), SSH tabs.

## 3. Design
| Piece | Where |
|---|---|
| Classification (`ExitDiag.classify`), launch argv, probe mapping, cache | `native/app/Sources/Logic/ExitDiagLogic.swift` (pure, unit-tested) |
| Probes, store bookkeeping, `ExitPanel` view | `native/app/Sources/App/ExitDiag.swift` |
| Last lines | new muyad RPC `sessions.tail` (`native/crates/muyad/src/rpc.rs`, `tail_lines` in `lib.rs`); muyad keeps the terminal state after the process exited |
| Tab start | `Store.openShell` routes Claude commands to `Store.launchClaude`, which spawns `login-shell -l -i -c '<claude cmd>; rc=$?; [ rc = 0 ] && exec $SHELL -l; exit $rc'` |

The wrapper is why the exit status is known: before, the command was typed into a shell that outlived Claude. After a clean exit the tab
continues as the login shell exactly as it did (nothing changes for `/exit`); only a non-zero end terminates the process so muyad reports the status.
muyad reports 128 + n for a signal; the wrapper keeps that number, so SIGABRT shows as "SIGABRT (exit status 134)".

## 4. Acceptance criteria
- AC1 `classify`: plain shell never, 0 after normal run never, non-zero/signal always, 0 within 10 s of a resume yes (unit tests).
- AC2 `sessions.tail` returns the last lines after the process exited (muyad rpc test).
- AC3 Preflight mapping: claude failure names the path; node failure is a warning with the first stderr line; timeouts handled (unit tests).
- AC4 Dev run with stub claude (exit 1, SIGABRT) and a broken stub node: panel and toast visible in dark and light (screenshots).
- AC5 A plain shell tab that runs `exit` gets no panel.

## 5. Integration (evidence)
- Tabs are started by `Store.openShell` (`Model.swift`) from `SessionsPage.resume`, the resume-on-launch plan (`UI.swift`) and the restart plan (`RestartDialog.swift`); all pass through it.
- Exit events already reach `Store.handle` (`.control(.exited)`); the panel hooks in there and in `Tile.configure` (`UI.swift`).
- UI uses the app's own `Theme*` kit (`ThemedBox`, `ThemedButton`, `ThemedText`), the same parts as the toasts and dialogs.
- muyad RPC follows `rpc.rs` (`on_muyad`); no protocol change.

## 6. Protection list
Plain shell tabs, `/exit` behaviour, the New agent dialog (still types its command), MCP `open_session`, session order/naming, the scheduler.

## 7. Risks
- A shell alias/function for `claude` still works for zsh/bash/sh (the command runs in the login shell itself); for fish and others the command runs through `/bin/sh` and aliases are not seen.
- Ctrl-C ends Claude with 130 (shown as SIGINT): accepted, the panel offers Resume/Close.

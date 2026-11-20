---
status: done
prd: docs/prd-native-mcp-terminal.md
started: 2026-11-11
---

## Phase output
Single phase. Broker arms + host seam in muya-core, muyad `terminals.rs`, sidecar tool defs, Swift adopt-on-event, tests, live run, skill docs.

## Changes
| Date | File | What |
|---|---|---|
| 2026-11-11 | native/crates/muya-core/src/broker.rs | `TerminalInfo` + `terminal_list/open/type` host seam, `open_terminal` / `send_terminal` / `broadcast` arms, `plan_broadcast`, `deliver_chat` extracted from send_to_session, 14 unit tests | AC2-AC6 |
| 2026-11-11 | native/crates/muyad/src/terminals.rs, broker_host.rs, lib.rs | `Muyad::terminals/open_terminal/type_text`, name registry, `muya://terminal-opened` | AC2, AC5, AC7 |
| 2026-11-11 | src-tauri/src/bin/muya_ssh_mcp.rs + tools-list.json | three sidecar tools, snapshot | AC1 |
| 2026-11-11 | native/app/Sources/App/Model.swift, Logic/StartedTerminal.swift | adopt the shell on the event, no focus steal | AC7 |
| 2026-11-11 | native/crates/muyad/tests/term_tools.rs | real muyad+ptyd e2e (open, send, enter:false, broadcast x3) | AC8 |
| 2026-11-11 | claude-plugin/muya-mcp | skill docs, plugin 1.0.9 | - |

## Verification
- `cargo test --workspace` (native): all green; `build.sh test`: 201 tests, 0 failures; `cargo build --bin muya-ssh-mcp` ok.
- Live (dev stack, isolated HOME, real sidecar -> broker socket -> muyad -> MuyaNative): open_terminal x3 -> tabs live-a/b/c appear named;
  send_terminal live-a "echo hi-$((6*7))" -> tab shows `hi-42`; broadcast kind=shell "echo B-$((6*7))" -> 3 sent, all 3 tabs show `B-42`;
  ambiguous target "live" -> error listing the 3 candidates; open_terminal command runs (`FIRST42`).
- Not live-tested: skip-waiting on a real Claude permission prompt and skip-self on a real Claude session (unit-tested with a fake host).

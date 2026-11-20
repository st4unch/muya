# Mini-PRD: terminal tools in muya-mcp (open_terminal, send_terminal, broadcast)

- Date: 2026-11-11
- Type: mini-PRD
- Operator request: "terminal açma ve terminal'e komut gönderme özelliği, aynı anda tüm açık sessionlara komut gönderme özelliği"

## 1. Problem
`open_session` only starts a Claude tab and `send_to_session` only sends a chat message to a Claude session found through
`claude agents`. An agent cannot start a plain shell (build, server, log tail), cannot type a raw command into any tab, and
cannot reach all tabs at once.

## 2. Scope
- In: three MCP tools served by the native daemon (muyad) through the existing broker: `open_terminal`, `send_terminal`, `broadcast`.
- Out: the Tauri app (its broker answers "terminal tools need the native Muya app"); reading a shell's screen (`read_session` is
  Claude transcripts only); closing shell tabs.

## 3. Tools (arg shapes follow `open_session` / `send_to_session`)
| Tool | Args | Does | Returns |
|---|---|---|---|
| `open_terminal` | `name?`, `cwd?`, `command?` | New shell tab (not Claude), optional first command + Enter | `{id, name}` |
| `send_terminal` | `target`, `command`, `enter?=true`, `include_waiting?` | Raw text + Enter into one tab (shell or agent) | `{target, bytes, enter}` |
| `broadcast` | `command` or `text`, `kind?=all\|claude\|shell`, `deliver?=keys\|muya`, `enter?`, `include_waiting?` | Same text to every matching tab | `{sent, skipped, results[]}` one row per tab |

`send_terminal` is NOT `send_to_session`: no "[message from X via Muya]" wrapper, no idempotency, works on shells.
`broadcast deliver:"muya"` is the chat wrapper, Claude sessions only (a shell would run it as a command).

## 4. Acceptance criteria (binary)
- [ ] AC1: `tools/list` of the sidecar shows the three tools with the shapes above (snapshot `muya-core/tests/snapshots/tools-list.json`).
- [ ] AC2: `open_terminal` returns `{id,name}`; the name is unique (case-insensitive), default `terminal-N`; `cwd` must be a folder; the first command runs in the new shell.
- [ ] AC3: `send_terminal` resolves `target` as terminal id, Claude session id, exact name, then unique substring; an ambiguous name returns the candidates and types nothing.
- [ ] AC4: text is capped at 16 KiB, empty/whitespace and NUL are refused; the text goes in as a paste, so control bytes cannot act as keys.
- [ ] AC5: a tab waiting on a permission prompt is refused by `send_terminal` and reported `skipped` by `broadcast`, unless `include_waiting`.
- [ ] AC6: `broadcast` never types into the caller's own session (matched by its Claude session id), caps at 64 tabs, and one failing tab does not stop the rest.
- [ ] AC7: native app: a tab opened by `open_terminal` appears in the session list under its name without stealing focus.
- [ ] AC8: live in a dev native stack through the real sidecar: `open_terminal` → `send_terminal "echo hi"` → the tab shows it; `broadcast` to 3 tabs → all 3 show it.
- [ ] AC9: every send is logged (id, name, bytes, enter; a 60-char control-free preview in the opt-in debug log).

## 5. Integration (evidence)
- Same socket, same caller check as every other tool: `serve_connection` rejects any peer uid but the owner (`native/crates/muya-core/src/broker.rs` `peer_uid`, the accept loop ~l.2428); the new ops are arms of `handle_request` (l.~807) behind it.
- Host seam: three default methods on `BrokerHost` (`terminal_list/open/type`, l.~123) answering `NATIVE_ONLY`; `MuyadBrokerHost` implements them (`native/crates/muyad/src/broker_host.rs`) on `Muyad` (`native/crates/muyad/src/terminals.rs`), which reuses `spawn`, the actor's `Cmd::Paste` / `Cmd::Key` encoding and the actor's screen state (permission prompt). No new socket, no new PTY path.
- Kind/ownership of a tab: a Claude conversation is mapped to its PTY by `getsid` of the `claude` pid (same rule as `default_claude_ids`, `muyad/src/lib.rs`).
- Target resolution reuses `resolve_target` (id > exact name > substring, never guesses on a tie).
- Chat delivery in `deliver:"muya"` is the code `send_to_session` already used, extracted to `deliver_chat` (channel event, else `muya://deliver-message`).
- App: muyad emits `muya://terminal-opened`; `Store.adoptStartedTerminal` (`native/app/Sources/App/Model.swift`) adopts the session with the existing private `adopt`, names it in `names.json` like `spawn` does.
- Protected (must not change): `open_session`, `send_to_session`, `close_session`, `list_sessions` behaviour; wire protocol of muya-proto (no new Control message — the event is a normal `Control::Event`).
- The Tauri sidecar binary is shared (`src-tauri/src/bin/muya_ssh_mcp.rs`): the tools exist there, the Tauri broker answers "terminal tools need the native Muya app".

## 6. Risks
| Risk | Mitigation |
|---|---|
| Enter answers a permission prompt | refused / skipped unless `include_waiting`; answering on purpose stays `send_to_session deliver:"keys"` |
| Agent types into the operator's working tab | documented in the tool description; broadcast skips caller; per-target results returned |
| Secrets typed by an agent end up in logs | log keeps id/name/length; the 60-char preview only in the opt-in debug log |
| Huge paste / flood | 16 KiB per call, 64 targets |

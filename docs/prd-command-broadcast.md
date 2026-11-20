# PRD: Command (send text or a slash command to one or many sessions) — Muya Native

## 1. What it does

The session header's **Compact** button becomes **Command**. It opens a dialog where the operator types a prompt or a slash command (`/compact`, `/model sonnet`, any text), picks who gets it, and sees what happened per session.

| Target | Meaning |
|---|---|
| This session | the selected tab |
| This group | every live Claude tab of the selected tab's split group (no group: just this session) |
| Pick sessions | checkbox list of open Claude sessions, by name |
| All sessions | every live Claude tab |

Preset chips: `/compact`, `/clear`, `/model sonnet`, `/cost`. Keyboard: **⌘⇧K** (View > Send Command…).

## 2. Result states

| State | When |
|---|---|
| submitted | the session's transcript shows the text as a new user turn |
| queued | the session was busy; it takes the text after its current turn |
| sent | typed + Enter pressed, but a slash command does not always show in the transcript, so it cannot be confirmed |
| skipped | the terminal waits on a permission/trust dialog; nothing was typed |
| failed | terminal gone, not a Claude session, hand-off error, or not taken within the wait; the reason is shown |

## 3. Design

- **Delivery** reuses the broker's tracked delivery (`muya_core::broker`): dialog guard (M6), paste + Enter, transcript confirmation, `queued` for busy sessions. New function `operator_send` runs it for several terminals at once with one shared wait.
- **Verbatim, not wrapped.** `send_to_session` (muya mode) prefixes `[message from X via Muya]`; a slash command must be the first characters of the line, so the operator path types the text exactly as written.
- **Operator-initiated = trusted**: no secret placeholders substituted, no per-caller ownership check, no idempotency key. The write is logged (`debuglog` `[audit] operator-send`); no "Typed by" toast (the operator did it themselves).
- **App to daemon**: new RPC `sessions.send_command {ids:[terminalId], text}` returning `{results:[{id,name,state,reason}]}`. Only the operator's control socket reaches it; agents (broker socket) cannot.
- **Targets are terminal ids** (what the app knows); the daemon maps them to Claude sessions (`TerminalInfo.claude_session_id`). Shell tabs and opencode tabs are not Claude sessions: they are not offered and, if sent anyway, fail with a clear reason.
- Limits: text <= 16 KiB, no NUL, <= 64 terminals per send.
- **UI** uses the existing `Dialogs` panel + `ModalFrame` (same parts as Broadcast/Rename/Settings): `ModalLayout.rowsBox`, `ThemedCheckbox`, `IconSegmented`, `ThemedButton`. The dialog turns into the result list after Send ("Sending…" while the daemon works).

## 4. Acceptance criteria

1. Header shows **Command** (no Compact); Split, Split to grid, Stop unchanged.
2. ⌘⇧K and View > Send Command… open the dialog; no existing shortcut uses ⌘⇧K (checked: ⌘K palette, ⌘⇧D/T/S/E/H/R/C are the neighbours).
3. Target resolution: this / group / pick / all return only live Claude tabs, in sidebar order, capped at 64 (unit-tested).
4. `/compact` preset sends exactly `/compact` + Enter to the chosen sessions.
5. A session waiting on a dialog is skipped and receives no bytes (muya-core test).
6. A busy session reports `queued`, an unconfirmed slash command `sent`, an unconfirmed prompt `failed` (muya-core test).
7. `sessions.send_command` over the real daemon: one result per unique id, shell/unknown id fail, empty text / no ids are errors (muyad rpc test).
8. Unknown daemon answers count as failed, never as success (unit test). Daemon down: every row fails with the connection text.
9. Dark and light screenshots match SettingsModal/Broadcast look.

## 5. Integration (evidence)

| Piece | Where |
|---|---|
| Tracked delivery being reused | `native/crates/muya-core/src/broker.rs:2007` (`handle_send_to_session`), `:2181` (`deliver_chat`), `:2247` (`confirm_chat`) |
| New multi-target delivery | `native/crates/muya-core/src/broker.rs:2327` (`operator_send`) |
| New RPC | `native/crates/muyad/src/rpc.rs:442` (`sessions.send_command`), params `:39`; host built on first use (`MuyadBrokerHost::new`, `broker_host.rs:49`), works without `--broker` |
| Header button | `native/app/Sources/App/SessionBar.swift:14` (`commandButton`), wiring `FrameWiring.swift:86` |
| Dialog | `native/app/Sources/App/Dialogs.swift:120` (`command`), `:197` (results) |
| Open + daemon call | `native/app/Sources/App/FrameWiring.swift:231` (`commandDialog`) |
| Shortcut | `native/app/Sources/App/main.swift:128` (View menu, ⌘⇧K) |
| Pure logic | `native/app/Sources/Logic/CommandLogic.swift` (targets, results, labels) |
| Mock + debug hooks | `Mock.swift:124`, `DebugTheme.swift` (`dialog command`, `dialog command-target <n>`) |
| Auth | no new auth: the control socket is already the operator-only channel (`rpc.rs` `call`: "the control socket is the app's own connection") |

## 6. Protection list (must not change)

- Split / Split to grid / Stop buttons and their handlers (`SessionBar.swift`, `FrameWiring.swift`, `SplitControl.swift`).
- Grid-mode **Broadcast to all** dialog (`Dialogs.broadcast`) and its select/paste/Return path.
- Agent-facing `send_to_session` (muya/keys/auto modes), its dialog guard, identity checks, secret substitution, idempotency keys, "Typed by" audit toast: untouched; `operator_send` is a separate function.
- Old Compact behaviour = the `/compact` preset on "This session" (paste `/compact`, Enter).
- ⌘K palette and every existing shortcut.

## 7. Known limits

- opencode tabs are not addressable by the tracked delivery (the daemon identifies Claude sessions); the old Compact button worked on them by pasting into the focused tab. Use the terminal directly for opencode.
- `/clear` starts a new transcript, so it is reported `sent`, not `submitted`.

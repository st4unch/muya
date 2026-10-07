# Mini-PRD: deliver bridge (and Muya) messages through Claude Code channels

- Date: 2026-10-07
- Type: mini-PRD
- Operator decision (2026-10-07): option B — use Claude Code's channel mechanism instead of
  typing incoming messages into the session's terminal.

## 1. Problem
A message from a paired Claude on another Mac (`bridge_send`) is typed into the receiving
session's PTY (`App.tsx` `muya://deliver-message` handler, `remoteMessageLine` ends in `\n`).
Claude's TUI takes that as a pasted newline, so the operator must press Enter for every message,
and the typed text mixes with whatever the operator is typing. Claude Code channels let an MCP
server push an event into a running session without touching the terminal.

## 2. Scope
- In:
  - muya-mcp sidecar becomes a channel: declares `experimental: {"claude/channel": {}}`,
    explains the tags in `instructions`, and emits `notifications/claude/channel`
    (`content` = message, `meta` = `kind`, `peer`, `peer_id`, `sender`; underscore keys only).
  - Sidecar ⇄ app push path: the sidecar keeps one long-lived `subscribe` connection to the broker
    socket, identified by `CLAUDE_CODE_SESSION_ID`; the app forwards messages for that session
    over it.
  - Delivery order in the app: session has a live channel subscriber → channel; otherwise →
    terminal (fallback), and the fallback submits properly (text, then Enter as a separate write).
  - Muya-launched Claude sessions (new agent, resume, restore) start with
    `--dangerously-load-development-channels plugin:muya-mcp@muya`; the one-time confirmation the
    flag shows is handled as decided in §6.
  - Same channel path for `send_to_session(deliver:"muya")` (local session → session).
  - Sidecar pins a protocol revision that Claude Code registers as a channel
    (`PROTOCOL_VERSION` 2025-06-18 today — not 2026-07-28).
- Out:
  - Permission relay (`claude/channel/permission`).
  - Approved-allowlist `--channels` path (needs Anthropic or org allowlisting).
  - Sessions started by hand in a plain terminal without the flag (they keep the terminal fallback).

## 3. Acceptance criteria (binary)
- [ ] AC1: In a Muya-launched session, an incoming `bridge_send` message appears as a channel event
  (`← muya-mcp …` line, `<channel source="plugin:muya-mcp:muya-mcp" kind="remote" …>`), nothing is
  typed into the prompt, and an idle session starts a turn and can answer with `bridge_send`.
- [ ] AC2: While the operator has half-typed text in the prompt, a delivered message does not alter it.
- [ ] AC3: A session without a channel subscriber gets the message via the terminal AND it is
  submitted without the operator pressing Enter.
- [ ] AC4: A message for a session whose channel is gone (sidecar exited) falls back to the terminal
  — never silently lost.
- [ ] AC5: `send_to_session(deliver:"muya")` uses the same path (channel, else submitted terminal line).
- [ ] AC6: New / resumed / restored Claude tabs launch with the channel flag; opencode tabs unchanged.
- [ ] AC7: Unit tests for the delivery decision and the launch command; live two-session test on this
  Mac plus a bridge round trip with the second Mac.

## 4. Protection list
- Bridge pairing, mTLS, sanitize(), opt-in target rule in `bridge_mcp::deliver` (`bridge_mcp.rs:304`).
- `deliver:"keys"` (raw keystrokes for answering a prompt) stays a raw terminal write.
- Native `SendMessage` path of `send_to_session(deliver:"auto")`.
- The "untrusted data from another machine" wording travels with every remote message.

## 5. Integration / harmony
- Sidecar: `muya_ssh_mcp.rs` (`PROTOCOL_VERSION` :22, `own_session_id()` :79 reads
  `CLAUDE_CODE_SESSION_ID`, `app_call` request/response over the broker UDS :36).
- Broker: `handle_request` ops (`broker.rs`), uid-checked UDS — the `subscribe` op lives there; the
  app-side registry of subscribers is keyed by session id.
- Delivery today: `bridge_mcp::deliver` → `muya://deliver-message` (`bridge_mcp.rs:353`) and
  `send_to_session` → same event (`broker.rs:1164,1181`) → `App.tsx:1181` handler → `pty_write`.
- Launch command: `AGENT_BASE_COMMAND.claude`, `buildResumeCommand` (`src/lib/agent.ts:26,83`).
- Plugin identity: muya-mcp is installed as `muya-mcp@muya` (`fs.rs:1636`).
- Submit idiom: text then `"\r"` 150 ms later (`App.tsx` `sendLine`, scheduled prompts).
- Break risk: the flag on every launch (an older CLI without channels must still start — verify it
  ignores or rejects; gate on CLI version if needed); sidecar long-lived connection must not block
  its stdio loop (separate thread).

## 6. Open decision (operator)
- The flag prints a one-time confirmation in each new session. Either the operator confirms it
  per session, or Muya auto-confirms it like the existing trust-folder auto-accept
  (`autoAcceptTrust`). Recorded in the progress file once decided.

## 7. Phases
1. Spike: a minimal channel event from the sidecar reaches a live session started with the flag;
   check idle wake-up, mid-typing behaviour, the confirmation screen, and how to detect a declined
   channel.
2. Push path (subscribe op, registry, fallback with proper submit), launch flag, tests.
3. Live: two local sessions + bridge round trip with the second Mac.

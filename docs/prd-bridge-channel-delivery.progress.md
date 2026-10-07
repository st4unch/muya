---
status: active
prd: docs/prd-bridge-channel-delivery.md
started: 2026-10-07
---

## Phase Outputs
- Phase 1 spike (2026-10-07, CLI 2.1.292, scratch channel server in Node + pty driver):
  - Startup screens for `--dangerously-load-development-channels server:<name>`: trust folder → (project MCP approval, only for .mcp.json) → "WARNING: Loading development channels" with "❯ 1. I am using this for local development" preselected → banner "Channels (experimental) messages from server:<name> inject directly in this session".
  - `notifications/claude/channel` renders `← <name>: <content>`; an idle session starts a turn and answers. ✅
  - Half-typed prompt text is untouched by an incoming event. ✅
  - Claude's `initialize` carries no channel hint (capabilities: roots, elicitation only) → the sidecar decides from its parent `claude` argv whether its session loaded it as a channel.
  - muya-mcp is registered as user MCP `muya-mcp` in ~/.claude.json by Muya itself (`broker.rs:1824`) → flag value `server:muya-mcp`.

- Phase 2–3 (2026-10-07):
  - Live, real Claude 2.1.292 session with the rebuilt sidecar as `server:muya-mcp` against an isolated dev app (fake HOME, own socket): sidecar subscribed with its `CLAUDE_CODE_SESSION_ID`; a pushed event showed as `← muya-mcp: …`, the idle session answered, half-typed prompt untouched (AC1, AC2 ✅). Unknown session → `ok:false`; after the session quit → `ok:false`, i.e. terminal fallback (AC4 ✅).
  - Auto-confirm, live in the real Terminal component (mock UI, WebKit): warning split across two PTY chunks → one Enter for `server:muya-mcp` on the visible and on two hidden (pooled) tabs; no Enter for `server:evil` or a mixed list (AC6 ✅). Detector also matched the captured real screen.
  - Unit: launch flag (`withChannel`), fallback submit (`deliveryWrites`), subscribe/push/meta keys, CLI version gate, parent-argv detection, protocol pin. Rust lib 367 ✅, sidecar 3 ✅, frontend 369 ✅, `npm run build` ✅.
  - Not yet live: a bridge message from the second Mac through the channel (needs the release on this Mac + a session started by the new Muya) — AC7 bridge round trip pending; terminal fallback submit in the running app (AC3) covered by unit test only.

## Changes
| Date | File | What changed | AC |
|-------|-------|-----------|-----|
| 2026-10-07 | src-tauri/src/broker.rs | channel subscriber registry, `subscribe` connection, `push_channel`, session events, dev-only `debug_push_channel`, send_to_session via channel | AC1, AC4, AC5 |
| 2026-10-07 | src-tauri/src/bridge_mcp.rs | bridge delivery tries the channel first (`remote_channel_event`) | AC1 |
| 2026-10-07 | src-tauri/src/bin/muya_ssh_mcp.rs | `claude/channel` capability + instructions, parent-argv detection, subscription thread, protocol pin | AC1 |
| 2026-10-07 | src-tauri/src/agents.rs, lib.rs | `claude_channels_supported` (CLI ≥ 2.1.234) | AC6 |
| 2026-10-07 | src/lib/statusline.ts, App.tsx, Terminal.tsx | `applyLaunchFlags` adds the channel flag; auto-confirm of Muya's channel warning | AC6 |
| 2026-10-07 | src/lib/channelPrompt.ts, remoteMessage.ts | warning detector; terminal fallback submits with a separate Enter | AC3, AC6 |
| 2026-10-07 | src/mock/installMock.ts | dev-only `__muyaMock.feed` for screen-handling checks | — |

## Decisions
- Channel flag only for CLI ≥ 2.1.234: `--version` ignores unknown flags, so support can't be probed; an older CLI would refuse to start the session.
- The sidecar decides channel mode from its parent `claude` argv (Claude Code's initialize carries no channel hint).
- 2026-10-07 operator (§6): Muya AUTO-confirms the channel prompt in sessions it launches (new agent, resume, restore) — same as the trust-folder auto-accept.
- 2026-10-07 operator chose option B (channels) over the terminal Enter fix; the Enter fix survives as the fallback for sessions without a channel.

## Lessons

# Mini-PRD: Remote Claude bridge as MCP tools (Chat page removed)

- Date: 2026-10-03
- Type: mini-PRD
- Design source: software-architect review (2026-10-03), decisions recorded in `docs/prd-bridge-mcp.progress.md`

## 1. Problem
Two Claude Code sessions on two Macs can only talk through the Chat page (ChatView), operated by hand. The operator wants the
existing mTLS + SPAKE2 bridge exposed as muya-mcp tools so the Claude sessions pair and talk themselves (one side listens =
"server", the other dials = "client"), with inbound messages pushed straight into a Claude session. The Chat page goes away.

## 2. Scope
- In:
  - 7 MCP tools: `bridge_listen`, `bridge_invite`, `bridge_connect`, `bridge_confirm`, `bridge_peers`, `bridge_revoke`, `bridge_send`.
  - Broker handlers reusing the existing bridge code via `*_impl` functions.
  - Push delivery of inbound remote messages into a local Claude session PTY:
    - target resolution: the sender's `target_session`, else the peer's bound session;
    - sanitised and tagged as remote/untrusted;
    - capped at 4 KB per message and 10 messages per minute per peer.
  - Remove the Chat page UI.
  - Remote inbound rejects Task/File kinds.
  - Auto-off timers for the listeners.
  - An audit line per pair, revoke and inbound message.
- Out:
  - NAT traversal.
  - The local UDS bridge and the muya-chat skill (kept as is).
  - Removing the Footer message-box toggle and `ChatRailIcon` (both kept).
  - An inbox UI.

## 3. Acceptance Criteria (binary)
- [ ] AC1: `bridge_listen` with `0.0.0.0` / `::` iface is refused (error, nothing bound).
- [ ] AC2: Pairing over MCP tools only, with two instances:
  - `bridge_invite` → PIN;
  - `bridge_connect` → SAS;
  - both sides report the same SAS;
  - after `bridge_confirm` on both sides, each lists the other in `bridge_peers`.
- [ ] AC3: Wrong PIN 5× → further attempts refused (lockout).
- [ ] AC4: `bridge_send` from A arrives in B's bound session PTY as ONE line:
  - prefixed `[REMOTE UNTRUSTED from <label>#<spki8> …]`;
  - with ESC / control characters stripped and newlines flattened.
- [ ] AC5: A remote message > 4 KB, or the 11th within a minute, is rejected and the sender gets an error.
- [ ] AC6: After `bridge_revoke`, the next `bridge_send` to/from that peer fails.
- [ ] AC7: The Chat page is gone:
  - no "Chat" rail item;
  - `ChatView.tsx` deleted;
  - the Footer message-box toggle still works;
  - `tsc` is clean and vitest passes.
- [ ] AC8: `cargo test` passes, including new tests for sanitising, rate limiting and the wildcard refusal.

## 4. Protection List (do not touch)
- `assert_not_wildcard`, SPKI pinning, PIN single-use / 5-minute TTL / 5 attempts (`bridge_remote.rs`).
- The local UDS bridge (`bridge.rs`), `MUYA_BRIDGE_AUTOLISTEN` (`lib.rs:184`) and the muya-chat skill.
- The session-messaging tools (`list_sessions` / `send_to_session` / `read_session`) and the `muya://deliver-message` flow for local messages.
- The Footer message box / Composer and `ChatRailIcon`.

## 5. Integration / Harmony
- **Auth:**
  - Sidecar ↔ app goes through the broker peer-uid check (`broker.rs:9-12`).
  - Remote peers use mTLS with a fail-closed pinned-SPKI verifier (`bridge_remote.rs:478-513`) and SPAKE2 PIN pairing (`:961`, `:1406`, `:1539`).
- **State:**
  - `RemoteBridgeState` / `BridgeState` are managed in `lib.rs:291-293`.
  - Broker handlers reach them with `app.state::<T>()`, as `broker.rs:457` / `:655` already do.
  - The peer registry is `peer_registry.json` (`bridge_remote.rs:312`).
  - `pending_sas` is stored at `bridge_remote.rs:1521` / `:1560`.
- **Conventions:**
  - New sidecar tool = schema entry plus a match arm calling `app_call({op})` (`muya_ssh_mcp.rs` ~:221, :663-682).
  - Broker dispatch arm plus handler (`broker.rs:495`, `:1028`).
  - Caller session id comes from `CLAUDE_CODE_SESSION_ID` (`muya_ssh_mcp.rs:80`).
  - Target resolution uses `resolve_target` (`broker.rs:836`).
  - Push goes through the `muya://deliver-message` → `pty_write` path in App.tsx (~:1109-1121).
- **Breakage risks:**
  - The `unsafe` state cast in the pairing listener (`bridge_remote.rs:1165`) becomes reachable from the broker. Replace it with `app.state()` in the `*_impl` refactor.
  - Removing ChatView leaves its Tauri commands without UI callers. They stay registered; only exec/auto-respond is closed for remote inbound.
  - MCP clients must reconnect to see new tools (L46). Verify by driving the sidecar over stdio.

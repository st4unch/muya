---
status: done
prd: docs/prd-bridge-mcp.md
started: 2026-10-03
---

## Phase Outputs
- Implemented in one pass. Rust: 84/84 bridge tests and 345 full tests pass. Vitest: 344/344. tsc is clean.
- Live end to end:
  - Setup: two isolated dev instances (HOME=/tmp/muyaA and /tmp/muyaB, separate broker sockets), driven through the muya-mcp sidecar over stdio exactly as a Claude session would. Harness: scratchpad `bridge-e2e.mjs`.
  - Result: 25/25 PASS. Covered: 7 tools listed; wildcard refused; wrong PIN gives different codes, both confirms refuse and nothing is pinned; correct PIN gives the same code on both sides and both pin; client→server delivered (status held, since there is no session); server→client queued, then picked up by the client's poll; >4 KB rejected; 10/min rate limit enforced by the receiver; after revoke the send fails at the TLS handshake; the port is freed after listen off.
  - **Not observed:** the final hop of a message being typed into a real Claude session's PTY. Claude in the fake-HOME instance never registered in `claude agents` (probably not logged in under that HOME). The path reuses the existing `muya://deliver-message` → `pty_write` listener; only the line format is new, and that is unit-tested (`remoteMessageLine`).

## Changes
| Date | File | What changed | AC |
|-------|-------|-----------|-----|
| 2026-10-03 | src-tauri/src/bridge_mcp.rs (new) | `bridge_*` op handlers, sanitising, rate limit, outbox + client poller, session binding, held messages | AC2-AC6 |
| 2026-10-03 | src-tauri/src/bridge_remote.rs | `*_impl` refactor; live allow-list shared with the verifier (pair/revoke take effect while listening); listener task aborted on stop (frees port); pairing window auto-closes at PIN expiry; inbound Question → bridge_mcp, Task/File refused; Control poll; SAS compare in confirm; `remote_exchange` | AC1-AC6 |
| 2026-10-03 | src-tauri/src/broker.rs, lib.rs | `bridge_*` dispatch; pollers resumed at startup | AC2 |
| 2026-10-03 | src-tauri/src/bin/muya_ssh_mcp.rs | 7 tool schemas + pass-through | AC2 |
| 2026-10-03 | src/App.tsx, src/lib/remoteMessage.ts, Rail.tsx, types.ts; ChatView deleted | remote line format; Chat page removed | AC4, AC7 |

## Decisions
- Operator: pairing is done entirely through MCP tools, with no UI. Delivery pushes directly into the session.
- software-architect: 7 tools.
  - SAS confirmation is left to the tool. The tool returns the SAS and the description tells Claude to show it to the operator; it is never auto-confirmed.
  - Routing uses `target_session`, falling back to the peer's bound session (the caller of listen/invite/connect).
  - Limits: 4 KB per message, 10 messages per minute per peer.
  - Remote Task/File requests are rejected.
- CANNOT-ANSWER → my decision:
  - The local UDS bridge and the muya-chat skill stay (minimal change).
  - Per-peer push consent = pairing itself; there is no separate opt-in, per the operator's push decision.

- Implementation decisions:
  - Only the client can dial (the server stores the dialer's ephemeral port), so the server's messages wait in an outbox. The client polls it every 2 s, backing off to 30 s.
  - The pairing window is the data port + 1.
  - SPAKE2 does not fail on a wrong PIN; it yields different codes. So `bridge_confirm` REQUIRES the other side's code (`sas`) and compares it. The operator relays it, which keeps the pairing secure even though the tools drive it.
  - A remote `target_session` may only name a session that already uses the bridge.

## Lessons

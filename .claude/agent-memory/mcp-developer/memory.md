# mcp-developer memory — claude-control-plane

## Current state (2026-07-15)

**Faz 1 LOCAL MVP — DONE** (branch: dev)

- `bridge.rs` fully implemented: accept loop, length-prefixed framing, broker queue, 3 new Tauri commands, approval gate state machine.
- All 9 bridge tests PASS; full suite 39/39.

## Key decisions / gotchas

- `BridgeState.staged` is `Arc<Mutex<HashMap>>` (not bare Mutex) — required to share with spawned connection-handler tasks. `tokio::sync::Mutex` doesn't impl Clone.
- `handle_connection` takes `AppHandle` for `app.emit(...)`. In tests we inline the same logic rather than calling the fn directly (avoids needing a mock AppHandle).
- `bridge_send` is a Faz 1 stub — returns req_id, no actual dialing. Faz 2 adds dialer + TLS.
- `required_approval`: only `kind:Task + capability:Shell` → PendingApproval. All others → NotRequired.
- Max frame: 16 MiB, checked BEFORE body allocation (DoS guard).
- Broker queue: `mpsc::channel(256)` — matches pty.rs philosophy.
- `bridge_poll_inbound` drains queue non-blocking (try_recv loop).
- Registered in `lib.rs generate_handler!`: `bridge_local_listen`, `bridge_poll_inbound`, `bridge_send`, `bridge_approve`.

## Next phase

**Faz 2** — remote TCP + TLS (tokio-rustls), CPace pairing, dialer. Do NOT add to Faz 1 scope.
**Faz 3** — real sandboxed exec (currently stub in bridge_approve → Approved state).

## ADR refs

- ADR 0002: `docs/adr/claude-remote-bridge-architecture.md`
- Envelope shape: ADR D6 (v:1, type, id, peer, capability, kind, payload, stream, seq, final)

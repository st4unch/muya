# mcp-developer journal

## 2026-07-15 — Faz 1 local-mvp implementation

- **Done:** Implemented all 5 ACs of faz-1-local-mvp. Replaced Faz 0 scaffold with full accept loop, length-prefixed framing (u32 BE + JSON), broker queue (mpsc 256), 3 Tauri commands (bridge_poll_inbound, bridge_send, bridge_approve), ApprovalState machine (PendingApproval/Approved/Denied/NotRequired). 9 new bridge tests, all pass. Full suite 39/39.
- **Decisions:** staged field → Arc<Mutex<...>> (tokio Mutex not Clone); bridge_send is Faz 1 stub; required_approval only gates Shell+Task; 16 MiB max frame checked pre-alloc.
- **Refs:** ADR `docs/adr/claude-remote-bridge-architecture.md`, `src-tauri/src/bridge.rs`, `src-tauri/src/lib.rs`, `docs/prd-verify/step-output-faz-1-local-mvp.md`
- **Handoff:** —
- **Next/Open:** Faz 2 (TCP + tokio-rustls + CPace pairing + dialer). Faz 3 (real sandboxed exec replacing stub).

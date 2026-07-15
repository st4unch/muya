# mcp-developer journal

## 2026-07-15 — Faz 3: task execution engine (bridge_exec.rs)

- **Done:** Implemented all 7 ACs of faz-3-task-handoff. New `bridge_exec.rs` (~900 lines) with: sandboxed exec (TempDir cwd + deny-list env strip), bounded streaming channel (256, mirrors pty.rs), capability scope gate, auto-run three-path (default/auto-run/approve-each), memory-only audit log (no disk writes), fan-out independence, AC-3-7 shell auto-run two-factor override. 32 new tests; 96/96 pass (100 total including Faz 1+2).
- **Decisions:** (1) New module bridge_exec.rs (not extending 2195-line bridge_remote.rs). (2) Deny-list env strip (not allow-list) + debug assertion. (3) Argv array format only — string cmd rejected at API (prevents shell interpolation). (4) Mutex locked per-line, not per-task (prevents stdout/stderr deadlock). (5) AC-3-7: two-factor shell override (capability in set + separate bool field). (6) tempfile moved to [dependencies] (used at runtime for TempDir).
- **Refs:** `src-tauri/src/bridge_exec.rs`, `src-tauri/src/lib.rs`, `src-tauri/Cargo.toml`, `docs/prd-verify/step-output-faz-3-task-handoff.md`
- **Handoff:** —
- **Next/Open:** Faz 4 optional: OS-level sandbox (macOS sandbox-exec / Linux seccomp). Frontend bridge UI for task approve/audit is minimal (events emitted via bridge://task-chunk, bridge://task-end, bridge://task-rejected).

## 2026-07-15 — Faz 2 AC-2-3 fix: invitee-side pairing handler

- **Done:** Wired the invitee side of the SPAKE2 pairing exchange. Root cause: Retry 0 discarded the `start_b` state and had no network handler to accept the dialer's pairing connection. Fixed: `handle_pairing_connection` (generic, testable with duplex pipes), `bridge_pair_start_listener` (dedicated pairing TLS listener, AnyCertVerifier, single-use, wildcard-rejected), `derive_sas` made canonical (sort SPKIs before HKDF), `AnyCertVerifier` scoped to pairing only. 6 new real-socket tests; 68/68 pass.
- **Decisions:** (1) duplex-pipe tests for protocol layer (no TLS overhead, same function); (2) canonical SAS via sorted SPKIs (no call-site changes); (3) raw-pointer watcher task for Tauri state write-back (standard pattern).
- **Refs:** `src-tauri/src/bridge_remote.rs`, `src-tauri/src/lib.rs`, `docs/prd-verify/step-output-faz-2-remote-mtls.md ## Retry 1`, commit be5d985
- **Handoff:** —
- **Next/Open:** Faz 3 (task handoff, streaming, sandboxed exec, per-peer capability scope, audit log).

## 2026-07-15 — Faz 2 remote-mtls implementation

- **Done:** Implemented all 5 ACs of faz-2-remote-mtls. New `bridge_remote.rs` with: BridgeIdentity (Ed25519 self-signed via rcgen, 0600), PinnedSpkiVerifier (fail-closed custom ClientCertVerifier for rustls 0.23), SPAKE2 PAKE pairing (spake2-conflux 0.6.0, RFC 9382), SAS derivation (HKDF-SHA256), PeerRegistry (SPKI-pinned, JSON, 0600, versioned v1), PIN lifecycle (single-use/5-min TTL/5-attempt lockout), 6 Tauri commands registered. 23 new tests; 62/62 total.
- **Decisions:** CPace → SPAKE2 substitution (ADR R7: cpace 0.1.0 unmaintained). SPAKE2 id param order gotcha fixed. base64 padding zero-byte bug fixed. SecretKey.expose() pattern for zeroize-safe comparison.
- **Refs:** ADR `docs/adr/claude-remote-bridge-architecture.md` D1/D2/D3; step-output `docs/prd-verify/step-output-faz-2-remote-mtls.md`; commit 21f9536
- **Handoff:** —
- **Next/Open:** Faz 3 — task handoff, streaming, sandboxed exec, capability scope, audit log. Note: SPAKE2 state non-Clone; Faz 3 must re-create state per accepted connection on invitee side.

## 2026-07-15 — Faz 1 local-mvp implementation

- **Done:** Implemented all 5 ACs of faz-1-local-mvp. Replaced Faz 0 scaffold with full accept loop, length-prefixed framing (u32 BE + JSON), broker queue (mpsc 256), 3 Tauri commands (bridge_poll_inbound, bridge_send, bridge_approve), ApprovalState machine (PendingApproval/Approved/Denied/NotRequired). 9 new bridge tests, all pass. Full suite 39/39.
- **Decisions:** staged field → Arc<Mutex<...>> (tokio Mutex not Clone); bridge_send is Faz 1 stub; required_approval only gates Shell+Task; 16 MiB max frame checked pre-alloc.
- **Refs:** ADR `docs/adr/claude-remote-bridge-architecture.md`, `src-tauri/src/bridge.rs`, `src-tauri/src/lib.rs`, `docs/prd-verify/step-output-faz-1-local-mvp.md`
- **Handoff:** —
- **Next/Open:** Faz 2 (TCP + tokio-rustls + CPace pairing + dialer). Faz 3 (real sandboxed exec replacing stub).

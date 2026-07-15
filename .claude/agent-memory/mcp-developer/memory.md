# mcp-developer memory — claude-control-plane

## Current state (2026-07-15)

**Faz 3 TASK EXECUTION — DONE** (branch: dev)

- `bridge_exec.rs` (new): sandboxed exec (TempDir cwd + deny-list env strip), bounded streaming channel (256), capability scope gate, auto-run three-path, memory-only audit log, fan-out independence, AC-3-7 shell two-factor override. 5 Tauri commands.
- `lib.rs`: mod bridge_exec, .manage(ExecState::default()), 5 new commands.
- `Cargo.toml`: tempfile moved to [dependencies] (runtime use for TempDir sandbox).
- 96/96 tests pass (32 new Faz 3 + 64 Faz 1+2 retained); 4 ignored (machine-specific).

**Faz 2 REMOTE mTLS + SPAKE2 PAIRING — DONE** (commit: be5d985)

- `bridge_remote.rs`: BridgeIdentity, PinnedSpkiVerifier (fail-closed), AnyCertVerifier (pairing-only), SPAKE2, PeerRegistry, PIN lifecycle, SAS derivation. 7 Tauri commands.

**Faz 1 LOCAL MVP — DONE**

- `bridge.rs`: UDS accept loop, length-prefixed framing, broker queue, approval gate. 4 Tauri commands.

## Key decisions / gotchas

### Faz 3 gotchas (HIGH PRIORITY)
- **Argv MUST be JSON array** — `extract_argv` rejects string cmd (prevents shell interpolation). No `bash -c "$payload"` ever.
- **env deny-list + HOME override:** `build_sandbox_env` starts EMPTY, copies SAFE_ENV_KEYS only, overrides HOME → TempDir path. Debug assertion checks no blocked pattern leaked.
- **Mutex per-line, NOT per-task:** stdout + stderr accumulators each lock briefly per line. Holding across `.await` deadlocks the other task.
- **AC-3-7 two-factor shell override:** shell auto-run requires `auto_run_capabilities.contains("shell")` AND `shell_auto_run_override == true`. Both must be explicitly set. API rejects adding "shell" without the flag.
- **`gate_and_execute` reads `req.approval`** — the InboundRequest field set by `bridge_approve()`. Not a separate staged lookup.
- **`tempfile` in `[dependencies]`** (runtime, not dev-only) — TempDir used in `execute_sandboxed_shell_task`.
- **Fan-out raw pointer pattern** — same `*const T as usize` pattern as Faz 2 pairing watcher. Safe: ExecState is 'static Tauri-managed.

### Faz 2 gotchas (still relevant)
- CPace → SPAKE2 (ADR R7). SPAKE2 identity order: `start_b(pw, id_a, id_b)` same as `start_a`. SecretKey.expose() for raw bytes. base64 padding = 255 (not 0). PAKE state non-Clone/non-Send — create fresh per connection. `client_auth_mandatory() = true`. SAS: canonical sorted SPKIs. AnyCertVerifier pairing-only.

### Faz 1 gotchas
- `BridgeState.staged` is `Arc<Mutex<HashMap>>`. Max frame 16 MiB, checked BEFORE alloc.

## Architecture (versioned one-way doors)
- PAKE wire version: v1 | Registry schema: v1 | Envelope: v1 (ADR D6) | SAS: canonical sorted SPKIs

## Files
- `src-tauri/src/bridge.rs` — local UDS (Faz 1)
- `src-tauri/src/bridge_remote.rs` — remote mTLS (Faz 2); ~2200 lines
- `src-tauri/src/bridge_exec.rs` — task exec engine (Faz 3); ~900 lines
- `src-tauri/src/lib.rs` — all registered
- `src-tauri/Cargo.toml` — rcgen, spake2-conflux, sha2, hkdf, rand, tempfile

## Next phase

**Faz 4 (optional):** OS-level sandbox (macOS `sandbox-exec` / Linux seccomp-BPF). Frontend bridge UI for approve/audit (events already emitted: `bridge://task-chunk`, `bridge://task-end`, `bridge://task-rejected`).

## ADR refs
- ADR 0002: `docs/adr/claude-remote-bridge-architecture.md`
- Step output Faz 3: `docs/prd-verify/step-output-faz-3-task-handoff.md`
- Step output Faz 2 (with Retry 1): `docs/prd-verify/step-output-faz-2-remote-mtls.md`

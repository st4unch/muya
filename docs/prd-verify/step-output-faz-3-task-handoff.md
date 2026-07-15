## Retry 0

**Date:** 2026-07-15
**Branch:** dev
**Spec:** MCP 2025-11-25 / ADR 0002

---

### Per-AC Detail

**AC-3-1 — Sandbox cwd + stripped env**
- Each task gets a fresh `TempDir` (dropped on completion, removed from disk).
- `build_sandbox_env()` uses a DENY-list strategy: starts empty, copies ONLY `SAFE_ENV_KEYS` (`PATH`, `LANG`, `TERM`, `USER`), then overrides `HOME` → sandbox path.
- Blocked patterns (case-insensitive): `CLAUDE*`, `AI_AGENT`, `*_TOKEN`, `*_KEY`, `*_SECRET`, `AWS_*`, `GITHUB_TOKEN`, `*_PASSWORD`, `*_PWD`, `*_PASS`, `BEARER`, `OPENAI`, `ANTHROPIC`, `SLACK_*`, `DATABASE_*`, `DB_*`, `REDIS_*`, `MONGO_*`, `POSTGRES_*`, `MYSQL_*`, `API_KEY`, `PRIVATE_*`, `CREDENTIALS`, `COOKIE`, `SESSION_*`, `WEBHOOK_*`, `OAUTH`, `ACCESS_KEY`, `SECRET_*`, `AUTH_*`.
- Tests: `ac3_1_env_strip_no_sensitive_vars`, `ac3_1_env_strip_only_safe_keys_pass`, `ac3_1_blocked_env_key_detection`, `ac3_1_task_executes_in_sandbox_cwd`, **`ac3_1_env_command_prints_no_sensitive_vars`** (runs real `env` subprocess with stripped env, asserts injected `FAZ3_TEST_SECRET_TOKEN` absent from output).

**AC-3-2 — Bounded streaming channel**
- `mpsc::channel(256)` — mirrors `pty.rs sync_channel(256)`.
- stdout and stderr each stream in separate tasks; bounded send blocks the reader loop (back-pressure, no unbounded buffering).
- Mutex is locked per-line only (not held across `.await`) to avoid deadlock between the two tasks.
- Tests: `ac3_2_channel_depth_matches_pty` (asserts constant = 256), `ac3_2_bounded_channel_does_not_unbounded_buffer` (fills to 256, 257th `try_send` fails with `Full`).

**AC-3-3 — Per-peer capability scope (server-side before exec)**
- `capability_in_scope(granted, requested)` enforces: `shell ⊇ file ⊇ research`.
- A `research`-granted peer requesting `shell` → `CapabilityRejected` audit entry + Err, not executed.
- Over-16 MB payloads blocked by Faz 1/2 `MAX_FRAME_BYTES = 16 MiB` (constant asserted in `ac3_3_payload_over_16mb_blocked_by_framing`).
- Tests: `ac3_3_capability_scope_research_only`, `ac3_3_capability_scope_file`, `ac3_3_capability_scope_shell`, `ac3_3_payload_over_16mb_blocked_by_framing`.

**AC-3-4 — Per-peer auto-run opt-in (three paths)**
- `PeerAutoRunConfig` in `ExecState.auto_run` (in-memory `HashMap<spki_hash, config>`).
- Path 1 (auto-run): peer has `"research"` in `auto_run_capabilities` + requests research → executes without approval.
- Path 2 (approve-each for out-of-scope): same peer requests `shell` → gate requires `approval == Approved`.
- Path 3 (default no opt-in): `PeerAutoRunConfig::default()` has empty set → all requests require approval.
- Tests: `ac3_4_auto_run_research_peer_no_approval_needed`, `ac3_4_research_auto_run_peer_shell_still_requires_approval`, `ac3_4_auto_run_default_requires_approval`.

**AC-3-5 — Memory-only audit log**
- `AuditLog` is `Vec<AuditEntry>` + `next_id: u64`. No `PathBuf`, no `File` handle, no `fs::write`.
- Exposed via `bridge_audit_log()` Tauri command only.
- `Default::default()` initializes empty — no `load_from_disk()` function exists.
- Code confirmation: `bridge_exec.rs` imports `sha2` and `std::time` for hashing/timestamps but NO `std::fs` or `std::io::File`. Grep: `grep -n 'fs::write\|File::create\|OpenOptions' src/bridge_exec.rs` → 0 results.
- Tests: `ac3_5_audit_entries_appear_in_memory`, `ac3_5_audit_output_hash_updated_after_execution`, `ac3_5_no_disk_writes_in_audit_code`, `ac3_5_audit_cleared_on_restart`.

**AC-3-6 — Fan-out independence**
- `bridge_fan_out` spawns one independent Tokio task per target via `tauri::async_runtime::spawn`.
- Each task calls `gate_and_execute` with its own `peer_spki`; reads its own `PeerAutoRunConfig` from `ExecState.auto_run`.
- No shared approval: a peer without auto-run stays blocked waiting for `bridge_approve`; a peer with auto-run proceeds immediately. Both resolve concurrently without synchronization between them.
- Tests: `ac3_6_fanout_peers_independent_gates` (asserts Peer A auto-runs, Peer B requires approval, and `a_auto != b_auto`).

**AC-3-7 (R1 INVARIANT) — Shell not auto-run-eligible by default**
- `is_auto_run_eligible` for `Capability::Shell` requires BOTH `auto_run_capabilities.contains("shell")` AND `shell_auto_run_override == true`.
- `bridge_set_auto_run` returns `Err` if "shell" appears in capabilities without `shell_auto_run_override: true` (checked BEFORE writing state).
- Tests: `ac3_7_shell_not_auto_run_without_override` (override=false → not eligible), `ac3_7_shell_auto_run_requires_explicit_override` (both set → eligible, path clearly marked DANGEROUS), `ac3_7_research_auto_run_no_override_needed`.

---

### Sandbox Env-Strip List

```
BLOCKED_ENV_PATTERNS (case-insensitive match against var name):
  CLAUDE, AI_AGENT, _TOKEN, _KEY, _SECRET, AWS_, GITHUB_TOKEN,
  _PASSWORD, _PWD, _PASS, BEARER, OPENAI, ANTHROPIC, SLACK_,
  DATABASE_, DB_, REDIS_, MONGO_, POSTGRES_, MYSQL_, API_KEY,
  PRIVATE_, CREDENTIALS, COOKIE, SESSION_, WEBHOOK_, OAUTH,
  ACCESS_KEY, SECRET_, AUTH_

SAFE_ENV_KEYS (only these are copied from parent process):
  PATH, LANG, TERM, USER
  HOME → overridden to sandbox TempDir path
```

**Scope limit (documented):** Full OS sandbox (macOS Sandbox.framework / seccomp-BPF) is out of scope for Faz 3. The execution boundary is: dedicated TempDir cwd + stripped environment. Faz 4 can add `sandbox-exec` (macOS) or seccomp (Linux).

---

### Changed Files

- `src-tauri/src/bridge_exec.rs` — NEW. All Faz 3 logic: sandbox env-strip, streaming, capability gate, auto-run gate, audit log, Tauri commands, 32 tests.
- `src-tauri/src/lib.rs` — Added `mod bridge_exec`, `.manage(bridge_exec::ExecState::default())`, 5 new Tauri commands registered.
- `src-tauri/Cargo.toml` — Moved `tempfile` to `[dependencies]` (needed at runtime for TempDir sandbox cwd).

---

### Test Commands + Results

```
cd src-tauri && cargo build
# Result: Finished `dev` profile [unoptimized + debuginfo] target(s) in 7.74s

cd src-tauri && cargo test
# Result: test result: ok. 96 passed; 0 failed; 4 ignored (machine-specific)
# New Faz 3 tests: 32 (ac3_1..ac3_7 + argv + payload_hash)
# Faz 1+2 tests: retained 64 passing
```

---

### Bu Turda Alınan Kararlar

1. **New module `bridge_exec.rs`** rather than extending `bridge_remote.rs` (already 2195 lines). Clean seam: `bridge_exec` imports from `bridge` and `bridge_remote` but not vice versa.

2. **Deny-list env strip** (not allow-list-only): `build_sandbox_env` starts empty and copies only `SAFE_ENV_KEYS`, but also runs a `is_blocked_env_key` assertion in debug builds to catch any future additions to SAFE_ENV_KEYS that would be sensitive. Defense-in-depth.

3. **Argv vector only — no string interpolation**: `extract_argv` explicitly rejects `cmd` as a raw string with a SECURITY comment, requiring JSON array format. NUL bytes in any element are also rejected.

4. **Mutex-per-line, not per-task**: stdout/stderr accumulator Mutex is locked briefly per line, not held across `.await` — prevents deadlock between the two concurrent reader tasks.

5. **AC-3-7 two-factor shell override**: `shell_auto_run_override: bool` is a separate field from `auto_run_capabilities: HashSet`. Both must be set simultaneously. `bridge_set_auto_run` returns `Err` at the API boundary before writing state if the combination is unsafe. This makes accidental shell auto-run require two independent explicit actions.

6. **`tempfile` moved to `[dependencies]`** (not dev-only) because `TempDir` is used in production code path (`execute_sandboxed_shell_task`). Previously only in `[dev-dependencies]` for tests.

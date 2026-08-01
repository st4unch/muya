# mcp-developer memory — claude-control-plane

## Current state (2026-08-01)

**AGENTIC SSH — `ssh_add_server` DONE (PRD ssh-agent-add-server)**
- Agents REGISTER an SSH server, then `ssh_open`/`ssh_run` it. `Server.agent_added: bool` (`agentAdded` serde default false). Core `ssh::agent_add_server_in(cfg,label,host,username,port,credential_ref)`: forces `direct` + `ssh_options=None`, `agent_access=true`+`agent_added=true`, CREATE-ONLY (`upsert_server_in` collision ⇒ Err — no overwrite of human servers), audit line. `reject_injection` rejects empty/whitespace/control/`@` in host+user (argv + user@host injection — load-bearing).
- **OPERATOR OVERRODE PRD D1:** agent MAY attach a stored credential BY NAME (`credential_source={kind:"local",local_cred_id:<NAME>}`); resolved+injected in Rust at connect. Value never crosses to agent. All OTHER guardrails kept (no ssh_options/psmp/set-cred, create-only, injection validation).
- **`ssh_pty_connect` local branch now uses `secret_for_ref` (name OR id)** instead of `secret_for` (id-only) — so agent-added servers (localCredId = NAME) connect; human picker (stores id) path unbroken.
- broker `add_server` op (BrokerReq +host/username/label/port/credential; uses `ssh::load_config`/`save_config` new pub(crate) wrappers). proxy `ssh_add_server` tool (required [host,username], optional label/port/credential). SshPage amber "agent-added" badge + `agentAdded?` TS field.
- Tests: cargo 185 (+6, was 180 baseline this task), vitest 88 (+1), tsc clean, both bins build. Proxy live tools/list = [ssh_list_servers, ssh_open, ssh_run, ssh_add_server, list_secrets, add_secret, get_secret, update_secret, list_operations, run_operation]; app-down ⇒ -32000. GAP: add_server not smoke-tested through live app UDS (needs GUI runtime).
- NOTE: baseline drifted since 3.2a memory (173) — get_secret/update_secret tools added in an interim session (present in broker + proxy). Live tools/list above is authoritative.

## Prior state (2026-07-26)

**SSH AGENT BROKER — Faz 3.2a DONE (AC17–AC19): `add_secret` WRITE path + `api_key` kind**
- Agents can STORE a NEW secret they generated/received. broker op `add_secret{name,description,kind,value}` → `credstore::add_credential` (delegates to path-injectable `add_credential_at(store,path,...)` so tests seal to a temp vault, NOT the real `~/.claude/muya-ssh-vault.enc`).
- **SECURITY:** CREATE-ONLY (label collision ⇒ error, NO overwrite — injected-agent can't clobber real secret), unlock-gated, empty name/value + bad-kind rejected. Response `{ok,secret:{name,kind}}` — value NEVER returned/logged. kind defaults `api_key` when omitted.
- `valid_secret_kind` now `password|key|token|api_key` (AC18). `CredMeta` derives `Debug`.
- proxy tool `add_secret` (enum kind, required [name,value], additionalProperties:false). Live `tools/list` = [ssh_list_servers, ssh_open, ssh_run, list_secrets, add_secret, list_operations, run_operation].
- UI: StoreTab select gains "API key" option; TS unions widened (SshPage/CredentialPicker/mockBackend); list row renders "API key".
- Tests: cargo 173 (+5), vitest 87 (+1), tsc clean. Proxy live smoke OK (add_secret in list; missing-value⇒isError; app-down⇒-32000). Step output: `docs/prd-verify/step-output-phase3.md` § Phase 3.2a.
- **Faz 3.2b (next):** real op defs (aws/git/gh), write-ops, overwrite/rotation path (operator-approved), op-add UI.

**SSH AGENT BROKER — Faz 3.1 DONE (AC11–AC16): secret-operation ENGINE + EMPTY registry**
- Agents USE a stored secret to run operator-defined fixed-program ops (aws/kubectl/git) WITHOUT reading it. Reference op BY NAME; Muya injects secret into CHILD process env, returns only stdout/stderr/exitCode.
- `src-tauri/src/agent_ops.rs` (NEW): `OpDefinition{name,description,program(abs path),pinnedArgv,allowedFlags,deniedFlags,secretId,envMap}`. Registry `~/.claude/muya-agent-ops.json` (file-based, operator-authored, `atomic_write`; absent/empty ⇒ 0 ops, malformed ⇒ hard error). Agents have NO registry-write path.
- **SECURITY CRUX = `enforce_arg_policy` (PURE, fail-closed):** reject leading-`-` positional, hard-denylist (`-c --endpoint-url --kubeconfig --output -o --query`)+op deny, unknown flag (allowlist), word-shaped non-pinned subcommand. **Flag values MUST be `--flag=value`** (bare word ⇒ rejected as subcommand) — conservative Phase-3.1 default, documented in file header, revisit Faz 3.2.
- `execute_op` = `std::process::Command` (NOT PTY — aws/git read env not TTY) argv-only `env_clear().envs()`, NO shell, 256KiB-capped concurrent stdout/stderr threads. `build_op_env` (PURE): `{{secret}}` / `{{secret.json:FIELD}}` (multi-var) / literal.
- `credstore.rs`: `description` (`#[serde(default)]`) on Credential/CredMeta/CredInput; `valid_secret_kind` now accepts `token`; `list_meta(store)` unlocked-gated non-secret projection.
- broker.rs +3 ops: `list_secrets` (→list_meta, `{name=label,description,kind}`), `list_operations` (`{name,description}` only), `run_operation` (resolve op→policy→secret_for in Rust→child env→execute_op via spawn_blocking; reuses N=4 run_slots semaphore). BrokerReq +`operation`+`args`.
- proxy `muya_ssh_mcp.rs` +3 MCP tools (same names). Live `tools/list` = [ssh_list_servers, ssh_open, ssh_run, list_secrets, list_operations, run_operation].
- SshPage StoreTab: description input + `token` select option; CredMeta TS/draft/CredentialPicker/mockBackend widened. Tests: 168 backend (+16), 86 vitest (+4), tsc clean, proxy builds.
- **GAP:** `run_operation` NOT verified through live app UDS (needs Tauri GUI runtime). execute_op real-subprocess (`/bin/echo`) unit-tested; proxy tools surface observed live. In-app smoke recommended before Faz 3.2.
- Step output: `docs/prd-verify/step-output-phase3.md`.

## Prior state (2026-07-26)

**SSH AGENT BROKER — Faz 1 DONE (AC1–AC7)** — a SECOND, separate MCP surface from the chat bridge.

- Publishes the `muya-ssh` MCP server so Claude Code agents use SSH servers BY ALIAS; password never reaches the model (resolved+injected Rust-side by existing `ssh_pty_connect`).
- `src-tauri/src/broker.rs` (NEW): owner-only UDS at `$HOME/.claude/muya-ssh-broker.sock` (env `MUYA_SSH_BROKER_SOCK`). 0600 + **`libc::getpeereid` uid check** (rejects uid != getuid) — bridge.rs has NO peer check; this is the new hardening. Ops: `list_servers` (only `agent_access==true`, metadata only, works when store locked), `open(alias)` (checks opt-in + local-store-lock, emits `ssh-broker-open {serverId,label}`).
- `src-tauri/src/bin/muya_ssh_mcp.rs` (NEW): thin stdio MCP proxy. MCP `2025-06-18`, newline-delimited JSON-RPC. Tools `ssh_list_servers`+`ssh_open` (NOT ssh_run). Forwards to broker UDS; app-absent → JSON-RPC err "Muya app not running". Light deps (serde_json+std).
- `Server.agent_access` (ssh.rs, `agentAccess` serde default=false). SshPage checkbox. App.tsx `openSshServer` useCallback + `ssh-broker-open` listener.
- Cargo.toml: `libc=0.2`, two `[[bin]]` (muya, muya-ssh-mcp). lib.rs: mod broker, manage(BrokerState), setup starts listener + register_mcp (idempotent install_mcp).
- Tests: 152 backend, 82 vitest, tsc clean, proxy builds. Live e2e 18/18 (scratchpad/e2e_proxy.py).

**SSH AGENT BROKER — Faz 2 DONE (AC8–AC10, 2026-07-26): `ssh_run(alias, command)`**
- `pty::run_with_injection(program, args, inject_secret: Option<Zeroizing<String>>, timeout) -> CommandOutput{stdout,exit_code,timed_out}` (`pty.rs`): REAL PTY (ssh needs a TTY, NOT std Command), reader thread injects once on `looks_like_password_prompt`, BOUNDED 256KB capture buffer, `try_wait` poll loop (50ms) → kill on timeout. SYNC → call via `tokio::task::spawn_blocking`. `strip_injected_prompt` removes prompt line (first `password:`/`passcode:`) so prompt text isn't returned; password never echoed by ssh anyway.
- `broker.rs`: `handle_request` now ASYNC; `run` arm → `handle_run` (async): `resolve_open` gate → local store-unlock gate → resolve secret (local→`secret_for`, cyberark→`fetch_password`, **prompt→hard error** "no password to inject") → `ssh::connect_command_for(server)` (NEW pub helper, resolves PSMP profile from config) → `assemble_run_args` → spawn_blocking run. Returns `{ok,stdout,exitCode,timedOut}`. Secret NEVER serialized.
- AC9: `assemble_run_args(base, command)` pops dest, inserts `-o LogLevel=ERROR` before it, appends command as EXACTLY ONE argv element (no `bash -c`, verbose off).
- AC10: `BrokerState.run_slots: Arc<Semaphore>` N=4 (`MAX_CONCURRENT_RUNS`), custom `Default` impl (no longer derive). `try_acquire_owned` or fail-fast; permit held for run. RUN_TIMEOUT=60s.
- `muya_ssh_mcp.rs`: `ssh_run` tool in tools/list (schema `{alias,command}`) + tools/call forwards `{op:run,alias,command}`, returns stdout text + exit-code note + structuredContent.
- Tests +4: `strip_injected_prompt_removes_prompt_line`, `ac9_remote_command_is_single_argv_element`, `assemble_run_args_rejects_empty_base`, `ac10_run_slots_cap_is_enforced`. Live `#[ignore]` `run_with_injection_live` (Docker sshd 127.0.0.1:2222) → stdout `MUYA_RUN_OK\r\n`, exit 0, no pw. PASS.
- Gotchas: (1) macOS = `getpeereid` NOT SO_PEERCRED. (2) proxy `[[bin]]` in same crate builds muya_lib too. (3) `.app` bundle of 2nd bin needs tauri externalBin/copy — dev current_exe-parent works, release TODO. (4) app↔proxy wire is PRIVATE `{op,alias,command}` JSON, distinct from MCP framing. (5) BrokerState Default now MANUAL (Semaphore has no Default). (6) run_with_injection holds `_master` alive until reader thread joins else reads error early.
- Step output: `docs/prd-verify/step-output-phase1.md`, `docs/prd-verify/step-output-phase2.md`.

## Prior state (2026-07-17)

**REMOTE DATA CHANNEL WIRING — DONE** (branch: main, commit 7e782c6)
(Note: this closes the gap Faz 2's `bridge_remote_listen` stub left — "Faz 3 adds full handler" — NOT the same as the "Faz 3 TASK EXECUTION" phase below, which is a separate exec-engine phase.)

- Wired the mTLS data path Faz 2 stubbed out. Receiving: `bridge_remote_listen` accept loop now extracts TLS-verified client SPKI, enqueues `InboundRequest` into the SAME `BridgeState.inbound_tx`/`staged` local UDS uses (`ingest_remote_request`, testable core extracted since `AppHandle` can't be mocked). Sending: new `bridge_remote_send` command + `remote_send_impl` (testable core) dials a pinned peer over mutual-auth TLS 1.3 via new `PinnedServerCertVerifier` (client-side verifier pinning the SERVER cert to the exact looked-up peer SPKI — NOT `NoCertVerifier`, which stays scoped to first-pairing only).
- `bridge::required_approval` made `pub(crate)` so the remote path reuses the identical approval gate as local.
- `ChatView.tsx` `send()` branches on `active.kind`: remote → `bridge_remote_send`, local → `bridge_send`.
- 4 new real-socket tests (real `TcpListener`+`TlsAcceptor`/`TlsConnector`, two Ed25519 identities pinning each other): round-trip proving broker gets sender's verified SPKI, unpinned-peer fail-closed, direct verifier reject/accept, real-socket SPKI-mismatch (stale-registry/MITM sim) rejected at handshake both sides. 102/102 backend, 55/55 frontend, tsc clean.
- Step output: `docs/prd-verify/step-output-faz-2-remote-mtls.md` § Data-channel wiring.

## Prior state (2026-07-15)

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
- `src-tauri/src/bridge.rs` — local UDS (Faz 1); `required_approval` now `pub(crate)`
- `src-tauri/src/bridge_remote.rs` — remote mTLS + pairing (Faz 2) + data channel wiring; ~2540 lines
- `src-tauri/src/bridge_exec.rs` — task exec engine (Faz 3); ~900 lines
- `src-tauri/src/lib.rs` — all registered
- `src-tauri/Cargo.toml` — rcgen, spake2-conflux, sha2, hkdf, rand, tempfile
- `src/components/ChatView.tsx` — routes send() to bridge_remote_send/bridge_send by peer kind

## Known gap (not yet wired)

`bridge_remote_listen` (the remote TCP+TLS listener start/stop) is registered as a
Tauri command but **the frontend never calls it** — grepped, zero call sites in `src/`.
`ChatView.tsx`'s "Accept connections" toggle only calls `bridge_local_listen` +
`bridge_pair_invite`. So today a peer can be PAIRED (SPKI pinned) but the remote
data listener that would let `bridge_remote_send` actually land anywhere is never
started via UI. Out of scope for the data-channel wiring task (explicitly scoped to
send()-routing only) — flag for whoever builds the remote-listener toggle UI.

## Next phase

**Faz 4 (optional):** OS-level sandbox (macOS `sandbox-exec` / Linux seccomp-BPF). Frontend bridge UI for approve/audit (events already emitted: `bridge://task-chunk`, `bridge://task-end`, `bridge://task-rejected`). Also: frontend toggle to start `bridge_remote_listen` (see gap above).

## ADR refs
- ADR 0002: `docs/adr/claude-remote-bridge-architecture.md`
- Step output Faz 3: `docs/prd-verify/step-output-faz-3-task-handoff.md`
- Step output Faz 2 (with Retry 1): `docs/prd-verify/step-output-faz-2-remote-mtls.md`

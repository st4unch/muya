# SSH Agent Broker — Phase 2 verification (AC8–AC10)

- Date: 2026-07-26
- Spec: `docs/prd-ssh-agent-broker.md` §3 Faz 2; MCP proxy targets protocol `2025-06-18`.
- Scope: `ssh_run(alias, command)` — one command on an opted-in server, stdout
  captured, password injected server-side (Rust), never exposed.

## AC8 — non-interactive capture-with-injection: PASS

- New `pty::run_with_injection(program, args, inject_secret, timeout) -> CommandOutput`
  (`src-tauri/src/pty.rs`). Opens a REAL PTY (ssh reads the password from a TTY),
  reader thread injects the secret once on `looks_like_password_prompt`, accumulates
  output into a BOUNDED buffer (256 KB cap), polls `try_wait` until child exit or
  `timeout` (kills on timeout → `timedOut:true`). Synchronous → called via
  `tokio::task::spawn_blocking` from the broker.
- `CommandOutput { stdout, exit_code, timed_out }`. Prompt line stripped from stdout
  via `strip_injected_prompt` (first `password:`/`passcode:` occurrence).
- LIVE e2e (`run_with_injection_live`, `#[ignore]`) against Docker sshd
  (`muya-ssh-test`, 127.0.0.1:2222, testuser/Sup3rSecret!):

  ```
  running 1 test
  captured stdout: "MUYA_RUN_OK\r\n"
  exit_code=Some(0) timed_out=false
  test result: ok. 1 passed; 0 failed; ...
  ```

  Asserts stdout contains `MUYA_RUN_OK` and does NOT contain `Sup3rSecret!`. PASS.

## AC9 — injection-safe: PASS

- `broker::assemble_run_args(base, command)`: pops the ssh destination, inserts
  `-o LogLevel=ERROR` before it, re-pushes destination, then appends `command` as
  EXACTLY ONE argv element. No `bash -c`, no shell on the Muya side. Verbose off.
- Secret only enters the PTY at the prompt; prompt line stripped from returned stdout.
- Unit test `ac9_remote_command_is_single_argv_element`: `echo hi; whoami && id`
  stays a single trailing argv element (metacharacters never split). PASS.

## AC10 — concurrency limit: PASS

- `BrokerState.run_slots: Arc<Semaphore>` (N=4, `MAX_CONCURRENT_RUNS`). `handle_run`
  `try_acquire_owned` or fails fast ("too many concurrent ssh_run"). Permit held for
  the run.
- Unit test `ac10_run_slots_cap_is_enforced`: acquire N, (N+1)th errors fast, freed
  slot reusable. PASS.

## Broker `run` op + proxy tool

- `broker.rs` `handle_request` now async; `run` arm → `handle_run`: resolve alias
  (`resolve_open`), local-store-unlock gate, resolve secret (local→`secret_for`,
  cyberark→`fetch_password`, prompt→clear error "no password to inject"), build via
  `ssh::connect_command_for`, `assemble_run_args`, `run_with_injection`. Returns
  `{ok,stdout,exitCode,timedOut}`. Secret NEVER serialized.
- `muya_ssh_mcp.rs`: `ssh_run` tool added to `tools/list` (schema `{alias, command}`)
  + `tools/call` forwards `{op:run,alias,command}`, returns stdout as MCP text +
  exit-code note + `structuredContent`. Builds clean.

## Test totals

- `cargo test`: 152 passed, 0 failed, 6 ignored (was 148 → +4 unit tests).
- `cargo test run_with_injection_live -- --ignored`: 1 passed (live sshd).
- `cargo build --bin muya-ssh-mcp`: clean.
- Frontend untouched this phase (no tsc/vitest impact).

## Security invariant held

Secret resolved + injected ONLY in the app process; never returned to proxy/agent,
never in the outer process argv (goes into the PTY at the prompt), never logged,
stripped from captured stdout. `prompt` sources rejected (nothing to inject).

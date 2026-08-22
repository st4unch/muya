---
name: muya-debugger
description: Diagnosis playbook for Muya, a Tauri v2 (Rust) + React 19 desktop app that runs parallel Claude Code agents in PTY terminals with an MCP server, SSH/CyberArk PSMP integration, and an encrypted credential vault. Use this skill whenever something in Muya isn't working and the cause isn't obvious — a terminal/PTY shows nothing, is garbled, or won't take input; a Claude session dies unexpectedly; an MCP tool doesn't appear in the agent's tool list or returns an error/does nothing; the UI shows stale state versus the real backend; an SSH or CyberArk PSMP connection fails, hangs, or asks for OTP repeatedly; a file changed on disk but the editor/file tree didn't update; or the app hangs/freezes. This is a diagnosis skill — it tells you where to look and what command to run, grounded in this codebase's actual failure history, not generic debugging advice.
---

# muya-debugger — find the bug fast in Muya's PTY/IPC/vault stack

Muya has three process boundaries (agent↔sidecar, sidecar↔app, Rust↔frontend) plus a PTY layer and an SSH/PSMP layer. Most "it's not working" reports map to exactly one of these. Triage first, read code second.

## 1. Triage table — symptom → layer → first thing to check

| Symptom | Most likely layer | First command/file |
|---|---|---|
| Terminal shows nothing / blank | PTY spawn or hidden-tab resize | Check `pty_spawn` returned an id (`Terminal.tsx` `onPtyReady`); if the tab was hidden then shown, see §5 |
| Terminal garbled / wrapped wrong after switching tabs | Hidden xterm missed a resize (L3) | `Terminal.tsx` `active` prop path — must re-`fit()` + `pty_resize` + `term.focus()` in `requestAnimationFrame` on show |
| Terminal won't accept input | Modal/overlay eating keys, or PTY never got `pty_write` | Check for an open `[role="dialog"]` stealing focus; check `term.onData` is wired in `Terminal.tsx` |
| Claude session dies when switching views | Component unmounted and cleanup called `pty_kill` (L1) | Confirm the view container is `hidden` (display:none), never conditionally unmounted, in `App.tsx` |
| A spawned `claude` in a Muya terminal can't be backgrounded / "nothing to resume" | Parent's `CLAUDE_CODE_SESSION_ID`/`CLAUDECODE`/`AI_AGENT` leaked into the child | `pty.rs` — grep `env_remove`, confirm the `CLAUDE*`/`AI_AGENT` strip loop ran before spawn; test: `cargo test pty_strips_claude_env` |
| New/changed MCP tool doesn't appear in the agent's tool list | Client cached `tools/list` at connect time | Not a code bug — reconnect/restart the Claude Code session using `muya-mcp`. See §3 |
| MCP tool call errors or returns nothing useful | Sidecar↔app socket down, or a response field dropped mid-hop (L36) | Drive the sidecar directly over stdio (§3); then check `~/.claude/muya-ssh-broker.sock` exists and the app is running |
| MCP tool response is missing a field you know the backend sends | Two-hop field loss: sidecar rebuilds `structuredContent` from a fixed field list (L36) | `src-tauri/src/bin/muya_ssh_mcp.rs` `tool_ok`/`handle_tools_call` — the field must be added at BOTH `broker.rs` and the sidecar's rebuild, not just the producer |
| UI shows state that doesn't match the backend (stale file tree, wrong agent status, vault looks unlocked but isn't) | A Tauri event never fired, or the frontend listener's target-id lookup missed | See §4 — check the event name matches and the id is present in the frontend's lookup map |
| SSH connects but no login happens, or login is flaky | PTY prompt-injection race, or PSMP wants keyboard-interactive not a plain password prompt | See §6 — L33/L34; check `is_psmp` branch and `SSH_ASKPASS` path, not `looks_like_password_prompt` pattern matching |
| SSH/PSMP: first command works, every command after fails ("Invalid session state", "Failed to receive an allowed pid message") | ControlMaster reuse against PSMP (L41) — always fails on the 2nd+ command | `ssh -O check <alias>` locally — if "Master running" persists across failures, `ssh -O exit` it; don't wait for `ControlPersist` to reap it (it won't — PSMP master is never "idle") |
| SSH/PSMP: keeps re-asking for OTP/push even for routine commands | Expected under PSMP — each new connection = new auth (L44) | Batch multiple commands into one `ssh_run`/session instead of one call per command; or use the persistent agent-owned session (`agent_ssh.rs`) |
| scp works over `ssh_run` but fails instantly (exit 255) or times out through PSMP | Modern OpenSSH scp defaults to SFTP subsystem; PSMP only proxies legacy scp exec protocol (L35) | Confirm `-O` (legacy) is forced in the PSMP scp command builder |
| A background exec/session call hangs and never returns | Missing subprocess timeout, or sentinel/marker echo collision (see §7) | Check the call has a wall-clock deadline (`agent_ssh.rs` `DEFAULT_EXEC_TIMEOUT` = 120s); if it always hangs to exactly that duration, suspect marker collision |
| File changed on disk but tree/editor didn't refresh | `watcher.rs` debounce dropped a trailing event (L38) | Confirm the flusher thread is alive (`start_watching` spawns one per watch generation); a leading-edge-only debounce silently drops the "just settled" event |
| App hangs / a simple command (list_dir, read_file) takes ~10s | A `#[tauri::command(async)]` with a blocking subprocess body starved the tokio worker pool (L16, L31) | grep the slow command for `Command::new(...).output()` without `spawn_blocking`; check polling intervals aren't too aggressive (e.g. `git_status` every 5s × N roots) |
| macOS "Muya wants to access data from other apps" prompt keeps appearing | Something is `read_dir`-ing `~/Library/CloudStorage`/iCloud/Containers on a poll (L43) | grep `vault.rs` `detect_vaults` and anything else scanning cloud-sync dirs automatically |
| Vault "unlock" looks like nothing happened | Argon2id KDF genuinely takes real time with no spinner (L30) | Check for a busy/"Unlocking…" state, not just `disabled` styling, before assuming it's broken |

## 2. The three process boundaries — how to observe each

**(1) External agent ↔ MCP sidecar.** Claude Code spawns `muya-ssh-mcp` (binary target in `src-tauri/Cargo.toml`, source `src-tauri/src/bin/muya_ssh_mcp.rs`, MCP server name `muya-mcp`) as a stdio JSON-RPC 2.0 process — newline-delimited, one message per line, responses on stdout, diagnostics on stderr. It holds no secrets; every tool call is forwarded to the running app over a Unix socket.

Drive it directly to see the REAL tool list and REAL responses, bypassing Claude Code entirely:

```bash
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | ./target/debug/muya-ssh-mcp
```

Add a third line with `"method":"tools/call","params":{"name":"ssh_list_servers","arguments":{}}}` to exercise a specific tool. This technique is the fastest way to tell "is the sidecar broken" from "is the app-side broker broken" from "is Claude Code's cached tool list stale" — each layer answers differently.

**(2) Sidecar ↔ main app.** The sidecar talks to the running Muya app over an owner-only Unix Domain Socket at `~/.claude/muya-ssh-broker.sock` (override: `MUYA_SSH_BROKER_SOCK`). Protocol is tiny newline-delimited JSON: `{"op":"list_servers"}` / `{"op":"open","alias":"..."}` in, `{"ok":true,...}` / `{"ok":false,"error":".."}` out. Checks:

```bash
ls -la ~/.claude/muya-ssh-broker.sock   # exists? mode should be 0600
lsof ~/.claude/muya-ssh-broker.sock     # who's listening — should be the running Muya app
```

`broker.rs` also checks the connecting process's uid via `getpeereid` (macOS/BSD) — a connection from a different user is rejected outright, distinct from `bridge.rs` which has no peer check. If `app_call` in the sidecar fails, it surfaces as "Muya app not running" even if the real cause is a stale/wrong-permission socket file.

**(3) Rust ↔ frontend.** Backend emits Tauri events (`app.emit("event-name", payload)`); frontend subscribes with `listen<T>("event-name", handler)` (see `App.tsx`'s `apache://open-file`/`fs-changed` patterns). A silent no-op here almost always means one of: the event name string doesn't match exactly on both sides, the listener's cleanup ran too early (React 19 StrictMode double-mount/unmount — mount effects can fire twice in dev), or the payload carries an id that isn't present in the frontend's own lookup map (e.g. a session id not found in `sessionIdToKeyRef`, so the update is silently dropped). Add a temporary `console.log` at the top of the `listen` callback to confirm the event even arrives before debugging further downstream.

## 3. "My new/changed MCP tool doesn't show up" — not a bug

`tools/list` is answered once, at connection time (see `handle_method` in `muya_ssh_mcp.rs` — `initialize` then `tools/list`). If you add, rename, or change a tool's schema and rebuild the sidecar binary, **the already-running Claude Code session still has the old list cached** — it will not see the change until that session reconnects. Don't chase a phantom bug here: restart/reconnect the Claude Code session (or start a fresh one) before concluding the tool registration is broken. Verify the binary itself is correct first with the stdio drive in §2(1).

## 4. Where the logs actually are

Muya has a dedicated, opt-in debug log for the CyberArk + SSH flows: **`~/.claude/muya-debug.log`**, gated by a Settings toggle (`debug_log_set`/`debug_log_get` Tauri commands, `src-tauri/src/debuglog.rs`). It's a global module-level sink (`ENABLED` atomic + `PATH` mutex) specifically so deep async code that never sees Tauri `State` can still log without threading a handle through — this is why the codebase uses `crate::debuglog::log(...)` at call sites in `ssh.rs`, `broker.rs`, `agent_ssh.rs`, and `cyberark.rs` instead of a general-purpose logging macro. **Ordinary `log::info!`/`println!` output does NOT land in `muya-debug.log`** and won't be visible to the operator watching that file — if you're adding a new diagnostic line for the SSH/CyberArk/PTY path, use `crate::debuglog::log(&format!(...))`, not `log::info!`. It's best-effort (a failed write is silently swallowed) and callers pass only metadata — no secret value may ever reach it.

To turn it on manually without the UI: write `{"enabled": true, "path": "..."}`-shaped content to `~/.claude/muya-settings.json` (see `debuglog::load_and_apply`/`read_settings`), or just flip the toggle in Settings and restart the flow you're chasing. Then:

```bash
tail -f ~/.claude/muya-debug.log
```

## 5. PTY-specific debugging

- **Sentinel/marker echo collision.** `agent_ssh.rs`'s `exec()` frames each remote command with a nonce'd begin/end marker (`__MUYA<n>B__` / `__MUYA<n>E:<exit>__`) built from a shell variable (`M=__MUYA<n>; printf '\n%sB__\n' "$M"; ...`) specifically so the shell's OWN ECHO of the command line never contains the full marker string — only the interpolated output does. If this guard is ever weakened (e.g. the marker gets hardcoded into the command text instead of built via `$M`/`$R`), the echoed input line can be mistaken for the real marker, and `exec()` will poll past the actual output all the way to `DEFAULT_EXEC_TIMEOUT` (120s) before giving up. If an SSH exec call reliably hangs for close to two minutes, suspect a marker-matching regression before anything else — check `agent_ssh.rs:290-310`.
- **Hidden-tab resize/focus (L3).** A `display:none` (0×0) xterm instance misses `onResize` (bails out at `offsetWidth===0`). `Terminal.tsx` must re-`fit()`, call `pty_resize`, and `term.focus()` inside `requestAnimationFrame` when the tab becomes `active` again — otherwise you get wrapped/garbled redraw or a terminal that silently ignores keystrokes until clicked.
- **CLAUDE\*/AI_AGENT env strip.** Every PTY spawn path (`spawn_process` and the SSH spawn path) strips any env var starting with `CLAUDE` or exactly `AI_AGENT` before `spawn_command`, so a `claude` launched inside a Muya terminal is a clean top-level session (not seen as a child of the Muya process's own session, which would make it non-backgroundable). Verify with:
  ```bash
  cd src-tauri && cargo test pty_strips_claude_env
  ```
  If a *new* spawn path is added and forgets this strip loop, `claude` inside that terminal will misbehave ("nothing to resume", odd session nesting) even though the PTY itself looks fine.
- **Unmount = kill (L1).** Never conditionally unmount a `<Terminal>`/PTY-backed component on view switch — its cleanup calls `pty_kill`, silently killing a running session. Always keep it mounted and toggle `hidden`.

## 6. SSH / CyberArk PSMP-specific debugging

PSMP (CyberArk's SSH proxy) behaves very differently from plain SSH. Do not assume normal SSH semantics.

- **ControlMaster reuse never works against PSMP (L41).** The first connection through a multiplexed master succeeds; every command after that fails ("Failed to receive an allowed pid message" / "Invalid session state -1,-3") because PSMP requires a fresh "allowed pid" handshake per session and a multiplexed channel skips it. The master process stays alive and reports "Master running" even 40+ minutes later — `ControlPersist` will NOT reap it because PSMP never counts it as idle. A broken master silently locks that alias until you force-close it:
  ```bash
  ssh -O check <alias>   # "Master running" = the trap
  ssh -O exit <alias>    # forces a fresh master on the next connection
  ```
  The fix in this codebase is architectural, not per-incident: batch multiple remote commands into one connection (`commands:[]`) rather than relying on reuse.
- **OTP/push fires per connection, not per command (L44).** With ControlMaster reuse off, every `ssh_run` call is a brand-new PSMP session, hence a brand-new OTP/RADIUS push. This is expected, not a regression — the only way to reduce prompt frequency is fewer connections (batch commands, or the persistent agent-owned session in `agent_ssh.rs` which keeps one PTY/one PSMP-audited session alive for many commands).
- **scp needs `-O` (legacy protocol) through PSMP (L35).** OpenSSH 9.0+ defaults `scp` to an SFTP-based transfer; PSMP only proxies the legacy scp exec protocol. Symptom: `ssh_run` works fine on the same server, but `scp`/`ssh_scp` fails instantly (exit 255) or times out. Confirm the PSMP scp path forces `-O`.
- **Password-prompt pattern matching is inherently racy (L33/L34).** `looks_like_password_prompt`-style detection over a chunked, async PTY stream can miss a prompt split across reads or trailing ANSI codes — this is why deterministic injection (`SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force`) is preferred over prompt-matching where available. If auth "sometimes" fails (not always), suspect the timing race, not the credential.
- **Mirror every auth-affecting flag when adding a new SSH-family command (L33).** `ssh_scp` originally missed `-o PubkeyAuthentication=no` that `ssh_run`'s connect path already had, so PSMP tried pubkey auth first and closed the connection before the password challenge ever appeared. When adding a new command that wraps `ssh`, diff it against the working command's full argv, not just the obviously-relevant flags.
- **Docker sshd, PSMP, and Docker + PSMP are different truths.** A local Docker sshd (plain `password:` prompt) validates PTY plumbing but does NOT validate PSMP's keyboard-interactive challenge — a fix that passes against Docker can still fail against real PSMP (this happened twice, L33/L34). State explicitly which target a fix was verified against.

## 7. Self-verification recipes (don't say "should work" — prove it)

- **Drive the MCP sidecar over stdio** (§2) — proves the tool list and a tool call end-to-end without needing Claude Code at all.
- **Live Docker sshd** (validates PTY password injection, NOT PSMP):
  ```bash
  docker run -d --name muya-ssh-test -e PASSWORD_ACCESS=true \
    -e USER_NAME=testuser -e USER_PASSWORD='Sup3rSecret!' -p 2222:2222 \
    lscr.io/linuxserver/openssh-server
  cd src-tauri && cargo test --lib -- --ignored --nocapture
  ```
  Runs the `#[ignore]`d live tests (`pty_injection_logs_into_real_sshd`, `run_with_injection_live`) that assert the real ssh login happens and the secret never leaks into captured output.
- **List real Claude sessions**: `claude agents --json` — this is exactly what `agents.rs`'s `list_agent_sessions_sync` shells out to; run it yourself to check whether a "session not showing in Muya" report is a Muya bug or the CLI itself not reporting the session.
- **Frontend wiring, not just backend logic (L39, the cardinal rule of this project).** `cargo test` and `npm test` green does NOT mean a GUI-triggered flow works — a past regression shipped as "6/6 AC, working" while the actual search box never called the backend function it was supposed to. If you can't drive the real UI (cua-driver or similar), say explicitly "backend verified, GUI unconfirmed" — never claim it works from unit tests alone.

**Test commands and what they do / don't catch:**

| Command | Catches | Does NOT catch |
|---|---|---|
| `cargo test --lib` | Rust logic, unit-level PTY/marker/argv-policy correctness | Real PSMP behavior, real UI wiring, timing races |
| `cargo test --lib -- --ignored --nocapture` | End-to-end PTY injection against a real (Docker) sshd | PSMP-specific keyboard-interactive quirks (L33) |
| `npm test -- --run` | Component/store logic (vitest) | Whether the compiled Tauri webview actually renders it (L21 dev-webview flake exists) |
| `npx tsc --noEmit` | Type errors | Runtime behavior entirely |

## 8. Safety while debugging

- **Never run a broad `pkill -f muya`.** If you're working inside a terminal that is itself hosted by the operator's running Muya app, this kills their live app and every session in it. Only kill a specific PID you resolved yourself, or a `target/debug/muya` **dev** instance you started.
- Don't assume a diagnosis from build/version strings ("this must be an old build") without reading the actual code path (L36) — two-hop response shapes and cached tool lists (§3) both produce symptoms that look exactly like "stale build."
- If you can't verify a fix against the real target (real PSMP, the real running app, the real UI), say so explicitly rather than declaring it fixed — this codebase's history (L33/L34) is largely a record of fixes shipped as "should work" against a mock that didn't fail the same way the real target did.

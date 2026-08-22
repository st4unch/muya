---
name: muya-agent
description: How to implement features IN the Muya codebase itself — a Tauri v2 (Rust) + React 19/TS desktop app for running parallel Claude Code sessions. Not about calling Muya's MCP tools; this is for an agent writing Muya's own code. Use when implementing a feature in this repo, adding a Tauri command, adding an MCP tool to the broker/sidecar, touching PTY/terminal code (pty.rs, Terminal.tsx), editing App.tsx, wiring a Tauri event, cutting a release, or when the task mentions "add a command", "add an MCP tool", "new terminal tab kind", "new frontend page", or "muya-agent".
---

# muya-agent — building Muya, not using it

Muya is a native macOS (Apple Silicon) desktop control panel for running/observing
multiple Claude Code sessions. This skill orients an agent that is about to change
Muya's own source, not one calling Muya's MCP tools (that's the `muya-mcp` skill).

## 1. Architecture in 10 lines

- **Frontend**: React 19 + TypeScript, Vite, rendered in a Tauri webview. Router/shell
  is monolithic `src/App.tsx` (~2900 lines) + focused components in `src/components/`.
- **Rust core**: `src-tauri/src/`, one crate `muya_lib` + two bins (`muya`, `muya-ssh-mcp`).
  ~15 modules, `#[tauri::command]` fns registered once in `lib.rs:274` `generate_handler![...]`.
  Shared state via `.manage(...)` in `lib.rs:263-273` (`PtyManager`, `BrokerState`,
  `CredStore`, `AgentSshStore`, etc.).
- **No database.** Config is plain JSON under `~/.claude/muya-*.json`. Secrets (added since
  the original SYSTEM.md) are AES-256-GCM + Argon2id encrypted via `credstore.rs`
  (`aes-gcm`, `argon2`, `zeroize` in `Cargo.toml:80-83`), zeroized in memory.
- **No separate backend server** — PTY sessions, the filesystem watcher, the MCP broker,
  and the remote bridge all run in-process as tokio tasks.
- Read `docs/SYSTEM.md` first for the full picture; it's kept current and cites `file:line`.

## 2. The MCP two-hop (the most error-prone task in this codebase)

An external agent (you, in another session) talks to Muya over MCP. That request crosses
**two process hops** before it can touch the UI:

```
external agent → muya-ssh-mcp sidecar (bin) → Unix socket → broker.rs (main app) → app.emit → App.tsx listen()
```

- **Sidecar**: `src-tauri/src/bin/muya_ssh_mcp.rs` — a standalone binary launched as the
  MCP server process. Owns the JSON-RPC `tools/list` schema and `tools/call` dispatch.
  Talks to the running app over a Unix socket (`app_socket_path()` / `app_call()`,
  `muya_ssh_mcp.rs:27-39`).
- **Broker**: `src-tauri/src/broker.rs` (2078 lines) — runs inside the main app, owns a
  `UnixListener` (`socket_path()` `broker.rs:376`, bind at `:1592-1597`), dispatches on
  `req.op.as_str()` (`handle_request`, `broker.rs:415-490`).
- **UI**: some ops also `app.emit(...)` a Tauri event the frontend `listen()`s for, e.g.
  `open_session` → `broker.rs:911` emits `muya://open-agent-session` → `App.tsx:937`.

**Adding a new MCP tool — do ALL of these, in this order, or it silently half-works:**

| # | File | What to add |
|---|---|---|
| 1 | `muya_ssh_mcp.rs` — `tools` list (~`:102` `json!({"tools": [...]})`) | Tool name, JSON-schema `inputSchema` |
| 2 | `muya_ssh_mcp.rs` — dispatch match arm | Build the `{"op": "...", ...}` request, call `app_call(&json!({...}))`, shape `structuredContent` via `tool_ok(text, Some(json!({...})))` |
| 3 | `broker.rs` — `handle_request` match (`:428-490`) | New `"your_op" => handle_your_op(app, &req).await` arm |
| 4 | `broker.rs` — handler fn | Parse `BrokerReq`, do the work, return JSON string via `err_resp`/success shape |
| 5 | **If UI-visible** — `broker.rs` handler | `app.emit("muya://your-event", payload)` |
| 6 | **If UI-visible** — `App.tsx` | `listen("muya://your-event", (e) => {...})` in a mount-once effect |

Every field you add to a response must be threaded through **both** hop-2→hop-1
reformatting steps — the sidecar rebuilds `structuredContent` field-by-field, it does not
forward the broker's JSON verbatim (L36: a `stderr` field was added to the broker response
but stayed invisible to the agent because the sidecar's fixed-field rebuild omitted it).
When a new field "isn't showing up", check the sidecar's rebuild *before* suspecting a stale
build.

**Ownership pattern**: several ops track "who opened this" so an agent can only act on
sessions/tabs it opened itself (never the operator's). See `register_ssh_session`/
`agent_session_is_open`/`release_agent_session` (`broker.rs:59-104`) and the mirrored
`resolve_target` (`broker.rs:827`) — exact-id → exact-name → substring, **never guesses
on ambiguous matches**, returns candidates instead. Reuse this pattern, don't invent a new
resolution scheme (L25: a "named" resource that's actually looked up by opaque id is
unusable by name).

## 3. Adding a plain Tauri command

1. `#[tauri::command]` (or `#[tauri::command(async)]`) `fn`/`async fn` in the relevant module.
2. Register it in `lib.rs`'s `generate_handler![...]` list (`lib.rs:274`).
3. If it needs shared state, `.manage(YourState::default())` in the builder chain
   (`lib.rs:263-273`) and take `State<YourState>` as a param.

**`(async)` matters — get it right:**

- A command that does I/O (subprocess, file, network) but is declared **without** `async`
  runs on the **main thread** and blocks the UI (L16: `pty_cwds`/`pty_session_ids` polling
  every 3s without `(async)` froze the UI for ~200ms each tick — `claude agents --json`
  spawns Node).
- Marking it `(async)` alone is not enough if the body still does *synchronous* blocking
  work — Tauri dispatches `(async)` commands onto the tokio **worker** pool (≈num_cpus,
  not the larger blocking pool), so a blocking subprocess call there starves *other*
  unrelated commands queued behind it (L31: `git_status`'s `Command::new("git").output()`
  starved the worker pool; innocent `list_dir` calls waited ~10s for a free worker).
- **Rule**: if the command shells out or does CPU-bound work, wrap that part in
  `tokio::task::spawn_blocking(move || { ... })` (24 existing call sites in `src-tauri/src/`,
  e.g. `broker.rs:676,922,956,1012,1094`) or use `tokio::process::Command` for a real async
  subprocess. Never leave blocking work directly in an `(async)` command body.
- Any subprocess/PTY op an **agent** can trigger needs a wall-clock timeout + kill — an
  agent-facing tool call that never returns locks that agent's session (L26: `run_operation`
  added a 60s `OP_TIMEOUT` + kill after a hang was reported as "terminal frozen").

## 4. Testing conventions

| Layer | Command | Notes |
|---|---|---|
| Rust unit/integration | `cargo test --lib` (from `src-tauri/`) | Pure fns extracted specifically to be testable without an `AppHandle` — e.g. `resolve_target` (`broker.rs:827`), `build_open_session_payload` (`broker.rs:890`), `parse_batch_output`, `is_stale_master`. Prefer extracting logic into such a fn over testing through Tauri state. |
| Rust hermetic git tests | same, `fs.rs` | Uses `tempfile::tempdir()` + real `git` in a scratch dir (`fs.rs:1169+`) — no mocking, no network. |
| Rust live/manual tests | `cargo test --lib -- --ignored` | `#[ignore]`d tests in `pty.rs` need a **real sshd**: `docker run -d --name muya-ssh-test -e PASSWORD_ACCESS=true -e USER_NAME=testuser -e USER_PASSWORD='Sup3rSecret!' -p 2222:2222 linuxserver/openssh-server` (full form: `pty.rs:864-867`; also `pty.rs:1059-1063` for the second test). |
| Frontend unit | `npm test` (= `vitest run`, `package.json:10`) | |
| Frontend types | `npx tsc --noEmit` | Run before every commit that touches `src/` — this repo has no separate lint-only CI gate. |
| Live UI verification | Tauri WKWebView dev has a known flake (blank white render, unrelated to your code — L21). Don't diagnose your change from a blank window; use the `VITE_BROWSER_MOCK=1` dev:mock shim or restart the Mac. |

All three green (`cargo test --lib`, `npm test`, `npx tsc --noEmit`) is the bar every
PRD in `docs/prd-*.md` cites as its final AC — match that convention in yours.

## 5. Frontend conventions

- **Never conditionally unmount a stateful component on view switch.** `App.tsx:59`
  (control view) stays mounted always, hidden via CSS — because unmounting `<Terminal>`
  runs its cleanup, which calls `pty_kill` and **kills the live PTY / running Claude
  session** (L1, the oldest and highest-confidence lesson in this repo, confidence 0.45).
  Same logic for any websocket/xterm/media component: mount-once, hide with `hidden`
  (display:none), never `{view === "x" && <Component/>}` for anything stateful.
- **But don't eager-mount everything either.** The fix to L1 over-corrected once into
  mounting every page at startup, causing a "thundering herd" of simultaneous data-fetches
  (L32). Pattern: a `mountedViews` Set that only grows — `mountedViews.has(view) &&
  <Panel/>` inside the always-present `hidden` wrapper. First visit mounts it; after that
  it stays alive.
- **Hidden xterm misses resizes.** A `display:none` terminal has `offsetWidth === 0` and
  bails out of resize handling. On show: re-fit + `pty_resize` + `term.focus()` inside
  `requestAnimationFrame` (L3, `Terminal.tsx`).
- **Refs, not state, inside mount-once listeners.** A `listen(...)` effect that runs once
  captures whatever `openTerminals` was *at mount time* — reading current state there is
  a stale closure. Use `openTerminalsRef.current` instead (see `App.tsx:417-422`,
  comment explains why: the listener predates any tab the ref needs to see).
- **`openTerminals` tab-key prefix scheme** — the `key` prefix drives close-time cleanup
  (`closeTerminal`, `App.tsx:401+`):
  | Prefix | Meaning | On close |
  |---|---|---|
  | `ssh:` | Agent-opened SSH session via `ssh_open` | `invoke("ssh_release_session")` so a later `ssh_send` to a dead tab is refused |
  | `aopen:` | Agent-opened local session via `open_session` | `invoke("release_agent_session", {name})` — read from `openTerminalsRef`, not state |
  | `edit:` | Monaco file editor tab | dirty-check + confirm dialog if unsaved |
  | `mdview:` / `img:` / `pdf:` | Read-only viewers (`openFile`, `App.tsx:390`) | no special release |
  | `new:` | Blank operator-opened terminal | plain `pty_kill` |
  Adding a new terminal-tab kind = pick a prefix, wire it into `closeTerminal`'s branch
  list, and decide whether it needs a release call on close.
- **UI text is English, always.** Chat with the operator can be Turkish; every label,
  status string, tooltip, and placeholder in the shipped app is English (L11, L22 — both
  were live corrections after Turkish strings shipped in the SSH page and a status bar).
- **App.tsx is monolithic** — new pages/panels should be their own component file under
  `src/components/`, wired in via the view union + nav button + render-switch pattern
  documented in `docs/SYSTEM.md` §6, not inlined into `App.tsx`.

## 6. PRD discipline (required before implementing a new feature)

This repo requires a mini-PRD before touching code for anything beyond a trivial fix —
see `docs/prd-close-session.md` for the canonical shape: `## 1. Problem`, `## 2. Scope`
(Dahil/Hariç — included/excluded), `## 3. Kabul Kriterleri` (binary, checkable ACs, closed
out with `[x]` + one-line proof), `## 4. Koruma Listesi` (protection list — subsystems this
PRD must NOT touch). PRDs are written in Turkish (operator's language); code, comments, and
UI stay English. Each PRD gets a matching `docs/prd-<feature>.progress.md` tracking
implementation. Look at 2-3 recent pairs (`docs/prd-agent-session-open.md` /
`.progress.md`, `docs/prd-close-session.md` / `.progress.md`) before writing a new one.

## 7. Release flow

1. Bump version in **both** `src-tauri/tauri.conf.json` (`"version"`) and
   `src-tauri/Cargo.toml` (`version =`) — they must match exactly (currently `0.2.39`).
2. Add a `## [x.y.z] - YYYY-MM-DD` section to `CHANGELOG.md`. This is not optional:
   `scripts/publish-release.sh:67-69` `die`s if the section is missing, and release notes
   are extracted straight from it (`:169-177`).
3. `scripts/build-sign-notarize.sh` → `scripts/publish-release.sh`. Don't hand-roll the
   codesign/notarize/ditto steps — the scripts encode `apex-notary` keychain-profile
   conventions and known gotchas (AppleDouble entries in `.app.tar.gz`, BSD `tar` hiding
   its own `._*` entries — verify archives with a non-BSD reader, e.g. Python `tarfile`, L18).

## 8. Hard rules

- **Never broad `pkill -f muya`.** Claude Code itself may be running inside the operator's
  live Muya app's terminal. Only kill a specific PID or a `target/debug/muya` dev instance
  you spawned — never a pattern match that could hit the host app.
- Never commit secrets, `.env` files, or private keys.
- Remote git (`push`, `push --force`, `gh pr merge`) needs explicit operator approval —
  this is a hard rule independent of how obviously-correct the change is.
- Don't claim a user-facing feature "works" from green tests alone — GUI-triggered flows
  need to be driven for real (cua-driver, or an honest "backend verified, GUI unverified")
  before calling it done (L39).

## 9. Common-task cookbooks

**Add an MCP tool** — see §2 table (6 steps: sidecar schema, sidecar dispatch, broker op
arm, broker handler, optional emit, optional listen).

**Add a plain Tauri command** — `#[tauri::command(async)]` fn in its module → wrap any
blocking work in `spawn_blocking` → register in `lib.rs` `generate_handler!` → `.manage()`
if it needs state → write a pure-fn unit test if the logic can be extracted.

**Add a terminal-tab kind** — pick a `key` prefix → add to `openTerminal(...)` call sites
→ add a branch in `closeTerminal` (`App.tsx:401+`) for any release/cleanup call it needs →
if it's agent-openable, add ownership tracking in `broker.rs` (mirror
`register_agent_session`/`release_agent_session`).

**Add a frontend page** — extend the view union (`App.tsx:345`-area `useState<"control"|...>`)
→ add a nav button → render it with `{mountedViews.has("x") && <YourPage/>}` inside the
always-present hidden wrapper (the real pattern, `App.tsx:1895/1907/1918`), **not**
`{view === "x" && ...}` — that unmounts on every view switch and would kill anything
stateful inside it (§5, L1) → new component file under `src/components/`, not inlined.

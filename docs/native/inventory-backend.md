# Muya Rust backend inventory (for native macOS rewrite)

Scope: `src-tauri` (read-only analysis, 2026-11-03, branch wip/native-rewrite).
Paths below are relative to `src-tauri/` unless noted. Line numbers are from the current tree. Purpose lines for modules are inferred from file names, doc comments and command names; anything not verified by reading the file body is marked "(inferred)". Tauri-coupling numbers come from grepping `AppHandle|Emitter|Manager|State<|Channel<|WebviewWindow|tauri::` plus reading the matched lines.

## 0. Headline facts

- 41 `.rs` files in `src/` plus `src/bin/muya_ssh_mcp.rs` (42 total). Crate is a lib (`muya_lib`) + 2 bins (app, `muya-ssh-mcp`) (`Cargo.toml:8-10` comments, `src/main.rs:4-10`).
- 151 `#[tauri::command]` fns; `generate_handler![]` in `src/lib.rs:463` registers exactly 151 (counted by script).
- 20 distinct `app.emit` event names plus 2 `Channel` streams (PTY output; `ssh_pty_connect` reuses it).
- Zero `#[tauri::command]` in: `broker.rs`, `bridge_mcp.rs`, `askpass.rs`, `agent_ssh.rs`, `opencode.rs`, `local_guard.rs`, `validate.rs`, `testutil.rs`, the bin.
- No `tauri-plugin-single-instance` and no deep-link plugin. Single-instance-ness is handled by the broker socket ownership (`broker::BROKER_OWNED_ELSEWHERE`, `lib.rs:356-366`).
- The app binary doubles as the background scheduler: `muya --scheduler` -> `run_scheduler()` (`src/main.rs:6-8`, `src/lib.rs:151-153`).
- Most "THIN" modules wrap a pure `*_sync` / `*_in(&path)` function inside a one-line command, so lifting them is mostly mechanical.

## 1. Module map

Classification: PURE = no tauri reference in code; THIN = tauri only in command wrappers/edges (few lines, lift by deleting the attribute and arg types); COUPLED = tauri types (AppHandle emit, Channel, State, RunEvent, window) woven through logic, needs an abstraction (event sink trait) before lifting.

| File | Lines | Purpose | Tauri dependence | Class |
|---|---:|---|---|---|
| src/main.rs | 10 | Entry: `--scheduler` flag else `muya_lib::run()` | calls lib only | PURE |
| src/lib.rs | 717 | Builder: plugins, menu, tray, setup, run loop, `quit_now`, close-to-hide, file-open handling, fd limit raise | everything (menu `:239-310`, tray `:131-150`, `.run` `:617-655`) | COUPLED |
| src/agent_files.rs | 279 | Files a session touched (transcript scan) | cmd at `:154` only | THIN |
| src/agent_ops.rs | 590 | Operator-pinned "operations" store + runner for agents | cmds `:406,413` | THIN |
| src/agent_ssh.rs | 468 | Agent SSH sessions on PTY, idle reaper (30 min `:44`), 60 ms poll `:27` | none | PURE |
| src/agents.rs | 780 | `claude agents --json` listing, kill/stop session, TTL cache 5 s `:420` | 4 cmds | THIN |
| src/app_location.rs | 402 | Is app in /Applications, quarantine/translocation (xattr) | none in code (1 doc ref) | PURE |
| src/app_prefs.rs | 126 | `muya-app.json` prefs (keep-running etc.) | 2 cmds | THIN |
| src/askpass.rs | 420 | SSH askpass + FIFO secret injection | none | PURE |
| src/bg_service.rs | 137 | `SMAppService.agent` register of scheduler plist | 3 cmds; objc2 is the real dep | THIN |
| src/bin/muya_ssh_mcp.rs | 1814 | Stdio MCP proxy (sidecar `muya-mcp`), forwards to broker UDS | none | PURE |
| src/bridge.rs | 1067 | Local Claude-to-Claude bridge over UDS | 4 cmds + 16 refs (emit/State) | COUPLED |
| src/bridge_exec.rs | 1490 | Remote task exec/gating/audit/fan-out | 6 cmds, `app.emit` at `:529,867,878` | COUPLED |
| src/bridge_mcp.rs | 909 | MCP surface of bridge, 2 s pollers `:34` | AppHandle emit `:361`, pollers | COUPLED |
| src/bridge_remote.rs | 3319 | mTLS + SPAKE2 pairing, remote listener | 10 cmds, emit `:807,821,1287,1313` | COUPLED |
| src/broker.rs | 2528 | Owner-only UDS broker (getpeereid) serving the MCP sidecar; emits UI events | AppHandle emit `:607,992`, State | COUPLED |
| src/claude_settings.rs | 192 | `cleanupPeriodDays` get/set in ~/.claude settings | 2 cmds | THIN |
| src/credstore.rs | 1596 | AES-256-GCM+Argon2id credential vault, Keychain/Touch ID | 18 cmds; `CredStore` plain struct via `State<>` | THIN (borderline) |
| src/cyberark.rs | 785 | CyberArk PVWA logon/accounts | 5 cmds, `State<CredStore>` | THIN |
| src/debuglog.rs | 257 | Debug log toggle to file | 2 cmds | THIN |
| src/file_history.rs | 297 | Per-file version snapshots | 3 cmds | THIN |
| src/fs.rs | 2570 | Files, git worktrees/branches, marketplace fetch, plugin install, privacy/Finder helpers | 30 cmds; `tauri::ipc::Response` `:86`, asset allowlist `:765` | THIN (largest wrapper surface) |
| src/history.rs | 949 | Session history list/transcript/archive/trash | 6 cmds | THIN |
| src/local_guard.rs | 277 | Local-only guard checks (inferred) | none | PURE |
| src/login_item.rs | 219 | Login item via plutil/launchd | 2 cmds | THIN |
| src/metrics.rs | 55 | App CPU/mem metrics | 1 cmd, `State<Metrics>` | THIN |
| src/opencode.rs | 529 | opencode CLI integration | none | PURE |
| src/pm.rs | 435 | Project status, merge check, merge, push via git | 5 cmds | THIN |
| src/pty.rs | 1515 | PTY manager (portable-pty), reader+coalescer threads, Channel streaming, cwd/session-id lookup | `Channel<InvokeResponseBody>` in spawn path `:77-142,293-300`; 6 cmds | COUPLED |
| src/schedules.rs | 2144 | Scheduled headless Claude jobs, 15 s tick `:30`, DST-aware next-run | emit `:1117`, AppHandle in start/run `:958-1471`; 6 cmds | COUPLED |
| src/sessions.rs | 558 | Transcript content search + Markdown export | 2 cmds | THIN |
| src/slash_commands.rs | 481 | Discover slash commands per agent | 1 cmd | THIN |
| src/spotlight.rs | 205 | `mdfind` file search, 3 s budget `:17` | 1 cmd | THIN |
| src/ssh.rs | 2463 | SSH server/PSMP store, connect cmd builder, `ssh_pty_connect` | 9 cmds; `State<PtyManager,CredStore,Cyberark>` + Channel at `:911-916` | THIN (one COUPLED fn) |
| src/statusline.rs | 648 | Footer status capture via `claude --settings` + sh tap | 2 cmds | THIN |
| src/term_history.rs | 656 | Terminal scrollback persistence/export | 4 cmds | THIN |
| src/testutil.rs | 56 | Test helpers (git temp repos) | none | PURE |
| src/titlebar.rs | 101 | Title-bar double-click (`defaults`), licenses open | 2 cmds, window refs | THIN (UI-only; drops out natively) |
| src/validate.rs | 148 | Input validation helpers | none | PURE |
| src/vault.rs | 906 | Obsidian vault MCP subprocess (python), detect/search | 5 cmds, `State<VaultMcpManager>` | THIN |
| src/watcher.rs | 398 | `notify` recursive watcher, debounced; emits via closures | 2 cmds; emit only at `:291,294` | THIN (already closure-based `:140-141`) |
| src/workspace_roots.rs | 71 | Registered workspace roots (path allowlist) | 1 cmd | THIN |

Counts (42 files): PURE 9 (main, agent_ssh, app_location, askpass, bin/muya_ssh_mcp, local_guard, opencode, testutil, validate), COUPLED 8 (lib, bridge, bridge_exec, bridge_mcp, bridge_remote, broker, pty, schedules), THIN 25.

Notes for the rewrite:
- Biggest lift targets with logic already pure: `fs.rs` (git/worktree/file ops), `history.rs`, `sessions.rs`, `agents.rs`, `statusline.rs`, `term_history.rs`, `schedules` scheduling math (the module is mixed, see OPEN QUESTION), `credstore`.
- `watcher.rs` is the model for decoupling: it takes `impl Fn()` emit closures (`:140-141`).
- Two Tauri-specific leaks to remove: `fs::read_file_bytes` returns `tauri::ipc::Response` (`fs.rs:86`) and `pty_spawn` takes a `Channel` (`pty.rs:77`).
- OPEN QUESTION: `schedules.rs` is large and mixed; whether the job runner (`:458-545`) is free of AppHandle was not fully verified (only the tick/emit/start parts at `:1087-1117` were seen).

## 2. Tauri commands (151)

Legend: A = async, S = sync. All return `Result<_, String>` unless noted. Args shown without injected `AppHandle`/`State`.

### pty (6) + pty-adjacent
| Cmd | file:line | Args | Does | A/S |
|---|---|---|---|---|
| pty_spawn | pty.rs:77 | on_event Channel, cwd, shell, cols, rows, history_key, ... | Spawn PTY child, stream bytes over Channel | S |
| pty_write | pty.rs:560 | id, data | Write to PTY | S |
| pty_resize | pty.rs:571 | id, cols, rows | Resize | S |
| pty_kill | pty.rs:640 | id | Kill child | S |
| pty_cwds | pty.rs:679 | ids | Map PTY ids to cwd via `lsof` | A |
| pty_session_ids | pty.rs:774 | ids | Map tabs to claude session ids via `ps` | A |

### fs / git / marketplace (30)
list_dir fs.rs:25 S; read_file :68 S; read_file_bytes :86 S (returns `ipc::Response`); write_file :128 S; create_file :136 S; path_kind :151 S; create_dir :162 S; read_head_file :171 S (git HEAD content); create_worktree :205 S; list_branches :333 A; branch_detail :397 S; git_branch_file_pair :503 S; remove_worktree :602 S; git_status :639 A; resolve_path_kind :696 S; local_ip :739 S; allow_asset_path :765 S; file_access_status :865 S; relaunch_in_place :917 S; open_privacy_settings :959 S; reveal_in_finder :977 S; rename_entry :987 S; delete_entry :1000 S; list_claude_resources :1057 S; fetch_skill_marketplace :1269 A (reqwest); fetch_mcp_marketplace :1373 A; install_skill :1436 S; install_mcp :1467 S; install_muya_plugin :1694 A (runs `claude` CLI); scan_prd_docs :2386 S.

### agents / sessions / history (14)
agents.rs: claude_channels_supported :390 S; list_agent_sessions :406 A; kill_session :502 S; stop_agent :522 S.
history.rs: list_session_history :212; read_session_transcript :445; archive_sessions :594; restore_sessions :608; list_archived_sessions :619; trash_sessions :625 (all S).
sessions.rs: search_session_contents :281 A; export_session_markdown :351 A.
agent_files.rs: session_touched_files :154 S.
slash_commands.rs: list_slash_commands :290 S.
term_history.rs: term_history_entries :354 A; term_history_full :366 A; term_history_export :419 A; term_history_delete :443 S.
(This block: 4+6+2+1+1+4 = 18.)

### ssh + cyberark (14)
ssh.rs: ssh_pty_connect :911 A (PtyManager+CredStore+Cyberark State, Channel); ssh_build_connect_cmd :1150; ssh_get_config :1165; ssh_list_servers :1170; ssh_upsert_server :1175; ssh_remove_server :1183; ssh_upsert_psmp_profile :1259; ssh_remove_psmp_profile :1267; ssh_set_cyberark_config :1283 (S).
cyberark.rs: cyberark_logon :591 A; cyberark_test_connection :603 A; cyberark_list_accounts :615 A; cyberark_logoff :623 A; cyberark_status :628 A.
(9 + 5 = 14.)

### vault / credstore (23)
credstore.rs (18): credstore_status :332 S; credstore_init :345 A; credstore_unlock :359 A; credstore_lock :379 S; credstore_biometric_available :487 S; credstore_enable_biometric_unlock :498 S; credstore_disable_biometric_unlock :506 S; credstore_unlock_biometric :515 A; credstore_export_master :539 S; credstore_import_key :553 S; credstore_import_secret :598 S; credstore_export_cred :638 S; credstore_reveal_cred :664 S; credstore_export :690 S; credstore_rekey :710 A; credstore_cred_list :735 S; credstore_cred_upsert :845 S; credstore_cred_remove :892 S.
vault.rs (5, Obsidian vault): vault_get_status :345 S; vault_detect_candidates :356 S; vault_set_path :363 S; vault_restart :380 A; vault_search :637 A.

### schedules (6)
schedules_list :1202 A; schedule_save :1277 A; schedule_set_enabled :1310 A; schedule_delete :1343 A; schedule_run_now :1359 S; schedule_runs :1365 A (all schedules.rs).

### bridge (20)
bridge.rs (4): bridge_local_listen :386; bridge_poll_inbound :462; bridge_send :481; bridge_approve :539 (all A).
bridge_exec.rs (6): bridge_set_capability :694; bridge_set_auto_run :730; bridge_audit_log :770; bridge_execute_task :781; bridge_fan_out :807; bridge_run_claude :972 (all A).
bridge_remote.rs (10): bridge_remote_listen :726; bridge_pair_invite :1038; bridge_check_port :1096; bridge_pair_start_listener :1196; bridge_pair_stop_listener :1383; bridge_pair_connect :1517; bridge_pair_confirm_sas :1660; bridge_list_peers :1752; bridge_revoke_peer :1859 is `bridge_remote_send`, `bridge_revoke_peer` :1762 (all A).

### settings / app / system (24)
app_prefs_get :85, app_prefs_set :90 (app_prefs.rs); bg_service_status :79, bg_service_set :84, bg_service_open_settings :116 (bg_service.rs); login_item_get :132, login_item_set :137; claude_cleanup_days_get :118, claude_cleanup_days_set :123 (claude_settings.rs); debug_log_set :175, debug_log_get :190; app_metrics (metrics.rs:28); workspace_roots set_workspace_roots :33; title_bar_double_click titlebar.rs:41; open_third_party_licenses :62; lib.rs: get_startup_files :18, ssh_release_session :28, release_agent_session :36, frontend_log :84; agent_ops_list agent_ops.rs:406, agent_ops_upsert :413; statusline_settings_path statusline.rs:349, statusline_get :362 (statusline). All S.

### watcher / file history / pm / spotlight (14)
start_watching watcher.rs:276, set_watched_files :304; file_history_snapshot file_history.rs:194, file_history_list :204, file_history_read :210; pm_status pm.rs:133 A, pm_check_merge :156 S, pm_merge :194 S, pm_push :221 S, pm_collisions :253 A; spotlight_search spotlight.rs:81 A.
(2+3+5+1 = 11.)

### Per-group counts (sum to 151)
| Group | Count |
|---|---:|
| pty | 6 |
| fs/git/marketplace/plugin install | 30 |
| agents/sessions/history/term_history/slash/agent_files | 18 |
| ssh | 9 |
| cyberark | 5 |
| credstore | 18 |
| vault (Obsidian) | 5 |
| schedules | 6 |
| bridge (local 4, exec 6, remote 10) | 20 |
| settings/app/system (app_prefs 2, bg_service 3, login_item 2, claude_settings 2, debuglog 2, metrics 1, workspace_roots 1, titlebar 2, lib.rs 4, agent_ops 2, statusline 2) | 23 |
| watcher 2, file_history 3, pm 5, spotlight 1 | 11 |
| updater | 0 (handled by plugin, see s4) |
| statusline | counted in settings (2) |
| **Total** | **6+30+18+9+5+18+5+6+20+23+11 = 151** |

Check: 6+30=36; +18=54; +9=63; +5=68; +18=86; +5=91; +6=97; +20=117; +23=140; +11=151. Matches the handler count.

Note: "bridge_remote_send" is at bridge_remote.rs:1859 and "bridge_revoke_peer" at :1762 (the bridge_remote list above names 9 explicitly plus `bridge_remote_send`; total 10).

## 3. Events emitted to the UI

| Event | Payload | file:line |
|---|---|---|
| menu:new-file | () | lib.rs:405 |
| menu:close-tab | () | lib.rs:408 |
| menu:open-file | () | lib.rs:411 |
| menu:reopen-closed-tab | () | lib.rs:414 |
| menu:version-history | () | lib.rs:417 |
| menu:check-update | () | lib.rs:420 |
| menu:settings | () (also from tray_settings) | lib.rs:423, :428 |
| menu:quit-hint | () first Cmd+Q press ("press again") | lib.rs:446 |
| apex://open-file | path string (Finder open while running) | lib.rs:~650 (`RunEvent::Opened`) |
| schedules-changed | () | schedules.rs:1117 (const `:31`) |
| fs-changed | () tree changed | watcher.rs:291 |
| fs-files-changed | Vec<String> open files changed | watcher.rs:294 |
| bridge://task-end | JSON string (peer, exit_code, output_hash) | bridge_exec.rs:529 |
| bridge://fanout-result | {req_id, peer_spki, result} | bridge_exec.rs:867 |
| bridge://fanout-error | {req_id, peer_spki, error} | bridge_exec.rs:878 |
| bridge://error | string `no_client_cert:`/`handshake_rejected:`/`pairing_tls_failed:` + addr | bridge_remote.rs:807, 821, 1313 |
| bridge://sas-compare | {sas, peerSpki, peerAddr, ...} | bridge_remote.rs:1287 |
| muya://deliver-message | {sessionId, text, remote{...}} inject text into a terminal session | bridge_mcp.rs:361 |
| ssh-broker-open | {serverId, label, sessionId} (UI must open an SSH tab) | broker.rs:607 |
| ssh-broker-send | {sessionId, text} (keystrokes into a UI-owned PTY) | broker.rs:992 |

Total distinct events: 20 (menu:settings has two emit sites).

Channels (not events): `pty_spawn` / `ssh_pty_connect` stream `InvokeResponseBody::Raw(bytes)` batches (coalesced, max 128 KB, 8 ms pacing; pty.rs:280-305) and a `Json {"type":"exit"}` message at end (`pty.rs:26-28`). Native replacement: direct callback/delegate from the reader thread.

Implication: `ssh-broker-open`, `ssh-broker-send` and `muya://deliver-message` mean the MCP sidecar controls UI-owned PTYs via the UI. A native app must expose these as an in-process command bus (OPEN QUESTION: whether the UI replies with an ack that the broker awaits; `broker.rs:1159` suggests registration happens before emit and rolls back on failure, but no ack was observed).

## 4. Tauri plugins and native replacements

| Plugin | Evidence | Used for | Native replacement |
|---|---|---|---|
| tauri-plugin-opener | Cargo.toml:41, lib.rs:223 | open URLs/paths | `NSWorkspace.open` |
| tauri-plugin-dialog | Cargo.toml:45, lib.rs:224 | open/save/confirm dialogs | `NSOpenPanel` / `NSSavePanel` / `NSAlert` |
| tauri-plugin-updater | Cargo.toml:67, lib.rs:225; endpoint `https://github.com/st4unch/muya/releases/latest/download/latest.json` + minisign pubkey in tauri.conf.json `plugins.updater` | self-update | Sparkle (needs new appcast and EdDSA key; existing minisign signatures do not carry over) |
| tauri-plugin-process | Cargo.toml:68, lib.rs:226; cap `process:allow-restart` | relaunch after update | `NSApplication` terminate + relaunch helper |
| tauri-plugin-clipboard-manager | Cargo.toml:72, lib.rs:227; write/read-text | copy buttons | `NSPasteboard` |
| tauri-plugin-log | Cargo.toml:75, lib.rs:212 | log to app log dir + stdout | `os_log` / keep Rust `log` crate + file sink |
| tauri `protocol-asset` | Cargo.toml:40; `assetProtocol` in conf | serve allowlisted local files to webview (`allow_asset_path` fs.rs:765) | not needed (native image/PDF views) |
| tauri `tray-icon` | Cargo.toml:40, lib.rs:131-150 | menu-bar icon, items tray_open/settings/quit | `NSStatusItem` |
| tauri menu | lib.rs:239-310 | native menu bar | `NSMenu` |

Not used: single-instance, deep-link, global-shortcut, store, fs, shell plugins. Capabilities file: `capabilities/default.json` (core:default, window theme/drag/fullscreen, opener, dialog, updater, process restart, clipboard read/write).

Non-Tauri macOS APIs already in Rust (reusable as-is): `security-framework` (Keychain/Touch ID, `credstore.rs`), `objc2-service-management` (`SMAppService`, `bg_service.rs:14,52`), `objc2`/`objc2-foundation`, `libc` (rlimit raise `lib.rs:168`, getpeereid in broker).

## 5. Background threads, pollers, timers

| What | Interval / trigger | Where |
|---|---|---|
| PTY reader thread per session (blocking read -> bounded queue) | continuous | pty.rs:458 (`reader_handle`), :240 |
| PTY coalescer thread (batch up to 128 KB, 8 ms sleep after send) | per output | pty.rs:280-305 |
| PTY kill/reap helper thread | on kill | pty.rs:633 |
| Idle SSH session reaper | every 5 min; reaps sessions idle 30 min | lib.rs:382-396, agent_ssh.rs:44 |
| agent_ssh PTY poll loops | 60 ms | agent_ssh.rs:27,249,348 |
| Schedules tick (lock-holder fires due jobs) | 15 s | schedules.rs:30, :1087 |
| Remote bridge pollers (peers we dialed) | 2 s, backoff up to 30 s | bridge_mcp.rs:34-35, started at lib.rs:341 |
| File watcher (notify) tick thread; tree debounce 1.5 s, file settle 120 ms, tick 40 ms | event-driven | watcher.rs:27-31, :218 |
| Agents list cache TTL | 5 s | agents.rs:420 |
| Vault MCP subprocess spawn + warmup at startup | once | lib.rs:318-323; vault.rs:550 |
| Broker UDS listener (accept loop) | continuous | broker.rs:1872 (bind) via lib.rs:350 |
| Local bridge UDS listener | when enabled | bridge.rs:418 |
| Remote bridge mTLS listener + pairing listener (PIN TTL 5 min) | when enabled | bridge_remote.rs (spawn at :3085,:3264 are tests; prod accept loops not individually verified) , PIN_TTL :67 |
| Statusline sh tap per PTY | per PTY | statusline.rs:439,468,537 |
| Opencode CLI resolve retry | 60 s | opencode.rs:32 |
| Spotlight search time budget | 3 s | spotlight.rs:17 |
| Timeouts (not pollers): op 60 s, ssh run 60 s, CyberArk 20/60 s, exec 120 s, ready 90 s | | agent_ops.rs:45, broker.rs:189, cyberark.rs:26-29, agent_ssh.rs:25-26 |
| Vault idle auto-lock 15 min (from memory notes) | | OPEN QUESTION: not located in code during this pass |
| `spawn_blocking` for sync git/fs/ps work in async commands | per call | e.g. fs.rs:337, pm.rs:138, sessions.rs:290 |

Startup (setup) side effects in order: strip own quarantine (`lib.rs:334`), build menu, tray, enable local bridge listener if configured, `bridge_mcp::start_pollers`, `login_item::refresh`, start broker listener + `register_mcp` (writes `~/.claude/.mcp.json`), create/sweep ssh ControlMaster dir, `statusline::init`, idle reaper, `schedules::start` (`lib.rs:334-399`); `raise_open_file_limit` at `:157/:210`.

## 6. External processes spawned

| Program | Used by | Purpose |
|---|---|---|
| claude (via `claude_bin()` resolution) | agents.rs:141,394,453,524; fs.rs:1674 (install plugin), bridge_exec.rs:943, schedules.rs:525, statusline (via sh) | `claude agents --json`, stop agent, headless scheduled prompts, bridge ask, plugin install; also the PTY children |
| user login shell (`zsh -l`/sh) in PTY | pty.rs:151 (portable-pty); term_history.rs:639 (`/bin/zsh`); schedules.rs:458 `login_env`; agents.rs:166; fs.rs:930 `/bin/sh`; statusline.rs `sh` | interactive tabs; resolving login env/PATH |
| git | pm.rs, fs.rs (many), agents.rs:213, testutil | status, worktrees, branches, merge, push |
| ssh / scp | ssh.rs, broker.rs:1002 (via `Command::new("ssh")`) | agent SSH / PSMP, ControlMaster |
| ps / pgrep-like | pty.rs:806,960,1032 (`/bin/ps`, `ps`); bin/muya_ssh_mcp.rs:1672 | cwd/session lookup, process tree |
| lsof | pty.rs:708 | cwd of PTY child |
| kill | agents.rs:508 | kill session pid |
| mdfind | spotlight.rs:87 | file search |
| xattr | app_location.rs:338,375; fs.rs:845 | strip quarantine |
| open | fs.rs:967,979; titlebar.rs:75 | Finder reveal, privacy settings |
| defaults | titlebar.rs:31 | read AppleActionOnDoubleClick |
| plutil | login_item.rs:211 | plist check |
| python (vault MCP server) | vault.rs:550 | Obsidian vault search subprocess |
| env | bridge_exec.rs:1087 | exec with env |
| opencode | opencode.rs:135,287 | opencode CLI |
| arbitrary op program | agent_ops.rs:347; bridge_exec.rs:414 (`argv[0]`); askpass.rs:146,314 | operator-pinned ops, remote tasks, askpass script |
| sleep | fs.rs:1780 | tests |

Binary resolution caveat (CLAUDE.md rule 9): `fs.rs:1670` comment confirms the GUI minimal-PATH problem; any native rewrite must keep the capability-probing `claude_bin()` logic (agents.rs) rather than PATH lookup.

## 7. Tray, menu, window, deep links, associations, entitlements, signing

- Window (tauri.conf.json): one window "Muya" 1440x900, min 1280x800, `titleBarStyle: Overlay`, `hiddenTitle`. Close button hides instead of quitting when `keep_running_in_background` is on (`lib.rs:98-111`, `app_prefs`); Dock reopen shows main (`:622-629`); `quit_now` kills PTYs, closes own SSH masters, cleans statusline, exits (`:120-128`).
- App menu: custom `MenuBuilder` (`lib.rs:239-310`) with New File, Close Tab, Open..., Reopen Closed Tab, Version History, Check for Updates, Settings, Quit (double Cmd+Q hint), plus hand-added Edit submenu.
- Tray: id "muya", items tray_open / tray_settings / tray_quit (`lib.rs:131-150`, handlers `:403+`).
- Deep links: none. File open: `RunEvent::Opened` (`lib.rs:630-655`) with `STARTUP_FILES` stash (`:16`) read via `get_startup_files`.
- File associations: single "Text File" Editor role, ~30 extensions (txt, md, json, yaml, toml, ts, tsx, js, rs, py, sh, css, html, xml, csv, log, env, pem, key, crt, conf, sql, lock, dockerfile, gitignore, ...) in `tauri.conf.json` `bundle.fileAssociations`.
- Bundle: target `app`; `externalBin: binaries/muya-ssh-mcp`; resource `THIRD_PARTY_LICENSES.txt`; macOS files: `Library/LaunchAgents/com.staunch.muya.scheduler.plist` from `launchd/com.staunch.muya.scheduler.plist`; signingIdentity is a Developer ID Application cert (value in tauri.conf.json, not reproduced here).
- Entitlements (`Entitlements.plist`): `keychain-access-groups` (restricted; required for data-protection keychain/Touch ID); other keys not enumerated in this pass.
- Info.plist: NSDesktop/Documents/Downloads/RemovableVolumes/NetworkVolumes FolderUsageDescription keys (permanent TCC grants). OPEN QUESTION: other Info.plist keys (UTIs for associations) not listed.
- CSP: `default-src 'self'` ... irrelevant after webview removal.
- Scripts (names only): `scripts/build-sign-notarize.sh`, `scripts/publish-release.sh`, `scripts/build-pkg.sh`, `scripts/check-version.sh`, `scripts/setup-vault.sh`, `scripts/loadtest/*` (app.mjs, fake-claude.sh, sample.mjs, ui.mjs, vite.loadtest.config.mjs), `scripts/redesign/*` (capture-app.mjs, contrast.mjs). Tauri bundler signs/stamps; `build.rs` copies sidecar (`src-tauri/build.rs`, contents not read).
- Updater signing: minisign pubkey in tauri.conf.json `plugins.updater`; endpoint on GitHub releases `latest.json`.

## 8. Tests

`#[test]`/`#[tokio::test]` occurrences by grep (includes any in comments, so approximate): total about 445, `#[ignore]` 21 (some ignore lines are doc/comment mentions, e.g. opencode.rs:372).

| Module | #tests | #ignored |
|---|---:|---:|
| ssh.rs | 47 | 1 (:2355) |
| bridge_remote.rs | 38 | 0 |
| fs.rs | 35 | 1 (:1854 needs real opencode.json) |
| broker.rs | 35 | 0 |
| bridge_exec.rs | 28 | 0 |
| credstore.rs | 25 | 0 |
| pty.rs | 21 | 2 (:1187, :1381) |
| schedules.rs | 18 | 1 (:2122 real claude CLI) |
| statusline.rs | 13 | 0 |
| agent_ops.rs | 13 | 0 |
| agents.rs | 11 | 2 (live claude CLI) |
| history.rs | 11 | 3 (reads ~/.claude) |
| vault.rs | 11 | 0 |
| sessions.rs | 11 | 0 |
| local_guard.rs | 11 | 0 |
| bridge.rs | 10 | 0 |
| bridge_mcp.rs | 10 | 0 |
| opencode.rs | 10 | 4 (needs opencode/claude) |
| slash_commands.rs | 9 | 0 |
| term_history.rs | 8 | 1 (benchmark :592) |
| app_location.rs | 7 | 1 (LaunchServices :369) |
| pm.rs | 6 | 1 |
| spotlight.rs | 6 | 0 |
| agent_ssh.rs | 5 | 2 (real bash PTY) |
| askpass.rs | 5 | 1 (docker container) |
| cyberark.rs | 5 | 0 |
| validate.rs | 5 | 0 |
| agent_files.rs | 4 | 1 |
| login_item.rs | 4 | 0 |
| file_history.rs | 3 | 0 |
| claude_settings.rs | 3 | 0 |
| watcher.rs | 3 | 0 |
| bin/muya_ssh_mcp.rs | 3 | 0 |
| debuglog.rs | 2 | 0 |
| lib.rs | 2 | 0 (window_close_tests with `tauri::test` mock, fd_limit_tests) |
| app_prefs.rs, bg_service.rs, titlebar.rs, workspace_roots.rs | 1 each | 0 |
| metrics.rs, main.rs, testutil.rs | 0 | 0 |

Tauri-dependent tests: `lib.rs` `window_close_tests` uses `tauri::test::mock_builder` (dev-dep feature `test`, Cargo.toml:104); these go away. Other dev-deps: `tempfile`, `wiremock`. Tests in COUPLED modules (pty uses `Channel::new` at pty.rs:898-1433) need a channel-free seam.

## 9. Open questions

1. `schedules.rs`: how much of the runner is independent of `AppHandle` (only partial view).
2. Does the broker await a UI acknowledgement after `ssh-broker-open`/`ssh-broker-send`/`muya://deliver-message`?
3. Where the 15-minute vault idle auto-lock lives (memory note says so; not found in this pass).
4. Remaining Entitlements.plist keys and Info.plist keys not listed; `build.rs` contents not read.
5. Exact production spawn sites of remote bridge accept loops (grep hits at bridge_remote.rs:3085/3264 are in the test region).
6. `local_guard.rs` and `app_location.rs` purposes are inferred from names.

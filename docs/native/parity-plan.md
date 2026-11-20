# AC16 parity plan — the 290 open rows of parity.md

Source: `docs/native/parity.md` (333 rows, 290 `todo`/`wip`). Classified from a code search of `native/app/Sources`,
`native/crates/muyad` and `native/crates/muya-core`. "Verify only" rows were matched at file level (cites below);
the worker must confirm each one with a test or screenshot before flipping the status — a miss there moves the row to (b)-(d).

## Counts per class

| Class | Meaning | Rows |
|---|---|---|
| (a) verify only | already implemented, needs evidence | 61 |
| (b) app work | SwiftUI/AppKit only | 106 |
| (c) daemon work | muyad / muya-core only | 12 |
| (d) both | RPC + UI | 86 |
| (e) operator-blocked | needs an operator decision | 10 |
| (f) obsolete | webview-only behaviour | 15 |
| **Total** | | **290** |

## (a) Verify only (61 rows, grouped; cite = where the implementation lives)

| Rows | Cite |
|---|---|
| pty_spawn/write/resize/kill/cwds/session_ids, Shift+Enter, ⌘R/K/L/A/E/D/U, ⌥←/→ | `crates/muya-ptyd`, `Sources/App/TerminalView.swift:184` (keyDown) |
| archive_sessions, list_archived_sessions, restore_sessions, storage heads-up toast | `Sources/App/SessionsExtras.swift:227` (Trash-based archive) |
| list_dir, read_file, read_file_bytes, create_file, create_dir, path_kind, resolve_path_kind, rename_entry, delete_entry, reveal_in_finder, path-action menu, file-tree context menu, view Control (files) | `Sources/Logic/FileLogic.swift:160` (trashItem), `Sources/App/FileTree.swift:397` (reveal) |
| start_watching, set_watched_files, fs-changed, fs-files-changed | FSEvents debounce, `Sources/Logic/FileLogic.swift:2` |
| git_status, list_branches, scan_prd_docs, set_workspace_roots | muyad rpc `git.status`, `git.branches`, `plan.list`, `workspace.set_roots` (`crates/muyad/src/rpc.rs`) |
| login_item_get/set, bg_service_status/set/open_settings, Settings "Open Muya at login" | `Sources/App/Services.swift:94-107` (SMAppService), `crates/muyad` bg_service |
| Settings "Auto-save files", muya.autoSave | `Sources/Logic/PageLogic.swift:408` (setting row exists; confirm it drives the editor once (e) is decided) |
| ssh_list/upsert/remove server, upsert/remove PSMP profile, SSH server form, PSMP form, view SSH | `Sources/SSH/SSHPage.swift`, `SSHForm.swift`; rpc `ssh.servers.*`, `ssh.psmp.*` |
| cyberark_list_accounts | rpc `cyberark.accounts.search` |
| credstore_status/unlock/cred_list/cred_upsert | rpc `vault.status/unlock/list/add/update` |
| views Queue, Kanban, Branches | `Sources/Queue/QueuePage.swift:1` |
| viewers mdview, imgview, pdfview | `Sources/App/Viewers.swift:1,78` (PDFKit, NSImageView, markdown) |

## (e) Operator-blocked (10 rows)

| Rows | Decision needed |
|---|---|
| editor viewer, write_file, Editor ⌘S save | Editor component choice (STTextView or other) |
| credstore_biometric_available / enable / disable / unlock_biometric | Touch ID (S6) on a real signed app |
| pm_merge, pm_push | Enabling push/merge from the app (remote-git rule) |
| Toast: update-ready strip | Real signing + updater key |

## (f) Obsolete in the native app (15 rows)

| Rows | Why |
|---|---|
| title_bar_double_click | AppKit handles title-bar double-click natively |
| open_privacy_settings, file_access_status, relaunch_in_place, allow_asset_path, File Access Gate dialog, muya.fileAccessGate.dismissed | These exist for the webview asset protocol; native code reads files directly |
| frontend_log | No webview to log from; unified logging replaces it |
| ssh_release_session, release_agent_session, events ssh-broker-open/send | Broker lives inside muyad now; no UI round-trip |
| Ctrl+U keystroke buffer | xterm.js input buffer; the native terminal sends keys straight to the PTY |
| apex.mergeQueue, muya.lastActive (v1) | Queue state is daemon-side (`queue.run`); v1 key superseded by v2 |

## Work packages

All paths relative to repo root. "Parallel-safe" = touches files no listed package touches.

| Id | Title | Rows | Paths | Parallel-safe with | Depends on |
|---|---|---|---|---|---|
| P0 | Verify sweep (all (a) rows) | 61 | `docs/native/parity.md` evidence column, tests/scripts only | everything except edits to parity.md | — |
| P1 | Design tokens + 9 terminal schemes | 22 | `native/app/Sources/App/Theme.swift` | all | — |
| P2 | Daemon: agent control, metrics, ops | 12 + events open/close-agent-session, deliver-message, vault-locked (≈15) | `crates/muyad/src/rpc*.rs`, `crates/muya-core/src/{agents,agent_ops,metrics,agent_files}.rs` | P1, P5-P11 | — |
| P3 | App shell: menus, shortcuts, panel toggles | ≈25 (8 menu events, apex://open-file, ⌘1-9, ⌥⌘1-9, ⌘B, ⌥⌘B, ⌘T, ⌘⇧D, ⌘⏎, Esc rules, ⌘F, font size, ⌘⇧C, get_startup_files) | `Sources/App/main.swift`, `TerminalView.swift`, `Model.swift` | P1, P2, P6+ | — |
| P4 | State restore (UserDefaults/prefs) | 30 localStorage rows + settings footer | `Sources/App/Model.swift`, `SettingsPalette.swift` | P1, P2 (NOT P3: both edit Model.swift) | P3 |
| P5 | Dialogs, menus, toasts (app-only) | ≈20 (New Agent, Create with Claude, Broadcast, Rename, Confirm, status picker, terminal appearance, notifications popover, terminal/agent/session/grid menus, notification toast, drop overlay, modal/menu/resize/rename key handling) | `Sources/App/UI.swift`, `Kit.swift`, `SessionsPage.swift`, `Renderer.swift` | P1, P2, P6+ | P3 |
| P6 | Git/worktree/file history + Review changes | ≈12 (file_history ×3, git_branch_file_pair, create/remove_worktree, branch_detail, Review dialog, [ ] keys) | `crates/muyad/src/rpc_git.rs`, `crates/muya-core/src/file_history.rs`, `Sources/Inspector/*` | P1, P5, P7-P10 | P2 |
| P7 | Term history + slash commands + statusline + Resources/marketplace | ≈25 (term_history ×4, slash, statusline ×2, list_claude_resources, marketplace/install ×5, Resources view, slash popover) | `crates/muyad/src/rpc.rs` (new `resources.*`, `term_history.*`), new `Sources/Resources/*` | P1, P5, P6, P8-P10 | P2 |
| P8 | Credstore complete (no Touch ID) | ≈15 (10 cmds, credential form/import, master-password dialog) | `crates/muya-core/src/credstore.rs`, `Sources/SSH/*` | P1, P5-P7, P9, P10 | P0 |
| P9 | SSH connect + CyberArk logon | ≈14 (ssh_get_config, set_cyberark_config, build_connect_cmd, ssh_pty_connect, cyberark ×4, CyberArk dialog) | `crates/muya-core/src/{ssh,cyberark}.rs`, `Sources/SSH/*` | P1, P5-P7, P10 | P8 |
| P10 | Bridge A: local bridge + remote pairing | ≈20 (bridge_local_listen/poll/send/approve, 10 remote/pairing cmds, 6 events) | `crates/muya-core/src/bridge*.rs`, muyad bridge host, new `Sources/Bridge/*` | P1, P5-P7 | P2 |
| P11 | Bridge B: capabilities, exec, fan-out, run_claude | ≈15 (6 cmds, 5 events task-*/fanout-*/held) | `crates/muya-core/src/bridge_exec.rs`, `Sources/Bridge/*` | P1, P5-P8 | P10 |
| P12 | Obsidian vault + auto-allow toast | ≈8 (vault_* ×5, Vault config panel, auto-allow toast) | `crates/muya-core/src/vault.rs`, `prompt_watch.rs`, `Sources/App/SessionsExtras.swift` | P1, P6, P10 | P2 |

Start order: **P0, P1, P2, P3** first (P0/P1/P2 touch disjoint files; P3 touches the app shell). Then P4/P5 after P3, and
P6, P7, P8, P10, P12 after P2. P9 after P8, P11 after P10.

Counts are approximate (±3 per package); a worker finishing a package reports the exact row ids it flipped.

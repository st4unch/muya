# Muya frontend feature-parity inventory (for the native macOS rewrite)

Scope: `src` (React 19 + TS, Tauri v2). Version in package.json: 4.1.20. About 33k lines of TS/TSX. Evidence is `file:line` relative to `src/`. Items marked OPEN QUESTION were not verified. Where I only extracted UI strings with grep (not read in full), I say so.

Counts: 8 views plus the Grid screen, 1 file-viewer family (4 tab kinds), about 22 dialogs and popovers, 10 Settings rows, about 45 distinct shortcuts, 121 distinct `invoke` commands (about 175 call sites), 18 `listen` events, 40 localStorage keys (and 1 sessionStorage key).

---

## 1. Screens and pages

Navigation model: `type View = "control"|"sessions"|"queue"|"tools"|"prd"|"ssh"|"schedules"|"branches"` (App.tsx:148) and `type Screen = "control"|"grid"` (App.tsx:149). Secondary pages are mounted lazily (`mountedViews`, App.tsx:420) and then stay mounted but hidden (they load once). A single hourly coordinator refreshes them one at a time (App.tsx ~560, comment "Sequential 60-min auto-refresh coordinator"). Each page registers a refresh function with it.

Left rail (`redesign/Rail.tsx`, 64px, `RailItem` in redesign/types.ts): Control, Files, Sessions, Queue, Kanban, Resources, SSH, Schedules, plus Settings (icon only, pinned bottom). Branches has no rail item and is reachable only from the palette (BranchesPage.tsx:1-2).

| Screen | Files | What it shows / does |
|---|---|---|
| Control (agents mode) | redesign/ControlScreen.tsx, AgentList, SessionHeader, SplitArea, ProgressStrip, Composer, Inspector | 3-pane layout: agent list (left, resizable), selected agent's terminal (center, or 2-8 split panes), Inspector (right, resizable). Session header, progress strip, composer under the terminal. Empty state "No agents yet" with New terminal / New agent buttons (ControlScreen:239-250). |
| Control (files mode) | ControlScreen (`mode="files"`), OpenFilesList, FilesSection, FileTree | Rail "Files": the main area holds the open file (editor / markdown / image / PDF) instead of a terminal. Empty state "No file open". |
| Grid | redesign/GridScreen.tsx, GridHeader, GridPanel | Layouts 1, 1x2, 2x2, 3x2 (`LAYOUT_CAPACITY` in GridScreen). Each panel shows a live terminal with header (name, status, session menu), full-screen button, and a fixed 58px bottom bar (approval Allow/Deny row when waiting, else composer). Empty panels show "Empty panel / Waiting for a task". Header has a Broadcast button ("Broadcast to all panels"), layout segmented control, and Back to Control (Esc). Footer shows a keyboard hint instead of the encoding. |
| Sessions | components/SessionsPage.tsx, TerminalHistoryView.tsx, SessionCleanupDialog.tsx | Two tabs. 1) Claude/opencode sessions: live (`claude agents --json --all`) plus transcript history. Search with filter syntax `session= include= path= branch= id=` (SessionsPage:286, lib/sessionQuery.ts), and transcript-content search (`search_session_contents`). Row actions: resume in new terminal, copy resume id, view conversation (transcript drawer), export as Markdown, stop background session (`stop_agent`), Archive / Move to Trash (disabled for live ones), cleanup dialog. 2) Terminal History: plain terminals' command histories grouped by day, reopen with history, download as text, delete. |
| Queue (Push/Merge Queue) | components/QueuePage.tsx | Per tracked project PM status (`pm_status`), FIFO queue (localStorage `apex.mergeQueue`), trial-merge check (`pm_check_merge`), operator-confirmed Push / Merge (`pm_push` / `pm_merge`), auto-remove worktree after merge, remove worktree button, "Review uncommitted changes" and "Review the branch's changes" (opens ReviewChanges), branch detail card (commits + diff vs base, `branch_detail`). |
| Kanban (PRD board) | components/PrdBoard.tsx | Columns Draft / In Progress / Review / Done, built from `docs/prd-*.md` scanned by `scan_prd_docs` (roots in lib/kanbanRoots.ts). Search "Search PRDs…", project filter pills. |
| Branches | components/BranchesPage.tsx, BranchDAG.tsx | Branch topology graph. Labels: AHEAD / CONFLICT / DIVERGED / SYNCED, "Deployable", "Open Stale", "PRD Release", "Workspace WIP"; search commits/branches/authors; "Click to checkout PTY". Click opens branch detail on Queue. |
| Resources | components/ResourcesPage.tsx | Local tabs Agents / Skills / Hooks / MCPs (`list_claude_resources`), file viewer for a resource, marketplace tab (`fetch_skill_marketplace`, `fetch_mcp_marketplace`, debounced search), one-click installs (`install_skill`, `install_mcp` with Command/URL/Args, `install_muya_plugin` for muya-mcp), "Create with Claude" modal. |
| SSH | components/SshPage.tsx (1521 lines) | Tabs `servers` / `cyberark` / `store` (SshPage:98). Servers: grouped cards (group collapse persisted), search, add/edit/delete, Connect (opens ssh terminal tab), PSMP jump-server profiles. CyberArk PAM connection (PVWA URL, auth method CyberArk/LDAP/RADIUS/Windows, test connection and browse accounts, logoff). Password Store (encrypted vault): master password create/unlock/lock, Touch ID unlock enable/disable, credential list with reveal, copy value, add/edit/delete, import (password/token/API key/SSH key from file), export (whole store / master / one credential), group collapse. |
| Schedules | components/SchedulesPage.tsx, ScheduledPromptModal (different feature), lib/schedules.ts | Headless Claude prompts on a timer in a folder. Stat cards (Schedules, Running now, Runs, Success rate, Last run, Last failure, Next run). Per-card: on/off switch, Run now, History, Edit, Delete. Create/edit dialog fields: Name, Folder, Prompt, Schedule kind (Every few minutes / Daily / Weekly with day chips and multiple times per day), Timeout, Options (Skip permission prompts, Browser via Claude in Chrome). "Run when Muya is closed" background-service switch (`bg_service_*`). History dialog keeps the last 100 runs (summary + output). Listens to `schedules-changed`. |
| Settings | components/SettingsModal.tsx | Modal, see section 6. |

---

## 2. Terminal features (components/Terminal.tsx, 887 lines)

xterm options (Terminal.tsx ~line 215): `fontFamily '"JetBrains Mono", ui-monospace, monospace'`; `fontSize/lineHeight/letterSpacing` from prefs; `cursorBlink: true`; `scrollback: 5000`; theme from `schemeTheme(scheme, appTheme)`. Addons: Fit, Search, WebGL (via lib/webglRenderer.ts). Output arrives on a Tauri `Channel` as raw ArrayBuffer (binary), or `{type:"exit"}` (Terminal:586).

- Appearance prefs (lib/terminalPrefs.ts): font 9-28 (default 13), line height 1.0-2.0 step 0.1 (default 1.6), letter spacing 0-4 px (default 0), scheme. Shared by all terminals through a store, persisted in `muya.terminalPrefs`. Changes apply live with no PTY respawn. Edited from the footer popover "Terminal appearance" (Font size / Line spacing / Letter spacing / Colors).
- Color schemes (theme/terminalThemes.ts): Muya (follows app theme), Dracula, Nord, One Dark, Tokyo Night, Gruvbox Dark, Solarized Dark, Solarized Light, GitHub Light.
- WebGL: one lease per visible terminal (`acquireWebgl/parkWebgl/unparkWebgl`). WebKit caps contexts at 16, so hidden tabs release the GPU renderer. After at most 3 consecutive GPU losses it falls back to the DOM renderer (Terminal:140-160).
- Hidden-tab output hold: output of a hidden terminal is buffered and flushed every 150 ms (`HIDDEN_FLUSH_MS`), immediately above 256 KiB (Terminal:46-49, flushHeld).
- Resize: ResizeObserver plus `syncSize`. Skips when the element is 0x0. A terminal parked in `[data-terminal-pool]` keeps its on-screen size. `pty_resize` is sent only when cols x rows changed. A refit runs once `document.fonts.ready` resolves.
- Mouse tracking: scans PTY bytes for `ESC[?1000/1002/1003 h|l` (`mouseTrackingChange`, Terminal:52-65). Wheel scrolls the viewport only when tracking is off, at `max(1, round(|dy|/40))` lines per event.
- Search (Cmd+F): overlay, "Search…", incremental `findNext`, Enter = next, Shift+Enter = previous, Esc closes and refocuses the terminal.
- Right-click menu (components/TerminalContextMenu.tsx): Copy (disabled without selection), Paste, Paste as Path (shell-escaped via lib/termMenu.escapeForShell, trailing newline removed), Select All, Open Link (only for a selected http(s) URL, uses plugin-opener), Find…, Clear Scrollback, Bigger/Smaller/Default Text Size. Paste reads the clipboard through the Tauri clipboard plugin and calls `term.paste`.
- Path links: regex over each buffer line. A candidate becomes a link only after `resolve_path_kind` confirms it exists (cache 2000 entries). Click or right-click opens an action menu (`onPathMenu`, App state `pathMenu`). Menu items live in App.tsx (OPEN QUESTION: exact items, not read).
- Keyboard interception (`attachCustomKeyEventHandler`, Terminal:~411-520): see section 7. When any app modal is open (`appModalOpen()`), keys are not sent to the PTY (L19).
- Keystroke buffer: printable chars are accumulated, Backspace trims, Ctrl+U clears. On Enter, `onPromptSubmit(prompt)` is called fire-and-forget. Enter still passes through to the PTY.
- Screen parsing (lib/screenState.ts, `parseClaudeScreen`), verified against Claude Code v2.1.285. Output `ScreenState` = `{activity?, mode, modeDetected, permission?, busy?}`. Throttled to 300 ms trailing (1000 ms if the tab is hidden) and reported only when the JSON signature changes (spinner glyph excluded).
  - Mode (from footer in the last 5 non-empty lines): `bypass permissions` / `accept edits` / `plan mode` / `auto mode` / `manual mode on`, mapped to bypass / acceptEdits / plan / auto / default.
  - Activity: spinner glyph in `·✢✳✶✻✽*` plus a capitalized verb ending in `…` and optional `(elapsed · ↑ tokens · thought for Ns · thinking)`. Accepted only with a busy footer or at least one metric.
  - Busy: the footer line carrying a mode marker contains "esc to interrupt" (`parseBusy`).
  - Permission dialog: `Do you want to ...?` followed by numbered options `1..N`, with "Esc to cancel". Option 1 must be an approve ("Yes"), the last must be a deny ("No"). Classified approve / approveAlways ("Yes, and ..." or "don't ask again" or "for this session") / deny. Tool is derived from the dialog title (Bash command -> Bash, Create file -> Write, Edit/Update file -> Edit, Read file -> Read). Target is the first body line under the top separator. Unparseable dialog gives `actionable:false`, which disables Allow/Deny.
- Agent model (redesign/agentModel.ts, useAgentModel.ts): status waiting / working / idle with since-duration. `muya.waitingSince` is kept in sessionStorage. Notifications are derived through lib/agentNotifications.ts.
- Auto-approve (lib/autoApprove.ts): setting `muya.autoApprove`. A prompt that is actionable and unanswered for 2000 ms (`AUTO_APPROVE_MS`) is approved. Applies to all sessions. Grid and Inspector Allow buttons show a 2 s fill animation (`rd-auto-allow`). A suggestion toast (AutoAllowSuggest) appears after the operator approves manually (OPEN QUESTION: trigger count, App.tsx ~1790); it closes with Esc at capture phase, with a 30 s timeout.
- Approval responses: `respond(key, "approve"|"deny"|"always")` writes the option digit to the PTY (App.tsx; OPEN QUESTION: exact write path not read). Y/N keys answer a waiting grid panel.
- Channel warning auto-accept (Terminal:~290-330, lib/channelPrompt.ts): when output matches /development channels/, it looks up to 5 times for the screen "Loading development channels" with "Channels: server:muya-mcp" ONLY and "❯ 1. I am using this for local development" selected, then writes `\r`. At most once per 5 s. Anything listing another channel is left to the operator.
- Trust-folder auto-accept: `autoAcceptTrust` prop sends a bare `\r` a few seconds after the initial command.
- Launch-flag transform (lib/statusline.ts): `applyLaunchFlags` injects `--settings <tap file>` after every `claude` launch (not subcommands), and `--dangerously-load-development-channels server:muya-mcp` only when the New Agent "channels" option is on and `claude_channels_supported`.
- Statusline footer: `statusline_get` polled every 2 s (STATUS_POLL_MS) for the selected PTY, only while fields are chosen or the picker is open. Field catalogue in lib/statusline.ts: about 65 fields in 10 groups (Model, Context, Cost & time, Rate limits, Session, Workspace & git, Pull request, Worktree, Prompt cache, Modes). Footer shows chosen fields (right-click a field to remove), picker has filter, wraps to a second line when too wide. Persisted in `muya.footer.statusFields`.
- Paste handling: no custom handler beyond the context-menu paste and xterm's built-in paste. OPEN QUESTION: bracketed paste is xterm default, not verified.
- Drag-to-split: NOT present as drag. Splits happen through the Split button and Cmd+Shift+D (App.tsx:2258). `components/TerminalGrid.tsx` has HTML5 draggable title bars but nothing imports it (apparently dead legacy; grep found no importer outside its own file). The one real drag feature is the OS file drop into the window (section 4).
- Split panes (lib/controlSplit.ts): Split clones the visible terminal (`splitClone` in lib/tabs.ts) into a group of 2-8 panes (`MAX_SPLIT = 8`). Layouts 2->2x1, 3->3x1, 4->2x2, 5-6->3x2, 7-8->4x2. Groups persist (`muya.splitGroups`, `muya.splitGroupsCollapsed`) and appear in the agent list as a collapsible "SPLITS" row. Each pane can be closed (agent keeps running). `open_session(split:true)` from the MCP joins the caller's group. Split to grid sends a group to the Grid screen.
- Grid focus rules (redesign/gridKeys.ts, App.tsx:2255-2320): Tab cycles panels; Cmd+Enter maximizes the focused panel; Esc exits the grid unless the event is inside a terminal/input/dialog or an overlay is open; Y/N answer a focused waiting panel instead of typing into the PTY; `focusToken` makes the picked terminal take keyboard focus (in grid all terminals stay `active`). Choosing a session already in another cell swaps the two (`pickForCell`).
- Plain-terminal command history: `historyKey/historyName` passed to `pty_spawn`, stored backend-side (term_history.rs).
- SSH tabs: `ssh_pty_connect` spawns `ssh` directly, password injected in Rust and never in JS. `ssh_release_session` on close.
- Other PTY invokes: `pty_spawn`, `pty_write`, `pty_resize`, `pty_kill`, `pty_cwds`, `pty_session_ids`.
- Resume: restored tabs rejoin conversations through `canResumeTab`/`resumeCommand` (lib/tabs.ts); `buildResumeCommand` = `claude --resume <id>` or `opencode --session <id>`.
- Agent kinds: `claude`, `opencode` (AGENT_BASE_COMMAND: `claude --permission-mode auto`, `opencode --auto`), plus plain `Terminal` and `ssh`.
- Unattended sessions (lib/agent.ts `unattendedFlags`): sessions opened by another agent get `--disallowedTools AskUserQuestion,EnterPlanMode,ExitPlanMode` and an appended system prompt naming the opener.

## 3. Editor and viewers

- Dispatcher (`viewerKindFor`, lib/format.ts:38): `.md/.mdx` -> mdview; png/jpg/jpeg/gif/webp/bmp/ico/svg -> imgview; pdf -> pdfview; everything else -> editor. No hex viewer exists. A non-UTF-8 file shows an error state (FileEditor ~line 276, PRD file-viewer-dispatcher AC5). Tab kinds: `"terminal"|"editor"|"mdview"|"imgview"|"pdfview"` (App.tsx:99).
- Monaco (components/FileEditor.tsx, monacoSetup.ts): `@monaco-editor/react` with locally bundled monaco 0.55 and workers for json/css/html/ts (no CDN). Themes `vs-dark` / `light` follow the app theme. Language map (lib/format.ts:20): ts, tsx, js, jsx, json, rs, md, py, css, scss, html, sh, bash, toml (as ini), yaml, yml, go, sql. Others are plaintext. Options: fontSize 12, minimap toggle (default off), word-wrap toggle (default off), Turkish-friendly (confusable-character warning off). Model path is percent-encoded (`monacoModelPath`) to avoid URI-scheme crashes (macOS ':' in names).
- Save: Cmd/Ctrl+S (Monaco command) writes via `write_file`, runs format-document first if available. Dirty marker "● unsaved". Save button disabled when not dirty.
- Auto-save (Settings): writes 1 s after typing stops, without formatting. With it off, a pause still stores the unsaved text as a local version.
- Dirty guard: if the file changes on disk while the editor is dirty, no overwrite. A badge offers a manual Reload ("Reload discards your edits"). Own writes are recognized so they raise no warning. Only the visible editor reloads on disk change; fast path via `fs-files-changed` (about 150 ms).
- Diff view: "Show diff against HEAD" toggle uses Monaco DiffEditor against `read_head_file`. A "Review diff" entry opens straight into it.
- Local file versions (lib/fileVersions.ts, `file_history_*`): versions stored in `~/.claude/muya-file-history`; Inspector Activity tab lists versions, a dialog compares each against the file now and can restore; menu event `menu:version-history`.
- Review changes dialog (components/ReviewChanges.tsx + ReviewDiffPane): read-only side-by-side diff of every changed file of a working tree or branch (or file versions), Prev/Next with `[` and `]`, "Open in editor", file list `aria-label="Changed files"`. Lazy-loaded so Monaco stays out of the main bundle.
- Markdown view (MarkdownView.tsx): `marked` + DOMPurify sanitize (hook on attributes), links open in the system handler (http/mailto), `#anchor` scrolls, others ignored. Single-click on `.md` opens this read-only view; right-click "Open in Muya" opens editable Monaco. (A second, regex-based `MarkdownViewer.tsx` exists with its own HTML-escape; OPEN QUESTION whether it is still used: PrdBoard/ResourcesPage probably.)
- Image viewer: `read_file_bytes` -> blob URL, fit by default, "100%" for real pixels with scroll, checkerboard background, images not draggable.
- PDF viewer: pdf.js (lazy-loaded), canvases per page, fit-to-width, -/+ zoom, "3 / 12" page counter, pages draw when scrolled near. Worker must be bundled.
- Error boundary: ViewerErrorBoundary wraps viewers.
- Open Files list in the Files rail (OpenFilesList): kind labels Code / Markdown / Image / PDF, unsaved dot, close. Persisted `muya.openFiles`.
- ⌘⇧T reopen closed tab: `closedTabsRef` (App.tsx:816) holds closed tabs, restored through `reopenSpec`. Closing a file picks a neighbouring file, never a terminal (`pickNextActiveKey`, lib/tabs.ts, L19).

## 4. File tree and workspaces (components/FileTree.tsx, 704 lines)

- Workspaces: multiple roots (`apex.workspaces`), one "selected root" (`apex.selectedRoot`) where new terminals/agents open. Header workspace menu: All workspaces (⌥⌘0), per-workspace rows (⌥⌘1-9), "Add workspace…", "Remove selected workspace". `set_workspace_roots` informs the backend. Workspace selection filters the agent list (`lib/workspaceScope.ts`). Worktrees tracked separately (`apex.worktrees`).
- Watching: `start_watching` + `set_watched_files`; events `fs-changed` (debounced 1.5 s, safety net) and `fs-files-changed` (fast lane for open files).
- Tree: lazy directory listing (`list_dir`), silent refresh of already-loaded folders (no placeholder row), refresh frozen while the context menu is open, local forced refresh after create/rename/delete. Filter-files search (flat file list; the host may own the toggle through fileTreeSearch.ts). Git status letters per file via `git_status`, polled every 30 s and skipped when the window is hidden.
- File context menu: Open in Muya (editable), Open in Terminal Here, Open Claude Here, New File, New Folder (inline name input), Add as @ Reference, Copy Path, Copy Relative Path, Reveal in Finder, Rename (inline, Enter/Esc), Delete (with confirmation). Folder menu: New File, New Folder, Open in Terminal Here, Open Claude Here, Copy Path, Reveal in Finder, Rename, Delete Folder. Root menu: Select workspace, New File, New Folder, Open in Terminal Here, Open Claude Here, Reveal in Finder, Copy Path, Remove from Workspace.
- Backend calls: `create_file`, `create_dir`, `rename_entry`, `delete_entry`, `reveal_in_finder`, `path_kind`.
- Drag-and-drop from Finder (App.tsx:1089-1118): Tauri `onDragDropEvent`. Full-window drop hint only for drags with file paths. A dropped folder becomes a workspace; a dropped file opens in the editor.
- OS file open: native menu File > Open (⌘O, `menu:open-file`), New File (⌘N, `menu:new-file`, path chosen through a dialog), `apex://open-file` event (open-with / file associations), `get_startup_files` for files passed at launch.
- File Access Gate (FileAccessGate.tsx): "Let Muya read your project folders" prompt that guides the user to macOS Full Disk Access (`file_access_status`, `open_privacy_settings`, mentions Muya.app); dismissal stored in `muya.fileAccessGate.dismissed`.

## 5. Agent list, inspector, activity, palette, footer, rail

- Agent list (redesign/AgentList.tsx): filter tabs (role=tablist, "Filter": incl. a "Recent" filter, active in the last 6 h or working/waiting), groups PINNED / WAITING FOR YOU / WORKING / IDLE (collapsible), SPLITS rows, workspace switcher ("Switch workspace"), per-row close button, inline rename (double-click, Enter/Esc), pinned set (`muya.pinnedAgents`), kind icon (claude/opencode/shell/ssh), branch, path, activity line ("Unfurling… · 16.9k token"), waiting duration. ⌘1-9 jumps to the Nth on-screen agent.
- Session header (SessionHeader.tsx): name (double-click to rename), permission-mode chip (click opens mode menu, Shift+Tab in the composer cycles), bypass warning pill (collapses to an icon when narrow), buttons Compact, Split, Split to grid, Stop (esc), More actions menu. Collapsible (`muya.sessionHeaderCollapsed`).
- Agent actions menu (App.tsx:2814): Pin/Unpin, Rename…, Duplicate, Reveal in Finder, Schedule prompt… (with "N pending"), Close agent. Mode menu: Manual, Accept edits, Plan, Auto (bypass is shown fixed, outside the cycle); `setModeTo` cycles with Shift+Tab sequences.
- Composer (redesign/Composer.tsx): textarea; Enter sends, Shift+Enter newline, ↑/↓ recall previous sends (per kind, `apex.composerHistory.<kind>`), Shift+Tab cycles mode, "/ Commands" popover, `@ files` hint. Shell tabs say "Run a shell command in <name>…" and hide agent-only controls. Show/hide via the footer chat toggle (`muya.composerOpen`).
- Slash popover (SlashCommandsPopover): built-ins captured from real CLIs (116 entries: 'CLAUDE_BUILTINS' and opencode's 17 in slashBuiltins.ts), plus PROJECT / USER / SKILLS from `list_slash_commands`; filter box, arrows, Enter, Esc.
- Progress strip (ProgressStrip): current verb, elapsed / tokens / thinking; also the "Update ready" prompt.
- Inspector (Inspector.tsx, ActivityPanel.tsx, 320px, 280 at <=1360; hidden under 1280px): approval cards per waiting agent (NEEDS APPROVAL: tool, target, Allow / Allow always / Deny with always-label tooltip), tabs Changes / Files / Activity, worktree conflict card ("File conflicts" / "No file conflicts"). Changes: git porcelain list for the active path (row click opens Review). Activity: AGENT FILES (READ / MODIFIED from the session transcript, `session_touched_files`, click opens file), file versions list ("Compare with the file now, or restore it"), LOCK / EDIT TELEMETRY (`pm_collisions`).
- Command palette (CommandPalette.tsx, cmdk): ⌘K. Groups: agents, files (workspace files), commands, and "On this Mac" (Spotlight, `spotlight_search`). Commands (App.tsx:234-248): New agent, New terminal, Control, Grid, Sessions, Branches, Queue, Kanban, Resources, SSH, Schedules, Settings, "Cycle theme (system, light, dark)", Schedule prompt, Add workspace. Placeholder "Search agents, files, commands — or files on this Mac…".
- Header (ControlHeader.tsx): Muya title, Workspace picker, agents-panel and inspector toggles, theme cycle button, Notifications bell (with unread dot), live CPU / RAM / clock readout (`app_metrics`, useLiveMetrics). Window uses `titleBarStyle: "Overlay"`, minWidth 1280, width 1440 (tauri.conf.json); double-click on title bar calls `title_bar_double_click`.
- Footer (Footer.tsx): workspace count, agents / working / waiting counts, collisions, status fields + add button, Terminal appearance popover, chat toggle, "UTF-8" (control) or grid key hint, version. Version comes from the real tauri.conf.json.
- Notifications (NotificationsPanel, lib/agentNotifications.ts): log (max 100, persisted `muya.notifications`, `muya.notificationsUnread`) of "waiting for you" / "finished" events, only for agents the operator isn't looking at, and only after the agent was WORKING. Popover with Dismiss / Clear all and click to open. A toast (6 s) shows the newest.
- Other toasts: StorageHeadsUp ("Big histories slow Muya and Claude down.", once per day, key `apex.sessionsHeadsUp`, opens the cleanup dialog), AutoAllowSuggest, update-ready.
- Updater: `check()` on startup and via `menu:check-update`, `downloadAndInstall` with progress, then `relaunch` (plugin-updater, plugin-process); `relaunch_in_place` backend command also exists.

## 6. Modals, dialogs, popovers and Settings rows

Shared kit: `components/modalKit.tsx` (ModalShell, Segmented, Switch, label/helper/input/button styles). Menus: `redesign/Menus.tsx` (MenuPopover, MenuItem, MenuSeparator, MenuHeading, DialogShell, rename dialog, generic confirm dialog). `lib/modalOpen.ts appModalOpen()` detects any open dialog (role=dialog or fixed inset-0 z-50) so Esc and terminal keys defer to it.

Dialogs and popovers (about 22):
1. Settings (SettingsModal)
2. New Agent (NewAgentModal): type tabs Claude Code / opencode / Terminal (arrows switch), Name (optional), workspace (known workspaces list + "Select workspace folder" dialog), Branch (optional, creates an isolated git worktree via `create_worktree`), Permission mode (Manual / Accept edits / Plan / Auto / Bypass permissions; bypass text "Approves every permission that is not explicitly denied"), Initial prompt, Files (optional, "Select file(s)", become `@path` refs), Claude channels checkbox (only if CLI supports), editable "Command that will run", Cancel / Create; Cmd+Enter submits, Esc closes (outside click does not).
3. Create with Claude (CreateWithClaudeModal): Agent / Skill / Hook / MCP, prompt to Claude to author the resource.
4. Scheduled Prompt (ScheduledPromptModal, Turkish strings "Zaman", "Claude'a gönderilecek komutu yaz…"): one-shot timed prompt into the current session; list with Düzenle / Sil. Held in memory (`scheduledPrompts` state, App.tsx:1310), not persisted (OPEN QUESTION).
5. Schedule create/edit (SchedulesPage)
6. Schedule history (SchedulesPage)
7. Clean up Claude sessions (SessionCleanupDialog): Archive / Move to Trash / Restore, per-path results.
8. File Access Gate
9. Vault config panel (VaultConfigPanel): Obsidian vault source: Auto-detected / Current / Custom path, Browse… (`vault_*` commands).
10. Review changes
11. Broadcast to all panels (BroadcastModal): send one message to every grid panel.
12. Rename agent (DialogShell)
13. Confirm dialog (DialogShell, Menus:173): used for deletes and similar.
14. Command palette
15. SSH server form (Label, Host, Port, Username, Connection type Direct/PSMP, Auth method, Credential source, PSMP profile, Group, Extra SSH options, tags, MCP-exposure opt-in)
16. PSMP profile form (address, user/param delimiters, extra `-o` options)
17. Credential form / import (Password, SSH key, Token, API key; label, note, description)
18. CyberArk connection + account browser (PVWA API URL, Vault username, internal CA cert path, session password, search accounts)
19. Master-password create / unlock (Touch ID capable)
20. Slash-commands popover; Status field picker; Terminal appearance popover; Notifications popover; Path action menu; Terminal context menu; File tree context menus; Agent/workspace/mode menus; Session "…" menu (Archive / Move to Trash); Grid panel session menu
21. Toasts: notification toast, auto-allow suggest, storage heads-up, update-ready strip
22. Drop overlay (drag hint)

Settings rows (SettingsModal.tsx; 10 rows; labels and controls; Save/Close buttons at the bottom, Cmd+Enter saves):

| # | Section | Title | Control | Storage |
|---|---|---|---|---|
| 1 | Appearance | Appearance (helper "System follows your macOS appearance.") | Segmented: System / Light / Dark | localStorage `apex.theme` |
| 2 | Startup | Open Muya at login | Switch | `login_item_set` / `login_item_get` |
| 3 | Startup | Keep running when the window is closed | Switch | `app_prefs_set {keepRunningInBackground}` |
| 4 | Startup | Resume Claude sessions on launch | Switch | `muya.resumeOnLaunch` |
| 5 | Startup | Auto-allow permission prompts | Switch | `muya.autoApprove` |
| 6 | Claude | Claude status in Muya's footer | Switch | `app_prefs_set {claudeStatusInFooter}` |
| 7 | Claude | Delete old Claude sessions after | Number input (days) | `claude_cleanup_days_set/get` |
| 8 | Editor | Auto-save files | Switch | `muya.autoSave` |
| 9 | Debug logging | Enable switch + Log file path input | Switch + text input | `debug_log_set/get` |
| 10 | Footer | "Muya is built on open-source software." | Link button | `open_third_party_licenses` |

Terminal appearance (Font size, Line spacing, Letter spacing steppers, Colors list) lives in the footer popover, not in Settings (redesign/TerminalAppearance.tsx).

## 7. Keyboard shortcuts (about 45 distinct)

Window-level (capture phase, App.tsx:2255-2320 unless noted):
- ⌘K command palette
- ⌘1-9 Nth agent as listed (also AgentList.tsx:107)
- ⌥⌘1-9 Nth workspace, ⌥⌘0 all workspaces (lib/workspaceScope.ts, uses `code`)
- ⌘B toggle agents panel, ⌥⌘B toggle inspector (redesign/usePanelLayout.ts:26)
- ⌘T new blank terminal in the selected path (App.tsx:1065)
- ⌘⇧D split the Control terminal area
- ⌘Enter maximize focused grid panel (App.tsx:2291, GridScreen:76)
- Esc leaves Grid (conditions above); Tab cycles grid panels; Y / N answer a waiting grid panel
- Esc double-press guard in fullscreen (first Esc re-enters fullscreen to cancel macOS exit, second within 700 ms exits) (App.tsx:455-480)
- Esc closes the auto-allow suggestion toast

Native menu items (Rust emits events): ⌘N New File, ⌘O Open File, ⌘W close tab (`menu:close-tab`), ⌘⇧T reopen closed tab, ⌘, Settings, Version History, Check for updates, quit hint (`menu:quit-hint`; OPEN QUESTION: exact accelerators for the ones not documented in comments).

Terminal (xterm key handler, Terminal.tsx:411-520):
- Shift+Enter writes `\n` (newline instead of submit)
- ⌘F search; Enter / Shift+Enter / Esc inside search
- ⌘= / ⌘+ / ⌘- / ⌘0 font bigger / smaller / default (all terminals)
- ⌘⇧C launch claude (with launch flags) in the current shell
- ⌘R/K/L/A/E/D/U send Ctrl+R/K/L/A/E/D/U; ⌘C sends Ctrl+C only with no selection, else copies
- ⌥←/→ send ESC b / ESC f; ⌥↑/↓ plain arrows
- Ctrl+U clears the keystroke buffer; Backspace trims it

Composer: Enter send; Shift+Enter newline; ↑/↓ history; Shift+Tab cycle permission mode. Slash popover: ↑/↓/Enter/Esc. Editor: ⌘/Ctrl+S save. Review dialog: `[` previous, `]` next. Modals: Esc closes; Cmd/Ctrl+Enter submits (modalKit.tsx:126); Segmented controls accept arrows. Menus: ↑/↓/Home/End/Esc. Resize handles: arrow keys (redesign/ResizeHandle.tsx:63). Inline rename: Enter / Esc. File tree rename/create input: Enter / Esc. Notifications items: Enter/Space.

## 8. Tauri surface

`invoke` commands: 121 distinct, about 175 call sites. Counts above 1: pty_write 15, read_file 11, reveal_in_finder 5, write_file 4, list_session_history 3, list_claude_resources 3, git_status 3, frontend_log 3, credstore_reveal_cred 3.

Full list (regex-extracted; the 5 dynamic names come from variables in SessionsPage/SessionCleanupDialog/QueuePage): app_metrics, app_prefs_get, app_prefs_set, archive_sessions*, bg_service_open_settings, bg_service_set, bg_service_status, branch_detail, claude_channels_supported, claude_cleanup_days_get, claude_cleanup_days_set, create_dir, create_file, create_worktree, credstore_biometric_available, credstore_cred_list, credstore_cred_remove, credstore_cred_upsert, credstore_disable_biometric_unlock, credstore_enable_biometric_unlock, credstore_export, credstore_export_cred, credstore_export_master, credstore_import_key, credstore_import_secret, credstore_init, credstore_lock, credstore_reveal_cred, credstore_status, credstore_unlock, credstore_unlock_biometric, cyberark_list_accounts, cyberark_logoff, cyberark_status, cyberark_test_connection, debug_log_get, debug_log_set, delete_entry, export_session_markdown, fetch_mcp_marketplace, fetch_skill_marketplace, file_access_status, file_history_list, file_history_read, file_history_snapshot, frontend_log, get_startup_files, git_branch_file_pair, git_status, install_mcp, install_muya_plugin, install_skill, list_agent_sessions, list_archived_sessions, list_branches, list_claude_resources, list_dir, list_session_history, list_slash_commands, login_item_get, login_item_set, open_privacy_settings, open_third_party_licenses, path_kind, pm_check_merge, pm_collisions, pm_merge*, pm_push*, pm_status, pty_cwds, pty_kill, pty_resize, pty_session_ids, pty_spawn, pty_write, read_file, read_file_bytes, read_head_file, read_session_transcript, relaunch_in_place, release_agent_session, remove_worktree, rename_entry, resolve_path_kind, restore_sessions*, reveal_in_finder, scan_prd_docs, schedule_delete, schedule_run_now, schedule_runs, schedule_save, schedule_set_enabled, schedules_list, search_session_contents, session_touched_files, set_watched_files, set_workspace_roots, spotlight_search, ssh_get_config, ssh_pty_connect, ssh_release_session, ssh_remove_psmp_profile, ssh_remove_server, ssh_set_cyberark_config, ssh_upsert_psmp_profile, ssh_upsert_server, start_watching, statusline_get, statusline_settings_path, stop_agent, term_history_delete, term_history_entries, term_history_export, term_history_full, title_bar_double_click, trash_sessions*, vault_detect_candidates, vault_get_status, vault_restart, vault_set_path, write_file. (* = dynamic name via variable. The count 121 includes these 5; `list_dir`'s sibling `export_session_markdown` is used from SessionsPage.)

`listen` events: 18 (each used once unless noted): `apex://open-file`, `fs-changed`, `fs-files-changed`, `menu:check-update`, `menu:close-tab`, `menu:new-file`, `menu:open-file`, `menu:quit-hint`, `menu:reopen-closed-tab`, `menu:settings`, `menu:version-history`, `muya://close-agent-session`, `muya://open-agent-session`, `muya://deliver-message`, `muya://vault-locked` (2 listeners: SshPage), `schedules-changed`, `ssh-broker-open`, `ssh-broker-send`.

Other transport: Tauri `Channel<PtyMsg>` for PTY output (Terminal:586), `getCurrentWebview().onDragDropEvent`, window `isFullscreen/setFullscreen/resize`, plugins: clipboard-manager (readText), dialog (open folders/files), opener (openUrl), process (relaunch), updater (check/downloadAndInstall). In-page DOM custom event `muya:auto-approve-changed`.

MCP-triggered UI behavior (events): `muya://open-agent-session` opens a session (name, cwd, initialMessage, agent kind, splitWith, openedBy, unattended); `muya://deliver-message` types text into a session's PTY (remote-bridge sender info, `raw`); `muya://close-agent-session`; `ssh-broker-open` opens an ssh tab for the broker; `ssh-broker-send` writes into it.

## 9. Persistence (localStorage unless noted)

| Key | Stores |
|---|---|
| apex.theme | system / light / dark |
| apex.viewMode | "grid" or "tabs" (Control vs Grid screen) |
| muya.gridLayout | grid layout 1 / 1x2 / 2x2 / 3x2 |
| apex.gridKeys | session keys in grid cells |
| muya.selectedAgent | last selected tab key |
| apex.openTabs | open terminal tabs (restored on launch) |
| muya.openFiles | open file tabs |
| muya.pinnedAgents | pinned agent keys |
| apex.workspaces | workspace root paths |
| apex.selectedRoot | selected workspace |
| apex.worktrees | tracked worktree paths |
| muya.splitGroups / muya.splitGroupsCollapsed | split groups; collapsed ids |
| muya.notifications / muya.notificationsUnread | notification log (max 100); unread flag |
| muya.composerOpen | composer visible |
| muya.sessionHeaderCollapsed | header collapsed |
| muya.panels.agentsOpen, .inspectorOpen, .agentsWidth, .inspectorWidth, .filesOpen, .filesHeight | panel layout (6 keys) |
| muya.lastActive.v2 | last-activity map ("Recent" filter) |
| muya.footer.statusFields | chosen status field ids |
| muya.terminalPrefs | {fontSize, lineHeight, letterSpacing, scheme} |
| muya.autoApprove | "1" when on |
| muya.autoSave | "1" when on |
| muya.resumeOnLaunch | "1" when on |
| muya.fileAccessGate.dismissed | "1" |
| apex.sessionsHeadsUp | date of last storage heads-up |
| apex.mergeQueue | push/merge queue entries |
| apex.composerHistory.<kind> | composer send history, per agent kind (about 2-3 keys) |
| muya.servers.collapsed / muya.vault.collapsed | SSH group collapse state |
| sessionStorage `muya.waitingSince` | when each agent started waiting |
| legacy `muya.lastActive` | removed on read |

Plus backend-side state the UI depends on: workspaces roots (`set_workspace_roots`), app prefs (`app_prefs_*`: keepRunningInBackground, claudeStatusInFooter), login item, Claude cleanup days, debug-log setting, file history under `~/.claude/muya-file-history`, terminal history files, schedules store, credstore.

## 10. Theming

- styles/tokens.css: 123 custom properties, `:root` (indigo raw scale), `:root[data-theme="dark"]`, `:root[data-theme="light"]`. Only tokens.css and theme/terminalThemes.ts may contain hex colors. Tokens: --bg-app/-chrome/-control/-input/-panel/-rail-active/-segment/-segment-active/-selected/-selected-head/-table-head/-terminal, --border, -control/-selected/-strong/-subtle, --text, -faint/-muted/-secondary/-strong/-terminal/-tertiary, --primary-bg/-fg, --accent/-hover, --success*, --warning*, --danger*, --agent-claude, --agent-opencode, --font-mono, --font-sans, --shadow-popover, --shadow-segment-active, --pdf-paper, --pdf-page-shadow.
- Theme logic: theme/theme.ts (`useTheme`, preference system/light/dark, live `prefers-color-scheme`), sets `data-theme` plus legacy `.dark` class. First paint handled by `public/theme-boot.js`; `public/boot-guard.js` also exists (OPEN QUESTION: purpose not read). Monaco and the terminal follow the resolved theme.
- Fonts: IBM Plex Sans 400/500/600 and JetBrains Mono 400/500/700 (bundled via @fontsource, main.tsx:10-15). UI sans = IBM Plex Sans, mono = JetBrains Mono (terminal).
- Animations: `muya-fade-in` 140ms page transition (`.muya-page-in`), `session-decision-blink` 1.15s infinite (waiting card border), `rd-auto-allow` 2s fill on the Allow button; reduced-motion media query disables them. The rail panda animation was removed (30-35% CPU) and any always-on animation must be measured.
- Tailwind v4 (`@tailwindcss/vite`) is still used by older pages (`indigo` scale from tokens); newer redesign components use inline styles with `var(--token)` and `redesign/redesign.css` (classes `rd-btn2`, `rd-icon-btn`, `rd-palette`, `rd-ellipsis`, `st-btn`...).

## 11. Third-party dependencies that carry features

| Package | Feature |
|---|---|
| @xterm/xterm 6, addon-fit, addon-search, addon-webgl | terminal engine, fit, Cmd+F search, GPU rendering (@xterm/headless is dev-only, used by tests and slash-command capture) |
| monaco-editor 0.55, @monaco-editor/react | editor, diff editor, 4 workers |
| pdfjs-dist 6 | PDF viewer |
| marked 14, dompurify | rendered Markdown, sanitized |
| cmdk | command palette |
| lucide-react | icon set (plus custom icons in redesign/icons.tsx) |
| @tauri-apps/api, plugin-clipboard-manager, plugin-dialog, plugin-opener, plugin-process, plugin-updater | native bridge, clipboard, file/folder pickers, URL opening, relaunch, auto-update |
| @fontsource/ibm-plex-sans, jetbrains-mono | bundled fonts |
| react 19 | UI |
| dev only: vitest, @testing-library/*, @playwright/test, pixelmatch, pngjs | tests, visual checks, load tests (`scripts/loadtest`, src/perf/harness.ts) |

## Notes for the native rewrite

1. Everything in section 2 under "Screen parsing" depends on the exact text of Claude Code's TUI (v2.1.285). A native app must either keep a terminal-emulator buffer to parse, or switch to structured data (hooks / status tap); the statusline tap and channel flags already provide some.
2. Terminal output flows as binary ArrayBuffers from Rust; the native app needs its own terminal emulator (e.g. SwiftTerm or a libghostty-class engine) with: scrollback 5000, path-link detection + existence check, search, mouse-tracking awareness, hidden-tab output coalescing, shared font/spacing/scheme prefs.
3. Keyboard capture is capture-phase and modal-aware (a terminal never receives keys while a dialog is open). Keep that rule.
4. Mock/dev surfaces (`src/mock`, `src/dev/mockBackend.ts`, `src/perf`, `redesign/Preview.tsx`, `previewFixture.ts`) are dev-only and need no port.
5. `components/TerminalGrid.tsx` looks unused (legacy); `MarkdownViewer.tsx` vs `MarkdownView.tsx`: confirm which is live before porting.

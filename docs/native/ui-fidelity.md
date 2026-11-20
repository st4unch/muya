# Native UI fidelity — "the native app must look like the running Muya"

Operator requirement (2026-11-04): same layout, same parts in the same places, same colours, fonts, sizes, spacing, icons,
labels and states, dark and light. Pixel-identical is impossible (WebKit CSS vs AppKit); a viewer must not be able to tell
which app is which at a glance.

## What this step delivered

| Piece | Where |
|---|---|
| Reference screenshots of today's Muya (WebKit, mock data, 35 views × dark/light × 1440×900 / 1120×732 = 140 PNG) | `native/ui-reference/screens/<view>-<theme>-<WxH>.png` |
| Script that makes them (fresh page per shot; retries until the mock shows "2 working") | `native/ui-reference/capture.mjs` — needs `npm run dev` on :1420, then `node native/ui-reference/capture.mjs [--only a,b] [--sizes 1440x900] [--themes dark]` |
| Design tokens (51 colours dark+light, terminal palette, fonts, geometry — each with `file:line`) | `native/app/Sources/Theme/Tokens.swift` (generated) + `native/ui-reference/tokens.json`; regenerate: `python3 native/ui-reference/gen-tokens.py` |
| Visual diff (reference \| native \| heat-map + score) | `native/tools/ui-diff/ui_diff.py` (one pair or two folders) |
| Baseline of today's native app vs reference | `native/tools/ui-diff/baseline.py` → `native/tools/ui-diff/baseline/BASELINE.md` + `*.compare.png` |

How a later worker proves "same": capture the native window at 1120×732 (point size; Retina is resized automatically) into
`<dir>/<view>-<theme>.png`, add the name to `native/tools/ui-diff/map.json`, run `baseline.py`. **Pass = layout ≥ 90 and colour ≥ 95**
("same at a glance"); score ≥ 90 = pixel-close. The scale is generous for dark empty screens (an unrelated dark app scores ~70),
so always also *look* at the `.compare.png`. Baseline today: mean **73.4** over 30 pairs (every view below 90; range 54–88).

## Sources of truth (read-only, web side)

* Colours/fonts: `src/styles/tokens.css` (`:root[data-theme=dark|light]`, `data-theme` set before first paint). Terminal palette: `src/theme/terminalThemes.ts`.
* Layout: `src/redesign/*` (Rail, ControlHeader, AgentList, SessionHeader, Composer, Inspector, Footer, GridScreen…), pages in `src/components/*`. Dialogs/forms: `src/components/modalKit.tsx`.
* **Fonts:** IBM Plex Sans (UI) and JetBrains Mono (terminal/code) — SIL OFL 1.1, bundled via `@fontsource/*`. Free to ship in the native app (ship the OFL text in THIRD_PARTY_NOTICES).
* **Icons:** hand-drawn inline SVG in `src/redesign/icons.tsx` (24-viewBox, round caps, stroke 1.6–2) for rail/header/footer + `lucide-react` (ISC licence, bundle-able) on the pages. Native: draw the rail/header icons as `NSBezierPath` from the same path data; lucide SVGs can be bundled as-is.
* Sizes in use: UI text 13px (97×), 12px (86×), 11px (34×), 14/15/10/17 rare; weights 600 (64×), 500, 400, 700 rare. Radii 7 (43×), 6, 8, 4, 10, 12, 5, 9. Mono 12–13px in terminal.

## App frame (every view)

```
┌ title bar 48px: [traffic lights] [M Muya] [⊟ agents toggle] [Workspace ▾ · N] [search 440 ⌘K] ··· CPU/RAM/clock [monitor][bell][⊟ inspector] ┐
│ rail 64px │ page area (view-specific) …                                                                                          │
│ 48px btns │                                                                                                                      │
│ ⚙ bottom  │                                                                                                                      │
├ footer 28px: ● Ready · N workspaces · N agents · N working · N waiting · N conflicts ····· UTF-8 · Aa · ▢ · + · Muya vX ────────────┤
```
Rail (`Rail.tsx:41,63`): Control, Files, Sessions, Queue, Kanban, Resources, SSH, Schedules (icon 20 + 10px label, active = `--bg-rail-active` rounded 10), Settings at the bottom. Panels: agents 296 (220–480), inspector 320 (260–520, auto-hidden ≤ ~1360 wide unless opened with ⌥⌘B), ⌘B toggles agents. A transient toast ("Turn on Auto-allow?") floats top-right in every reference shot; notifications panel is the bell dropdown.

**Biggest frame gap (all views):** the native window has no rail, no 48px header with workspace picker/search/CPU-RAM-clock, no footer; it has a 150–200px "New Session + session list + Files tree" sidebar, macOS system fonts/colours, and a window title "Muya Native – …".

## Progress

| WP | State | Result |
|---|---|---|
| WP0 Foundations | **done** | bundled IBM Plex Sans (400/500/600/700) + JetBrains Mono (400/700) TTFs (unpacked from the repo's @fontsource WOFF files by `native/app/tools/make-fonts.py`, latin + latin-ext merged, SIL OFL texts next to them), registered process-scoped at launch (`ThemeFonts.register`); all 37 web icons as native paths (`Icons.swift` + generated `IconData.swift`); terminal palette = the xterm.js theme; terminal font = JetBrains Mono; shared parts in `Sources/Theme/ThemeKit.swift` (ThemedButton ghost/primary/danger, ThemedSegmented, ThemedSwitch, ThemedPill, ThemedBox rows/card/popover, label/helper/title text). `gallery` debug command shows them. Idle: app CPU 0.0 % before and after, footprint 90 → 85 MB. |
| WP1 App frame | **done** | `Sources/App/Frame.swift` + `FrameWiring.swift`: full-size content view with transparent title bar; 48px header (logo, sidebar toggle, workspace chip, ⌘K search field → palette, CPU/RAM/clock of the app on a 5 s tolerant timer, theme cycle, notifications popover, inspector toggle), 64px rail (Control, Files, Sessions, Queue, Kanban, Resources, SSH, Schedules, Settings; highlight follows the open page), 28px footer (Ready, session counts, version); sidebar now `--bg-panel`. Files rail item = Control until WP5; workspace chip is a label until WP9. Idle CPU 0.0 %. Baseline control+grid mean 76.8 → 80.1. |
| WP2 Agents panel + session header + composer | **done** | `AgentsPanel.swift` (Agents N, "+ New agent", All/Waiting/Working filter, WAITING FOR YOU / WORKING / IDLE groups of cards with state dot, kind icon, status, folder, ×, rename/close menu), `SessionBar.swift` (name, status pill, folder, Split to grid, Stop while working), `Composer.swift` (message box with placeholder, Mode chip, @ Add file, / Commands, send; Return pastes + presses Return, ⇧↩ newline, ↑ history). Hidden in grid mode. Idle CPU 0.0 %. Baseline control+grid mean 80.1 → 79.9 (control dark 80.4 → 82.3; grid unchanged — WP4). |
| Mock mode | **done** | `MUYA_MOCK=1` (only with `MUYA_DEBUG_SOCKET`): `Sources/App/Mock.swift` seeds the 7 agents of `src/mock` (documents-44 waiting, muya-all + opencode-review working, 4 idle), folder `~/Documents/claude-control-plane`, muya-all terminal text, header CPU/RAM/clock and footer counts — no daemon. `native/app/run-mock.sh start [app]` + `MUYA_SHOT_SELECT=2 native/ui-reference/native-shots.sh OUT` + `baseline.py --native-dir OUT/1120x732` measure style, not content. Baseline with mock data (control + grid, 1120x732): mean 74.9 (control 79, grid 69–72). |
| Control-view gaps + WP4 grid | **done** (terminal line height unverified visually) | Files collapsed to a "› FILES N" row at the sidebar bottom (`SidebarView.swift`); session header second line "Claude Code · ~/path" + bypass warning icon; status strip "● verb · 4m 15s · ↓ tokens · thought for 3s … Update ready [Restart]" (`StatusStrip.swift`; Restart/update only in mock mode); terminal line height 1.6 like xterm (`Renderer.swift`); auto-allow toast seeded in mock mode. Grid: panels with 10px radius, header 34px (state dot, name, status), amber 2px border + inline Allow ⏎ / Deny ⎋ bar for waiting panels (`GridChrome.swift`), grid header band "Grid · N panels" + Exit grid. Screen was locked during verification: shots taken with the in-process `snap` (WP8) — the Metal terminal area is empty there, so scores from these shots (control 73/81, grid 68/77) are NOT comparable with the earlier screencapture baselines; re-measure with real screenshots when the screen is unlocked (`native-shots.sh` without MUYA_SHOT_SNAP). |
| WP5 Files | **partly done** | Rail Files item opens the sidebar tree and the Files home ("Files N", "No file open — Pick a file in the tree…", `FilesHome.swift`); opened files keep the existing viewer. Not done: open-file chips, tree row styling/context menu restyle, editor chrome (Wrap/Map/Diff). `rail <item>` debug command added. Grid Allow/Deny now calls `Store.answerPrompt`. |
| WP6 Sessions + Cleanup | **mostly done** | Legacy pages follow the tokens. Sessions: tabs with icons (plug / terminal) on a soft pill, bordered cards (mono name, pills NEEDS YOU / OPENCODE / status, model tag, meta row folder · branch icon + branch (read from .git/HEAD) · clock + duration), amber NEEDS YOU card, today's buttons: .md always; opencode → Resume; attachable → Attach + Stop (red, `agents.stop` via the daemon, no confirm like today); otherwise Open; mono LIVE/PAST SESSIONS headers, flat past list, bottom amber banner, Terminal History tab. Mock seeds live agents + transcripts + a main branch. Not done: Cleanup sheet tabs/switches. In-process snapshots only (screen locked); 141 tests pass. |
| P5 (dialogs, menus, toasts, popovers) | **mostly done** | Broadcast (verified on real shells), Rename, Confirm, session menu with Pin and Move to Trash…, grid-panel and terminal context menus, drop overlay, footer "Aa" terminal appearance popover (font size + line spacing) and "+" status field picker with chosen fields in the footer, generic toasts + storage heads-up. Not done: notification toast, colour schemes, Paste as Path / Find / Clear Scrollback, real statusline values. |
| WP4 Grid (rework) | **mostly done** | App header in grid mode: breadcrumb "Muya / Grid · N panels", workspace chip, Exit grid, layout segmented 1 / 1×2 / 2×2 / 3×2, Waiting first, Broadcast to all…; agents panel hidden; panels 49px head with expand icon, 58px bottom bar = approval row (Allow ⏎ amber, Deny ⎋, "Don't ask again (this project)" from the prompt's approveAlways option) or "Message <name>…" input; "Empty panel — Waiting for a task / Assign from Queue / Swap panel" cards; footer hint "Tab to switch panels · ⌘↵ maximize"; rules in `GridLogic.swift` (layouts, waiting first, picks, swap/append, cell rects; tests). Real captures, mock mode (3 panels + 1 empty, no default footer fields, like the web mock): grid 66.5/69.4 → 80.3/83.1 @1120, 85.2/87.7 @1440 (baseline-grid/). Open: mock should pick 3 panels + give the waiting prompt an approveAlways option (mock.swift is polish's); panel name menu (choose session), double-click rename, bypass pill. |

## Per-view spec and gaps

Ref = `native/ui-reference/screens/<view>-<theme>-<size>.png`. Native = existing shot in `native/app/screenshots/`. "Frame" = the frame gap above (assumed in every row, not repeated).

| View (ref name) | Regions (left→right, top→bottom) | Native shot | Gap list |
|---|---|---|---|
| **control** | agents panel 296: "Agents N" + black "+ New agent" pill; segmented All/Waiting/Working/Recent; groups WAITING FOR YOU (amber card) / WORKING (blue-selected card) / idle; collapsible FILES; hint footer (⌘1–9). Centre: session header (name 15/600, status pill "Working · 4m 15s" green, bypass pill red, Compact/Split/Split to grid/Stop outline buttons), terminal, progress strip, composer (textarea + Mode chip, @ Add file, / Commands, send ↑), inspector 320: permission card (Allow amber / Deny / Open), tabs Changes N / Activity, file list with M/A/? badges, Review diff / Commit…, "No file conflicts" green card | `app-*` | no agents panel/cards/segments; no session header with status pills and action buttons; terminal background `#15171B` vs token `--bg-terminal #0B0D11`, ANSI palette differs; no composer; no inspector; sidebar lists sessions as plain rows |
| control-agents-hidden / control-terminal-focus | same without agents panel (⌘B) / without both panels (⌥⌘B) | — | native has no panel toggles |
| control-inspector-activity | Activity tab: AGENT FILES (modified/read lists), LOCK / EDIT TELEMETRY | `inspector-activity-*` | native inspector is a tabbed list under the terminal, not a right panel; headings/tokens differ |
| agent-card-menu | context menu: Pin, Rename…, Duplicate, Reveal in Finder, Schedule prompt…, Close agent (red) | — | no menu |
| composer-slash | popover "Filter commands…" + BUILT-IN list (/add-dir …) above composer | — | no composer/popover |
| more-actions | narrow-width header overflow ⋯ menu (captured at 1000×700 because the button only exists when narrow) | — | no header |
| footer-add-status / terminal-appearance / workspace-switcher / notifications | popovers from footer "+", footer "Aa", header workspace chip, bell (empty: "No notifications.") | — | none exist natively |
| palette / palette-query | centred 560-wide card, search field, groups Agents / Files / Commands, selected row `--bg-selected` | `pages-palette-*` | native palette is a flat translucent list over the terminal; wrong group set, fonts, row height |
| new-agent | modal: tabs Claude Code / opencode / Terminal, WORKSPACE select + Browse, NAME, PERMISSION MODE, checkboxes, BRANCH, INITIAL PROMPT, FILES, Cancel / Launch agent (white pill) | — | no New Agent dialog (native: "New Session" button) |
| settings | modal (modalKit): APPEARANCE segmented System/Light/Dark, STARTUP/CLAUDE switch rows (bold 13 title + helper + switch right), footer "Theme changes apply right away" + Close/Save | `pages-settings-*` | native is a separate window with large 15–17px type, different switch/segmented look, extra sections |
| grid | header "Muya / Grid · N panels" + Exit grid, 1/1×2/2×2/3×2, Waiting first, Broadcast to all…; 2×2 panels with title, status, expand icon, inline Allow/Deny card, "Message …" input; empty panel "Assign from Queue / Swap panel" | `grid-*` | native grid has no panel chrome (title/status/expand), no permission cards, no input row, no header controls |
| files / files-tree / files-context-menu / files-editor | "Files N" header + open-file chips, empty state "No file open", FILES tree with workspace rows (badge), context menu (Open in Muya, Terminal Here, Open Claude Here, New File/Folder, @ Reference, Copy Path, Reveal, Rename, Delete red), Monaco editor with Wrap/Map/Diff | `files-tree-*` | native tree is in the sidebar with folder icons in blue; no chips/empty state; menu missing items; editor chrome differs |
| inspector-review-diff | modal "Uncommitted changes · <repo>": file list left, before/after diff right (red/green), footer "File 1 of 14 · [ ] to move", Open in editor / Prev / Next | `inspector-diff-*` | native diff is a pane, not a modal; colours differ |
| inspector-commit | (Commit… did not open a dialog in mock mode — shot shows the control view) | — | n/a |
| sessions / sessions-cleanup | "Agent Sessions" / "Terminal History" tabs, filter field, LIVE SESSIONS rows (status chips, branch, .md / Attach / Stop), amber "5 sessions · 415 MB…" banner + Clean up…, PAST SESSIONS; Cleanup modal with Clean up/Archived tabs, limit rows with switches, checklist, Move to Trash / Archive | `pages-sessions-*`, `pages-4e-cleanup-*` | native is a plain list with grey groups, no chips/actions per row; cleanup sheet is a system sheet with different controls |
| queue | "Push / Merge Queue" title, queue empty line, TRACKED PROJECTS cards with branch, changes, "Add to queue" violet button | `queue-*` | native is a table with Queue/Branches/Kanban buttons; no cards |
| kanban | "PRD Board" columns DRAFT / IN PROGRESS / REVIEW / DONE (mock has no PRDs → empty columns) | `kanban-*` | native cards with data; header differs (reference mock empty — needs mock data to compare cards) |
| branches | "BRANCH TOPOLOGY DAG" card with search, lanes (mock empty); lists PRODUCTION / ACTIVE WORKSPACE WIP / OPEN PENDING | `branches-*` | native shows a populated commit graph table; layout unrelated |
| resources / resources-marketplace | "Claude Resources" title + search + Refresh + violet "Create with Claude"; tabs Skills/Agents/Hooks/MCPs/Marketplace; list left, detail right (empty in mock) | — | Resources/Marketplace page does not exist natively |
| ssh-servers / ssh-add-server / ssh-cyberark / ssh-store | "SSH Configuration" title; Servers / CyberArk / Password Store tabs (underline); grouped server cards with Connect + edit/delete; PSMP profiles; form fields in 2 columns; Password Store locked card (Touch ID / master password) | `ssh-cyberark-empty-*`, `ssh-cyberark-*` | native: button-style tabs, account table, English copy differs; no grouped cards, no form layout |
| schedules / schedules-editor | "Schedules" title + helper, "Run when Muya is closed" switch card, 4 stat tiles, schedule cards (name, Success/Timed out pill, switch, runs/last/next, Run now/History/edit/delete); modal editor (NAME, PROMPT, FOLDER, SCHEDULE segmented, At, OPTIONS switches) | `pages-schedules-*`, `pages-schedule-editor-*` | native: table + bottom button row, stat tiles flat; editor is a sheet with checkboxes instead of switch rows |

Not reachable / limited in mock mode (cannot be fixed without editing `src/mock/`, which is out of this task's paths): Kanban/Branches/Resources show empty data; Commit… dialog; image/PDF/Markdown viewers and the editor tabs beyond `notes.ts` (mock filesystem has one file per workspace); Settings sections below the fold; the real title-bar traffic lights (browser has none — reserve ~78px left padding in the native header); live terminal content is mock lines. Agent states sometimes come up "Idle" in the mock — `capture.mjs` reloads until the footer reads "2 working".

## Proposed work packages for restyling

Rule for all: colours only through `Theme.dynamic(.token)`, fonts through `ThemeFont`, geometry from `ThemeMetric`; each package ends with a `ui-diff` row ≥ 90 / 95 in both themes.

| WP | Scope | Files (current names; some are new) | Parallel? |
|---|---|---|---|
| **WP0 Foundations** (do first, small) | add `Sources/Theme/Tokens.swift` to build.sh; bundle IBM Plex Sans + JetBrains Mono (OFL) and register; terminal palette from `TerminalPalette`; icon set (`Sources/Theme/Icons.swift`, NSBezierPath from `icons.tsx`); shared kit parts (pill, segmented, switch row, card, modal shell, popover) in `Kit.swift` matching `modalKit.tsx` | `Sources/Theme/*`, `Sources/App/Theme.swift`, `Sources/App/Kit.swift`, `build.sh` | no — blocks the rest |
| **WP1 App frame** | window chrome: 48px header (logo, panel toggles, workspace chip, ⌘K search field, CPU/RAM/clock, bell, inspector toggle), 64px rail, 28px footer, panel layout/resizers | `Renderer.swift`, `Model.swift`, new `Sources/App/Frame.swift` | after WP0; then everything else hangs off it |
| **WP2 Agents panel + session header + composer** | agent cards/segments/groups, session header pills & buttons, progress strip, composer, slash popover, card context menu | `Replica.swift`, `SessionsExtras.swift`, `TerminalView.swift` (palette only) | parallel with WP3–WP8 after WP1 |
| **WP3 Inspector panel** | right panel: permission card, Changes/Activity tabs, file list, Review diff modal, no-conflicts card | `Inspector/InspectorPane.swift`, `Viewers.swift` | parallel |
| **WP4 Grid** | grid header controls, panel chrome, inline permission cards, empty panel | `Renderer.swift` (grid part → split to `Grid.swift`) | parallel (touches Renderer: coordinate with WP1) |
| **WP5 Files** | Files page, tree rows, context menu, open-file chips, editor chrome | `Viewers.swift`, `SettingsPalette.swift` (palette), tree in `Replica.swift` | parallel with WP3 only if `Viewers.swift` is split first |
| **WP6 Sessions + Cleanup** | Agent Sessions / Terminal History tabs, row chips/actions, banner, cleanup modal | `SessionsPage.swift`, `SessionsExtras.swift` | parallel |
| **WP7 Queue / Kanban / Branches** | cards layout, PRD board, topology | `Queue/QueuePage.swift`, `Queue/QueueViews.swift` | parallel |
| **WP8 SSH / Settings / Schedules** | SSH tabs + cards + forms, Settings as modal with switch rows, Schedules cards + editor modal | `SSH/SSHPage.swift`, `SSH/SSHForm.swift`, `SettingsPalette.swift`, `SchedulesPage.swift`, `ScheduledPromptSheet.swift` | parallel (3 sub-workers; Settings/Schedules share `SettingsPalette.swift`? no — separate files) |
| **WP9 New pages** | Resources/Marketplace, New Agent dialog, notifications/workspace/footer popovers, palette restyle | new `ResourcesPage.swift`, `NewAgentSheet.swift`, `Popovers.swift` | parallel after WP1 |
| **WP10 Verification** | capture native at 1120×732 for all views in both themes, fill `map.json`, run `baseline.py`, put the table in the PR | `native/tools/ui-diff/*` | last |

Conflicts to watch: `Renderer.swift`, `Replica.swift`, `Kit.swift` are touched by several packages — land WP0/WP1 first, split the big files, then run WP2–WP9 in parallel on disjoint files. Another worker ("native app-acc2") currently edits `native/app/Sources/App/**`; do not start WP1+ until it has committed.

## Low-screen pass (after baseline-final-3)

- **Clean up Claude sessions** is now a themed modal over the scrim (ModalFrame: title rule, intro, rules box with select + switch, tick-box rows with the size on the right, Close + Move to Trash) instead of the system sheet. New `ThemedCheckbox` / `ThemedSelect` in `Theme/ThemedControls.swift`. `byteSize` follows `formatBytes` of the web app ("415 MB"). Mock history = the web mock's rows.
- **Archive (done):** muyad `sessions.archive` / `sessions.restore` / `sessions.archived`; the dialog has the Clean up / Archived (n) tabs with Archive / Restore, the Sessions cards a "···" menu (Archive, Move to Trash). Checked on a real daemon + app in a temp HOME: files move into session-archive, restore is byte-identical.
- **Palette:** the card was stuck at the offsets of its first layout (not centred, 50 px too high) — laid out again once it sits at the window root; paths mono 11 muted, input centred in its bar; mock shows the web mock's files.
- **Sessions:** status pills use today's Tailwind pairs (outlined, light fill for IDLE in both themes), meta row = FolderGit2 icon, branch as text, clock; mono 10.
- Scores (in-process `snap`, screen locked; the cleanup dialog could not be captured): sessions 82.5 → 84.5 dark, 85.9 → 86.9 light; palette 81.7 → 88.0 dark, 85.3 → 85.6 light @1120×732. Cleanup was not re-scored.

## Terminal schemes, find, status fields

- **Colour schemes:** the 9 schemes of today's picker (generated into `Tokens.swift` from `terminalThemes.ts` by `gen-tokens.py`), picked in the appearance popover (now a themed card with the swatches), applied to every terminal and to the padding around the grid, kept in `muya.terminalPrefs.scheme`.
- **Terminal menu:** Paste as Path, Find… (⌘F bar, current match selected and scrolled to), Clear Scrollback, Open Link.
- **Footer status fields:** the full catalogue of 67 fields; values are the real status JSON of the selected session (`statusline.session`).
- `native/app/verify-term-features.sh` runs all of it on a real daemon + app in a temp HOME.

### Re-score of the changed screens (real captures, mock mode, `native-shots.sh` with the window-id fallback)

| view | theme | 1120×732 before → after | 1440×900 before → after |
|---|---|---|---|
| sessions-cleanup | light | 72.2 → **82.2** (colour 80.4 → 96.2) | 74.6 → **86.0** |
| sessions-cleanup | dark | 77.9 → **81.3** | 82.2 → **85.2** |
| palette | dark | 81.7 → **90.1** | 84.6 → **85.9** |
| palette | light | 85.3 → **87.2** | 83.5 → **84.7** |
| sessions | dark | 82.5 → **83.4** | 84.2 → **84.6** |
| sessions | light | 85.9 → **86.4** | 86.9 → **87.3** |

Mean over all 18 views: 88.1 @1120×732, 89.4 @1440×900 (88.1 / 89.7 → 87.4 / 88.9 in baseline-final-3 before the mock rows moved; the mean now includes the cleanup rows).

## Round "push the views under 90" (window-id captures, mock mode, toast kept in the window)

One commit per view; before → after (score, 1120×732 dark / light unless noted):

| view | before | after | what moved |
|---|---|---|---|
| sessions-cleanup | 81.3 / 82.2 | **90.5 / 90.6** (1440: 92.4 / 92.0) | ModalShell geometry for every dialog (15 px title, close X, 20 px body and gaps, 12 px footer), helper line height 1.45, 16 px tick, 13 px select, the dark dialog border was a bright outline (a CGColor taken under the wrong appearance) |
| sessions | 83.4 / 86.4 | **88.4 / 88.4** (1440: 90.0 / 89.3) | page and cards `--bg-control`, neutral-700 card border, radius 8, 12 px names, 9 px model, the web mock's durations |
| grid | 83.3 / 86.5 | **84.9 / 87.8** (1440: 87.9 / 90.5) | kind icon, 14 px names, "Needs permission · 1m", Allow Y / Deny N, Empty panel position, toast 370 px |
| control @1440 | 84.0 / 87.5 | **87.4 / 89.8** | the inspector is open by default from 1280 px like today's Control screen (it was never shown), hidden on pages and in the grid; width bug on re-show |
| new-agent | 85.7 / 83.4 | 85.8 / 83.4 (1440: 88.1 / 85.8) | plain select, no select-all in the field, toast above the dialog (not visible in window-id captures) |
| palette (1440) | 85.9 / 84.7 | 89.2 / 86.9 | (inspector default, geometry) |

Mean over 36 pairs: **88.5 @1120×732, 90.7 @1440×900** (88.1 / 89.4 before this round).

Also fixed on the way: toast cards stay above dialogs (lifted into panels above the scrim, hidden while the app is inactive, `verify-toast-lift.sh`), the Schedules page keeps its own line height.

### What still differs, and why (nothing got closer than ±1 per round on these)

- **Files (files-tree 89.2 / 88.8)**: today's left panel in Files mode is the open-files list plus a multi-root workspace tree (one root per agent folder with the agent's chip); the native tree is a single root for the selected session. A feature (multi-root `FileTreePanel`), not a restyle.
- **SSH → CyberArk (85.2 / 84.7)**: today's tab is the PAM connection form (PVWA URL, auth method, login credential, test connection); the native tab is the accounts browser, and has an extra "PSMP profiles" tab. Different content.
- **Grid (84.9 / 87.8)**: the panels' terminal text in the reference has a 7.0 px advance with 27 px rows (a 13 px font), ours 7.8 px — the reference renders xterm.js text with a different glyph advance than JetBrains Mono at 13 px under CoreText; shrinking the font made the score worse (82.1) and was dropped. The mock's terminal lines also wrap differently (a longer `bypass permissions…` line).
- **New agent light (83.4)**: colour 92 comes from the Auto-allow toast, which today's app draws above the dialog and a window-id screenshot cannot show (child panels are left out); with a real screen capture the toast is right (looked at it). Layout: the dialog is a system sheet (position fixed under the title bar), today's is centred.
- **Schedules (90.1 / 89.5)**: mock rows say "Every 120 min" / "today 07:49" where the web mock says "Every 2 hours" / "tomorrow 04:21" (schedule mock data in muyad's clock), no card selection state in the reference.
- **Text rendering**: AppKit (CoreText, subpixel positions) vs WebKit/CSS: single-pixel offsets of every text line cap the *detail* score at about 80–85 for text-heavy pages (kept above 78 everywhere).

# PRD: Sessions rail (Muya Native)

## 1. What and why
When the Agents column is closed, the narrow left rail (Control, Files, Sessions, Queue ...) is the only left-hand navigation, and the sessions are out of reach. The rail gets two pages while the column is closed: **Sessions** (default) and **Menu** (today's icons).

## 2. Behaviour
- Sessions page: one compact item per session, same order and split grouping as the Agents list (thin bracket on the left of a split's members, bigger gap between groups). Kind icon (Claude asterisk / terminal / opencode / robot for agent-opened) with the status dot, a 2-3 letter monogram, tooltip = name, status, folder. Click selects (same as clicking the card). Waiting sessions get the amber ring. Scrolls when long.
- Menu page: today's rail unchanged. A small ‹ [two dots] › switcher sits at the top of the rail while the column is closed.
- Reopening the column returns the rail to Menu; closing it starts on Sessions. The closed/open state is already saved (`muya.panels.agentsOpen`).

## 3. Keyboard (exact chords only)
| Chord | Action |
|---|---|
| ⌃⌥← / ⌃⌥→ | Sessions page / Menu page (only while the column is closed; passes through when open) |
| ⌃⌥↑ / ⌃⌥↓ | previous / next session as listed on screen (open or closed) |
Conflict check: ⌘1-9, ⌥⌘1-9, ⌘⇧K, ⌘[ ⌘] all need ⌘ (the router returns early without ⌘). Terminal keys: ⌥+arrow is word-move and needs no ⌃ (`TerminalKeys.altArrow`, tested); ⌃←/→ without ⌥ is macOS Spaces. All four are in the View menu.

## 4. Non-goals
No change to the Agents column, its width logic or the split model.

## 5. Integration (evidence)
- Rail: `RailView` in Sources/App/Frame.swift; new pane, switcher and wiring in Sources/App/SessionsRail.swift.
- List order and groups: `AgentsPanel.onScreenSessions`, `SplitModel.groups`; the panel calls `onSynced` after each reload so the rail follows streaming status.
- Selection: `agentsPanel.onSelect` (FrameWiring.swift) is reused by `railPick`.
- Collapsed state: `MainController.sidebarCollapsed` (didSet updates `railPages`), persisted by Prefs.swift `saveLayout`.
- Keys: `ShortcutRouter.handle` (Sources/App/Shortcuts.swift) pure map in Logic/SessionsRailLogic.swift `RailKeys`.
- Protected: ⌘-key map, terminal key handling, FILES section, AgentsWidth/rootSplit logic.

## 6. Acceptance criteria
1. Collapsed: rail shows Sessions page with N items in list order; Menu page shows the 8 icons. (rail-state + screenshots)
2. Re-open: Menu page. Re-collapse: Sessions page. (RailPages test)
3. ⌃⌥ arrows map as in §3 and nothing else is claimed. (RailKeys test, rail-key hook)
4. Stepping wraps and works with nothing selected. (SessionStep test)
5. `build.sh test` green; screenshots dark + light of both pages.

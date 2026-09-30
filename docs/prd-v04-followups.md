# Mini-PRD — v0.4 redesign follow-ups (operator feedback 2026-09-30)

Branch: `feat/ui-redesign-v0.4`. UI language English. Design system: `src/styles/tokens.css`
(colours only via `var(--token)`), `src/redesign/redesign.css`, and the reference designs in
`docs/design/redesign-v0.4/`. Rules that stay in force: no text wraps, nothing misaligned,
no hex outside tokens.css / terminalThemes.ts, never unmount a terminal, never a second PTY,
components are never declared inside another component's render body.

## 1. Panel toggles + resizable side panels (Control screen)
- Header gets two 32×32 icon buttons in the same style as the theme/bell buttons: a
  "left panel" toggle placed right after the "Muya" logo, and a "right panel" toggle at the
  far right after the bell. Icons: panel-left / panel-right (stroke 1.8, 16px). aria-label
  "Hide agents panel"/"Show agents panel" and "Hide inspector"/"Show inspector"; pressed
  state via `aria-pressed`.
- Left toggle hides only the agents panel (the rail stays). Right toggle hides the inspector.
- Both panels resizable by a drag handle on their inner edge (a 5px hit area, 1px visible
  border; hover/drag shows `var(--accent)`), cursor `col-resize`. Agents panel 220–480px
  (default 296), inspector 260–520px (default 320). Widths and open/closed state persist in
  localStorage. Double-click on a handle resets to default.
- Keyboard: ⌘B toggles the agents panel, ⌥⌘B toggles the inspector (VS Code convention).
- At 1440×900 with defaults the Control screen still matches the reference (pixel diff ≤ 1%).

**AC**
- [ ] 1.1 Clicking each toggle hides/shows exactly its panel; the terminal re-fits (no clipping).
- [ ] 1.2 Dragging each handle resizes within the limits; widths survive an app restart.
- [ ] 1.3 ⌘B / ⌥⌘B work while focus is in the terminal and in the composer.
- [ ] 1.4 `node scripts/redesign/verify.mjs … --target app` ≤ 1% for control and grid.

## 2. File directory under the agents list (expand / collapse)
- The agents panel becomes two stacked sections: Agents (existing) and **Files**. The Files
  section header is a full-width row: chevron (right = collapsed, down = expanded) + "FILES"
  label (11px/600, letter-spacing .06em, `--text-muted`, like the group labels) + root count;
  clicking toggles it. Collapsed = header only, pinned above the "Drag to reorder" footer.
- Expanded: the existing `FileTree` (wrapped `.rd-legacy`) fills the section; a horizontal
  drag handle between Agents and Files resizes the split (min 120px each); height and
  expanded state persist.
- The inspector's "Files" tab is removed (one tree, not two); inspector tabs: Changes / Activity.

**AC**
- [ ] 2.1 Files section expands/collapses by click; state persists across restart.
- [ ] 2.2 Split between agents and files is draggable, bounded, persisted.
- [ ] 2.3 Opening a file from this tree opens it in the main area (existing behaviour).
- [ ] 2.4 Inspector shows Changes / Activity only.

## 3. Grid: a clear way back
- Grid header gets a secondary button "Exit grid" (left of the layout segment) that returns to
  the Control screen with the focused panel's agent selected. Esc (when focus is not in a
  terminal or input) does the same. Clicking the rail's Control item while in grid also
  returns to the Control screen.

**AC**
- [ ] 3.1 Control → Split to grid → Exit grid returns to Control with the same agent selected.
- [ ] 3.2 Rail "Control" from grid returns to Control. 3.3 No terminal is re-spawned.

## 4. "/ Commands" shows what "/" can do
- Clicking "/ Commands" opens a popover anchored above the chip listing the slash commands
  for the agent running in the tab (Claude Code or opencode): name + one-line description,
  grouped "Built-in" / "Project" / "User" (/ "Skills" for Claude). Type-to-filter; ↑/↓ + Enter
  or click inserts `/<name> ` into the composer and focuses it; Esc closes.
- Built-in lists come from the real CLIs (captured from the installed claude / opencode —
  not guessed); custom ones are read from disk by a new Tauri command
  `list_slash_commands(agent, cwd)`: Claude — `<cwd>/.claude/commands/**/*.md`,
  `~/.claude/commands/**/*.md`, `~/.claude/skills/*/SKILL.md` (name + description
  frontmatter); opencode — `<cwd>/.opencode/command/*.md`, `~/.config/opencode/command/*.md`.
  Read-only, bounded (max 500 entries, max 64 KiB per file read), never follows symlinks out.

**AC**
- [ ] 4.1 Claude tab: popover lists built-ins + this machine's user/project commands and skills.
- [ ] 4.2 opencode tab: opencode's commands. 4.3 Selecting inserts `/<name> ` and focuses input.
- [ ] 4.4 Rust unit tests for the scanner (frontmatter, nesting, limits, missing dirs).

## 5. New agent dialog, rebuilt in the v0.4 design
- Same contract (`NewAgentSpec` → `onLaunch`), new UI built from tokens (no Tailwind neutral
  palette): agent type as a 3-option segmented control (Claude Code · opencode · Terminal);
  workspace field with a dropdown of known workspaces/recent folders + browse; permission
  mode select for Claude (manual / accept edits / plan / auto / bypass) mapped to the right
  CLI flags, opencode's own auto flag; branch (optional, "creates an isolated worktree"
  helper text); initial prompt textarea; files as removable chips; "Advanced" disclosure
  showing the exact command that will run (editable). ⌘Enter launches, Esc closes, focus
  trapped, first field focused. Validation: workspace must exist (inline error).
- Title "New agent" / "New terminal" follows the type.

**AC**
- [ ] 5.1 Launching each type opens the right tab with the right command (verified live).
- [ ] 5.2 The dialog uses only design tokens; `grep` hex clean; matches both themes.
- [ ] 5.3 Tests: type switch, mode→flag mapping, validation, ⌘Enter, Esc.

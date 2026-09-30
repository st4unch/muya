# Mini-PRD — Claude status data in the footer (user-picked fields)

Operator request 2026-09-30: every field from https://code.claude.com/docs/en/statusline#available-data
should be available in Muya, and the user adds them one by one to the bottom bar (where
"Muya vX" is). Must be PC-agnostic (no operator paths, no extra tools like jq).

## 1. Capture (Rust)
- At startup Muya creates a per-instance dir `<temp_dir>/muya-status-<pid>/` (0700) with:
  - `tap.sh` — POSIX sh: copies stdin to `$MUYA_STATUS_FILE` (atomic tmp+mv), then, if
    `user-statusline.sh` exists, runs it with the same JSON on stdin so the user's own
    status line still renders in the terminal.
  - `user-statusline.sh` — the user's `statusLine.command` from `~/.claude/settings.json`,
    verbatim (only when they have one).
  - `settings.json` — `{"statusLine":{"type":"command","command":"sh '<dir>/tap.sh'"}}`
    (+ the user's `padding` / `refreshInterval` if set).
- Every PTY gets `MUYA_STATUS_FILE=<dir>/<pty-id>.json`.
- Commands: `statusline_settings_path() -> Option<String>`,
  `statusline_get(pty_id) -> Option<Value>` (≤ 256 KiB, parsed JSON, None if absent/bad;
  pty_id validated `^pty-\d+$`).
- Quit removes the dir; startup sweeps `muya-status-<pid>` dirs whose pid is dead.

## 2. Launch (frontend)
- Every `claude` Muya launches (initialCommand, resume `cd X && claude --resume …`,
  "Open Claude here") gets `--settings '<settings path>'` right after `claude` —
  not for subcommands (`claude agents`, `claude attach …`, `claude mcp …`).
- A `claude` the user types by hand in a shell is not captured (footer says so).

## 3. Footer
- A "+" icon button left of the version opens a picker: every documented field, grouped
  (Model · Context · Cost & time · Rate limits · Session · Workspace & git · Pull request ·
  Worktree · Prompt cache · Modes), each with a human label and a live preview value.
- Checked fields appear in the footer (in the order added) for the SELECTED session,
  formatted for humans ($0.12, 4m 15s, 42%, "resets 18:30", +156/−23 lines, …); a field
  the session doesn't have (absent/null) is simply not shown. Right-click a footer item or
  uncheck to remove. Persisted in localStorage.
- Non-Claude tab / no data: the chosen fields are hidden; the picker explains why.
- Polls `statusline_get` for the selected tab every 2 s (only while fields are chosen).

## AC
- [ ] 1 A Claude session launched from Muya writes its JSON; `statusline_get` returns it.
- [ ] 2 The user's own terminal status line still shows inside Muya tabs.
- [ ] 3 No operator path in shipped code; works with HOME containing spaces; no jq.
- [ ] 4 Picker lists every documented field; add/remove one by one; persisted.
- [ ] 5 Footer never wraps; values truncate with ellipsis; both themes; tokens only.
- [ ] 6 Rust tests (script/settings generation, quoting, id validation, sweep); vitest
      (command transform, formatters, picker).

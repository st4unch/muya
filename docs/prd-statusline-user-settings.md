# Mini-PRD — Status bar data without `--settings` on every launch

## 1. Problem
Muya starts every Claude session as `claude --settings <temp>/settings.json …` only to read Claude's
status JSON (model, context, cost, limits) for its footer. Operators ask why each session "needs
Muya's settings"; a `claude` typed by hand gets no footer data; the temp file must be rebuilt when
macOS clears the temp folder.

## 2. Scope
- Muya keeps its tap script at a stable per-user place:
  `~/Library/Application Support/com.staunch.muya/statusline/tap.sh` (no installer — written by the
  app on start).
- Muya points `statusLine.command` in `~/.claude/settings.json` at it, once:
  `f='<tap>'; [ -f "$f" ] && exec sh "$f"; <the user's own command, if any>` — if Muya is ever
  removed the user's own status line still runs. Other `statusLine` keys (padding, refreshInterval)
  and every other key in the file stay as they are. Atomic write; a backup of the original file is
  kept next to the tap (`settings.before-muya.json`).
- The user's own command is saved (`user-statusline.sh`) and chained by the tap, so their terminal
  status line looks the same. If they later set another `statusLine`, Muya re-wraps it on its next
  start (theirs keeps running).
- The tap writes to `$MUYA_STATUS_FILE` only when set — Muya sets it on every PTY — so any
  `claude` inside Muya (button or hand-typed) feeds the footer; outside Muya nothing changes.
- With that in place `statusline_settings_path` returns nothing and no `--settings` flag is added.
  If the write fails (unwritable file, invalid JSON) the old per-launch `--settings` path is used.
- Settings row "Claude status in Muya's footer" (on by default). Off → the user's original
  `statusLine` is put back (or the key removed) and Muya adds no flag.

## 3. Acceptance criteria
- AC1: install into a fake HOME with/without a user statusLine and with other keys: keys preserved,
  command wraps theirs, re-run is a no-op, backup written once — cargo test.
- AC2: running the installed command with `MUYA_STATUS_FILE` set stores the JSON and prints the
  user's line; without it prints the user's line only; with the tap deleted prints the user's line
  — cargo test (real `sh`).
- AC3: turning it off restores the original `statusLine` exactly — cargo test.
- AC4: a launch command has no `--settings` when installed — vitest; settings row screenshots dark
  + light (`?mock=1`).
- AC5: full suites pass.

## 5. Integration
- `src-tauri/src/statusline.rs` (`TAP_SH`, `init`, `statusline_settings_path`, `status_file_for`),
  `src-tauri/src/pty.rs` l.188 (`MUYA_STATUS_FILE` per PTY), `src/lib/statusline.ts`
  `applyLaunchFlags` (unchanged: no path → no flag).
- Pref stored in `~/.claude/muya-app.json` (`src-tauri/src/app_prefs.rs`).
- Same `~/.claude/settings.json` writer as `docs/prd-session-housekeeping.md` (C).

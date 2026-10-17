# Mini-PRD — Session housekeeping (plans A + B + C)

## 1. Problem
Claude Code keeps every session as `~/.claude/projects/<project>/<id>.jsonl` (+ a `<id>/` folder for
subagents and tool output). They pile up and single sessions grow huge (201 MB measured on the
operator's Mac). Muya gets slower, Claude resumes big sessions slowly, and nobody notices: Muya
shows no sizes and offers no way to clean up.

## 2. Scope
**A — Muya stays fast whatever is on disk**
- `read_session_transcript` reads from the END of the file (growing window) until it has the newest
  `max_messages` turns; never the whole file. Same output as today.
- `list_session_history` caches each transcript's `cwd` with its name (`NameScan`), so an unchanged
  file is only `stat`-ed on refresh. Each entry also reports `extraBytes` (its `<id>/` folder).

**B — Sessions screen shows it and cleans up**
- A strip above "Past sessions": `N sessions · X GB · K older than 30 days · L over 100 MB` and a
  **Clean up…** button. Amber when total > 2 GB or any session > 100 MB.
- Clean-up dialog (modalKit): filter "older than [30] days" / "larger than [100] MB", a checkable
  list (name, folder, size, age), and two actions: **Archive** (moves the files to
  `~/Library/Application Support/com.staunch.muya/session-archive/`, same layout, restorable) and
  **Move to Trash**. An **Archived** tab lists archived sessions with **Restore** and **Move to Trash**.
- Each past-session row gets Archive / Move to Trash in a "…" menu.
- Safety: the backend refuses a transcript changed in the last 10 minutes or listed as live
  ("in use"), and only touches `.jsonl` + its `<id>/` folder under `~/.claude/projects`
  (`checked_transcript_path`). Archive and restore are `rename`s (same disk, instant).

**C — Automatic retention + a heads-up**
- Settings row "Delete Claude sessions after" `[7 · 14 · 30 · 60 · 90 · 180 · 365 days]`: writes
  `cleanupPeriodDays` into `~/.claude/settings.json` (Claude itself deletes older sessions at
  startup; its default is 30). Other keys untouched, atomic write, one backup kept.
- Heads-up: once per day at most, when the strip would be amber, a toast "Claude sessions use 2.4 GB
  — Clean up" that opens the Sessions screen.

Not in scope: compacting a running session, editing transcripts, opencode sessions.

## 3. Acceptance criteria
- AC1: tail reader returns the same messages as the full read for a test transcript (incl. a line
  longer than the first window) — cargo test.
- AC2: archive → file gone from projects and present in archive; restore → back; live/recent
  transcript refused; path outside `~/.claude/projects` refused — cargo test with a fake HOME.
- AC3: `cleanupPeriodDays` write keeps other keys and comments-free JSON valid; missing file created
  — cargo test.
- AC4: strip numbers + dialog filtering — vitest; `?mock=1` Playwright dark + light screenshots of
  strip, dialog, settings row.
- AC5: `cargo test --lib`, `npx tsc --noEmit`, `npm test -- --run` pass.

## 5. Integration
- `src-tauri/src/history.rs` l.155 `list_session_history`, l.256 `read_session_transcript`,
  l.131 `checked_transcript_path`, l.91 name cache.
- `src/components/SessionsPage.tsx` l.114 `refresh`, history rows ~l.398; live ids from
  `list_agent_sessions` (same refresh).
- Settings: `src/components/SettingsModal.tsx` rows + `modalKit.tsx`.
- `~/.claude/settings.json` writer shared with `docs/prd-statusline-user-settings.md`.
- Trash: `NSFileManager trashItemAtURL` via `objc2-foundation` (already a dependency).
- Commands registered in `src-tauri/src/lib.rs`; mocks in `src/mock/installMock.ts`.

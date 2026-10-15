# Mini-PRD — Activity: files the agent read and changed

## 1. Problem
The Inspector's Activity tab only shows worktree collision telemetry. The operator wants to
see which files the agent in the selected session opened and modified, and open one with a click.

## 2. Scope
- For the selected terminal tab's Claude session, list files from its transcript:
  **Modified** (Edit, Write, MultiEdit, NotebookEdit) and **Read** (Read). A file both read
  and changed is listed once, under Modified. Newest first, with a touch count.
- Click a row → the file opens in Muya (same `openFile` as the file tree).
- Refresh every 4 s while the Activity tab is open; parsing is incremental (only new bytes).
- Not in scope: files touched through Bash (`sed`, `>`), codex/opencode sessions, other tabs.

## 3. Acceptance criteria
- AC1: Rust `touched_files` collects Read vs modified tool uses, relative paths joined to the
  cwd, modified wins over read, newest first — covered by unit tests.
- AC2: Incremental read: a transcript that grows is parsed from the last offset; a partial last
  line is not consumed; a shrunk file is re-read from 0 — unit test.
- AC3: The path goes through `history::checked_transcript_path` (transcript trust boundary).
- AC4: Activity tab shows both groups for a Claude tab, a hint for a non-Claude tab; a row click
  calls `onOpenFile` with the absolute path (vitest) and renders in dark and light (`?mock=1`).
- AC5: `cargo test --lib`, `npx tsc --noEmit`, `npm test -- --run` pass.

## 5. Integration
- Transcript location: `sessions::transcript_path` (sessions.rs:46); Claude's dir encoding is
  not always `/`→`-`, so fall back to `~/.claude/projects/*/<id>.jsonl`.
- Tool-use parsing pattern: `sessions::line_text` (sessions.rs:60).
- Active tab: `selectedTab` / `selectedCwd` in App.tsx:1791; `sessionId`/`sessionCwd` on the tab model (App.tsx:100).
- Open: `openFile` (App.tsx:793). Panel: `src/redesign/ActivityPanel.tsx`, built at App.tsx:2579.
- Mock: `src/mock/installMock.ts` `handleInvoke`.

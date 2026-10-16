# Mini-PRD — Local file versions + auto-save

## 1. Problem
Files edited in Muya's editor have no history: an unsaved edit or an overwrite is gone. The operator
wants every version kept automatically (no git commit needed), an auto-save option, and the versions
of the file in view listed in Activity, reachable from the File menu.

## 2. Scope
- **Versions (local, automatic).** Each version is a full copy of the file's text, stored under
  `~/.claude/muya-file-history/<sha256(path)>/` (dir 0700, files 0600), never inside the project.
  A version is taken when the file is **opened**, when its text **pauses** for 3 s after an edit
  (unsaved "draft"), when it is **saved**, and right **before a restore**. Same text as the newest
  version → nothing new. Kept: last 100 per file. Files over 2 MB, and secret-looking files
  (`.env*`, `*.pem`, `*.key`, `*.p8`, `*.p12`, `id_*`), are never copied.
- **Auto-save (Settings → Editor, off by default).** When on, an edited file is written to disk
  1 s after typing stops (no auto-format, so the caret never jumps); ⌘S still saves and formats.
- **Activity → VERSIONS.** When the editor shows a file, Activity lists its versions newest first:
  time, kind (opened / draft / saved / before restore), size. Clicking one opens the Review dialog
  on the versions (that version vs the file on disk now, Prev/Next across versions) with
  **Restore this version**: saves the current disk text as a version, then writes the old one.
- **File ▸ Version History (⌥⌘H)** opens the same dialog for the file in view and switches
  Activity to it.
- Not in scope: binary files, sync between machines, history for files changed outside the editor
  (agents' edits show up as the next "opened"/draft version only when the file is open in Muya).

## 3. Acceptance criteria
- AC1 (Rust, cargo test with temp HOME): snapshot skips unchanged text, too-large and secret files;
  list is newest first; read returns the text; prune keeps 100; ids/paths are validated.
- AC2: `autoSave` pref load/save + FileEditor saves 1 s after an edit when on, not when off — vitest.
- AC3: ActivityPanel shows VERSIONS for `activeFile` and a click calls `onOpenVersion` — vitest.
- AC4: `?mock=1`: open a file, Activity shows versions, click → dialog shows a diff and Restore;
  Settings shows the Auto-save switch — Playwright dark + light screenshots.
- AC5: File menu has "Version History" (native menu, checked in a dev build's AX tree) and the
  `menu:version-history` event opens the dialog.
- AC6: `cargo test --lib`, `npx tsc --noEmit`, `npm test -- --run` pass.

## 5. Integration
- Save path: `src/components/FileEditor.tsx` `save()` l.~140, load `doLoad` l.~95, Monaco onChange l.~280.
- Rust: new `src-tauri/src/file_history.rs`; `write_private` pattern `term_history.rs` l.75; register in
  `src-tauri/src/lib.rs` invoke_handler; File menu `lib.rs` l.193-243 + `on_menu_event` l.350.
- Pref pattern: `src/lib/autoApprove.ts`; Settings Switch rows `src/components/SettingsModal.tsx` l.258-320.
- Activity: `src/redesign/ActivityPanel.tsx` (props l.18, AGENT FILES l.97), rendered `src/App.tsx` (activitySlot).
- Dialog: reuse `src/components/ReviewChanges.tsx` (add an optional action button + per-file language path).
- Data dir convention: `~/.claude/muya-*` (schedules.rs, term_history.rs).

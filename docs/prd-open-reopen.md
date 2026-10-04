# Mini-PRD — Find files on this Mac, ⌘O, ⌘⇧T

## 1. Problem
Opening a file that isn't already open or in a workspace means going through Finder.
A tab closed by mistake (⌘W) is gone; a closed Claude tab loses its place.

## 2. Goal
- **T2** The ⌘K palette also lists matching files from the whole Mac (Spotlight,
  by file name, like Finder's search). Picking one opens it in Muya.
- **T3** File → Open… (⌘O) shows the macOS open dialog. The chosen files open in Muya.
- **T4** File → Reopen Closed Tab (⌘⇧T) brings back the last closed session, terminal
  or file, newest first. A Claude tab comes back in its own conversation
  (`claude --resume <id>`), an SSH tab reconnects, a terminal reopens in its folder,
  and a file reopens in its viewer.

## 3. Out of scope
Searching inside file contents, folders as results, and a closed-tab history that
survives a restart (the history lives in memory and is capped at 20).

## 4. Acceptance criteria (binary)
- AC1 `spotlight_search(query)` returns at most 50 existing regular files whose name
  contains the query (case-insensitive). Files under a workspace root come first,
  then $HOME. Hidden paths (any `/.` component) and `~/Library` are excluded.
  Queries shorter than 2 characters return [].
- AC2 The query reaches `mdfind` as a single argv entry (`-name`), never through a
  shell. mdfind is stopped after 400 lines or 3 s.
- AC3 In the palette, typing ≥2 characters shows an "On this Mac" group after a
  ~200 ms pause. Enter on a result opens it via `openFile` (same viewer routing).
  Results already listed under Files are not repeated.
- AC4 The File menu has "Open…" (⌘O). The dialog allows multiple files, starts in
  the selected workspace, and each chosen file opens via `openFile`.
- AC5 The File menu has "Reopen Closed Tab" (⌘⇧T). After closing a Claude tab with a
  sessionId, a terminal, and a file, three presses reopen file → terminal → Claude,
  in that order. The Claude tab runs `claude --resume <its id>` in its session folder.
  With an empty history, nothing happens.
- AC6 tsc, vitest, cargo test and `npm run build` are green; no operator paths.

## 5. Integration (evidence)
- Palette: `src/redesign/CommandPalette.tsx` (cmdk) is rendered at App.tsx ~2350 with
  `paletteFiles`/`paletteFileMap` (App.tsx:1858). `openFile` is at App.tsx:778.
- Native menu: `src-tauri/src/lib.rs:115-170` builds File with New File/Close Tab.
  `on_menu_event` emits `menu:*` (lib.rs:258), and App.tsx listens with `listen`
  (the `menu:new-file` pattern).
- Dialog: `tauri_plugin_dialog` is already registered (lib.rs:102) and the capability
  `dialog:default` already exists. `saveDialog` is already used for New File.
- Closing: `closeTerminal` (App.tsx:793) is the single close path for ⌘W, the × button
  and MCP closes.
- Reopening semantics: same as `duplicateTerminal` (App.tsx:~735), using
  `resumeCommand` and `newSshTabKey` (src/lib/tabs.ts).
- Rust command pattern: `#[tauri::command]` registered in `generate_handler!`
  (lib.rs:303).

## 6. Protection list
⌘W close behaviour (dirty-file prompt, ssh/agent release), the ⌘K palette's
existing groups, ⌘N, session restore, resume on launch.

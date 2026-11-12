# PRD (mini): Large files open without freezing Muya

## 1. Problem
Operator opened a ~3 MB file on another Mac and Muya froze. Measured (WebKit, the
engine Muya renders with, harness `scripts/bigfile/`): the Markdown preview parses + sanitises
the whole file and injects it as one DOM blob — 1.5 s UI freeze at 3 MB, 2.8 s at 5 MB on a
fast Mac (a slower Mac is several times worse). Files above 5 MB are refused with a bare error.
The editor itself survives plain 3–5 MB text, but nothing stops it from running full
tokenization / bracket colouring / wrap / diff on big or binary-ish files, and the whole text
is always sent through IPC.

## 2. Goal
Opening any file never blocks the window. Thresholds (VS Code style):
| Size | Text file | Markdown |
|---|---|---|
| < 1 MB | unchanged | rendered preview (< 512 KB) |
| 1 – 8 MB | editor in **large-file mode** (plain text, no minimap/wrap/folding/bracket colours/diff) + banner | opens as text in large-file mode (no render) + banner |
| > 8 MB | prompt: *Open anyway* (first 8 MB, read-only) / *Open in default app* | same |
| binary (NUL in first 8 KB) | never loaded: "isn't text" + *Open in default app* | same |

## 3. Scope
- Rust: `file_probe(path)` (size + binary guess, reads ≤ 8 KB) and `read_file_prefix(path, max)`.
  Both `#[tauri::command(async)]` (off the UI thread).
- `src/lib/largeFile.ts`: pure `decideOpen()` + Monaco option sets (unit-tested).
- `FileEditor`, `MarkdownView`: probe first, then dispatch.
- No change to image/PDF viewers (already byte-capped at 100 MB, rendered by the browser).

## 4. Out of scope
Streaming/virtual file reading, editing >8 MB files, hex viewer.

## 5. Integration (evidence)
- Dispatcher: `src/App.tsx` `openFile` → `viewerKindFor` (src/lib/format.ts:35) — unchanged; gating is inside the viewers so every entry point (tree, palette, Files page, drag-drop, Open With) is covered.
- Existing `read_file` 5 MB cap (src-tauri/src/fs.rs) stays for other callers (versions, review).
- UI: tokens only (`var(--…)`), no modal needed (inline panel), English text.

## 6. Acceptance criteria
1. `decideOpen` unit-tested for every row above incl. boundaries.
2. 3 / 10 / 50 MB samples (lines, one long line, json, log, md, binary) open with worst UI frame gap < 150 ms.
3. Normal (< 1 MB) files behave exactly as before (existing tests green).
4. cargo test --lib, tsc, vitest, vite build all green.

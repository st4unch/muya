# Mini-PRD — Terminal Path Links (clickable/actionable paths in terminal output)

**Status:** Implemented (2026-07-16) — all ACs met
**Owner:** staunch · **Implementer:** Claude Code
**Depends on:** current code (grounding below)

## 1. Goal
When a filesystem path appears in a terminal's output, let the user hover it (underlines, cursor: pointer) and click it to get an action menu — Open in Muya, Reveal in Finder, Copy Path, and Open Terminal Here (for directories). Removes the copy-paste friction of acting on paths the CLI prints.

## 2. Non-goals
- Not a full URL/link handler (there's no web-links addon today; scope is filesystem paths only; `http(s)://` links out of scope for this PRD).
- Does not track a terminal's *live* cwd across `cd` — relative paths resolve against the terminal's spawn cwd (the `cwd` prop). Absolute/`~` paths always work.
- No inline preview; actions reuse existing open/reveal flows.

## 3. Integration (grounded)
- **xterm instance:** `src/components/Terminal.tsx:106` (`new XTerm({...})`). Register a custom link provider via `term.registerLinkProvider(...)` after `term.open(el)` (line 116). Addons already loaded: fit, webgl, search — no new npm dep needed (link provider is core xterm API).
- **Open in Muya:** `openEditor(filePath)` — `src/App.tsx:308` (Monaco for code, markdown viewer for `.md`). Passed into Terminal as a new callback prop.
- **Reveal in Finder:** existing Tauri command `reveal_in_finder(path)` — `src-tauri/src/fs.rs:513`.
- **Open Terminal Here:** `openTerminal({cwd})` — `src/App.tsx:292`; passed as a callback.
- **Path resolution + kind:** add a Tauri command `resolve_path_kind(path, cwd) -> {resolved, kind}` where `kind ∈ {"file","dir","none"}`, expanding `~` and joining relative paths onto `cwd`. Registered in `lib.rs` `generate_handler!`. Reuses `validate.rs` path hygiene.
- **Context menu:** mirror the FileTree menu pattern (`FileTree.tsx` MenuItem) — a small fixed-position menu at the click coords.

## 4. Detection rules
- Regex-match candidates in each rendered line: absolute (`/…`, `~/…`) and relative-looking tokens (contain `/` or end in a common extension). Windows paths out of scope (macOS-first).
- A candidate becomes an active link **only after** `resolve_path_kind` confirms it exists (`kind != "none"`). Non-existent tokens are not linkified (kills false positives).
- Trailing punctuation (`.`, `,`, `:`, `)`) is trimmed from the match.

## 5. Acceptance criteria
- **AC-1:** Hovering an existing absolute path in terminal output underlines it and shows a pointer cursor; a non-path token does not.
- **AC-2:** `resolve_path_kind` returns `file`/`dir`/`none` correctly for: an absolute file, an absolute dir, a `~/…` path, a relative path joined to cwd, and a non-existent path. (Rust unit tests.)
- **AC-3:** Left-clicking a linked path opens an action menu at the cursor with: Open in Muya, Reveal in Finder, Copy Path; and additionally Open Terminal Here when the path is a directory.
- **AC-4:** "Open in Muya" on a file calls `openEditor(resolved)`; "Reveal in Finder" calls `reveal_in_finder(resolved)`; "Copy Path" writes the resolved path to the clipboard; "Open Terminal Here" (dir) calls `openTerminal({cwd: resolved})`.
- **AC-5:** Right-clicking a linked path opens the same menu (does not fall through to the terminal's native/paste behavior for the link).
- **AC-6:** A relative token that does not resolve to an existing path is NOT linkified and behaves as plain text.
- **AC-7:** `cargo test` + `npx tsc --noEmit` + `npm test` all green; existing terminal behavior (typing, Enter, scroll, selection) unchanged.

## 6. Risks
- False-positive linkification → mitigated by existence-check before linkify (AC-6).
- Live-cwd drift for relative paths → documented non-goal; absolute paths unaffected.
- Perf: existence-check per candidate. Mitigate by only checking on hover-provide (xterm calls the provider lazily per viewport line), debounced, and caching resolved results briefly.

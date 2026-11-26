# Mini-PRD addendum: Terminal Path Links in Muya Native

**Status:** Implemented on `feat/term-path-links` · **Base:** `docs/prd-terminal-path-links.md` (classic; read it first)

## 1. Goal
Bring classic's "terminal path links" to Muya Native with classic's behaviour and nothing new: hover a file or folder path printed
in the terminal and it underlines; click or right-click it for the same menu (header with 📁/📄 and the basename, then
Open in Muya (files) / Open Terminal Here (folders), Reveal in Finder, Copy Path).

## 2. Decisions
- Detection is classic's regex and trim, ported exactly (`Terminal.tsx:252`, trim at `:280`): `(?:~/|\.{0,2}/)[^\s"'<>|()]+|[\w.\-]+/[^\s"'<>|()]+`, trailing `[.,:;)\]]+` removed. No `line:col`, no URLs: `foo.ts:42` stays one token and fails the stat.
- A token is a link only if it resolves to an existing file or folder (classic `resolve_path_kind`, `native/crates/muya-core/src/fs.rs:710`). Native resolves locally with `FileManager`, since the pty runs on this Mac: `~/` against the app's home, a relative token against the session's CURRENT directory (`SessionModel.currentDirectory(of:)`, `Model.swift:76`, better than classic's spawn cwd). Cache keyed by (cwd, token), bounded at 2000 like classic; the stat runs off the main thread and only once per token while the pointer stays on it.
- Hover: underline plus pointing-hand cursor, no modifier, no tooltip. The underline is drawn by the renderer as a per-cell flag (the same flag SGR underline uses), not as a selection. It clears when the pointer leaves the token or the view, on scroll, on session switch and when the window loses key.
- Open the menu on mouse UP when the press started on the link and no drag left that cell (selection and drag untouched), and on right-click over a link instead of the normal context menu. A program that grabbed the mouse (`replica.mouseTracking`) owns the click unless Shift is held (`MouseRoute`, same rule as selection).
- Actions reuse Native's code: Open in Muya = `MainController.openViewer` (what the file tree's Open calls); Open Terminal Here = `store.spawn(cwd:)` via `PathActions.terminalDirectory` (the tree's "Open in Terminal Here"); Reveal in Finder = `NSWorkspace.activateFileViewerSelecting`; Copy Path = the resolved path on the pasteboard.
- The existing terminal context menu is untouched for anything that is not a link.

## 3. Integration points
- `native/app/Sources/Logic/TerminalPathLinks.swift`: detection, trim, resolve, kind, menu titles/header, cache (pure, unit-tested).
- `native/app/Sources/App/Replica.swift` `rowCells(_:)`: one viewport row as cells (a wide character's second cell is "").
- `native/app/Sources/App/Renderer.swift` `link`: per-cell underline; row cache is invalidated when it changes (like `selectionVersion`).
- `native/app/Sources/App/TerminalView.swift`: tracking area, `mouseMoved`/`mouseExited`, `hover(col:row:)`, `resetCursorRects`, press/drag/up handling, `menu(for:)`, `pathMenu`, `runPathAction`.
- `native/app/Sources/App/UI.swift` `wireTile`: `onOpenFile`, `onTerminalHere` (same bodies as the file tree's `onOpen`/`onTerminalHere`).
- Debug socket (MUYA_TEST_HOOKS builds): `term-link`, `term-link-hover`, `term-link-state`, `term-link-menu`, `term-link-capture`, `term-link-run`; `mouse move|right`.
- Tests: `native/app/Tests/TerminalPathLinksTests.swift`; live check `native/app/verify-path-links.sh`.

## 4. Acceptance criteria (mirror classic AC-1..AC-7)
- **AC-1:** Hovering an existing absolute path in terminal output underlines it and shows the pointing hand; a non-path token or a path that does not exist does not. (`verify-path-links.sh` hover checks.)
- **AC-2:** Resolution returns file / dir / none for an absolute file, an absolute folder, a `~/` path, a relative path joined to the session's current directory, and a missing path. (Unit tests + script P1-P8.)
- **AC-3:** A click (press and release on the link, no drag) opens the menu: file = header, Open in Muya, Reveal in Finder, Copy Path; folder = header, Open Terminal Here, Reveal in Finder, Copy Path. A click on text, a missing path or after a drag opens none.
- **AC-4:** Open in Muya opens the file in the viewer; Open Terminal Here starts a session in that folder; Reveal in Finder selects it in Finder; Copy Path puts the resolved path on the pasteboard.
- **AC-5:** Right-click on a link opens the same menu; right-click elsewhere keeps the normal terminal menu, item for item.
- **AC-6:** A token that does not resolve (including `foo.ts:42`) is not linkified and behaves as plain text.
- **AC-7:** `native/app/build.sh test` passes with zero failures; `verify-path-links.sh` passes; typing, selection, scroll, find and mouse reporting behave as before (a program tracking the mouse gets the click unless Shift is held).

## 5. Known limits (as classic)
- A path wrapped over two screen rows is not joined; `folder/` with nothing after the slash is not matched by classic's regex; the underline of a row whose text changes under a still pointer refreshes when the pointer moves.

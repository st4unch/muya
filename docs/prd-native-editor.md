# Mini-PRD: full file editor in Muya Native

- Date: 2026-11-19
- Type: mini-PRD
- Operator request (2026-11-16): "bütün geliştirmeler muya native için olacaktır. tam düzenleyici eklenmesi gerekiyorsa eklensin."

## 1. Problem
Native's Files page shows text in a read-only `NSTextView` (`native/app/Sources/App/Viewers.swift`, "INTERIM: the real code editor
component is still awaiting an operator decision on a package"). Classic edits files in Monaco (`src/components/FileEditor.tsx`).
An operator on Native cannot fix a typo in a config an agent wrote. Classic gets no change and no release.

## 2. Scope
- In: an editor in the Files viewer with classic's behaviour (inventory below), engine chosen by measurement (ADR), unit tests, a perf
  script with budgets, a live run in a dev build on a fake HOME.
- Out: classic changes; releasing (this PRD stops at the dev-build proof); multi-cursor / code folding / IntelliSense / formatters
  (classic has them only through Monaco; listed as gaps in the summary); local file *versions* store (`file_history`, see §4 AC-V).

## 3. Inventory of classic's editor (what "parity" means)
Read from `src/components/FileEditor.tsx`, `monacoSetup.ts`, `src/lib/format.ts` (LANG), `fileVersions.ts`, `largeFile.ts`, `src-tauri/src/fs.rs`.

| # | Classic behaviour | Evidence | Native plan |
|---|---|---|---|
| 1 | Open: `read_file` (UTF-8 only, 128 MB cap); non-UTF-8 -> "isn't text, Open in default app" | FileEditor.tsx:300-318, fs.rs `read_file` | same refusal -> existing "other" view with Open With |
| 2 | Edit + Cmd+S save (`write_file`); Save button disabled when clean | FileEditor.tsx:127-142, 233-239 | `EditorDocument.save` (atomic temp+rename, keeps mode/symlink/BOM/EOL) |
| 3 | Dirty "● unsaved" indicator, set on any edit, cleared on save/reload | FileEditor.tsx:213 | same flag semantics; dot also in the Open Files list |
| 4 | Unsaved-changes guard on close (`confirmDialog`) | App.tsx:821-828 | NSAlert Save / Don't Save / Cancel on close tab, close from list, quit |
| 5 | Wrap toggle | FileEditor.tsx:216-230 | header button |
| 6 | Map (minimap) toggle | FileEditor.tsx:231-245 | header button + custom minimap view |
| 7 | Diff toggle: HEAD vs buffer, read-only, side-by-side (`DiffEditor renderSideBySide`; untracked -> empty) | FileEditor.tsx:60-72, 270-290 | side-by-side with aligned rows and synced scroll; unified only under 700 px (Monaco's own inline fallback) |
| 8 | Syntax highlighting per language (LANG table: ts tsx js jsx json rs md py css scss html sh bash toml yaml go sql) | format.ts:17-25 | own scanner, the same set plus swift/c/java/ruby/xml; Monaco vs / vs-dark colours |
| 9 | Find / replace (Cmd+F / Cmd+Opt+F), go to line (Ctrl+G), undo / redo, bracket-pair colours + matching, indentation folding (chevrons on hover), multi-cursor (Opt-click, Cmd+D) | Monaco defaults | system find bar (+replace), go-to-line sheet, NSUndoManager; own bracket depth colours, match box, hidden-glyph folding with gutter chevrons, own multi-caret editing |
| 10 | Multiple open files (one view at a time, dirty state per file, switching keeps edits) | App.tsx dirtyTabs | `EditorSession` per path, kept while open |
| 11 | External change on disk: reload when clean, "changed on disk - reload" badge when dirty, own save is not a change | FileEditor.tsx:86-124, 177-187 | FSEvents on the parent folder + `DiskStamp`; plus save-time conflict prompt (classic overwrites silently) |
| 12 | Large files: full features to 50 MB, plain to 128 MB, prompt above, long-line guard | docs/large-file-measurements.md | `EditorFeatures.decide` (same thresholds) |
| 13 | Markdown: `.md` opens rendered (`mdview`) | format.ts `viewerKindFor` | rendered view stays default; "Edit" switches to the editor |
| 14 | Images / PDF | viewerKindFor | already native (PDFKit / NSImageView), unchanged |
| 15 | Auto-save (Settings, 1 s after typing stops) | FileEditor.tsx:145-175 | honours the existing `muya.autoSave` pref |
| 16 | Font JetBrains Mono 12, theme follows app | FileEditor.tsx options | same font; Monaco palettes per appearance |
| 17 | Format-on-save (Monaco formatter, JSON/CSS/HTML/TS only) | FileEditor.tsx:132 | gap (no formatter library) |
| 18 | File versions snapshot on open/save/draft (`file_history_*`) | fileVersions.ts | gap (not in Native yet; own PRD) |

## 4. Engine decision (ADR)
Constraints: Native links no WebKit (`docs/prd-native-rewrite.md` AC15, `otool -L` + `vmmap`); builds with plain `swiftc`, no SwiftPM / external
packages (`native/app/build.sh`); closed-source app, so no copyleft code; "quality over speed of delivery".

| Option | Licence / maintenance | Build impact | Measured |
|---|---|---|---|
| (a) NSTextView (TextKit 1 or 2) + own windowed highlighter | system framework | none | table below |
| (b) CodeEditSourceEditor / CodeEditTextView | MIT, active (pushed 2026-10-18; tree-sitter based) | needs SwiftPM + ~15 grammar packages; breaks the plain-swiftc build | see below |
| (b') STTextView (the PRD's original pick) | GPL-3.0 or commercial licence (`LICENSE.md`) | SwiftPM | **rejected on licence** before measuring: closed-source app, paid licence = operator decision |
| (c) Monaco in WKWebView | MIT | WebKit + a bundled 5 MB editor | classic numbers (`large-file-measurements.md`): 20 MB JSON = 2 GB browser memory, 50 MB = 1.6-2.6 GB; violates AC15 |

Spike for (a): `native/app/measure-editor.sh` (standalone harness, real `SyntaxHighlight.swift`, windowed highlighting, window offscreen), JSON fixtures
from `make-large-fixtures.py`. open = read + set text + first paint; type = median of 40 key inserts incl. re-highlight and repaint.

| File | Engine | open ms | highlight whole-file pass (background) | window highlight ms | typing median ms | RSS MB |
|---|---|---|---|---|---|---|
| JSON 3 MB | TextKit 1 | 19 | 5 ms | 0.1-0.4 | 2.3 | 83 |
| JSON 20 MB | TextKit 1 | 24 | 32 ms | 0.2-0.4 | 2.3 | 169 |
| JSON 50 MB | TextKit 1 | 33 | 84 ms | 0.2-0.4 | 2.3 | 322 |
| TS 20 MB | TextKit 1 | 23 | 36 ms | 0.5-2.1 | 2.1 | 169 |
| JSON 3 / 20 / 50 MB | TextKit 2 | 14 / 18 / 26 | 5 / 32 / 81 ms | 0.2-0.5 | 0.8 / 1.7 / 1.7 | 91 / 179 / 331 |

Findings that shaped the design (all measured in the spike):
- TextKit 1 *temporary attributes* cost O(file) on the first far-away call (112 ms at 20 MB, 280 ms at 50 MB); real attributes on the text storage do not (18 ms first, then < 0.5 ms). Highlight therefore writes real attributes in a window around the viewport.
- Real attributes keep memory flat: only the windows that were visited carry colour runs.
- TextKit 1 and 2 are within noise of each other; TextKit 1 has the longer track record for editing (`NSTextFinder`, non-contiguous layout, glyph-based minimap hit-testing), TextKit 2 is the system default. Decision: build the stack explicitly as TextKit 1 (the editor never asks the text view for a layout manager lazily), because the known TextKit 2 issues (viewport estimated height jumps on scroll in 100 MB documents) are the exact case the 128 MB tier serves.

**Decision: (a), TextKit 1, own scanner-based highlighter with per-256-line state checkpoints.** (b) is recorded below once measured; it cannot win on the build constraint alone (it would put a package manager into a build that has none), and (c) violates AC15.

**(b) CodeEditSourceEditor: NOT measured.** A SwiftPM package with it as the only dependency was resolved (checkouts: CodeEditTextView, CodeEditLanguages,
tree-sitter, SwiftLintPlugin, ...), then `swift build -c release` sat at 0 % CPU for 30 minutes (stalled on its binary grammar bundle / build-tool plugin
in a non-interactive shell) and was stopped. The decision does not rest on it: the build-system argument above already excludes it, and the shipped editor
meets every budget without it. Revisit only if the operator accepts SwiftPM + a vendored grammar bundle.

**Numbers of the shipped editor** (real view, dev build, `verify-editor.sh` AC9, 20 MB JSON, fake HOME): open + first paint 163 ms, RSS 313 MB, typing (insert +
edited-line recolour + repaint) median 7.7 ms (first key 125 ms while layout warms), scroll step (window move + repaint) median 4.3 ms. The spike's 2.3 ms typing figure
was optimistic: it skipped the line-number ruler and the checkpoint bookkeeping, and the first real build re-coloured a whole 8.5K-char window per key (53 ms)
because TextKit 1 re-lays-out whatever an attribute change touches; now only newly covered / edited lines are coloured.

## 5. Integration (evidence)
| Seam | Where | What changes |
|---|---|---|
| File read | Native reads in-process with `FileProbe` (`Logic/FileSafety.swift:8-60`: non-blocking open, regular-file check, head read); muyad has no file RPC (`crates/muyad/src/rpc.rs` has none; classic's `read_file` is Tauri-only) | editor uses `FileProbe` too; no daemon change |
| Viewer host | `ViewerPane.show(url, kind:)` (`Viewers.swift:79`) <- `MainController.openViewer` (`UI.swift:432`) <- Files tree `files.onOpen` (`UI.swift:373`), ⌘O (`Shortcuts.swift:112-126`), palette "Files", open-files list (`FrameWiring.swift:183`), reopen closed tab (`Shortcuts.swift:150`) | all keep calling `openViewer`; only `ViewerPane`'s text branch changes |
| Open-files list | `OpenFilesList.swift` (`paths`, `current`, `onClose`) | adds a dirty dot; `onClose` goes through the guard |
| Close tab | `ShortcutRouter.closeTab` (`Shortcuts.swift:129`), `closeViewer` (`UI.swift:438`) | ask first when dirty |
| Quit | `quitPressed` (`Shortcuts.swift:155`) + `applicationWillTerminate` (`main.swift:73`) | `applicationShouldTerminate` asks when any document is dirty |
| File watching | `DirectoryWatcher` (FSEvents, `FileTree.swift:11`) | reused, one per open document's folder |
| Settings | `muya.autoSave` (`Logic/PrefsLogic.swift:178`), `PageLogic.swift:455` row exists | editor reads it |
| Key routing | classic has no app-level ⌘S (Monaco binds it while focused); Native's menu puts Sessions on ⌘S (`main.swift`) | `Shortcuts.handle` (the key monitor) saves on ⌘S whenever a dirty file is on screen (`AppShortcuts.commandSSaves`, tested), else the menu's Sessions; the editor's `performKeyEquivalent` also takes ⌘F / ⌥⌘F / ⌘G / ⌃G / ⌘D while focused |
| Tests / build | `build.sh test` globs `Sources/Logic/*.swift` + `Tests/*.swift`; app builds `Sources/App/*.swift` | new pure logic in `Logic/`, view in `App/` |
| Protected (must not break) | terminal, split panes, Files tree, image / PDF / Markdown viewers, `viewer-open` debug hooks used by `verify-files*.sh` | regression: `verify-files.sh`, unit suite |

## 6. Acceptance criteria (binary)
- AC1: opening a text file shows it editable, highlighted by extension; typing marks it dirty; ⌘S writes it; the file on disk has the new bytes and the dirty mark clears.
- AC2: save keeps BOM, CRLF/CR line endings, file mode, and writes through a symlink; a crash-safe temp+rename write leaves no temp file.
- AC3: closing a dirty file (⌘W, the list's ×, quit) asks Save / Don't Save / Cancel; Cancel keeps everything; Don't Save discards.
- AC4: switching to another file and back keeps unsaved edits, scroll and selection.
- AC5: a clean open file reloads when it changes on disk; a dirty one keeps its text and shows "changed on disk - reload"; saving over a changed file asks (Overwrite / Reload / Cancel); our own save is not reported.
- AC6: Wrap, Map, Diff buttons work; Diff compares with git HEAD (untracked -> all added) and says so when git is missing / file too large.
- AC7: ⌘F find, ⌥⌘F replace, ⌃G go to line, ⌘Z / ⇧⌘Z undo / redo work in the editor.
- AC8: sizes: < 50 MB all features; 50 MB-128 MB editable without highlight / map / diff; > 128 MB prompt, "Open Anyway" shows the first 16 MB READ-ONLY; a line > 200 KB opens read-only, cut for display. A read-only document can never be saved.
- AC9: perf budgets (script): 20 MB JSON open+first paint < 500 ms, window highlight < 16 ms, typing key-to-paint median < 16 ms, RSS < 12 x file size + 100 MB at 20 MB.
- AC10: dark and light screenshots compared with classic's editor; no WebKit linked (`otool -L`, `vmmap`).

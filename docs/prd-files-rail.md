# Mini-PRD — Files rail + image/PDF viewing

Operator request 2026-10-01: "açılan dosyaları göremiyorum resim ve pdf desteği de getirir
misin. en sol tarafa files adında bir yer açalım Control'ün altına sessions'un üstüne
gelsin. orada files alanı olsun Agents gibi sol stünü gibi olsun açık olan dosyalar orada
olsun".

## Problem (measured, not assumed)
- PDFs show a blank white box: `PdfViewer` hands the file to WebKit's PDF plug-in via
  `<embed>`, which WKWebView does not run in a page (reproduced in WebKit, 2026-10-01).
- Images depend on the asset protocol scope (`allow_asset_path` → `allow_file`), which
  refuses paths under dot-folders by default; operator reports images not showing.
- Open files are invisible: `buildAgents` drops file tabs (`agentModel.ts:131`) and only
  ONE clean file tab is kept (`dropCleanFiles`), so there is no list of open files.

## Scope
1. **Bytes, not asset URLs.** New Rust command `read_file_bytes(path)` → raw bytes
   (`tauri::ipc::Response`, no JSON/base64), regular files only, ≤ 200 MB, same macOS
   permission message as `read_file`. Images render from a `blob:` URL (CSP `img-src`
   gains `blob:`). PDFs render with pdf.js (`pdfjs-dist`, legacy build, lazy-loaded,
   `isEvalSupported: false`): every page drawn to a canvas, fit-to-width, zoom −/+,
   page count; pages render when scrolled near.
2. **Files rail item** between Control and Sessions. It shows the Control layout with
   the left column listing OPEN FILES (Agents-column look: name, folder, kind icon,
   unsaved dot, close ×, count in the header) above the existing FILES tree; the main
   area shows the selected file (FileHeader + viewer) or an empty state.
3. **Files stay open.** Opening a file adds it to the list and switches to Files; files
   are no longer dropped when another file/agent is picked. Selecting an agent (or the
   Control rail item) returns to the agent's terminal; the file stays open. Open files
   (path + viewer kind) persist across restarts (`muya.openFiles`), missing files are
   skipped. ⌘W in Files closes the file, in Control the agent (unchanged).

## Integration (evidence)
- File tabs: `OpenTerminal.kind` editor/mdview/imgview/pdfview, `openTerminal` /
  `openFile` / `openEditor` / `closeTerminal` (App.tsx 609–760); viewer dispatch
  `FileTabView` (App.tsx 214–244); `viewerKindFor` (lib/format.ts:35).
- Main-area swap: `ControlScreen` `openFile` / `fileSlot` (ControlScreen.tsx 159–170).
- Rail: `RailItem` (redesign/types.ts:106), `ITEMS` (Rail.tsx 23–31), `railActive` /
  `navigateRail` (App.tsx 1598–1608).
- Left column look/width: `AgentList` + `usePanelLayout` (AGENTS_W), `FilesSection`.
- Rust fs commands: `read_file` (fs.rs:69), `allow_asset_path` (fs.rs:672).

## Protect (must not break)
Terminals never unmount; ⌘W semantics (L19); dirty-file close confirm; Monaco editor,
markdown view and diff view; grid; file tree; palette file open; colors only via tokens.

## AC (binary)
- [ ] 1 A PNG, JPG, SVG and a PDF open and are visible in the real app (Tauri WebKit).
- [ ] 2 PDF: all pages render, zoom −/+ works, page count shown.
- [ ] 3 Rail shows Files between Control and Sessions; it lists every open file; click
      shows it; × closes it (dirty → confirm).
- [ ] 4 Opening a 2nd file keeps the 1st in the list.
- [ ] 5 Picking an agent shows its terminal; Files rail shows the last file again.
- [ ] 6 Open files survive a restart; a deleted file is skipped silently.
- [ ] 7 `read_file_bytes` rejects directories and > 200 MB; Rust + vitest tests pass.

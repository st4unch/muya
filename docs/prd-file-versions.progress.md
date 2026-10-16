---
status: done
prd: docs/prd-file-versions.md
started: 2026-10-16
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-16 | src-tauri/src/file_history.rs (+3 tests), lib.rs | snapshot/list/read, dedupe, 100 cap, 2 MB + secret skip, 0700/0600; File ▸ Version History ⇧⌘H | AC1, AC5 |
| 2026-10-16 | src/lib/fileVersions.ts (+test) | snapshot helper + event, versionsSource (restore), auto-save pref | AC2 |
| 2026-10-16 | src/components/FileEditor.tsx (+autosave test) | versions on open/pause/save, auto-save 1 s, no false "changed on disk" after own write | AC2 |
| 2026-10-16 | src/redesign/ActivityPanel.tsx (+test) | VERSIONS section for the file in view | AC3 |
| 2026-10-16 | src/components/ReviewChanges.tsx | optional action, side labels, unit, language path | AC4 |
| 2026-10-16 | src/components/SettingsModal.tsx | Editor ▸ Auto-save files switch | AC4 |
| 2026-10-16 | src/App.tsx, src/mock/installMock.ts | dialog + menu wiring, mocks | AC4, AC5 |

## Doğrulama
- cargo 403 ok · vitest 467 ok · tsc clean · no hardcoded home paths.
- `?mock=1` Playwright dark + light: file opened → Activity VERSIONS (3 rows) → dialog "Versions · pty.rs" with diff + Restore; Settings Auto-save switch saves `muya.autoSave=1`. No page errors.
- Dev build (fake HOME), AX tree: File menu has "Version History" ⇧⌘H.
- Not verified live: pressing the menu item with a real file open, and Restore writing to a real file (unit-tested with mocks only).

## Kararlar
- Shortcut ⇧⌘H, not ⌥⌘H from the PRD: ⌥⌘H is macOS "Hide Others" in the app menu.
- Auto-save writes without formatting (caret would jump); ⌘S still formats.
- Versions view reuses the Review dialog (one diff UI in the app).
- Secret-looking files are never copied into the history folder.

## Dersler

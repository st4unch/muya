---
status: done
prd: docs/prd-session-housekeeping.md
started: 2026-10-17
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-17 | src-tauri/src/history.rs | tail reader (4 MB window ×4), cwd + folder-size caches, archive/restore/trash, in-use guard | AC1 AC2 |
| 2026-10-17 | src-tauri/src/claude_settings.rs | safe edits of ~/.claude/settings.json (order kept, invalid JSON untouched, symlink kept, backup once), cleanupPeriodDays | AC3 |
| 2026-10-17 | src/lib/sessionStorage.ts (+test) | summary + candidates (skips live and <10 min) | AC4 |
| 2026-10-17 | src/components/SessionCleanupDialog.tsx, SessionsPage.tsx | strip, Clean up dialog (Clean up / Archived), row … menu | AC4 |
| 2026-10-17 | src/redesign/StorageHeadsUp.tsx, App.tsx | once-a-day heads-up, waits for other toasts | AC4 |
| 2026-10-17 | src/components/SettingsModal.tsx | Claude group: cleanup days | AC4 |

## Kararlar
- Archive lives in ~/Library/Application Support/com.staunch.muya/session-archive (outside Claude's folder, same disk → rename).
- Trash via NSFileManager trashItemAtURL (recoverable), verified once against the real Trash.
- Measured on the operator's Mac (release build): 201 MB transcript read 0.26 s; history scan cold 113 ms / warm 2 ms.

## Dersler

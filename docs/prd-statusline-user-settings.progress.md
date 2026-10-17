---
status: done
prd: docs/prd-statusline-user-settings.md
started: 2026-10-17
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-17 | src-tauri/src/statusline.rs | stable tap dir, install/uninstall/apply, fallback flag only when install fails | AC1-AC3 |
| 2026-10-17 | src-tauri/src/app_prefs.rs | claudeStatusInFooter pref, toggling applies | AC3 |
| 2026-10-17 | src/components/SettingsModal.tsx | Claude group: footer switch; both prefs saved together | AC4 |

## Kararlar
- Live check: dev Muya with fake HOME wrapped the user's `echo MY-LINE`; command stores JSON with MUYA_STATUS_FILE and prints MY-LINE with/without it.
- Note: the Claude CLI itself rewrites settings.json (key order, model alias) — not Muya.

## Dersler

- Code review (2026-10-17) fixes: user statusLine recovered from the wrapper when the saved copy is gone; footer switch edits settings first (retry works); settings edits serialized + unique temp file; cwd "not found yet" not cached; folder size re-measured every 5 min; session + folder move whole-or-nothing; finished sessions not treated as running; custom retention shown as is; strip colors via tokens.

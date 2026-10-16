---
status: done
prd: docs/prd-workspace-shortcuts.md
started: 2026-10-16
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-16 | src/lib/workspaceScope.ts (+test) | `workspaceShortcut` (⌥0–9 → workspace / all) | AC1 |
| 2026-10-16 | src/App.tsx | capture-phase handler calls `selectWorkspace`; menu hints `⌥N` | AC2, AC3 |
| 2026-10-16 | README.md | shortcut mentioned under Agents list | — |

## Doğrulama
- vitest 451 ok (3 new) · tsc clean.
- `?mock=1` Playwright, dark + light: ⌥2 → iptv, ⌥0 → all, ⌥9 (no workspace) → unchanged, ⌥1 → back; menu shows ⌥0–⌥3; no page errors.

## Kararlar
- `e.code` not `e.key`: macOS ⌥1 types "¡".
- Shortcut first in the menu hint: a long path truncated it at the end.

## Dersler

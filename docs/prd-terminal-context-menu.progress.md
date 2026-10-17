---
status: done
prd: docs/prd-terminal-context-menu.md
started: 2026-10-17
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-17 | src/lib/termMenu.ts (+test) | escapeForShell, isWebUrl | AC1 |
| 2026-10-17 | src/components/TerminalContextMenu.tsx (+test) | the menu | AC2 |
| 2026-10-17 | src/components/Terminal.tsx | right-click (grid + padding) opens it; actions; focus back | AC3 |
| 2026-10-17 | src/redesign/Menus.tsx | MenuPopover `autoFocus` + ↑/↓/Home/End | AC3 |
| 2026-10-17 | src/App.tsx | auto-allow toast leaves Esc to an open menu | AC3 |
| 2026-10-17 | src/mock/installMock.ts | mock clipboard keeps what was written | AC3 |

## Kararlar
- Menu items follow VS Code and iTerm2 terminal menus; no "kill/split" items (one wrong click must not end a session).

- Menu box takes focus (not the first item): keys can't leak into the PTY, and no item is highlighted until ↓/hover — like native menus.

## Faz Çıktıları (sonuç)
- AC1/AC2: 7 vitest pass. AC3: Playwright WebKit ?mock=1 dark+light — Paste as Path wrote `/tmp/My\ Dir/a\ b.txt`, Copy filled the clipboard, Open Link → open_url, Select All+Copy, Find focuses search, Esc closes without reaching the PTY, typing while open goes nowhere. AC4: tsc + 481 tests + build pass.

## Dersler
- The auto-allow toast's window-capture Esc handler swallowed Esc for every non-dialog overlay; menus must be checked too.

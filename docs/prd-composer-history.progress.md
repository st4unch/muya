---
status: done
prd: docs/prd-composer-history.md
started: 2026-10-16
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-16 | src/redesign/composerHistory.ts (+test) | load/save/push/step helpers, per-target lists | AC1 |
| 2026-10-16 | src/redesign/Composer.tsx | ↑/↓ recall on first/last line, send stores, "↑ history" hint | AC2, AC3 |

## Doğrulama
- vitest 457 ok (6 new) · tsc clean.
- `?mock=1` Playwright dark + light: sent 2 prompts, ↑ → second, ↑↑ → first, ↓↓ → empty draft; no page errors.

## Kararlar
- One list per target, shared by all agents: what the operator typed is useful in any session; shell vs agent kept apart so a sentence never recalls into zsh.
- Not reading `~/.claude/history.jsonl`: it holds prompts typed in the TUI too, per project; out of scope.

## Dersler

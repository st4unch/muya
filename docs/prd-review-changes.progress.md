---
status: done
prd: docs/prd-review-changes.md
started: 2026-10-16
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-16 | src-tauri/src/fs.rs, lib.rs | `git_branch_file_pair` (+ temp-repo test) | AC1 |
| 2026-10-16 | src/components/ReviewChanges.tsx, ReviewDiffPane.tsx, monacoSetup.ts (+test) | dialog, lazy diff pane, shared Monaco setup | AC2 |
| 2026-10-16 | src/lib/reviewSources.ts, src/App.tsx | working-tree / branch sources, dialog state, Inspector + Queue wiring | AC3, AC4 |
| 2026-10-16 | src/redesign/Inspector.tsx (+test) | all changes listed, row → review | AC3 |
| 2026-10-16 | src/components/QueuePage.tsx | "N changed" / "N uncommitted" / changed-file rows open the review | AC4 |
| 2026-10-16 | src/App.tsx | auto-allow toast no longer eats Esc while a dialog is open | — |

## Doğrulama
- cargo 400 ok · vitest 460 ok · tsc clean.
- `?mock=1` Playwright dark + light: Inspector 14 rows; Review diff → 14 files, "]" → file 2; Esc closes; Queue "14 uncommitted" → dialog. No page errors.
- Not end-to-end in mock: the branch review (Queue "N changed" / branch inspector rows) — mock projects have no branch changes; the Rust side is unit-tested on a real temp repo.

## Kararlar
- Dialog (ModalShell) instead of a new tab kind: review is a pass over a set, not a file you keep open.
- Row click in Changes now opens the review at that file; "Open in editor" is one click inside it.

## Dersler

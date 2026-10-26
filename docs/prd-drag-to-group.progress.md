---
status: done
prd: docs/prd-drag-to-group.md
started: 2026-10-26
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-27 | src/lib/controlSplit.ts (+test) | `joinGroup` | AC1 |
| 2026-10-27 | src/redesign/AgentList.tsx (+test) | drop modes (`dropModeAt`, `dropStyle`), `onGroup`, `onGroupInto` on split header, footer hint | AC2, AC3 |
| 2026-10-27 | src/redesign/ControlScreen.tsx, src/App.tsx | `groupAgents`, `groupInto`, `reorderOrUngroup` | AC2 |

## Kararlar
- Middle half of a row = group, edges = reorder (same model as file managers dropping into a folder vs between items); no modifier key, so it is discoverable.

- Verified: tsc clean, npm tests pass; mock mode (dark + light) Playwright drag of documents-44 onto opencode-review shows a solid accent outline while hovering the middle, and the drop creates the split and shows both panes at once; no page errors.
- Not seen in the real app.

## Dersler

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
- 2026-10-27 operator: in 4.1.18 dragging showed the "Drop to open" file overlay and did nothing. Cause: Tauri's native drag handler (dragDropEnabled) takes every drag over the window and never passes it to WebKit, so HTML5 dragover/drop never fire (wry wkwebview/drag_drop.rs, tauri-runtime-wry returns true). Fix: AgentList drags with pointer events + elementFromPoint (data-drop-key), with a ghost label; the OS drop hint only shows when the native drag carries paths (L80).
- Verified in a real debug build (WKWebView, fake HOME) driven with cua-driver: drag → split made, both panes shown, no "Drop to open"; mid-drag ghost + outline visible. Mock dark/light still pass; tsc clean, npm 525 passed.

## Dersler

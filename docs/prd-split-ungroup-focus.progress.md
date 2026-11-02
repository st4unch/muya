---
status: done
prd: docs/prd-split-ungroup-focus.md
started: 2026-11-02
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-11-02 | src/redesign/AgentList.tsx (+test) | `data-drop-key="ungroup"` on the list, `onUngroup`, ghost "· out of split", list outline | AC1 |
| 2026-11-02 | src/redesign/SplitArea.tsx (+new test), icons.tsx `MinimizeIcon` | `zoomedKey` / `onToggleZoom`, focus + restore button | AC2 |
| 2026-11-02 | src/redesign/ControlScreen.tsx, src/App.tsx | `zoomedPane` state, `splitVisibleKeys` honours it, `ungroupAgent` | AC2 |

## Kararlar
- Focus renders only the zoomed pane; the others' terminals go back to the hidden pool through adoptHosts and refit on return (no display:none tricks).
- Focus is not persisted and ends when another terminal becomes active.
- Verified: tsc clean, npm 529 passed; mock dark + light Playwright: group → 2 panes, focus → 1 pane + Restore, restore → 2 panes, drag member to empty list → groups [], no page errors.
- AC4 (real WKWebView build) NOT done: the Mac's display was asleep (idle ~6 h), the dev window captured blank white. To redo when the operator is at the Mac.

## Dersler

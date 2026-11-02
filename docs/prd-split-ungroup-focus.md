# Mini-PRD — drag a session out of a split; focus one pane of a split

## 1. Problem
Drag-to-group (4.1.18/4.1.19) puts sessions into a split, but taking one out by dragging
only works when it is dropped on the edge of an ungrouped row, which nobody discovers.
In a split with several panes there is no way to look at one pane full size for a moment
and come back to the same split.

## 2. Outcome
- **Ungroup:** drag a split member out of its split and drop it anywhere in the agent list
  that is not a session row (empty list space, a section title, the split area of another
  group's list) — it leaves the split. While dragging over such a spot the drag label reads
  "<name> · out of split". Dropping on another row still reorders / groups as today.
- **Focus pane:** each split pane's title row gets a focus button (expand icon). Clicking it
  shows only that pane in the terminal area, still running; the button turns into a restore
  icon, and clicking it brings the split back exactly as it was. Picking another session
  in the list also ends the focus.

## 3. Scope
- In: `AgentList` drag targets, `SplitArea` pane title row, `App.tsx` state.
- Out: keyboard shortcut for focus, persisting focus across restarts, Grid screen
  (it already has its own Full screen per panel).

## 4. Behaviour
- `AgentList`: the list's scroll container is marked `data-drop-key="ungroup"`. In
  `dropTargetAt`, a pointer that is not over a row/header but is inside that container
  returns `{ key: "ungroup" }` only when the dragged session is in a split. New prop
  `onUngroup(fromKey)`. Ghost text appends " · out of split" while that is the target.
- `SplitArea`: props `zoomedKey: string | null` and `onToggleZoom(key)`. When `zoomedKey`
  is one of the panes, only that pane is rendered (1×1), so the others' terminals return
  to the hidden pool (adoptHosts). Button: `aria-label="Focus pane <name>"` /
  `"Restore split"`, before the ×.
- `App.tsx`: `zoomedPane` state (not persisted). `zoomed` = it, when it is in the active
  split. `splitVisibleKeys` = `[zoomed]` when zoomed. Toggling on activates that pane.
  Any change of the active terminal to another key clears it. `ungroupAgent(key)` =
  `removeFromGroups`.

## 5. Integration (evidence)
- Pointer drag + `dropTargetAt` + `data-drop-key`: `src/redesign/AgentList.tsx` (L80 fix).
- Groups: `removeFromGroups`, `groupOf` in `src/lib/controlSplit.ts`; `closeSplitPane`,
  `reorderOrUngroup` `src/App.tsx:2089-2122`.
- Split render: `src/redesign/SplitArea.tsx`; wired via `ControlScreen.tsx:112-115,235`
  and `App.tsx:2685-2690`.
- Terminal visibility: `splitVisibleKeys` `App.tsx:2351`, `terminalIsVisible` `App.tsx:2536`;
  host adoption every render `App.tsx:2330` (slots that disappear send terminals to the pool,
  ResizeObserver refits on return — `Terminal.tsx:617`).

## 6. Protection list
Drag reorder / group / join header, the × (close pane keeps the agent), Split button,
⌘1–9, Grid full screen, open_session split, persisted groups, OS file drop overlay.

## 7. Acceptance criteria
- AC1: AgentList test — a grouped session dropped on list empty space calls
  `onUngroup(from)`; an ungrouped session dropped there calls nothing.
- AC2: SplitArea test — with `zoomedKey` set only that pane renders and its button is
  "Restore split"; clicking a pane's "Focus pane" calls `onToggleZoom(key)`.
- AC3: tsc clean, npm tests pass.
- AC4: real debug build (WKWebView) driven with cua-driver: drag a member to empty list
  space → split gone; focus button → one pane full size; restore → both panes back with
  their terminals showing text.

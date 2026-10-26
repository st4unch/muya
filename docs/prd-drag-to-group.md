# Mini-PRD — drag a session onto another to group them into a split

## 1. Problem
Split groups only form through the Split button (which clones the terminal on screen) or
`open_session(split:true)`. Two sessions that already exist — e.g. agents in different
workspaces working on one job — can't be put side by side.

## 2. Outcome
In the agent list, dropping a session onto the MIDDLE of another session's row groups
them; dropping onto a split's header row joins that split. The grouped split is shown
right away. Dropping onto the top/bottom edge of a row reorders, as today. Dragging a
grouped session onto an ungrouped row's edge takes it out of its split.

## 3. Scope
- In: agent list (Control, left panel) drag-and-drop; any two terminal sessions, any
  workspace; MAX_SPLIT (8) still applies.
- Out: tab bar dragging, dragging into the split pane area, naming groups.

## 4. Behaviour
- Pure helper `joinGroup(groups, from, to, newId)` in `src/lib/controlSplit.ts`: takes
  `from` out of its current group (dissolving a group left with one) and adds it to
  `to`'s group, or makes a new group `[to, from]`. Null when `from === to`, both already
  share a group, or the target group is full.
- `AgentList`: drag-over tracks `{ key, mode }`; mode = "group" when the pointer is in the
  middle 50% of the row's height, else "reorder". Group mode shows a solid accent outline
  on a tinted background; reorder keeps the dashed outline. The split header row
  (`GroupRow`) accepts drops in group mode only. New prop `onGroup(fromKey, toKey)`;
  `onGroupInto(fromKey, groupId)` for the header.
- `App.tsx`: `groupAgents(from, to)` → `joinGroup` → `setSplitGroups` → `activateTerminal(to)`
  so the split shows at once. Reorder of a grouped `from` onto an ungrouped row also calls
  `removeFromGroups`.
- Footer hint: "Drag to reorder · onto a session to split".

## 5. Integration (evidence)
- Existing drag: `src/redesign/AgentList.tsx:57-134` (`dragKeyRef`, `dragOverKey`,
  `onReorder`); rows `AgentCard` :342, `IdleRow` :387, `GroupRow` :430; footer :319.
- Wiring: `ControlScreen.tsx:46,116,202-205` → `App.tsx:2655-2666`
  (`reorderAgents`, `selectSplitGroup`, `splitGroups`).
- Groups: `src/lib/controlSplit.ts` (`addToGroup`, `removeFromGroups`, `resolveGroups`,
  MAX_SPLIT), persisted `muya.splitGroups` `App.tsx:2056`; a group IS the split view
  (`selectSplitGroup` `App.tsx:2096`).
- L-lessons: DnD `onDragLeave` relatedTarget check and `useRef` for the dragged key are
  already in place — keep them.

## 6. Protection list
Reorder by drag, ⌘1–9, rename, context menu, close ×, Split button, open_session split,
group collapse/select, persisted groups.

## 7. Acceptance criteria
- AC1: `joinGroup` unit tests: new pair; join existing group; move between groups
  (old group of two dissolves); full group → null; same group → null; from === to → null.
- AC2: AgentList test: a drop with mode "group" calls `onGroup(from, to)`, not
  `onReorder`; an edge drop calls `onReorder` as before.
- AC3: Dropping on a split header calls `onGroupInto(from, groupId)`.
- AC4: tsc, npm test pass; mock-mode screenshots (dark + light) show the group outline
  during drag and the new split after the drop.

# Mini-PRD — ⌥1–9 switches workspace

## 1. Problem
⌘1–9 already jumps between the agents of the current workspace. Switching the workspace itself
needs the mouse (header menu or a file-tree root). The operator wants a keyboard jump.

## 2. Scope
- ⌥1…⌥9 picks the Nth workspace, in the header Workspaces menu order. ⌥0 picks "All workspaces".
- A number with no workspace behind it does nothing (the key passes through).
- Works while a terminal has focus (capture phase, like ⌘1–9); not while a dialog/palette/menu is open.
- Matched on the physical key (`e.code` `Digit1`…), because on macOS ⌥1 types "¡" in `e.key`.
- The Workspaces menu shows each item's shortcut in its hint.
- Not in scope: rebinding, numpad digits.
- Trade-off: ⌥digit no longer reaches the shell (readline meta-digit numeric argument). Rarely used.

## 3. Acceptance criteria
- AC1: Pure `workspaceShortcut(e, workspaces)` returns the Nth root for ⌥N, `"all"` for ⌥0, null for
  out-of-range N, other modifiers, or a non-digit key — vitest.
- AC2: App's capture-phase handler calls `selectWorkspace` with it and stops the event; ignored when an overlay is open.
- AC3: Menu hint shows `⌥N` — `?mock=1` screenshot dark + light; pressing ⌥2 in the mock changes the workspace.
- AC4: `npx tsc --noEmit`, `npm test -- --run` pass.

## 5. Integration
- Global shortcut handler: `src/App.tsx` ~l.2118 (`shortcutRef`, ⌘1–9 at l.2137).
- Workspace pick: `selectWorkspace` `src/App.tsx` l.590; menu `src/App.tsx` l.2654; list `workspaces` state.
- Pure helpers: `src/lib/workspaceScope.ts` (+ `.test.ts`).

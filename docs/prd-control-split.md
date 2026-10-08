# Mini-PRD: split the Control terminal in place (up to 8 panes)

- Date: 2026-10-08
- Type: mini-PRD
- Operator request (2026-10-08): "ana terminal ekranını bölelim, olduğu yerde, grid ekranına
  geçmeden, 8'e kadar izin verelim."

## 1. Problem
Control shows one agent's terminal. To watch several at once the operator has to leave for
the Grid screen (max 6, its own header/rail behaviour, no agent list or inspector). They want
to split the Control terminal area itself — keeping the agent list, header, composer and
inspector — into up to 8 terminals.

## 2. Scope
- In:
  - **Split** button in the session header (next to "Split to grid") and **⌘D**: adds a pane to
    the Control terminal area. Max **8** panes; the button disables at 8.
  - A new pane takes the next agent that is not already shown (agent-list order). If every
    agent is shown, it is an empty pane with "New terminal" / "New agent" buttons.
  - **Focused pane** = the selected agent: clicking a pane focuses it (and the keyboard goes to
    its terminal); the session header, composer, progress strip and inspector follow it.
    Clicking an agent in the left list while split puts that agent into the focused pane
    (if it is already in another pane, the two swap).
  - Each pane has a slim title row (agent name + status dot + close ×). Close removes the pane
    only — the agent keeps running. Down to 1 pane = the normal single-terminal Control.
  - Waiting-for-approval agents show the usual waiting colour on the pane's title row.
  - **Automatic layout** by pane count: 1 → 1; 2 → 2 columns; 3 → 3 columns; 4 → 2×2;
    5–6 → 3×2; 7–8 → 4×2. Equal sizes (no drag-resize in this version).
  - Split set persists across restarts (localStorage), like the grid's agent choice.
- Out:
  - Drag-resize of panes, drag-and-drop between panes, custom layouts.
  - Files rail inside a pane (the Files rail still replaces the whole area as today).
  - Changing the Grid screen (keeps 1/1x2/2x2/3x2, max 6).

## 3. Acceptance criteria (binary)
- [ ] AC1: Split button and ⌘D add a pane, up to 8; at 8 the button is disabled and ⌘D does nothing.
- [ ] AC2: Pane count → layout exactly as in §2 (unit test over 1–8).
- [ ] AC3: Every pane shows a live terminal (renderer attached, sized to its pane, PTY told the size).
- [ ] AC4: Clicking a pane focuses it: typed keys reach that pane's PTY only; header/composer/inspector
  show that agent.
- [ ] AC5: Agent-list click while split puts that agent in the focused pane (swap if already shown).
- [ ] AC6: Close × removes the pane, the agent keeps running (still in the list, PTY alive).
- [ ] AC7: Leaving Control (another page, Files rail, Grid screen) and coming back keeps the split and
  the focused pane takes the keyboard again (no deaf terminal — L54).
- [ ] AC8: The split survives a restart; agents that no longer exist drop out of it.
- [ ] AC9: With 1 pane, Control looks and behaves exactly as before (protection).
- [ ] AC10: Live check in a real WebKit window: 8 panes render and accept keys per pane.

## 4. Protection list
- Single-terminal Control, Grid screen (layouts, maximize, Y/N keys), Files rail.
- Terminal pool: one xterm + one PTY per agent, never unmount (L1); hosts move between slots.
- Terminal visibility: `terminalIsVisible` must count the new split layer (L54).
- Composer, slash commands, approvals, ⌘1–9, ⌘K.

## 5. Integration / harmony
- Terminal pool: `adoptHosts` moves a host into `[data-terminal-slot=<key>]` (`src/redesign/terminalHosts.ts:36`,
  `App.tsx` layout effect) — each pane renders one slot; nothing new to spawn.
- Visibility: `terminalIsVisible` (`src/lib/terminalVisibility.ts`) + `App.tsx:2226` `active=`; add
  `inSplit` (this terminal is in a visible Control pane) next to `inGrid`.
- Focus: `Terminal.tsx` `focusToken` / `tabPickCount` (`App.tsx:2232`, `pickTab` :364).
- Selection: `activeTerminalKey` / `selectedAgentKey` (`App.tsx:1773`) = the focused pane.
- Main area: `ControlScreen.tsx:206` renders the single slot — becomes a CSS grid of panes when split.
- Header button: `SessionHeader.tsx:189` ("Split to grid") — new "Split" button beside it.
- Persistence pattern: `apex.gridKeys` (`App.tsx:381`); new key `muya.splitKeys`.
- Pane picking: reuse `pickGridPanels`-style helper (`agentModel.ts:218`), pure + unit-tested.
- WebKit keeps ≤16 WebGL contexts; 8 visible panes stay under it (hidden tabs are suspended).

## 6. Phases
1. Pure helpers (layout by count, add/close/swap pane list) + tests; visibility layer.
2. ControlScreen split UI, header button, ⌘D, list-click-into-focused-pane, persistence.
3. Full suite + live run in a real WebKit window (native driver), 8 panes.

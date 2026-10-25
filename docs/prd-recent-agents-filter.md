# Mini-PRD — "Recent" filter in the agent list

## 1. Problem
The agent list filters are All / Waiting / Working. Waiting is almost always 0, so the
operator has no quick way to find the sessions they actually used today among many idle ones.

## 2. Outcome
A fourth tab, **Recent N**, shows the terminals that were active (working, waiting, or had a
Claude transcript written) in the last 6 hours. Waiting and Working stay.

## 3. Scope
- In: the filter tab, a per-tab "last active" time that survives an app restart, seeding it
  from Claude transcript times at launch.
- Out: tracking keystrokes in plain shells (a shell has no working/waiting status; it counts
  as recent only through a Claude transcript), a configurable window, sorting by recency.

## 4. Behaviour
- `lastActiveAt[key]` = the latest of: now, whenever the model derives `working` or
  `waiting` for that tab (written at most once a minute); the tab's Claude transcript
  `lastModified` (from `list_session_history`, read once at launch).
- Recent = `status !== "idle"` OR `now - lastActiveAt < 6h`.
- Stored in localStorage `muya.lastActive` (`{ [tabKey]: ms }`); entries for closed tabs
  are dropped.
- Pinned rows follow the same filter as every other row (as with Waiting/Working today).

## 5. Integration (evidence)
- AgentVM built in `src/redesign/agentModel.ts:136` (`buildAgents`), wrapped by
  `src/redesign/useAgentModel.ts` (stamps, 30 s `now` tick, sessionStorage wait clocks).
- `AgentTab` (`agentModel.ts:13`) is structurally App's tab, which already carries
  `sessionId` (`App.tsx:112`, persisted in `apex.openTabs`).
- Transcript times: Tauri command `list_session_history` (`src-tauri/src/history.rs:206`),
  already used by the Sessions page; returns `sessionId` + `lastModified`.
- Filter type + tabs: `src/redesign/AgentList.tsx:13, 60-63, 229-242`; state at
  `App.tsx:1900` and `Preview.tsx:26`.
- No backend change.

## 6. Protection list
Waiting/Working filters and counts, the waiting clock (`muya.waitingSince`), PINNED and
split-group rendering, the grid and palette (they read `agents`, unchanged).

## 7. Acceptance criteria
- AC1: `AgentFilter` includes `"recent"`, and the list shows a fourth tab `Recent N`.
- AC2: With filter `recent`, an idle agent whose `lastActiveAt` is 5 h old is listed; one
  at 7 h old, or with no time, is not; a working/waiting agent always is.
- AC3: `lastActiveAt` survives a reload (read from `muya.lastActive`), and closed tabs'
  entries are removed.
- AC4: Transcript `lastModified` for a tab's `sessionId` seeds `lastActiveAt` at launch.
- AC5: `npx tsc --noEmit`, `npm test -- --run` and `cargo test --lib` pass; mock-mode
  screenshots in dark and light show four tabs fitting the list width without wrapping.

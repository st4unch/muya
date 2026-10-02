# Mini-PRD — Workspace scope for the agent list

## 1. Problem
The header's **Workspace** picker only sets where new agents open. The agent list
always shows every terminal from every workspace (21 agents across 5 workspaces), so
the operator can't focus on one project.

## 2. Goal
Picking a workspace shows only that workspace's terminals/agents. Terminals in other
workspaces keep running (never closed) and come back when their workspace is picked.
New terminals and agents open under the picked workspace.

## 3. Scope
- Workspace menu: **All workspaces** item on top; each workspace shows its agent count.
- Agent list (Control) shows only terminals in the picked workspace.
- A tab belongs to workspace `W` when its spawn cwd is `W` or under it, or under the
  worktree folder Muya creates for it (`<parent>/<repo>-worktrees/…`, see
  `src-tauri/src/fs.rs` `create_worktree`). SSH tabs (no local folder) show in every
  workspace. Tabs matching no workspace show under **All workspaces**.
- Selecting an agent from elsewhere (⌘K palette, notification, "jump to waiting", an
  MCP-opened session) switches the workspace to that agent's, so it is never hidden.
- Switching workspace selects the first agent of that workspace (or the empty state).
- "All workspaces" persists across restarts (today `undefined` is not saved).

Out of scope: grid screen, file tree, footer/bell counts (stay global so waiting agents
elsewhere still show).

## 4. Acceptance criteria
- AC1: With workspace A picked, the agent list contains only A's tabs (+ SSH tabs).
- AC2: Switching to B and back to A: A's terminals are still alive with their output.
- AC3: "All workspaces" lists every tab; the choice survives a reload.
- AC4: New terminal (⌘T) / New agent with A picked opens with cwd in A.
- AC5: Picking an agent of B from the palette switches the header to B and shows it.
- AC6: Switching to a workspace with no agents shows the "No agents yet" empty state.
- AC7: Unit tests for the membership rule (prefix boundary, worktree folder, SSH, none).

## 5. Integration
- Scope state = existing `selectedRoot` (`src/App.tsx:549`), set by the header menu
  (`App.tsx:2265`) and the file tree root click (`App.tsx:1969`).
- New agents already use it: `launchAgent` (`App.tsx:1341`), `openBlankTerminal`
  (`App.tsx:894`), MCP open (`App.tsx:997`).
- Selection: `pickTab` (`App.tsx:354`), `openTerminal` (`App.tsx:637`).
- List: `ControlScreen agents={agentVMs}` (`App.tsx:2148`).
- Terminals stay mounted in the pool (`App.tsx:1995`) — filtering the list never
  unmounts or kills a PTY (L1).

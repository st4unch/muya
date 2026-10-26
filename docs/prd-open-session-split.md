# Mini-PRD — `open_session` can open the new session as a split pane

## 1. Problem
An agent that opens a parallel session with `open_session` always gets a new tab. The
operator wants to watch both side by side, so today they have to arrange it by hand
(and ⌘⇧D only clones the current terminal, it can't host the new session).

## 2. Outcome
`open_session(..., split: true)` opens the new session as a split pane next to the
CALLING session's terminal, in the same split group (up to the 8-pane limit).

## 3. Scope
- In: one optional boolean `split` on the MCP tool; anchor = the caller's own terminal.
- Out: splitting next to an arbitrary other session, split direction/size, splitting
  for `ssh_open`.

## 4. Behaviour
- Sidecar: `split: true` adds `splitWith: <own CLAUDE_CODE_SESSION_ID>` to the broker op.
- Broker: forwards `splitWith` in the `muya://open-agent-session` payload (absent → absent).
- Frontend: after building the `aopen:` tab as today, resolves `splitWith` to the
  caller's tab key (`sessionIdToKeyRef`), and if that tab is an open terminal and its
  group has room, adds the new key to its group (`addToGroup`) before opening it.
- Fallback (no session id, caller tab not found, group full): opens a normal tab, as
  today. Nothing errors.

## 5. Integration (evidence)
- Tool schema + forwarding: `src-tauri/src/bin/muya_ssh_mcp.rs:189-208, 760-785`;
  caller id: `own_session_id()` at `muya_ssh_mcp.rs:81`.
- Broker: `BrokerReq` `broker.rs:331-345`, `build_open_session_payload` `broker.rs:1096`.
- Frontend listener: `src/App.tsx:1145-1178`; session id → tab key map
  `sessionIdToKeyRef` `App.tsx:1312`; split state + `addSplitPane` `App.tsx:2048-2072`;
  pure helpers `src/lib/controlSplit.ts` (`addToGroup`, MAX_SPLIT).
- Skill doc: `claude-plugin/muya-mcp/skills/muya-mcp/SKILL.md` (open_session section).

## 6. Protection list
`open_session` without `split` behaves exactly as before; `aopen:` prefix (close_session
ownership release); ⌘⇧D split, group pruning and persistence (`muya.splitGroups`).

## 7. Acceptance criteria
- AC1: The tool schema lists `split` (boolean); with `split: true` the sidecar sends
  `splitWith` = its own session id; without it, no `splitWith` is sent.
- AC2: `build_open_session_payload` carries `splitWith` when given and omits/nulls it
  when absent (Rust test).
- AC3: A pure helper returns the new groups with the new key in the caller's group when
  the caller's tab is open, and `null` when the id is unknown, the tab is not open, or
  the group already has 8 panes (TS test).
- AC4: The listener uses that helper; `open_session` without `split` still opens a plain
  tab (code path unchanged).
- AC5: `cargo test --lib`, `npx tsc --noEmit`, `npm test -- --run` pass; the sidecar's
  `tools/list` shows `split`.

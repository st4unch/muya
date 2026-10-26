# Mini-PRD — sessions opened by `open_session` run unattended

## 1. Problem
A session an agent opens with `open_session` still asks the operator things: Auto mode
covers yes/no permission prompts, but Claude's question survey (AskUserQuestion) and plan
approval (EnterPlanMode/ExitPlanMode) still stop and wait for the operator. The new session
also never tells the session that opened it that it finished or got stuck.

## 2. Outcome
By default a Claude session opened with `open_session`:
- cannot call AskUserQuestion, EnterPlanMode or ExitPlanMode (`--disallowedTools`);
- is told (`--append-system-prompt`) that it runs unattended, that another session opened
  it, that it must decide on its own, and that it reports back with
  `send_to_session(target: <opener id>, deliver: "muya")` when done or blocked.
`unattended: false` opens it exactly as today (for a session the operator will drive).

## 3. Scope
- In: Claude sessions from `open_session`; opener id sent always (not only for split).
- Out: opencode (no equivalent flags; unchanged), sessions opened by hand ("+ New Agent"),
  schedules, changing the permission mode.

## 4. Behaviour
- Sidecar: new optional boolean `unattended` (default true) in the schema; forwards
  `unattended` when given and always `openedBy: own_session_id()` when non-empty.
- Broker: `BrokerReq.opened_by` (`openedBy`), `unattended`; payload carries
  `openedBy` (trimmed, blank → null) and `unattended` (absent → true).
- Frontend: pure helper `unattendedFlags(openedBy)` in `src/lib/agent.ts` returns the
  flag string; the open-agent-session listener appends it to the claude base command
  when `unattended !== false`. Without an opener id the prompt says "report in your final
  answer" instead of naming a target.

## 5. Integration (evidence)
- Sidecar schema + forwarding: `src-tauri/src/bin/muya_ssh_mcp.rs:189-198, 761-796`;
  `own_session_id()` `muya_ssh_mcp.rs:81`.
- Broker: `BrokerReq` `broker.rs:330-346`, `build_open_session_payload` `broker.rs:1099`,
  tests `broker.rs:2075-2117`.
- Frontend listener: `src/App.tsx:1150-1183` (base command + `buildAgentCommand`);
  `singleQuote` already used there; `AGENT_BASE_COMMAND` in `src/lib/agent.ts`.
- CLI flags verified on this machine: `claude --help` lists `--disallowedTools` and
  `--append-system-prompt`.
- Skill doc: `claude-plugin/muya-mcp/skills/muya-mcp/SKILL.md` open_session section.

## 6. Protection list
`split`, `aopen:` prefix / close_session ownership, `initial_message` delivery, opencode
command, "+ New Agent" and the Cmd+Shift+C/New Claude shortcuts, resume commands.

## 7. Acceptance criteria
- AC1: Schema lists `unattended`; sidecar always sends `openedBy` when the env id is set.
- AC2: `build_open_session_payload` carries `openedBy` (trimmed, blank → null) and
  `unattended` defaulting to true, false when given false (Rust test).
- AC3: `unattendedFlags("abc")` contains `--disallowedTools AskUserQuestion EnterPlanMode
  ExitPlanMode` and an `--append-system-prompt` naming `abc`; without an id it names no
  target (TS test).
- AC4: Listener adds the flags only for claude and only when `unattended !== false`.
- AC5: A real `claude` run with the flags starts and the model reports it has no
  AskUserQuestion tool; cargo/tsc/npm suites pass.

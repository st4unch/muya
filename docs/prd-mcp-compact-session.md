# Mini-PRD: compact_session + usage (new MCP tools)

- Date: 2026-11-11
- Type: mini-PRD

## 1. Problem
An orchestrating session that drives long-running workers (open_session + send_to_session) has no
way to compact a worker's context; the only options are letting it hit auto-compact at a bad moment
or closing it (losing the session). The operator asked for Claude Code's `/compact` as an MCP tool.

## 2. Scope
- In: sidecar tool `compact_session(target, instructions?)`; broker op `"compact_session"`; a
  `submit` flag on the existing `muya://deliver-message` event so the frontend types the line and
  then presses Enter (separately, as the composer does).
- Out: opencode / shell / ssh tabs; auto-compact policy; `/clear`, `/model` or other slash commands.

## 3. Design decisions
| Question | Decision | Why |
|---|---|---|
| What is typed | `/compact` or `/compact <instructions>` + a separate Enter | Same two-write rule as chat delivery: Enter inside the same write is a bracketed-paste newline (remoteMessage.ts SUBMIT) |
| Target kind | Claude only (`AgentSession.agent == "claude"`); opencode refused | `/compact` is a Claude Code command; opencode has no equivalent |
| Not self | Refused when the resolved id == caller's `sessionId` | Compacting yourself mid-tool-call would type into your own prompt |
| Busy | Refused unless `status == "idle"`: `working` → "busy", `waiting-for-input` / any `waitingFor` → "stuck on a prompt (answer it first)" | `/compact` typed mid-turn is queued/garbled; typed into a permission menu it selects an option |
| Instructions | Single line: control chars/newlines → space, whitespace collapsed, trimmed, capped at 500 chars (char-safe); empty after cleaning = plain `/compact` | Newlines would submit a half line; control chars (ESC) could drive the TUI |
| Ownership | NOT restricted to sessions the caller opened; any local Claude session except self | Compact is non-destructive (history summarised, session kept) unlike close. The opened-by record (`AGENT_OPENED_SESSIONS`) is lost on a Muya restart, which would make a restricted tool useless exactly for long-running workers. The idle gate already protects the operator's mid-turn work |
| Resolution | `resolve_target` exactly like send_to_session (id > name > substring, ambiguity returns candidates) | Consistency |

## 4. Acceptance criteria (binary)
- [ ] AC1: sidecar `tools/list` contains `compact_session` (`target` required, `instructions` optional).
- [ ] AC2: pure fn tests: target kind, self, working, waiting, idle ok; sanitize (newline, ESC, cap, empty).
- [ ] AC3: the typed text reaches the PTY followed by a separate Enter (`deliveryWrites` test).
- [ ] AC4: `cargo test --lib`, `npx tsc --noEmit`, `npm test -- --run` green.
- [ ] AC5: muya-mcp SKILL.md documents the tool; plugin.json version bumped.

## 5. Integration / harmony (evidence)
- Addressing: `running_sessions()` + `resolve_target` (broker.rs `handle_send_to_session`).
- Delivery: existing `muya://deliver-message` listener (src/App.tsx, `deliveryWrites` in
  src/lib/remoteMessage.ts); raw mode today never submits, so a `submit` flag is added — default
  behaviour of raw (`["2"]`) is unchanged.
- Sidecar passes `sessionId: own_session_id()` as send_to_session does (muya_ssh_mcp.rs) — needed for the self check.
- Both hops updated: `BrokerReq.instructions` (broker) and the sidecar schema/handler.

## 6. Protection list
send_to_session modes (auto/muya/keys), close_session ownership, raw-keys no-submit behaviour.

## 7. Known limits
- Fire-and-forget: success means "typed", not "compaction finished"; poll `list_sessions` (working → idle) or `read_session`.
- Slash-command autocomplete behaviour of the Claude TUI on Enter is verified only as far as noted in the progress file.

## 8. Add-on: `usage(target?)` (operator: "collect /usage output with muya")
- Path chosen: **data, not screen-scraping.** Claude Code's status-line JSON carries `rate_limits.five_hour|seven_day|spend_limit`
  (`used_percentage` 0-100, `resets_at` unix secs; spend adds `used_usd/limit_usd/period`) —
  https://code.claude.com/docs/en/statusline#available-data. Present only for claude.ai Pro/Max/Ultra (or gateway spend limit) and only
  after a session's first API response; each window may be absent.
- Muya already captures that JSON per tab (`statusline.rs` tap → `<dir>/pty-N.json`; footer reads `rate_limits.*` in
  `src/lib/statusline.ts:220`). New `statusline::all_status()` lists those files; broker op `"usage"` picks the newest file
  with `rate_limits` (or the one whose `session_id` == resolved `target`), drops windows already past `resets_at`, and returns
  `windows{fiveHour,sevenDay,spendLimit}`, `capturedAt`, `ageSeconds`.
- The typed-`/usage` fallback was NOT built: the statusline has the data, and typing into a session + parsing the TUI is brittle and
  disruptive. Limit: only sessions started in Muya with the footer tap enabled report; data is as fresh as that session's last refresh.
- Read-only ⇒ no busy/idle refusals, no ownership check.
- AC6: pure-fn test (newest pick, expired-window drop, per-session filter, error text). AC7: sidecar `tools/list` shows `usage`.

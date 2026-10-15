# Mini-PRD — Several times a day for one schedule

## 1. Problem
A daily/weekly schedule has one time. The operator wants "ITA Mail Özeti" at 09:00 **and** 19:00
(maybe a third) without cloning the job (a clone doubles the prompt to maintain and splits history).

## 2. Scope
- `daily` and `weekly` gain an optional `extraTimes: ["HH:MM", …]` next to `time`. The job runs at
  `time` and every extra time; at most 6 times a day in total; duplicates are ignored.
- Old files (no `extraTimes`) read unchanged; an empty list is not written, so a job saved without
  extra times is byte-identical to before (older builds keep reading it).
- Schedules page: the time row gets "+ Add time" and a remove button per extra time.
  Card text: "Every day at 09:00, 19:00".
- muya-mcp `schedule_create`/`schedule_update`: schema + description mention `extraTimes`.
- Not in scope: interval schedules, per-time prompts.

## 3. Acceptance criteria
- AC1: `next_after` returns the earliest of all times (same day and roll-over to the next day / next
  picked weekday) — unit tests for daily and weekly.
- AC2: An invalid extra time or more than 6 times total is refused with a clear message — unit test.
- AC3: A job JSON without `extraTimes` deserializes; serializing with an empty list omits the field — unit test.
- AC4: The page can add/remove a time and saves `extraTimes`; `describeSchedule` lists all times sorted — vitest;
  `?mock=1` screenshot dark + light.
- AC5: Apply to the operator's "ITA Mail Özeti": 09:00 + 19:00; the status file shows the next due time.
- AC6: `cargo test --lib`, `npx tsc --noEmit`, `npm test -- --run` pass.

## 5. Integration
- Model + timing: `src-tauri/src/schedules.rs` `Schedule` (l.37), `next_after` (l.155), `validate` (l.185).
- MCP schema: `src-tauri/src/bin/muya_ssh_mcp.rs` l.493/523; docs `claude-plugin/muya-mcp/skills/muya-mcp/SKILL.md` l.147.
- UI: `src/lib/schedules.ts` (`Schedule`, `describeSchedule`, `rememberSchedule`, `withKind`),
  `src/components/SchedulesPage.tsx` l.510 time input; mock `src/mock/schedulesMock.ts`.

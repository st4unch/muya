---
status: done
prd: docs/prd-schedule-multi-times.md
started: 2026-10-15
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-15 | src-tauri/src/schedules.rs | `extraTimes` on daily/weekly, `day_times`, next_after = earliest, validation msg | AC1-AC3 |
| 2026-10-15 | src-tauri/src/bin/muya_ssh_mcp.rs, plugin SKILL.md (1.0.6) | schema + docs | — |
| 2026-10-15 | src/lib/schedules.ts, SchedulesPage.tsx | Add time / remove, describeSchedule lists all times | AC4 |

## Doğrulama
- cargo 399 ok (4 new schedule tests) · tsc clean · vitest 448 ok (3 new).
- ?mock=1 dialog screenshots dark + light.

## Kararlar
- `extraTimes` next to `time` (not replacing it with `times[]`): old files and older builds keep working, no migration.
- Cap of 6 times a day: each run is a full `claude -p`; more than that is an interval schedule.

## Dersler

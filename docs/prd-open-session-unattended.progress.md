---
status: done
prd: docs/prd-open-session-unattended.md
started: 2026-10-26
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-26 | src-tauri/src/bin/muya_ssh_mcp.rs | `unattended` in schema; `openedBy` always sent | AC1 |
| 2026-10-26 | src-tauri/src/broker.rs (+test) | payload `openedBy`, `unattended` (default true) | AC2 |
| 2026-10-26 | src/lib/agent.ts (+test) | `unattendedFlags` | AC3 |
| 2026-10-26 | src/App.tsx | listener adds the flags for claude unless `unattended:false` | AC4 |
| 2026-10-26 | SKILL.md, plugin.json 1.0.8, CHANGELOG | docs | — |

## Kararlar
- Default ON (operator: survey/plan approvals must not reach them); `unattended: false` opts out.
- Both disallow the tools AND tell the session why — removing tools alone leaves it looking for another way to ask.

- Flags before `--name`: `--disallowedTools` is variadic and would eat a trailing prompt.
- Verified: real `claude -p` with the generated flags lists none of the three tools and quotes the opener id; tsc clean, npm 515 ok, cargo 418 ok + 1 schedules timing test that passes alone and on unchanged code; sidecar tools/list shows `unattended`.
- Not seen in the real GUI.

## Dersler

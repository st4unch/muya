---
status: done
prd: docs/prd-recent-agents-filter.md
started: 2026-10-25
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-25 | src/redesign/recentActivity.ts (+test) | last-active map: stamp, seed, prune, localStorage | AC2-AC4 |
| 2026-10-25 | src/redesign/useAgentModel.ts | reads transcript times once, marks `recent` on each agent, persists the map | AC3, AC4 |
| 2026-10-25 | src/redesign/AgentList.tsx (+test) | `recent` filter + "Recent N" tab, tab labels kept on one line | AC1, AC2 |
| 2026-10-25 | src/redesign/types.ts, agentModel.ts, previewFixture.ts | `AgentVM.recent`, `AgentTab.sessionId`, fixture | AC1 |

## Kararlar
- 6 h window fixed (operator asked "son 6 saat"); Waiting kept, Recent added next to it.

- Verified: tsc clean, npm test 507/507, mock-mode screenshots dark+light (4 tabs, no wrap). No Rust change, so cargo not re-run.
- Not verified in the real app: transcript seeding against real `~/.claude/projects` (needs a dev instance).

## Dersler

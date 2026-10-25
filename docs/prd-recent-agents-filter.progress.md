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

## Hotfix 2026-10-25 (after 4.1.14)
- Bug: after a restart Recent showed all 6 resumed tabs. Launch resumes every saved tab with `claude --resume`, which appends untimed records (mode, bridge-session, cost-state) and moves the transcript mtime to "now".
- Fix: `list_session_history` returns `lastMessageAt` (timestamp of the last user/assistant line in the last 512 KB, cached by size+mtime); the frontend seeds from it, ignores working/waiting for 90 s after launch, and uses a new storage key (`muya.lastActive.v2`) so the bad v1 stamps are dropped.
- Real data after the fix: 1 recent (muya-all); the others' last messages are 45-442 h old.

## Dersler
- L79: file mtime is not "used"; the launch resume touches every transcript.

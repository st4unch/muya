---
status: done
prd: docs/prd-open-session-split.md
started: 2026-10-26
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-26 | src-tauri/src/bin/muya_ssh_mcp.rs | `split` in schema; sends `splitWith` = own session id | AC1 |
| 2026-10-26 | src-tauri/src/broker.rs (+test) | `BrokerReq.split_with` → payload `splitWith` | AC2 |
| 2026-10-26 | src/lib/controlSplit.ts (+test) | `splitForOpenSession` | AC3 |
| 2026-10-26 | src/App.tsx | open-agent-session listener joins the caller's group | AC4 |
| 2026-10-26 | claude-plugin/muya-mcp SKILL.md, plugin.json 1.0.7 | documents `split` | — |

## Kararlar
- Anchor = the caller's own terminal (operator: "terminal açarken split yapıp öyle açsın"); no arbitrary target (YAGNI).

- Verified: cargo test --lib 418 ok, tsc clean, npm test 512 ok, sidecar tools/list shows `split`.
- Not verified in the real GUI (needs the next release in the running app).

## Dersler

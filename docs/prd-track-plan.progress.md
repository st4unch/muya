---
status: done
prd: docs/prd-track-plan.md
started: 2026-08-07
completed: 2026-08-07
---

## Faz Çıktıları
**P1 (2026-08-07) — opus impl:** 7/7 AC kod+unit. sidecar `track_plan` tool: `current_dir/docs/prd-<slug>.md` (# title + body) + `.progress.md` (status frontmatter) yazar; slugify (unicode-safe, filename-safe) +test. Board taraması union'ı (workspaces∪worktrees∪agents) zaten mevcut. cargo/tsc/npm yeşil. Canlı GUI (agent track_plan → Kanban kartı) operatör teyidi.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-08-07 | src-tauri/src/bin/muya_ssh_mcp.rs | track_plan tool + schema + slugify (+test) | AC1-AC5 |

## Kararlar
- **Sidecar doğrudan yazar (broker değil):** düz doküman, secret yok; agent kendi projesine (`current_dir`) yazar. ssh_* gibi broker'a gitmeye gerek yok.
- **Hedef = current_dir/docs:** Claude Code MCP server'ı agent'ın proje dizininde spawn eder; board bu dizini zaten tarar → ekstra wiring yok.
- **Aynı title → üzerine yaz:** "active" başla, "done" bitir akışı için idempotent güncelleme.

## Dersler

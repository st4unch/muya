# Mini-PRD — track_plan: agent PRD/plan'ını Kanban'a ekler

## 1. Amaç (ne işe yarar)
Agent bir PRD/plan oluşturduğunda veya bitirdiğinde, bunu Muya'nın Kanban board'una **görünür** kılabilsin — insan ilerlemeyi tek yerden izlesin. Bugün agent'ın oluşturduğu plan dosyaları board'da görünmüyordu (ya farklı isimde/yerde, ya da tarama kapsamı dışında).

## 2. Kapsam
- Yeni `muya-mcp` tool **`track_plan(title, status?, body?)`**: agent'ın **kendi çalıştığı proje** (`current_dir`) altında `docs/prd-<slug>.md` + `docs/prd-<slug>.progress.md` yazar. Kanban zaten bu dizini tarıyor → kart görünür.
- `status`: `active|draft|blocked|done` (default `active`) → progress frontmatter'ına yazılır → board kolonu.
- Aynı `title` ile tekrar çağırınca kartı **günceller** (üzerine yazar) — "başladım (active)" → "bitti (done)".
- Kanban taraması worktree + agent cwd'lerini zaten kapsıyor (union `App.tsx:1793`).

## 3. Kapsam dışı
- Board'dan agent'a geri-bildirim (agent kartı okumaz, sadece yazar).
- Broker/secret yolu — düz doküman yazımı, secret yok; sidecar kendi kullanıcı/projesinde doğrudan `std::fs` ile yazar (ssh gibi broker'a gitmez).
- Rastgele path'e yazma — yalnız `current_dir/docs/` (agent'ın kendi projesi).

## 4. Kabul Kriterleri (binary)
- **AC1:** `track_plan(title:"Vault RAG", status:"active", body:"## Faz1")` → `<cwd>/docs/prd-vault-rag.md` (`# Vault RAG` + body) + `prd-vault-rag.progress.md` (`status: active`) yazılır; dönüşte `prdPath` gelir.
- **AC2:** `title` boş / kullanılabilir karakter yok → tool-error, dosya yazılmaz.
- **AC3:** `status` verilmezse `active` yazılır; verilen enum dışı da string olarak yazılır (board gösterir).
- **AC4:** Aynı `title` ile ikinci çağrı (status:"done") aynı dosyaları üzerine yazar (kart güncellenir).
- **AC5:** Slug filename-safe (alfa-nümerik + tek tire; Türkçe harf korunur; baş/son tire yok). Unit test.
- **AC6:** Board tarama union'ı worktree+agent cwd kapsar (mevcut, korunur); yeni yazılan prd-*.md görünür.
- **AC7:** cargo + tsc + npm yeşil.

## 5. Entegrasyon (harmony — dosya:satır)
- **Yazım hedefi:** sidecar `std::env::current_dir()` = Claude Code'un MCP server'ı spawn ettiği dizin = agent'ın projesi/worktree'si. `muya_ssh_mcp.rs` `track_plan` arm → `fs::create_dir_all(docs)` + iki `fs::write`.
- **Board okuma:** `scan_prd_docs` (`fs.rs:1423`) `<dir>/docs/prd-*.md` + `.progress.md` tarar; status = progress frontmatter `status:` (`fs.rs:1479`), title = ilk `# ` (`fs.rs:1468`). track_plan tam bu formatı yazar.
- **Tarama kapsamı:** `PrdBoard workspaces` = `workspaces ∪ worktrees ∪ agents.map(worktree)` (`App.tsx:1793`). Agent cwd'si tracked bir worktree/workspace ise kart görünür.
- **Koruma:** mevcut ssh_* tool'ları, broker, scan_prd_docs slug-dedup korunur. track_plan yalnız kendi projesine yazar.

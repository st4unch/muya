## Retry 0

**Faz:** faz-1-vault-integration
**Model:** claude-sonnet-4-6
**Tarih:** 2026-06-30

### AC Durumu

| AC | Durum | Kanıt |
|----|-------|-------|
| AC-1-1 | DONE | `vault_search` komutu implement edildi, `Vec<VaultBlock>` veya `Err("no_results")` döner |
| AC-1-2 | DONE | warmup_vault startup'ta initialize + dummy query gönderir → embeddings önbelleğe alınır |
| AC-1-3 | DONE | timeout=300ms → `Err("timeout")` → App.tsx catch → original prompt PTY'ye gider |
| AC-1-4 | DONE | `blocks.retain(|b| b.similarity >= 0.35)` vault.rs:265 |
| AC-1-5 | DONE | `formatVaultContext` → `[Vault Context]\n--- {path} (similarity: {score})\n{text}\n---\n[/Vault Context]\n\n{prompt}` |
| AC-1-6 | DONE | `lock.as_mut() == None` → `Err("mcp_unavailable")` → graceful fallback |
| AC-1-7 | DONE | `tauri::async_runtime::spawn(warmup_vault)` lib.rs setup hook'ta |
| AC-1-8 | VERIFY | Terminal.tsx:206-214 — Faz 0'da implement edildi. Backspace `\x7f` line 206, Ctrl+U line 212 |

### Commit Listesi

- `8e710e9` feat(prd): AC-1-1 — Cargo.toml tokio features (process/io-util/time/sync)
- `a8fd622` feat(prd): AC-1-1,AC-1-6 — vault.rs VaultMcpManager + vault_search + crash handling
- `476c33a` feat(prd): AC-1-7,AC-1-2 — vault module registered + warmup on app startup
- `52e36c3` feat(prd): AC-1-3,AC-1-4,AC-1-5 — App.tsx async handleBeforeSubmit + vault context format

### Dosyalar

- `src-tauri/src/vault.rs` — yeni dosya (353 satır)
- `src-tauri/src/lib.rs` — vault mod + manage + handler + warmup spawn
- `src-tauri/Cargo.toml` — tokio features genişletildi
- `src/App.tsx` — VaultBlock interface + formatVaultContext + async handleBeforeSubmit

### Build Doğrulama

- `cargo check` — clean (5.07s, no warnings)
- `tsc --noEmit` — clean (no errors)

### Notlar

- `VaultMcpProcess.kill_on_drop(true)` — timeout'ta `*lock = None` ile drop edilir, subprocess otomatik kill edilir
- `parse_mcp_response` üç format destekler: JSON array, tek JSON obje, ham metin
- Similarity filter `vault_search`'te yapılır (Rust tarafı) → App.tsx'e sadece 0.35+ bloklar gelir
- 2000 char cap `formatVaultContext`'te enforce edilir (char count'a göre blok keser)

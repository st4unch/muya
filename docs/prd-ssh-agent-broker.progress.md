---
status: active
prd: docs/prd-ssh-agent-broker.md
started: 2026-07-26
---

## Faz Çıktıları

- **Mini-PRD yazıldı — 2026-07-26:** `docs/prd-ssh-agent-broker.md`. Operatör kararı:
  MCP plugin mekanizması + korumalar (sunucu başına opt-in `agentAccess` + sadece store
  açıkken). `software-architect` (opus) gate = **GO, 2 faza böl**; D1-D6 kararları + §5
  entegrasyon kanıtı (file:line) PRD'ye işlendi. Kilit karar: mevcut chat-bridge socket'i
  DEĞİL, yeni özel UDS (0600 + SO_PEERCRED uid kontrolü — bridge'de olmayan sertleştirme).

- **Faz 1 impl — DONE 2026-07-26 (mcp-developer opus, prd-run):** AC1-AC7 tümü PASS,
  bağımsız concrete-check ile doğrulandı (148 rust test / tsc temiz / 82 vitest / proxy
  build) + subagent canlı e2e 18/18 (gerçek stdio + gerçek UDS). Yeni: `broker.rs`
  (owner-only UDS, 0600 + `getpeereid` uid gate fail-closed, list/open ops, register_mcp),
  `src/bin/muya_ssh_mcp.rs` (stdio MCP proxy — ssh_list_servers+ssh_open, ssh_run YOK).
  Değişen: ssh.rs (`agent_access` alanı), credstore.rs (`is_unlocked` gate), lib.rs
  (mod+state+setup listener/register), Cargo.toml (libc + 2. bin), SshPage.tsx (toggle),
  App.tsx (`openSshServer` + `ssh-broker-open` listener → inject yolu). Kod bağımsız
  okundu: uid gate fail-closed, `open` sadece serverId event yayar (sır yok), ServerMeta
  sırsız.
  **AÇIK RELEASE GAP (Faz 1.5):** ikinci binary `.app` bundle'ına girmiyor — dev'de
  `current_exe().parent()` ile bulunuyor ama release'de tauri `externalBin`/kopya adımı
  gerek; yoksa shipped build'de `.mcp.json` yolu kırık olur. Bir sonraki release'den
  ÖNCE çözülmeli. + macOS `getpeereid` kullanıldı (ADR'nin generic "SO_PEERCRED"i Linux).

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-07-26 | docs/prd-ssh-agent-broker.md | Mini-PRD oluşturuldu (architect GO) | — |
| 2026-07-26 | src-tauri/src/broker.rs (yeni) | UDS broker + getpeereid gate + list/open + register_mcp + 5 test | AC3-AC7 |
| 2026-07-26 | src-tauri/src/bin/muya_ssh_mcp.rs (yeni) | stdio MCP proxy (ssh_list_servers/ssh_open) | AC6, proxy |
| 2026-07-26 | src-tauri/src/ssh.rs | Server.agent_access alanı + deser test | AC1 |
| 2026-07-26 | src/components/SshPage.tsx | "Agent may use this server" toggle | AC2 |
| 2026-07-26 | src/App.tsx | openSshServer + ssh-broker-open listener | AC5 |
| 2026-07-26 | src-tauri/src/{lib.rs,credstore.rs}, Cargo.toml | broker kaydı + is_unlocked + libc/2.bin | AC3,AC5,AC6 |

## Kararlar
- Transport: stdio MCP proxy + yeni UDS (0600+SO_PEERCRED); HTTP/bridge-reuse red — architect D1.
- Kayıt: ~/.claude/.mcp.json (install_mcp pattern), env değil — architect D2.
- Araçlar: ssh_list_servers/ssh_open (P1) + ssh_run stdout-only (P2) — architect D3.
- Gating: Server.agentAccess + secret_for locked-gate, ikisi Rust-tarafı — architect D4.
- Faz: P1 temel, P2 ssh_run (P1 socket/uid bariyeri contract-test'le kanıtlandıktan sonra).

## Dersler
- (henüz yok)

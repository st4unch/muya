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

- **Faz 1 CANLI doğrulandı — 2026-07-26:** gerçek dev app'te broker socket `srw-------`
  (0600) oluştu + `~/.claude/.mcp.json`'a `muya-ssh` kaydı düştü (operatör tool'ları gördü).
  **BUG (canlı yakalandı):** 2. binary `cargo run`'ı kırdı → `default-run = "muya"`
  eklendi (Cargo.toml). Yalnızca app açınca ortaya çıktı.
- **Faz 2 impl — DONE 2026-07-26 (mcp-developer opus):** `ssh_run(alias, command)` — agent
  SSH'ta komut çalıştırır, çıktı döner, şifre sunucu-tarafında enjekte. AC8-AC10 PASS,
  bağımsız doğrulandı: 152 rust test (+4) + **canlı Docker e2e** (`MUYA_RUN_OK`, exit 0,
  şifre yok). `pty::run_with_injection` (PTY capture+inject, 256KB cap, 60s timeout),
  `broker::handle_run` + N=4 semaphore, `assemble_run_args` (tek argv, verbose off),
  proxy `ssh_run` tool. prompt-source sunucu ssh_run'da reddedilir (enjekte edilecek sır yok).

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-07-26 | docs/prd-ssh-agent-broker.md | Mini-PRD oluşturuldu (architect GO) | — |
| 2026-07-26 | src-tauri/Cargo.toml | default-run="muya" (2. binary dev-run fix) | — |
| 2026-07-26 | src-tauri/src/pty.rs | run_with_injection (capture+inject variant) | AC8 |
| 2026-07-26 | src-tauri/src/broker.rs | handle_run + run_slots semaphore | AC8-AC10 |
| 2026-07-26 | src-tauri/src/bin/muya_ssh_mcp.rs | ssh_run MCP tool | AC8 |
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

---
status: done
prd: docs/prd-ssh-session.md
started: 2026-08-15
completed: 2026-08-15
---

## Faz Çıktıları
**P1 (2026-08-15) — opus impl:** 7/7 AC kod+unit. Yeni `agent_ssh.rs`: headless kalıcı PTY oturumları
(`AgentSshStore` Arc-Mutex, Clone), `open`/`exec`/`close`. Enjeksiyon `run_with_injection` deseninden
adapte (pub(crate) `looks_like_*`); reader thread çıktıyı ring-buffer'a biriktirir. exec = shell-değişkeninden
üretilen B/E sentinel (`M=__MUYA<n>; printf '%sB__'` → echo collision yok), region'dan çıktı+RC. Timeout'ta
Ctrl-C + partial. broker 3 op (session_open/exec/close, spawn_blocking), sidecar 3 tool + şema. lib.rs mod+manage.
**Uçtan uca doğrulandı (yerel bash PTY, 0.39s):** açma, framed exec, çıktı yakalama, **durum korunması**
(cd /tmp→pwd=/tmp), exit code, close, close-sonrası-hata. cargo 243 + sidecar + tsc yeşil.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-08-15 | src-tauri/src/agent_ssh.rs (YENİ) | kalıcı oturum open/exec/close + sentinel + 4 test (3 pure + 1 bash-e2e ignored) | AC1-5 |
| 2026-08-15 | src-tauri/src/pty.rs | looks_like_password_prompt/challenge_prompt pub(crate) | AC1 |
| 2026-08-15 | src-tauri/src/broker.rs | session_open/exec/close op + handler + BrokerReq.timeout_secs | AC1-6 |
| 2026-08-15 | src-tauri/src/lib.rs | mod agent_ssh + manage(AgentSshStore) | AC1 |
| 2026-08-15 | src-tauri/src/bin/muya_ssh_mcp.rs | ssh_session_open/exec/close tool + şema | AC1-6 |

## Kararlar
- **Headless (görünür sekme değil):** broker doğrudan sahip → frontend/sessionId-ptyId köprüsü gerekmez. PSMP server-side denetler.
- **Sentinel echo-collision fix (kritik):** marker'ı shell değişkeninden üret (`printf '%sB__' "$M"`); yoksa PTY input-echo'su `find()`'i yanıltır. exec loop `end_prefix` ile marker formatı MUTLAKA eşleşmeli (bir kez kaçtı, 120s hang → yakalandı).
- **Auth:** parola PTY-enjeksiyonu (mevcut mantık); OTP typed-challenge reddedilir; push out-of-band (open bekler). Kalıcı test operatörün PSMP'sinde.

## Dersler

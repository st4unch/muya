# Mini-PRD — Faz 2: agent'a kalıcı SSH oturumu (tek OTP, çok komut, durum korunur)

## 1. Amaç (ne işe yarar)
Agent bir PSMP sunucusuna **TEK bir kalıcı SSH oturumu** açsın (tek OTP/push), sonra o oturumun İÇİNDE çok komut çalıştırıp çıktısını okusun. Böylece: iş-seansı boyunca **1 OTP**, komutlar arası **durum korunur** (cd/env/sudo), ve PSMP mutlu (tek denetim oturumu, çoğullama yok). ControlMaster'ın PSMP'de çözemediği "durmadan OTP" sorununun nihai çözümü.

## 2. Kapsam
- Broker'ın SAHİP olduğu **headless** kalıcı PTY oturumları (görünür sekme değil; agent sürer, PSMP server-side denetler).
- Üç MCP tool:
  - **`ssh_session_open(alias)`** → oturumu açar (parola askpass-benzeri PTY enjeksiyonu; OTP/push burada BİR kez), hazır olunca `sessionId` döner.
  - **`ssh_session_exec(sessionId, command)`** → komutu oturuma yazar, sentinel'le çerçeveler, çıktı + exit code döner. Durum korunur.
  - **`ssh_session_close(sessionId)`** → oturumu kapatır.
- Sentinel: her exec'e nonce'lu `__MUYA_S_<nonce>:%d__`; çıktı bu ile RC arasından okunur.
- Timeout'ta: Ctrl-C (\x03) gönder + resync, timeout döndür.

## 3. Kapsam dışı
- Görünür terminal (Faz 2 headless; görünür sürüm ayrı iş). stdout/stderr ayrımı (PTY'de birleşir; v1 birleşik).
- OTP'yi otomatik geçme — push/OTP insan tarafında (askpass parolayı enjekte eder, OTP challenge'ı reddeder; push out-of-band onaylanır). Open bu tamamlanana kadar bekler.

## 4. Kabul Kriterleri (binary)
- **AC1:** `ssh_session_open(alias)` PTY açar, parola PTY'ye enjekte edilir, shell hazır olunca (ready-probe sentinel) `{ok, sessionId}` döner. Auth tamamlanmazsa timeout hatası (push onayla).
- **AC2:** `ssh_session_exec(sessionId, "echo hi")` → `{ok, stdout:"hi", exitCode:0}`. Echo'lanan komut satırı + sentinel çıktıdan temizlenir.
- **AC3:** Durum korunur: `exec("cd /tmp")` sonra `exec("pwd")` → `/tmp`.
- **AC4:** Bilinmeyen/kapalı sessionId → hata. `ssh_session_close` sonrası exec → hata.
- **AC5:** exec timeout'ta Ctrl-C + resync, `{timedOut:true}` döner; oturum sonraki exec için kullanılabilir kalır.
- **AC6:** Sadece agent-erişimli sunucu; oturum broker-sahipli (uid-korumalı socket arkasında). Parola değeri agent'a asla geçmez.
- **AC7:** cargo + tsc + npm yeşil; sentinel parse + buffer-extract unit testleri.

## 5. Entegrasyon (harmony — dosya:satır)
- **Bağlantı:** `ssh::connect_command_for(server)` (:599) — PSMP `ControlPath=none` (reuse yok, L41), askpass/PTY enjeksiyonu. Yeni oturum bunu kullanır.
- **PTY + enjeksiyon:** `pty.rs run_with_injection` (:324) tek-atış; kalıcı oturum için buna PARALEL yeni `agent_ssh` modülü — PTY açık kalır, reader thread çıktıyı `Arc<Mutex<String>>` ring'e biriktirir (frontend Channel'a DEĞİL), `looks_like_password_prompt`/PSMP-challenge enjeksiyon mantığı reuse edilir (:195,:405).
- **Broker:** yeni `agent_ssh` store (managed state), broker op'ları `session_open/session_exec/session_close`. `resolve_open` (agent-access) + credstore reuse.
- **Sidecar:** `muya_ssh_mcp.rs` üç yeni tool; iki-hop structuredContent forward (L36).
- **Koruma:** mevcut ssh_run/ssh_send/ssh_scp/commands:[]/ControlMaster gate korunur. Bu AYRI bir kanal (kalıcı), onları değiştirmez.

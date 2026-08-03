# Mini-PRD: ssh_run — PSMP hardening (agent komut çalıştırma)

- Tarih: 2026-08-04
- Tür: mini-PRD

## 1. Problem
Claude, MCP `ssh_run` ile SSH sekmesinde tanımlı (yerel kimlikli) PSMP-önlü bir sunucuya
komut gönderebiliyor — mekanizma kodda var (`ssh_run` PSMP destinasyonunu kurup parolayı
Rust'ta prompt'a enjekte ediyor). İki eksik onu güvenilmez kılıyor: (a) PSMP bir **2FA/OTP
challenge** (RADIUS passcode) gösterirse Muya saklı **parolayı OTP yerine enjekte edip** boşa
auth denemesi yapar → **hesap kilitlenme riski**; (b) PSMP **RADIUS push** beklerse (prompt
yok) run 60s `RUN_TIMEOUT`'a düşer ve agent'a **belirsiz timeout** döner. Ayrıca yol **gerçek
PSMP'ye karşı hiç canlı test edilmedi**.

## 2. Scope
- **Dahil:**
  - PSMP + yerel/CyberArk kimlikli `ssh_run`'da güvenli enjeksiyon: standart `Password:`
    prompt'unda enjekte et (mevcut davranış korunur).
  - **Challenge sınıflandırması:** PSMP bağlantısında bir OTP/2FA/passcode challenge
    prompt'u görülürse **parola enjekte etme**, hızlı ve **eyleme dönük hata** döndür
    ("PSMP 2FA istiyor — non-interactive `ssh_run` desteklenmiyor, `ssh_open` kullan").
  - RADIUS-push timeout'unda dönen mesaj olası-2FA'yı jenerik timeout'tan ayırsın.
  - `ssh_run` MCP tool açıklamasına PSMP + 2FA sınırını yaz (agent ne zaman `ssh_open`'a
    düşeceğini bilsin).
  - Canlı e2e doğrulama (gerçek PSMP operatör tarafında, veya katmanlı `Password:` prompt'unu
    taklit eden yerel sshd harness).
- **Hariç:**
  - **Domain (AD) hesap syntax'ı** (`targetUser#domainAddress`) — operatör yerel-kimlikli
    sunucu kullanıyor, gerek yok. Gelecekte ayrı iş.
  - CyberArk PVWA REST / RADIUS logon değişikliği (bu yol vault-fetch içindir; kapsam dışı).
  - Rust-only kimlik modeli (secret JS/argv/disk'e gitmez) — değişmez.

## 3. Kabul Kriterleri (binary)
- [ ] **AC1** (mevcut yol korunur): connection_type=`psmp`, kimlik yerel parola, PSMP
  vault-user prompt'u `Password:` olan bir sunucuda `ssh_run(alias, "uname -a")` →
  `ok:true`, `stdout` dolu, `exitCode:0`. (Docker/harness PSMP-benzeri katmanlı prompt ile.)
- [ ] **AC2** (challenge → enjekte etme): Bağlantı bir OTP/passcode/2FA prompt'u gösterirse
  (tail `passcode:` / `verification code:` / `one-time` / `otp:` ile biter) **parola PTY'ye
  YAZILMAZ** ve `ok:false` + mesaj "2FA/interactive — use ssh_open" içerir. Kanıt: enjeksiyon
  sayacı 0.
- [ ] **AC3** (push timeout ayrımı): Prompt hiç gelmeden `RUN_TIMEOUT`'a düşülürse dönen
  yanıt `timedOut:true` + mesajda "olası 2FA push; ssh_open ile interaktif dene" ipucu.
- [ ] **AC4** (direct SSH regresyon yok): connection_type=`direct` bir sunucuda `ssh_run`
  `Password:` prompt'unda parolayı **eskisi gibi enjekte eder** (Docker sshd e2e yeşil kalır).
- [ ] **AC5** (MCP açıklama): `ssh_run` tool `description`'ı PSMP + 2FA sınırını ve `ssh_open`
  fallback'ini belirtir.
- [ ] **AC6** (canlı doğrulama): Gerçek PSMP'ye VEYA katmanlı-prompt harness'a karşı bir uçtan
  uca koşu progress dosyasına kanıtla (PASS/FAIL + çıktı) kaydedilir.

## 4. Koruma Listesi (dokunulmayacak)
- Mevcut **direct-SSH `ssh_run`** davranışı (Docker sshd e2e, AC4) — `Password:` enjeksiyonu.
- **`ssh_open`** interaktif akışı (parola enjeksiyonu orada da olduğu gibi kalır).
- **Rust-only secret** modeli: secret JS/argv/log/disk'e sızmaz (`ssh_pty_connect` yorumu §9).
- Broker **owner-only UDS + `getpeereid` uid gate + `agent_access` opt-in** (broker.rs) — güvenlik bariyeri.
- Eşzamanlılık **`MAX_CONCURRENT_RUNS` semaphore** (broker.rs:530) ve `RUN_TIMEOUT`.

## 5. Entegrasyon / Harmony (ZORUNLU)
- **Auth / enjeksiyon:** Mevcut `run_with_injection` + `looks_like_password_prompt`
  (`pty.rs:54`, reader-thread inject `pty.rs:174-186`) yeniden kullanılır; kimlik Rust'ta
  çözülür (`broker.rs:541-575`, local→`credstore::secret_for`, cyberark→`fetch_password`).
  Challenge sınıflandırması **enjeksiyon anına** eklenir — yeni auth yolu icat edilmez.
- **Komut kurma:** `build_connect_command` PSMP dalı (`ssh.rs:451-483`) +
  `assemble_run_args` (`broker.rs:191-201`) **değişmez**; sadece prompt sınıflandırma davranışı eklenir.
- **Hata konvansiyonu:** Yeni fail-fast mesajları mevcut `err_resp` JSON `{ok:false,error}`
  şekliyle döner (`broker.rs:244`); `ssh_run` çıktı şekli (`stdout/exitCode/timedOut`) korunur.
- **Challenge tespitinin direct'i kırmaması:** OTP/challenge → enjekte-etme davranışı
  **enjeksiyondan önce** ayrı bir sınıflandırma; `password:` eşleşmesi (direct dahil) aynen
  enjekte eder. Böylece AC4 (direct regresyon yok) korunur. Karar dayanağı: CyberArk resmi
  dokümanı — PSMP non-interactive exec RADIUS challenge-response'u desteklemez (bu oturum
  araştırması, docs.cyberark.com psso-pmsp.htm).
- **Kırma riski:** `looks_like_password_prompt` sınıflandırmasını değiştirmek direct-SSH
  enjeksiyonunu etkileyebilir → önlem: mevcut `password:`/`passcode:` → inject davranışını
  bozmadan, PSMP challenge kalıplarını **ayrı bir kontrol** olarak ekle ve AC4 ile kilitle.

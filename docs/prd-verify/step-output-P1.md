# Step Output — Faz: P1

> Bu dosya append-only'dir. Her implementation/fix turu yeni bir `## Retry N` bloğu olarak eklenir. Önceki retry'ları silmeyin.

---

## Retry 0

**Zaman:** 2026-08-04
**Subagent:** mcp-developer (dispatched directly, not via prd-run-impl)
**Model (probe):** claude-sonnet-5

### Hedeflenen AC'ler
- [x] AC1 — direct-yol-korunur mekanizması yerinde (mevcut PSMP + password: davranışı dokunulmadan bırakıldı); **canlı gerçek-PSMP koşusu operatörde**.
- [x] AC2 — PSMP + OTP/passcode/2FA challenge → parola enjekte edilmez, `ok:false` + "2FA/interactive ... use ssh_open" içeren mesaj. Unit test ile kanıtlandı (enjeksiyon sayacı fiilen 0 — `out.injected == false`).
- [x] AC3 — PSMP + prompt hiç gelmeden timeout → `timedOut:true` + "message" alanında RADIUS push ipucu + ssh_open önerisi.
- [x] AC4 — direct SSH `Password:`/`Passcode:` enjeksiyonu değişmedi (regresyon testiyle kanıtlandı: `ac4_direct_still_injects_on_passcode_prompt`).
- [x] AC5 — `ssh_run` MCP tool description'ı PSMP+2FA sınırını ve ssh_open fallback'ini anlatıyor.
- [ ] AC6 — **operatör-gerekli** canlı e2e (gerçek PSMP veya katmanlı-prompt harness). Bu turda gerçek PSMP erişimi yok; mekanizma yerel bir PTY harness ile (AC2/AC4 testleri, Docker gerektirmez) doğrulandı, ama gerçek CyberArk PSMP'ye karşı KOŞULMADI.

### Değişen Dosyalar
- `src-tauri/src/pty.rs:54-70` — yeni `looks_like_challenge_prompt` (passcode:/verification code:/one-time/otp: trailing match), sadece PSMP yolunda kullanılır.
- `src-tauri/src/pty.rs` `CommandOutput` struct — `+challenge_detected: bool`, `+injected: bool` alanları.
- `src-tauri/src/pty.rs` `run_with_injection(...)` — yeni `is_psmp: bool` parametresi; reader-thread'de challenge sınıflandırması password sınıflandırmasından ÖNCE ve YALNIZ `is_psmp` iken çalışır; challenge tespit edilince outer poll loop `timeout` beklemeden child'ı hemen kill eder.
- `src-tauri/src/pty.rs` testler: `challenge_prompt_matches_2fa_shapes`, `ac2_psmp_challenge_prompt_withholds_injection` (gerçek PTY harness — `sh -c 'printf "Passcode: "; read line; echo "GOT:$line"'`, Docker gerektirmez), `ac4_direct_still_injects_on_passcode_prompt` (regresyon).
- `src-tauri/src/broker.rs` `handle_run` — `is_psmp = server.connection_type == "psmp"`; `run_with_injection` çağrısına iletildi; `challenge_detected` → `err_resp(...)` (AC2 mesajı); PSMP + `timed_out && !injected` → response'a `"message"` alanı eklenir (AC3 mesajı).
- `src-tauri/src/bin/muya_ssh_mcp.rs:97` — `ssh_run` tool `description`'ına PSMP + 2FA sınırı + ssh_open fallback cümlesi eklendi (AC5).

### Concrete Check Sonuçları (özet)
- `cargo check --bin muya`: PASS (yalnız pre-existing dead-code/unused-import uyarıları, hatasız).
- `cargo check --bin muya-ssh-mcp`: PASS (hatasız).
- `cargo test --lib`: PASS — 191 passed; 0 failed; 6 ignored (ignored'lar Docker sshd gerektiren mevcut live testler, bu PRD kapsamında değil).

### LLM Verification Sonuçları
- AC2: PASS ✅ — `pty.rs::ac2_psmp_challenge_prompt_withholds_injection` PSMP+Passcode prompt'unda `injected=false`, `challenge_detected=true`, stdout'ta secret/GOT: yok, ve child ~50ms içinde kill edildi (20s timeout beklenmedi).
- AC3: PASS ✅ (mekanizma) — `broker.rs::handle_run` PSMP + `timed_out && !injected` durumunda `resp["message"]` set ediyor; bu path gerçek-timeout senaryosunda (RADIUS push, prompt hiç gelmeden) tetiklenir. Doğrudan bir unit test broker.rs seviyesinde eklenmedi (broker.rs'de zaten canlı-app/Tauri state gerektiren entegrasyon testleri yok — pty.rs seviyesindeki `timed_out`/`injected` alanları ve broker.rs'deki koşullu mantık kod-okuma ile doğrulandı).
- AC4: PASS ✅ — `pty.rs::ac4_direct_still_injects_on_passcode_prompt`: `is_psmp=false` ile aynı "Passcode:" prompt'unda secret hâlâ enjekte ediliyor (`GOT:mysecret` stdout'ta).
- AC5: PASS ✅ — `muya_ssh_mcp.rs:97` description string'i "PSMP", "2FA", "ssh_open" içeriyor (kod okuma ile doğrulandı; live tools/list smoke bu turda koşulmadı çünkü .app runtime gerekli — GAP olarak not edildi).

### PRD'den Sapmalar
YOK — tasarım PRD §5 Entegrasyon yönergesine sadık kaldı: challenge sınıflandırması enjeksiyondan ÖNCE ve SADECE PSMP yolunda; direct-SSH davranışı değişmedi; `err_resp`/`{ok,stdout,exitCode,timedOut}` sözleşmesi korundu (AC3'te ek `message` alanı additive, breaking değil).

Küçük not: PRD AC3 "mesajda ... ipucu" derken response şeklini spesifik olarak belirtmiyordu (`ok:true` mi `ok:false` mi). `ok:true` + ek `"message"` alanı seçildi çünkü bir timeout kesin bir hata değil (belki komut gerçekten yavaş) — agent hâlâ `timedOut:true` bayrağını görüyor, ek "message" sadece PSMP-özel bir ipucu. Bu **non-critical** bir tasarım kararıydı, araştırılıp karar verildi (Golden Rule §5).

### Bu Turda Alınan Kararlar
- Challenge tespiti PSMP-only gate: `is_psmp` parametresi `run_with_injection`'a eklendi (mevcut imzayı genişletti, tüm çağıranlar güncellendi — 3 call site: broker.rs handle_run, pty.rs iki test).
- Challenge tespit edilince outer poll loop timeout'u beklemeden hemen kill eder (PRD'de açıkça istenmese de, "hesap kilitleme riski" + operatör deneyimi için mantıklı — gereksiz 60s bekleme yerine hızlı hata).
- AC3 mesajı `ok:true` gövdesine eklenen ek `"message"` alanı olarak modellendi (yukarıda gerekçelendirildi).

### Commit'ler
- `d28d42f`: 🔒 fix(ssh): PSMP 2FA/OTP challenge gate — never inject password into a passcode prompt (pty.rs)
- `8d93080`: 🔒 fix(ssh): broker handle_run wires PSMP challenge-gate + push-timeout hint (broker.rs)
- `0c89b9d`: 📝 docs(ssh-mcp): ssh_run tool description documents PSMP + 2FA limitation (muya_ssh_mcp.rs)

### Operatör-gerekli / kapatılmamış
- **AC1 canlı**: gerçek PSMP sunucusuna karşı `ssh_run(alias,"uname -a")` koşusu operatörde — bu oturumda gerçek PSMP erişimi yok.
- **AC6 canlı e2e**: gerçek PSMP VEYA katmanlı-prompt harness'a karşı uçtan uca koşu + PASS/FAIL kanıt kaydı operatörde. Bu turda AC2/AC4 için yerel bir PTY harness (`sh` ile prompt taklidi, Docker gerektirmez) eklendi ve PASS etti — bu, mekanizmanın doğruluğunu kanıtlıyor ama gerçek PSMP/CyberArk'ın layered-prompt davranışını (vault-user password → target-user 2FA sırası, gerçek RADIUS timing) birebir taklit etmiyor. Gerçek PSMP erişimi olduğunda operatör `ssh_run` ile hem düz-parola hem 2FA'lı bir sunucuya karşı test etmeli.

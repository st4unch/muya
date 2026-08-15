# Mini-PRD — SSH ControlMaster: agent tek bağlantıyı yeniden kullanır

## 1. Amaç (ne işe yarar)
Agent bir sunucuya art arda komut çalıştırdığında (`ssh_run`), her seferinde **yeni TCP + yeni auth + yeni OTP** ödemek yerine **tek bir SSH bağlantısını yeniden kullansın**. İlk komut bağlantıyı ("master") kurar ve auth/OTP'yi bir kez öder; sonraki komutlar aynı soketten anında geçer. Kullanıcı isteği: "1 kere açınca oradan komut gönderip alsın, durmadan ssh açmasın."

Araştırma (2026-08-07): OpenSSH ControlMaster/ControlPath/ControlPersist bunu sağlar; **CyberArk parola-auth için PSMP üzerinden resmî destekli** (Ansible pattern'i). İstisna sadece Vault'a SSH-key/Smart-Card ile giriş — bizim durumumuz değil (parola + OTP).

## 2. Kapsam
- Broker'ın kurduğu ssh (connect: `ssh_run` + interaktif `ssh_open`) ve scp komutlarına şu opsiyonlar eklenir:
  `-o ControlMaster=auto -o ControlPath=<dir>/%C -o ControlPersist=10m`.
- `<dir>` = `~/.claude/muya-cm` (0700, başlangıçta oluşturulur). `%C` = ssh'ın bağlantı-parametre hash'i → aynı sunucuya run/scp/interaktif **aynı soketi paylaşır** (kısa, sabit, çakışmaz).
- **Yeni MCP tool YOK** — agent aynı `ssh_run`'ı çağırır, yeniden-kullanım şeffaf.
- Sinerji: bir insan `ssh_open` ile OTP'yi bir kez geçince master kurulur → agent'ın `ssh_run`'ı OTP'siz reuse eder.

## 3. Kapsam dışı
- Shell durumu (cd/env/sudo) komutlar arası korunması — ControlMaster her komuta **taze login shell** verir (bağlantı paylaşılır, shell değil). Durum-tutan akış ayrı `ssh_shell` (Faz 2, bu PRD değil).
- Agent'a raw ssh flag verme — ControlPath/opsiyonları broker koyar, agent asla göremez/set edemez.

## 4. Kabul Kriterleri (binary)
- **AC1:** `build_connect_command` (direct + PSMP dalları) çıktısı `ControlMaster=auto`, `ControlPath=<dir>/%C`, `ControlPersist=10m` içerir. Unit test.
- **AC2 (ERTELENDİ):** scp'ye ControlMaster EKLENMEZ (bu Faz'da). Gerekçe: scp/PSMP `-O` legacy yolu çalışıyor; connect-reuse canlı doğrulanmadan o yolu riske atmıyoruz. connect-reuse PSMP'de geçtikten sonra ayrı adımda eklenir.
- **AC3:** ControlPath dizini (`~/.claude/muya-cm`) broker başlangıcında 0700 ile oluşur (yoksa). 
- **AC4:** Agent'a opsiyon set etme yolu yok (ssh_options/extraArgs allowlist'i `-o`'yu zaten reddediyor — korunur).
- **AC5:** İlk komut davranışı bugünküyle aynı (master kurulurken auth/askpass akışı değişmez) → mevcut ssh_run/scp kırılmaz.
- **AC6:** cargo + tsc + npm yeşil; mevcut connect/scp arg testleri güncellenir (yeni opsiyonları bekleyecek).
- **AC7 (operatör, canlı):** Gerçek PSMP'de iki ardışık `ssh_run` → 2.si OTP'siz/anında gelir (reuse çalışır). PSMP reddederse → ControlMaster'ı direct-only'e gate'le.

## 5. Entegrasyon (harmony — dosya:satır)
- **Ortak kurucu:** `ssh.rs build_connect_command` (:459, direct dalı :497-509 + PSMP dalı :480-495) — `ssh_run` (broker :702 `connect_command_for`) VE interaktif `ssh_open` ikisi de buradan geçer. `build_scp_command` (:644) scp için. Üç opsiyonu yeni `control_master_opts(cm_dir)` (saf) döndürür, her iki kurucuya eklenir.
- **Dizin:** `~/.claude/muya-cm` 0700 — broker start'ta `ensure_control_master_dir()` (broker.rs). ControlPath `%C` token'ı kullandığından per-bağlantı değer gerekmez; dizin var olmalı.
- **Askpass uyumu:** ControlMaster=auto'da yalnız MASTER bağlantı prompt sorar → askpass FIFO enjeksiyonu master'da çalışır (bugünkü akış); reuse eden bağlantılar prompt sormaz (enjeksiyon devreye girmez) — çakışma yok. OTP'yi askpass zaten reddediyor (AC6 korunur); OTP'li PSMP'de master'ı insan `ssh_open` ile kurar.
- **Koruma listesi:** mevcut PSMP `-O` scp, askpass, ssh_send/track_plan, `-o` reddi korunur. İlk-komut yolu değişmez (AC5).

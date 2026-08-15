---
status: done
prd: docs/prd-ssh-controlmaster.md
started: 2026-08-07
completed: 2026-08-07
---

## Faz Çıktıları
**P1 (2026-08-07) — opus impl:** AC1/AC3/AC4/AC5/AC6 kod+unit. `ssh.rs`: `control_master_opts(cm_dir)` (saf) + `control_master_dir()` + `ensure_control_master_dir()` (0700); `build_connect_command` her iki dalına (direct + PSMP) dest'ten önce eklendi → ssh_run + interaktif ssh_open reuse eder. `lib.rs`: broker start'ta dizin oluşturma. Testler: control_master_opts_shape + connect_command_enables_control_master_reuse + 4 mevcut connect testi `without_cm` ile güncellendi. cargo 235 / tsc / npm 92 yeşil. Process-riski elendi: askpass yalnız timeout'ta child.kill() (grup değil) → ControlPersist master (detached) hayatta kalır.

**AC2 (scp) ERTELENDİ:** çalışan scp/PSMP `-O` yolunu riske atmamak için connect-reuse PSMP'de doğrulanana kadar scp'ye eklenmedi.
**AC7 (2026-08-07, operatör canlı test):** PSMP'de İLK ssh_run'lar geçti, sonra "Invalid session state / Failed to receive allowed pid / Shared connection closed" → bayat-master (PSMP oturumu timeout, yerel soket kaldı).
**Karar (operatör düzeltmesi, L42):** kapatma/gate DEĞİL — PSMP reuse TUTULDU, kök neden **enstrümante** edildi. **v0.2.29: `broker::handle_run`'a `[ssh-cm]` debug log** (master_before/after via `ssh -O check` yerel, exit, süre, stale-imza tespiti). Operatör gerçek PSMP'de log toplayıp paylaşacak → kanıtla çözülecek. Ders L41 (bayat-master) + L42 (danışmadan kapatma).

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-08-07 | src-tauri/src/ssh.rs | control_master_opts/dir/ensure + build_connect_command'a ekleme + 2 test + 4 test güncelleme | AC1,AC3,AC5 |
| 2026-08-07 | src-tauri/src/lib.rs | broker start'ta ensure_control_master_dir() | AC3 |

## v0.2.30 — operatör kanıtı + planı (kesin çözüm)
Operatör 4 soket (43/17/6/2 dk, dördü de `Master running`) + soket-kapat→çalıştı testiyle KANITLADI:
PSMP reuse HER ZAMAN başarısız (1. komut çalışır, 2.+ düşer); master idle sayılmadığı için ControlPersist
reap etmez → ölü master alias'ı kilitler (kendiliğinden düzelmez). Operatörün prioritize planı uygulandı:
- **Item 1 (PSMP `ControlMaster=no` + `ControlPath=none`):** `control_master_disabled_opts()`, PSMP dalı. Direct reuse korunur. (Yalnız `=no` yetmez, ssh var olan soketi kullanır → `ControlPath=none` şart.)
- **Item 2 (sweep):** `sweep_control_master_sockets()` (startup, lib.rs) — her sokete `ssh -O exit` + unlink.
- **Item 3 (`commands: []`):** tek bağlantıda çok komut, sentinel-çerçeveli (`build_batch_script`/`parse_batch_output`, nonce'lu), broker `handle_run` + sidecar ssh_run. Per-komut `{command, stdout, exitCode}`. En büyük verim kazancı.
- **Item 4 (safety net):** item 1 PSMP reuse'u kapattığı için stale-hata artık oluşmuyor → gereksiz, EKLENMEDİ.
- **Sonra (Faz 2, alias-başına kalıcı oturum):** operatörün sentinel tasarımı; PTY'siz `bash -s` ölçümü (`ssh -T -o ControlPath=none <alias> 'bash -s'`) operatörde bekliyor. Deferred.
cargo 240 + sidecar test yeşil.

## Kararlar
- **ControlPath=`<dir>/%C`:** ssh'ın bağlantı-param hash'i → aynı sunucuya run/interaktif aynı soketi paylaşır; kısa, çakışmaz, dizin `~/.claude/muya-cm` (0700).
- **ControlPersist=10m:** iş patlaması reuse eder, sonra otomatik kapanır.
- **scp ertelendi:** regresyon riski (çalışan upload). connect-reuse doğrulanınca eklenir.
- **Sinerji:** OTP'li PSMP'de insan ssh_open ile master'ı kurar → agent ssh_run OTP'siz reuse eder.

## Dersler

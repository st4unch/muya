---
status: done
prd: docs/prd-ssh-controlmaster.md
started: 2026-08-07
completed: 2026-08-07
---

## Faz Çıktıları
**P1 (2026-08-07) — opus impl:** AC1/AC3/AC4/AC5/AC6 kod+unit. `ssh.rs`: `control_master_opts(cm_dir)` (saf) + `control_master_dir()` + `ensure_control_master_dir()` (0700); `build_connect_command` her iki dalına (direct + PSMP) dest'ten önce eklendi → ssh_run + interaktif ssh_open reuse eder. `lib.rs`: broker start'ta dizin oluşturma. Testler: control_master_opts_shape + connect_command_enables_control_master_reuse + 4 mevcut connect testi `without_cm` ile güncellendi. cargo 235 / tsc / npm 92 yeşil. Process-riski elendi: askpass yalnız timeout'ta child.kill() (grup değil) → ControlPersist master (detached) hayatta kalır.

**AC2 (scp) ERTELENDİ:** çalışan scp/PSMP `-O` yolunu riske atmamak için connect-reuse PSMP'de doğrulanana kadar scp'ye eklenmedi.
**AC7 (operatör, canlı):** gerçek PSMP'de iki ardışık ssh_run → 2.si OTP'siz/anında mı? Reddederse ControlMaster'ı direct-only'e gate'le.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-08-07 | src-tauri/src/ssh.rs | control_master_opts/dir/ensure + build_connect_command'a ekleme + 2 test + 4 test güncelleme | AC1,AC3,AC5 |
| 2026-08-07 | src-tauri/src/lib.rs | broker start'ta ensure_control_master_dir() | AC3 |

## Kararlar
- **ControlPath=`<dir>/%C`:** ssh'ın bağlantı-param hash'i → aynı sunucuya run/interaktif aynı soketi paylaşır; kısa, çakışmaz, dizin `~/.claude/muya-cm` (0700).
- **ControlPersist=10m:** iş patlaması reuse eder, sonra otomatik kapanır.
- **scp ertelendi:** regresyon riski (çalışan upload). connect-reuse doğrulanınca eklenir.
- **Sinerji:** OTP'li PSMP'de insan ssh_open ile master'ı kurar → agent ssh_run OTP'siz reuse eder.

## Dersler

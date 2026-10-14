---
status: done
prd: docs/prd-schedules-background.md
started: 2026-10-14
---

## Faz Çıktıları
- B: `app_prefs.rs` (muya-app.json, keepRunningInBackground), lib.rs `on_window_event` CloseRequested → hide; `RunEvent::Reopen` ve `Opened` → show. Settings anahtarı.
- Çekirdek: schedules.rs Role(App/Service), sink, her tick kilit yeniden deneme/devir, mtime reload, status + heartbeat + request dosyaları. 4 yeni Rust testi (AC5-7).
- A: `bg_service.rs` (SMAppService.agent, status/set/open_settings), `main.rs --scheduler`, `launchd/com.staunch.muya.scheduler.plist`, tauri.conf `bundle.macOS.files`. Schedules sayfasında BackgroundRow.
- Canlı: `muya --scheduler` env -i + sahte HOME + sahte claude → request ve daily iş çalıştı, run kaydı yazıldı (AC8). Binary değişince idle'da exit 75.
- Doğrulanamadı: kırmızı düğme → hide (dev penceresi başka Space'te, AX ağacı boş).

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-14 | src-tauri/src/app_prefs.rs | yeni: keep-running tercihi | AC1-2 |
| 2026-10-14 | src-tauri/src/lib.rs | close→hide, Reopen, komutlar, run_scheduler | AC1,3,10 |
| 2026-10-14 | src-tauri/src/schedules.rs | Role/sink/coordination/status/requests | AC4-7 |
| 2026-10-14 | src-tauri/src/bg_service.rs | yeni: SMAppService.agent | AC8,10 |
| 2026-10-14 | src-tauri/launchd/*.plist + tauri.conf.json | bundle plist | AC9 |
| 2026-10-14 | src/components/SchedulesPage.tsx, SettingsModal.tsx, lib/schedules.ts | anahtarlar | AC10-11 |

## Kararlar
- software-architect (sonnet): B = hide on CloseRequested + Reopen, Dock kalır, tray yok. A = aynı binary `muya --scheduler`, SMAppService.agent, plist `bundle.macOS.files`, KeepAlive SuccessfulExit:false, ThrottleInterval 30. Run now pasif taraftan istek dosyası. Sıra: B → çekirdek/koordinasyon → A.

## Dersler

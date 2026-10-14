# Mini-PRD: Schedules keep running in the background

- Tarih: 2026-10-14
- Tür: mini-PRD
- Danışılan: software-architect (sonnet), 2026-10-14

## 1. Problem
Zamanlanmış işler (docs/prd-schedules.md) yalnızca Muya açıkken çalışıyor. Pencerenin kırmızı düğmesi uygulamayı kapatıyor, bu yüzden pencereyi kapatan kullanıcının işleri de duruyor. Bazı kullanıcılar Muya'dan tamamen çıksa ya da Mac'i yeniden başlatsa bile işlerin çalışmasını istiyor.

## 2. Scope
- Dahil:
  - **B — Pencereyi kapatınca arka planda çalış:** Kırmızı düğme pencereyi gizler, Muya çalışmaya devam eder (PTY oturumları ve zamanlayıcı yaşar). Dock simgesi kalır, Dock'a tıklayınca pencere geri gelir. ⌘Q (çift basış) gerçekten çıkar. Settings'te "Keep running when the window is closed" anahtarı (varsayılan açık); kapalıysa eski davranış.
  - **Ortak zamanlayıcı çekirdeği:** `schedules.rs` AppHandle'a bağlı olmadan çalışır (olay alıcısı fonksiyonu). Kilit her tick'te yeniden denenir. Aktif süreç iş dosyası değişince yeniden okur. Aktif süreç bir durum dosyası yazar (`~/.claude/muya-schedules.status.json`: pid, sürüm, running, queued, next due, ts). Pasif Muya bu dosyadan canlı durumu gösterir. Pasif taraftan "Run now" bir istek dosyası (`~/.claude/muya-schedule-requests/<id>-<n>.json`) bırakır, aktif süreç sonraki tick'te çalıştırır.
  - **A — Muya kapalıyken de çalıştır (isteğe bağlı, varsayılan kapalı):** Schedules sayfasında "Run when Muya is closed" anahtarı. Açılınca aynı `muya` programı `muya --scheduler` olarak (penceresiz) `SMAppService.agent` ile arka plan servisi kaydedilir. Plist bundle içinde: `Contents/Library/LaunchAgents/com.staunch.muya.scheduler.plist`, `AssociatedBundleIdentifiers=com.staunch.muya`. Böylece Login Items'ta "Muya" adıyla görünür. Servis kayıtlıyken Muya penceresi kilidi almaz, servis yürütür. macOS onay isterse (RequiresApproval) sayfada "Open Login Items" düğmesi gösterilir. Uygulama güncellenince servis sürümü uyuşmazsa yeniden kaydedilir.
- Hariç: menü çubuğu simgesi; Mac uykudayken çalıştırma (pmset wake); servis içinde vault/Touch ID veya Muya MCP broker'ı (servis yalnızca `claude -p` çalıştırır; Muya penceresi kapalıyken muya-mcp araçları çalışmaz); kaçırılan çalışmaları geriye dönük doldurma; Chrome'u servis tarafından açma.

## 3. Kabul Kriterleri (binary)
- [ ] AC1: Anahtar açıkken kırmızı düğme pencereyi gizler, süreç yaşar (dev instance'ta `ps` ile kanıt), Dock reopen pencereyi geri getirir.
- [ ] AC2: Anahtar kapalıyken kırmızı düğme uygulamayı kapatır (eski davranış). Ayar `~/.claude/muya-app.json` dosyasında kalıcıdır.
- [ ] AC3: ⌘Q çift basış ve updater relaunch gizleme tarafından engellenmez (kod yolu `app.exit`/`restart`; CloseRequested yalnızca kullanıcı kapatmasında engellenir).
- [ ] AC4: `schedules.rs` çekirdeği AppHandle olmadan derlenir ve testlerde bir no-op olay alıcısıyla çalışır. Mevcut tüm schedules testleri geçer.
- [ ] AC5: Pasif bir instance, aktif olan kilidi bırakınca (süreç bittiğinde) en geç bir tick sonra kilidi alır. Testle kanıtlanır.
- [ ] AC6: Aktif instance, başka bir süreç `muya-schedules.json` dosyasını değiştirince bir tick içinde yeni işleri kullanır. Testle kanıtlanır.
- [ ] AC7: Pasif instance'ta `schedules_list`, durum dosyasındaki running/queued/next değerlerini gösterir. Pasif taraftaki Run now bir istek dosyası yazar, aktif taraf onu çalıştırıp siler. Testle kanıtlanır.
- [ ] AC8: `muya --scheduler` penceresiz başlar, kilidi alır, zamanı gelen işi çalıştırır ve run kaydını yazar. Bunu sahte HOME ve sahte claude ile canlı bir süreçte kanıtla.
- [ ] AC9: Release bundle'ında plist `Contents/Library/LaunchAgents/` altındadır ve `codesign --verify --deep --strict` geçer.
- [ ] AC10: Schedules sayfasında "Run when Muya is closed" anahtarı servisin durumunu gösterir: off, on, needs approval veya unavailable (dev build). Açmak/kapatmak `SMAppService.agent` register/unregister çağırır. Servis kayıtlıyken GUI kilidi almaz.
- [ ] AC11: UI metinleri İngilizce, renkler `var(--token)`, anahtarlar modalKit `Switch`. Vitest + tsc + build + cargo test geçer.

## 4. Koruma Listesi (dokunulmayacak)
- ⌘W = sekme kapat, ⌘Q çift basış koruması (lib.rs `"quit"` kolu).
- Schedules dosya biçimleri (`muya-schedules.json` v1, runs jsonl 0600), muya-mcp schedule araç sözleşmeleri (broker `schedule*` op'ları).
- `login_item.rs` mainApp kaydı ("Open Muya at login") aynen kalır.
- `debuglog.rs` ve `muya-settings.json`: başka dosyalara karışılmaz (debuglog o dosyayı tümüyle yeniden yazıyor, yeni anahtar oraya konmaz).
- Kirli, ilgisiz dosyalar commit'e girmez.

## 5. Entegrasyon / Harmony
- Auth: yok. Servis kullanıcının kendi oturumunda, kendi kullanıcı izniyle çalışır. Çalıştırma yöntemi aynı kalır: `login_env()` + `claude_bin()` (schedules.rs `launch`).
- Servis/Tablo:
  - Kilit `~/.claude/muya-schedules.lock` (schedules.rs `ScheduleState::at`, `try_lock`) tek hakem olarak kalır.
  - SMAppService için `objc2_service_management` zaten bağımlılık (login_item.rs `main_app` modülü).
  - Plist bundle'a Tauri v2 `bundle.macOS.files` ile girer (config şemasında mevcut).
- Konvansiyon:
  - Olaylar `CHANGED_EVENT` ile gider (schedules.rs).
  - Tauri komutları `lib.rs` invoke_handler'a eklenir.
  - Ayar dosyaları `~/.claude/muya-*.json`, atomik yazılır (schedules.rs `atomic_write`).
  - Arayüz modalKit `Switch`/`Segmented` kullanır (src/components/modalKit.tsx).
  - Settings modalı `SettingsModal`.
- Kırma riski:
  - Kapatmanın engellenmesi updater relaunch'ı veya ⌘Q'yu kilitleyebilir. Önlem: yalnızca `WindowEvent::CloseRequested` engellenir, `ExitRequested` engellenmez.
  - Pasif GUI'nin yazdığı dosya aktifin bellekteki değişikliğini ezebilir. Önlem: her değişiklik önce diskten okunur, sonra yazılır (mtime reload).
  - Servis ile GUI aynı anda iş çalıştırabilir. Önlem: tek kilit; GUI Run now'ı aktif sürece devreder.
  - Dev build'de plist yok. Önlem: durum `unavailable`, anahtar devre dışı.

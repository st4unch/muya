---
status: done
prd: docs/prd-vault-touchid-autolock.md
started: 2026-08-19
completed: 2026-08-19
---

## Faz Çıktıları
**P1 (2026-08-19):** 8/8 AC (AC8'in canlı Touch ID promptu hariç — headless test edilemez, eski PRD'nin
de belirttiği kısıt). `security-framework` (OSX_10_15 feature) crate kaynağından API doğrulandı (varsayım
değil): `PasswordOptions::set_access_control_options(BIOMETRY_CURRENT_SET|DEVICE_PASSCODE|OR)` +
`use_protected_keychain()`. `credstore.rs`: `keychain_store_key`/`load_key`/`delete_key` (dosya-bazlı değil,
tek Keychain item, service=`com.staunch.muya.vault`), 4 yeni komut (`credstore_biometric_available`,
`_enable_biometric_unlock`, `_disable_biometric_unlock`, `_unlock_biometric`), `credstore_rekey` artık
Touch ID etkinse Keychain kaydını yeni anahtarla senkronlar. Ayrı `muya-vault-prefs.json` (debug-log'un
paylaşımlı `muya-settings.json`'ıyla ÇAKIŞMASIN diye — o dosya merge yapmadan tam-üzerine-yazıyor).
Frontend: `SshPage.tsx` StoreTab — kilitliyken "Unlock with Touch ID" butonu (etkinse), açıkken
Enable/Disable Touch ID; `App.tsx` üst-seviye 15dk idle-lock timer (mousemove/keydown/wheel, her yerde
çalışır, sadece SSH sayfasında değil). Doğrulama: cargo check+254 test (+3 pref-persistence, gerçek
Keychain'e dokunmadan) / tsc temiz / npm 102 (+1 Touch ID enable→lock→unlock akışı, mock backend'de) /
gerçek `npm run build`.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-08-19 | src-tauri/Cargo.toml | security-framework (OSX_10_15) eklendi | AC1 |
| 2026-08-19 | src-tauri/src/credstore.rs | Keychain modülü + 4 komut + rekey senkronu + 3 test | AC2-6 |
| 2026-08-19 | src-tauri/src/lib.rs | 4 komut kaydı | AC2-4 |
| 2026-08-19 | src/components/SshPage.tsx | Touch ID butonları (locked+unlocked), biometricAvailable prop | AC2-4,AC6 |
| 2026-08-19 | src/dev/mockBackend.ts, SshPage.test.tsx | mock case'ler + 1 test | AC8 (dev-mode) |
| 2026-08-19 | src/App.tsx | 15dk app-genelinde idle-lock timer | AC7 |

## Kararlar
- **Ayrı prefs dosyası (`muya-vault-prefs.json`):** `debug_log_set` paylaşımlı `muya-settings.json`'ı
  merge'süz tam-üzerine-yazıyor — aynı dosyaya yazmak diğer ayarı silme riski taşırdı (regresyon testiyle
  kilitlendi: `biometric_pref_own_file_never_shares_debuglog_settings`).
- **Re-key'de sil+yeniden-yaz (update değil):** access-control'lü Keychain item'ı `SecItemUpdate` ile
  kısmi güncellemenin belirsiz semantiğinden kaçınmak için temiz insert.
- **İdle-lock App.tsx'te (SshPage'de değil):** "Muya'nın tamamı kullanılmadığında" — SSH sayfası kapalıyken
  de çalışmalı; her zaman mount App.tsx doğru yer.
- **15 dakika sabit:** eski PRD'nin R2 mitigasyon değeriyle aynı (non-critical, araştır+karar).

## P2 — operatörün "memory dump ile okunabilir mi?" sorusuna verilen cevabın gereği (2026-08-19/20)
İncelerken 2 gerçek bulgu çıktı, ikisi de düzeltildi:
1. **UI-tutarsızlığı:** idle-timer arka planda `credstore_lock` çağırıyordu ama `SshPage` bunu bilmiyordu
   (mount'ta bir kez `refresh()`, polling yok) — ekran "Unlocked" gösterirken backend kilitli kalıyordu,
   önceden `reveal` edilmiş bir değer JS state'inde açıkta kalıyordu. **Fix:** `credstore_lock` artık
   `muya://vault-locked` event'i yayınlıyor (manuel + idle-tetiklemeli, ikisi de); `StoreTab` bunu dinleyip
   `revealed` state'ini temizliyor + `refresh()` çağırıyor.
2. **`Credential.secret`/`key_passphrase` zeroize edilmiyordu:** yalnız master anahtar (`Unlocked.key:
   Zeroizing<[u8;32]>`) sıfırlanıyordu; tekil credential secret'ları düz `String` olarak store açıkken
   bellekte kalıyordu (drop sadece serbest bırakır, sıfırlamaz). **Fix:** `Credential.secret`/`key_passphrase`
   ve `CredInput`'un aynı alanları `Zeroizing<String>`/`Option<Zeroizing<String>>` oldu (`zeroize` crate'inin
   `serde` feature'ı sayesinde disk formatı **değişmedi** — kaynaktan doğrulandı). 7 üretim + 9 test noktası
   derleyici rehberliğinde düzeltildi (double-wrap riski `secret_for`/`secret_for_ref`'te fark edilip
   önlendi). `blob_has_no_plaintext_secret`/`ac0_1_round_trip`/migration testleri dahil **25/25 credstore
   testi** hâlâ geçiyor — format regresyonu yok.

Doğrulama: cargo check (lib+bins) + 254 test / tsc temiz / npm 102.

## Dersler

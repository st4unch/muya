# Mini-PRD — Vault: Touch ID unlock + boşta kalınca otomatik kilit

## 0. Önceki karar (yeniden tartışılmadı, üstüne inşa edildi)
`docs/prd-ssh-cyberark.md` "Model A" mimarisini zaten architect-review + operatör-onayı ile belirlemişti
(D1/D4/ARCH1/R2, satır 90-352): Argon2id-türetilmiş anahtar **Keychain'de Touch ID/`kSecAccessControl`
biometry arkasında** önbelleklenir; crate = **`security-framework`** (`keyring` biometry'yi desteklemiyor —
ARCH1). Bu PRD o kararı **uygular** (Faz 1'in "Keychain/Touch-ID auto-unlock" bekleyen maddesi).

**Bu oturumda doğrulanan gerçek API** (`security-framework` 3.7.0 kaynağından, varsayım değil):
`security_framework::passwords::{set_generic_password_options, generic_password, delete_generic_password_options}`
+ `PasswordOptions::set_access_control_options(AccessControlOptions::BIOMETRY_CURRENT_SET | DEVICE_PASSCODE | OR)`.
`OR` → Touch ID **ya da** Mac giriş şifresi (operatörün "parmak izi ya da şifre" isteğiyle birebir örtüşüyor).
`OSX_10_15` feature + `use_protected_keychain()` gerekiyor (legacy dosya-tabanlı keychain access-control
desteklemiyor). `set_generic_password_options` zaten upsert (`SecItemAdd`→dup ise `SecItemUpdate`).

## 1. Amaç
Vault'u her seferinde master şifre yazmadan **Touch ID** ile açabilmek + Muya'nın tamamı bir süre
kullanılmayınca vault'un **kendiliğinden kilitlenmesi** (walk-away riski — eski PRD'nin R2/A2 bulgusu).

## 2. Kapsam
- **Touch ID unlock (opt-in):** Store açıkken "Enable Touch ID unlock" → türetilmiş anahtar Keychain'e
  yazılır (biometry-veya-passcode gated). Kilitliyken "Unlock with Touch ID" butonu → Keychain okuması OS'un
  kendi Touch ID/passcode promptunu tetikler → anahtar doğrudan kullanılır (Argon2id yeniden çalışmaz, anlık).
  Master şifre her zaman fallback olarak kalır (Touch ID devre dışı/iptal/kayıtlı değilse).
  "Disable" → Keychain kaydı silinir.
- **Re-key uyumu:** `credstore_rekey` sonrası, Touch ID etkinse Keychain kaydı **sil+yeniden yaz** (yeni
  anahtarla, temiz insert — access-control'lü item'ı update etmenin belirsiz semantiğinden kaçınmak için).
- **Boşta-kalınca-kilitle:** Muya'nın herhangi bir yerinde (SSH sayfası açık olmasa bile) **15 dakika**
  etkileşimsizlik (mouse/klavye) → store kilitli değilse otomatik kilitlenir. Sabit değer (eski PRD'nin R2
  mitigasyonuyla aynı sayı — non-critical, araştır+karar).
- Biometric-etkin durumu **ayrı, düz-metin** bir dosyada tutulur (`muya-vault-prefs.json`) — `muya-settings.json`
  paylaşımlı olduğundan (debug-log tam-üzerine-yazma yapıyor, bkz. Kararlar) oraya eklemek riskli.

## 3. Kapsam dışı
- macOS ekran-kilidi/uyku bildirimine abone olma (eski PRD'nin ikincil D8 önerisi) — NSDistributedNotification
  Objective-C köprüsü gerektiriyor, ayrı iş. İdle-timer bu turun tek tetikleyicisi.
- İdle süresini UI'dan ayarlanabilir yapmak (şimdilik sabit 15dk).

## 4. Kabul Kriterleri (binary)
- **AC1:** `security-framework` (`OSX_10_15` feature) bağımlılığı eklenir; build başarılı.
- **AC2:** `credstore_enable_biometric_unlock` — yalnız store AÇIKKEN çalışır; türetilmiş anahtarı
  `BIOMETRY_CURRENT_SET | DEVICE_PASSCODE | OR` access-control ile Keychain'e yazar; `muya-vault-prefs.json`'a
  `biometricUnlockEnabled:true` yazar.
- **AC3:** `credstore_unlock_biometric` — Keychain'den anahtarı okur (OS promptu tetiklenir canlıda), doğrudan
  `open()` ile blob'u açar; başarısızsa (iptal/kayıt yok/passcode yok) anlaşılır hata döner, master-şifre
  akışı bozulmaz.
- **AC4:** `credstore_disable_biometric_unlock` — Keychain kaydını siler + prefs `false` yazar.
- **AC5:** `credstore_rekey` sonrası, Touch ID etkinse Keychain kaydı yeni anahtarla güncellenir (sil+yaz);
  eski anahtarla `credstore_unlock_biometric` artık başarısız olur (unit test — gerçek Keychain'e dokunmadan,
  saf mantık simüle edilir).
- **AC6:** `biometric_unlock_available()` (senkron, prefs dosyasından) → UI "Unlock with Touch ID" butonunu
  yalnız etkinse gösterir; Keychain'e dokunmaz (promptu tetiklemez).
- **AC7:** Frontend'de 15dk etkileşimsizlik → store kilitliyse no-op, açıksa `credstore_lock` çağrılır;
  herhangi bir görünümde (sadece SSH sayfasında değil) çalışır.
- **AC8:** cargo + tsc + npm yeşil. Gerçek Touch ID promptu **canlı app'te operatör teyidi** (headless test
  biometry'yi tetikleyemez — eski PRD'nin de belirttiği kısıt).

## 5. Entegrasyon (harmony — dosya:satır kanıtı)
- **credstore.rs:** mevcut `Unlocked{key,kdf,data}` (:137), `credstore_unlock`(:354)/`credstore_lock`(:365)/
  `credstore_rekey`(satır ~500) — yeni komutlar bu state'i paylaşır, kripto çekirdeğine dokunmaz.
- **Prefs dosyası:** `debuglog.rs settings_path()`(:36) ile AYNI dizin (`~/.claude/`) ama AYRI dosya —
  `debug_log_set`(:157) tüm dosyayı `{debugLogging,debugLogPath}` ile ÜZERİNE YAZIYOR (merge yok); aynı
  dosyaya `biometricUnlockEnabled` eklemek debug-log tercihini silme riski taşır → ayrı dosya.
- **UI:** `SshPage.tsx StoreTab` (unlock formu) — Touch ID butonu + Enable/Disable toggle eklenir.
- **İdle-timer:** `App.tsx` üst seviye (her zaman mount) — yeni `useEffect`, `document` üzerinde
  mousemove/keydown/mousedown dinler, debounce'lu son-aktivite zaman damgası, `setInterval` kontrolü.
- **Koruma listesi:** master-şifre unlock/lock/rekey akışı, mevcut credstore testleri (250+), agent-facing
  `list_secrets`/`add_secret` broker yolu değişmez.

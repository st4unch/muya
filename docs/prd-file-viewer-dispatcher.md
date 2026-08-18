# Mini-PRD — Dosya viewer dispatcher: resim/PDF görüntüleme + okunamayan ikili dosya için "dışarıda aç"

## 1. Amaç (ne işe yarar)
Bugün TÜM dosyalar Monaco'ya (metin editörü) gönderiliyor. `read_file` UTF-8 metin bekliyor
(`read_to_string`) — bir resme veya PDF'e tıklayınca **hata** görünüyor ("read failed: stream did not
contain valid UTF-8"), kullanıcı içeriği hiç göremiyor. Hedef: resim → gerçek görsel önizleme, PDF →
gömülü PDF görüntüleyici, okunamayan diğer ikili dosyalar → "Varsayılan uygulamada aç" butonu (Finder'ın
kendi programıyla). Metin dosyaları (bugünkü davranış) değişmez.

## 2. Kapsam
- Yeni tab kind'leri: `imgview` (png/jpg/jpeg/gif/webp/bmp/ico/svg), `pdfview` (pdf).
- `openFile()` (tek-tık varsayılan açma) uzantıya göre yönlendirir: resim→`imgview`, pdf→`pdfview`,
  `.md/.mdx`→`mdview` (mevcut), diğer→`editor` (Monaco, mevcut).
- Yeni `ImageViewer.tsx` / `PdfViewer.tsx`: Tauri asset protokolü (`convertFileSrc`) ile native `<img>`/
  `<embed>` render.
- `FileEditor.tsx`'in mevcut hata dalı: UTF-8 decode hatasıysa "Bu dosya metin olarak önizlenemiyor" +
  **Varsayılan uygulamada aç** butonu (mevcut `@tauri-apps/plugin-opener`, ek Rust komutu gerekmez).
- Sağ tık "Open in Muya" davranışı DEĞİŞMEZ — her zaman Monaco/metin zorlar (mevcut .md semantiğiyle aynı).

## 3. Kapsam dışı
- Hex önizleme (deferred — "dışarıda aç" yeterli, ayrı bir iş).
- Video/audio player, ofis dosyaları (docx/xlsx) önizleme.
- Resim/PDF **düzenleme** — salt görüntüleme.

## 4. Kabul Kriterleri (binary)
- **AC1:** `tauri = { features: [...] }` `protocol-asset` içerir (şu an YOK — derlenmiyor); build başarılı.
- **AC2:** Yeni `allow_asset_path(path)` komutu ilgili dosyayı `app.asset_protocol_scope().allow_file()`
  ile açar (dosya-bazlı, dizin değil); `read_file`'la aynı emsal — path'e ekstra kısıtlama yok (operatör
  zaten Finder'dan her yere erişir).
- **AC3:** Bir `.png`/`.jpg` dosyasına tıklayınca `imgview` sekmesi açılır, gerçek görsel render olur
  (hata değil).
- **AC4:** Bir `.pdf`'e tıklayınca `pdfview` sekmesi açılır, PDF gömülü görüntüleyicide açılır.
- **AC5:** Okunamayan ikili bir dosyaya (ör. `.bin`) tıklayınca Monaco sekmesi hata yerine "önizlenemiyor
  + Varsayılan uygulamada aç" gösterir; buton gerçekten Finder'ın varsayılan programını açar.
- **AC6:** `.md/.mdx` ve metin dosyaları davranışı DEĞİŞMEZ (regresyon yok). Sağ tık "Open in Muya" resim
  için bile Monaco'yu zorlar (mevcut .md semantiğiyle tutarlı).
- **AC7:** cargo + tsc + npm yeşil.

## 5. Entegrasyon (harmony — dosya:satır kanıtı)
- **Kök neden:** `fs.rs:52` `read_file` → `read_to_string` (UTF-8 zorunlu); `App.tsx:375` `openFile` yalnız
  `.md/.mdx`'i ayırıyor (`isMarkdown`, :370), gerisi `openEditor` (:361, kind:"editor").
- **Asset protokolü kanıtı:** `tauri.conf.json:21` CSP zaten `asset:`/`http://asset.localhost` izinli ama
  `app.security.assetProtocol` hiç yapılandırılmamış; `Cargo.toml:37` `tauri` features boş →
  `protocol-asset` derlenmiyor (kaynak: `tauri-2.11.3/src/lib.rs:761` `asset_protocol_scope()`
  `#[cfg(feature = "protocol-asset")]`; `Cargo.toml:117` `protocol-asset = ["http-range"]`, default'ta
  YOK). `scope::fs::Scope::allow_file(path)` (`tauri-2.11.3/src/scope/fs.rs:370`) runtime'da tek dosya
  izni verir. Frontend: `@tauri-apps/api/core` `convertFileSrc(path)` zaten mevcut (node_modules'te
  doğrulandı).
- **Tab render:** `App.tsx:2276` `kind==="editor"||"mdview"` dalı — `imgview`/`pdfview` için yeni dal
  eklenir, aynı `Suspense`/lazy-import deseni (`MarkdownView`/`FileEditor` gibi).
- **"Dışarıda aç":** `@tauri-apps/plugin-opener` zaten npm bağımlılığı + `opener:default` capability
  izinli (`capabilities/default.json`) — yeni izin gerekmez.
- **Koruma listesi:** `read_file`/`write_file`/Monaco akışı, `.md` davranışı, sağ tık "Open in Muya"
  semantiği değişmez.

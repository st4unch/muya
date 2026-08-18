---
status: done
prd: (mini, no separate doc — small follow-up to prd-vault-ux)
started: 2026-08-17
completed: 2026-08-17
---

## Faz Çıktıları
**P1 (2026-08-17):** 3 iş. (1) **Kopyalama fix (app-genelinde bug):** `navigator.clipboard.writeText()`
Tauri WKWebView'da "NotAllowedError" ile başarısız oluyordu — web Clipboard API izin/focus modeli native
webview'a temiz map olmuyor. `tauri-plugin-clipboard-manager` eklendi (Cargo + npm + capability +
lib.rs registration) + `src/lib/clipboard.ts` (`copyToClipboard`, native+fallback) ile 5 dosyadaki TÜM
`navigator.clipboard.writeText` çağrısı değiştirildi (SshPage, App, SessionsPage, ChatView, FileTree).
(2) **Genel credential import:** `credstore_import_secret` (herhangi secretKind, `trim_imported_secret`
saf fonksiyonu ile +test) — "Import SSH key" (kind-locked) yanında "Import credential" (password/token/
api_key/key) eklendi. Export zaten vardı (per-item, mevcut). (3) **Arama:** Password Store + Servers'a
arama kutusu (label/username/group/host/tag/note), eşleşen gruplar collapse durumundan bağımsız açık kalır.
Doğrulama: cargo 251 (+2 test) / npm 97 (+2 test) / tsc temiz.

## Değişiklikler
| Tarih | Dosya | Ne değişti | Konu |
|-------|-------|-----------|-----|
| 2026-08-17 | src-tauri/Cargo.toml, capabilities/default.json, src/lib.rs | tauri-plugin-clipboard-manager eklendi + izin | Copy fix |
| 2026-08-17 | src/lib/clipboard.ts (YENİ) | copyToClipboard (native+fallback) | Copy fix |
| 2026-08-17 | src/App.tsx, SshPage.tsx, SessionsPage.tsx, ChatView.tsx, FileTree.tsx | navigator.clipboard → copyToClipboard | Copy fix |
| 2026-08-17 | src-tauri/src/credstore.rs | credstore_import_secret + trim_imported_secret (+test) | Import |
| 2026-08-17 | src/components/SshPage.tsx | Import credential formu, arama kutusu (StoreTab+ServersTab), collapse-override | Import+Search |
| 2026-08-17 | src/components/SshPage.test.tsx | +2 test (arama, import-form açılışı) | Test |

## Kararlar
- **Merkezi clipboard helper:** her dosyada ayrı import/fallback yazmak yerine tek `copyToClipboard`;
  native başarısız olursa web API'ye düşer (test ortamı gibi plugin mock'suz yerlerde de çalışır).
- **Import: tek trailing-newline trim, key hariç:** dosya-yapıştırma editörlerinin eklediği tek `\n`
  düşürülür; PEM/key byte-byte korunur (multi-line, çoklu newline etkilenmez).
- **Arama sırasında collapse override:** `collapsed={q ? false : collapsed.has(name)}` — kullanıcı ararken
  eski collapse tercihi sonucu gizlemiyor.

## Dersler

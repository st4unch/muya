---
status: done
prd: docs/prd-file-viewer-dispatcher.md
started: 2026-08-18
completed: 2026-08-18
---

## Faz Çıktıları
**P1 (2026-08-18):** 7/7 AC. `Cargo.toml` `tauri` features'a `protocol-asset` eklendi (yoktu, derlenmiyordu —
kaynakta doğrulandı). `tauri.conf.json` `security.assetProtocol.enable:true` + CSP `object-src` (embed için).
Yeni `allow_asset_path` komutu (`fs.rs`, dosya-bazlı `asset_protocol_scope().allow_file()`, `read_file` ile
aynı emsal — ekstra path kısıtlaması yok). Frontend: `lib/format.ts` `viewerKindFor` (saf, +4 test) →
`openFile` bunu kullanıyor; yeni `ImageViewer.tsx`/`PdfViewer.tsx` (lazy, `convertFileSrc` ile asset://).
`FileEditor.tsx` UTF-8-decode hatasında "Open in default app" (mevcut `@tauri-apps/plugin-opener`, ek izin
yok). `lib/tabs.ts TabLike.kind` genişletildi (grup-bazlı `pickNextActiveKey` mantığı otomatik kapsadı).
Doğrulama: cargo check+251 test / tsc temiz / npm 101 test (+4) / **gerçek `npm run build`** (ImageViewer/
PdfViewer ayrı chunk üretti, hata yok).

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-08-18 | src-tauri/Cargo.toml | tauri features += protocol-asset | AC1 |
| 2026-08-18 | src-tauri/tauri.conf.json | assetProtocol.enable + CSP object-src | AC1,AC4 |
| 2026-08-18 | src-tauri/src/fs.rs, lib.rs | allow_asset_path komutu + kayıt | AC2 |
| 2026-08-18 | src/lib/format.ts, format.test.ts | viewerKindFor (+4 test) | AC3,AC4,AC6 |
| 2026-08-18 | src/components/ImageViewer.tsx, PdfViewer.tsx (YENİ) | asset:// tabanlı görüntüleyiciler | AC3,AC4 |
| 2026-08-18 | src/components/FileEditor.tsx | UTF-8-hatası → "Open in default app" | AC5 |
| 2026-08-18 | src/App.tsx | lazy import, tab dispatch, tab-bar ikon, startup/drop dispatch openFile'a | AC3,AC4,AC6 |
| 2026-08-18 | src/lib/tabs.ts | TabLike.kind genişletildi | AC6 |

## Kararlar
- **Dosya-bazlı asset scope (`allow_file`, dizin değil):** bir resmi açmak tüm klasörü webview'a açmasın.
- **`.md` semantiğiyle tutarlılık:** sağ tık "Open in Muya" resim/PDF için de Monaco'yu zorlar — yeni özel
  durum eklenmedi.
- **Hex önizleme kapsam dışı bırakıldı** ("dışarıda aç" yeterli MVP; ayrı iş).

## Dersler

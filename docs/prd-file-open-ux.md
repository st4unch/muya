# Mini-PRD — Dosya Açma UX'i: drag-drop + Finder association + New File/Folder

## 1. Amaç (ne işe yarayacak)
Kullanıcının dosyaları Muya'da açması üç yeni yoldan mümkün olsun:
1. **Pencereye sürükle-bırak** → dosya viewer'da (Monaco) açılır.
2. **macOS Finder "Open With → Muya"** → `.pem/.key/.crt/.conf/.ini` dahil metin dosyaları.
3. **Sol dosya ağacında sağ tık → New File / New Folder** → seçili klasörde oluştur.

## 2. Kapsam
- Dışarıdan (Finder/masaüstü) sürüklenen **dosya** → viewer'da aç. Sürüklenen **klasör** → workspace root olarak ekle.
- Finder dosya-tipi ilişkilendirmesine eksik uzantıları ekle (`.pem`, `.key`, `.crt`, `.cer`, `.conf`, `.cfg`, `.ini`, `.properties`, `.sql`, `.lock`, `.dockerfile`, `.gitignore`).
- Dosya ağacı context menüsüne **New File** + **New Folder** (klasör, root ve dosya öğelerinde; dosyada = kardeş olarak parent'ta).

## 3. Kapsam dışı
- Resim/PDF/hex viewer (ayrı "dosya viewer dispatcher" todo'su — bu PRD metin/Monaco ile sınırlı).
- Binary (non-UTF-8) dosya render'ı — `read_file` `read_to_string` olduğundan hata gösterir (mevcut davranış korunur).

## 4. Kabul Kriterleri (binary)
- **AC1:** Finder'dan Muya penceresine bir `.pem` dosyası sürüklenince Monaco sekmesinde içeriğiyle açılır; view `control`e geçer.
- **AC2:** Bir **klasör** pencereye sürüklenince workspace listesine root olarak eklenir (zaten varsa yinelenmez).
- **AC3:** Sürükleme sırasında pencerede görsel drop-overlay ("Drop to open") görünür; drop/leave sonrası kaybolur.
- **AC4:** `tauri.conf.json` `fileAssociations` ext listesi `pem,key,crt,cer,conf,cfg,ini,properties,sql,lock,dockerfile,gitignore` içerir.
- **AC5:** `create_dir` Rust komutu eklenir + `invoke_handler`'a kayıtlıdır; workspace-altı bir yolda klasör oluşturur, mevcutsa hata vermez.
- **AC6:** Ağaçta klasöre sağ tık → **New Folder** → inline isim → Enter: klasör oluşur, fs-watcher ile ağaç tazelenir.
- **AC7:** Ağaçta klasöre/dosyaya sağ tık → **New File** → inline isim → Enter: dosya oluşur ve Monaco'da açılır (dosyada context ise parent klasörde oluşur).
- **AC8:** `cargo test` + `npx tsc --noEmit` + `npm test` yeşil.

## 5. Entegrasyon (harmony — dosya:satır kanıtı)
- **Drag-drop:** `src/App.tsx` — mevcut tek `onDrop` (`App.tsx:2193`) sadece terminal sekme sıralaması; OS drop dinleyicisi **yok**. Tauri v2 default `dragDropEnabled:true` → `getCurrentWebview().onDragDropEvent` (`@tauri-apps/api/webview`, `node_modules/@tauri-apps/api/webview.js` mevcut) ile dinlenir. Açma için mevcut `openFile` (`App.tsx:373`) ve `addWorkspace`/`setWorkspaces` (`App.tsx:1180,595`) kullanılır.
- **Finder association:** `RunEvent::Opened` handler **zaten kurulu** (`src-tauri/src/lib.rs:333-349`) → `STARTUP_FILES` + `apex://open-file` emit; frontend `get_startup_files` + `listen("apex://open-file")` → `openEditor` (`App.tsx:804-816`). Sadece `tauri.conf.json bundle.fileAssociations[0].ext` genişletilir.
- **New File/Folder:** `create_file` mevcut (`src-tauri/src/fs.rs:71`, `valid_mutable_path` `validate.rs:61`). `create_dir` aynı kalıpla eklenir. UI: `FileTree.tsx` context menu (`:464-568`), `CtxMenu` tipi (`:19`), inline-input kalıbı `confirmDelete` (`:502`) + `renamingPath` (`:204`) referans. Tazeleme: fs-watcher `fs-changed` → `fsTick` → `refreshSignal` (`App.tsx:553,1708`; TreeNode `:74` reload).
- **Koruma listesi:** mevcut terminal-tab drag reorder (`App.tsx:2193`), rename/delete akışları, `read_file` 5MB cap kırılmaz.

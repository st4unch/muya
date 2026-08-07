---
status: done
prd: docs/prd-file-open-ux.md
started: 2026-08-07
completed: 2026-08-07
---

## Faz Çıktıları
**P1 (2026-08-07) — orchestrator (opus) impl:** 8/8 AC kod+unit. Drag-drop (App.tsx onDragDropEvent+overlay),
Finder ext genişletme (tauri.conf), create_dir+path_kind (fs.rs)+kayıt (lib.rs), New File/Folder context menu
(FileTree.tsx inline input + localRefresh lever), watcher trailing-edge fix (kullanıcı raporu: dış dosya
eklemede ağaç yenilenmiyor). Ek: MCP entry rename muya-ssh→muya-mcp (broker/sidecar/remove_mcp migration).
tsc✓ / cargo check✓ / npm 92✓ / cargo 229✓ (2 yeni remove_mcp testi). Canlı GUI teyidi operatör.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-08-07 | src-tauri/src/watcher.rs | Leading-only debounce → leading + trailing-edge flusher thread (stop-flag'li); dış değişiklik artık yutulmuyor | (bugfix) |
| 2026-08-07 | src-tauri/src/fs.rs | create_dir + path_kind + remove_mcp(+_at) komutları + 2 test | AC5,drag-drop |
| 2026-08-07 | src-tauri/src/lib.rs | create_dir + path_kind invoke_handler kaydı | AC5 |
| 2026-08-07 | src-tauri/tauri.conf.json | fileAssociations ext: pem/key/crt/cer/conf/cfg/ini/properties/sql/lock/dockerfile/gitignore | AC4 |
| 2026-08-07 | src/App.tsx | onDragDropEvent → dosya=openFile, klasör=workspace + drop overlay | AC1,AC2,AC3 |
| 2026-08-07 | src/components/FileTree.tsx | New File/Folder menü (file/folder/root) + inline input + localRefresh (anlık tazeleme) | AC6,AC7 |
| 2026-08-07 | src-tauri/src/broker.rs | MCP_ENTRY_NAME muya-mcp + legacy muya-ssh temizleme (register_mcp) | (rename) |
| 2026-08-07 | src-tauri/src/bin/muya_ssh_mcp.rs | SERVER_NAME muya-mcp (socket adı IPC eşleşmesi için kalır) | (rename) |

## Kararlar
- **2026-08-07 — Finder association altyapısı zaten kurulu:** `RunEvent::Opened`+`STARTUP_FILES`+`apex://open-file` (lib.rs:333) ve frontend listener (App.tsx:804) mevcut; tek eksik `fileAssociations` ext listesi (`.pem` vb. yok). Yeniden yazılmadı, genişletildi.
- **2026-08-07 — .pem/.yaml zaten destekli:** `read_file` uzantı filtresi yok, Monaco düz metin/yaml render eder. "Destek yok" algısı drag-drop'un çalışmamasından; drag-drop düzelince çözülür.
- **2026-08-07 — Klasör drop → workspace root:** dosya drop=viewer, klasör drop=workspace ekle (en sezgisel; ayrı soru sormadan).

## Dersler

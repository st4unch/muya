---
status: done
prd: docs/prd-vault-ux.md
started: 2026-08-17
completed: 2026-08-17
---

## Faz Çıktıları
**P1 (2026-08-17):** 8/8 AC. Backend (orchestrator): `group` alanı Credential/CredMeta/CredInput (credstore.rs)
+ Server (ssh.rs), serde `default` → eski vault/config dosyaları hatasız yükleniyor (+test), upsert korur.
UI (subagent, spec'e göre): `w-full` (max-w-4xl kalktı) + grup içi `md:grid-cols-2 2xl:grid-cols-3`;
`useCollapsedGroups`/`GroupCard`/`GroupField` helper'ları; collapse `muya.vault.collapsed` /
`muya.servers.collapsed`'da kalıcı; **yerinde edit** (`draft?.id === c.id` → satır forma dönüşür, yeni kayıt
üstte); grup alanı datalist'li. Doğrulama (orchestrator bağımsız koştu): tsc temiz, npm 92→**95** (+3 yeni test:
gruplama+collapse+persistence, cred edit-in-place, server edit-in-place), cargo **248**.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-08-17 | src-tauri/src/credstore.rs | Credential/CredMeta/CredInput `group` + upsert + back-compat testi | AC1,AC2 |
| 2026-08-17 | src-tauri/src/ssh.rs | Server `group` | AC1,AC6 |
| 2026-08-17 | src/components/SshPage.tsx | grup kartları, collapse, yerinde edit, tam genişlik, GroupField | AC3-AC7 |
| 2026-08-17 | src/components/SshPage.test.tsx, src/test/setup.ts, src/dev/mockBackend.ts | +3 test, localStorage shim, mock `group` | AC8 |

## Kararlar
- **Serbest-metin `group`** (boş = "Ungrouped", listede sona): kullanıcı-tanımlı gruplama; `tags` alanına
  dokunulmadı (ayrı amaç). Datalist ile mevcut gruplardan seçim + yeni yazma.
- **Yerinde edit** (`draft.id === item.id` satırda form): kullanıcı yerini kaybetmesin; yeni kayıt üstte.
- **Test setup'a localStorage shim:** jsdom bare object veriyordu → collapse kalıcılığı test edilebilir oldu.

## Dersler

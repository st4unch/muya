---
status: done
prd: docs/prd-schedules.md
started: 2026-10-14
---

## Faz Çıktıları
- Rust `schedules.rs`: model, next_after (interval/daily/weekly, DST), saklama (atomik, 0600/0700), çalıştırıcı (login-shell env, process group, timeout, 64 KB), zamanlayıcı (15 sn tick, kilit dosyası, en fazla 3 paralel), komutlar, agent API.
- UI: `SchedulesPage.tsx` (rapor kartları, iş kartları, Edit/History/Delete dialogları), `lib/schedules.ts`, rail öğesi.
- MCP (operatör isteği, PRD sonrası eklendi): broker `schedule*` op'ları + sidecar'da 7 araç.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-14 | src-tauri/src/schedules.rs | yeni modül | AC3-AC9, AC12 |
| 2026-10-14 | src-tauri/src/lib.rs | manage + komutlar + start | AC5 |
| 2026-10-14 | src/components/SchedulesPage.tsx, src/lib/schedules.ts | sayfa + model | AC1, AC2, AC10-AC14 |
| 2026-10-14 | src/components/modalKit.tsx, SettingsModal.tsx | ortak modal parçaları (L65) | AC14 |
| 2026-10-14 | src/redesign/Rail.tsx, types.ts, icons.tsx, src/App.tsx | rail + view | AC1 |
| 2026-10-14 | src-tauri/src/broker.rs, src/bin/muya_ssh_mcp.rs | MCP araçları | (ek kapsam) |
| 2026-10-14 | src/mock/schedulesMock.ts, installMock.ts | tarayıcı mock'u (UI testi) | — |

## Kararlar
- software-architect incelemesi: `-i`'siz çalıştırma, env bir kez yakalanır (önce `-l -i` 8 sn sınırla, sonra `-l`); process group öldürme; prompt `--` sonrası argv; kilit dosyasıyla tek zamanlayıcı; global 3 slot; izin modu iş başına (varsayılan bypass, operatör "tüm MCP açık" istedi).
- Kaçan çalışmalar telafi edilmez; uyku sonrası tek çalışma (next = now'dan).
- Agent geçmişinde çıktı 8000 karakterle sınırlı.

## Dersler
- L65: yeni dialog SettingsModal kalıbıyla kurulur; ilk sürüm iki stil sistemini karıştırdı, operatör yakaladı.

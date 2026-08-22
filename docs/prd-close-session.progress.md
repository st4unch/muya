---
status: done
prd: docs/prd-close-session.md
started: 2026-08-22
completed: 2026-08-22
---

## Faz Çıktıları
**Tek faz (2026-08-22):** AC1-AC6 tamamı geçti. `ssh_send`'in sahiplik-kısıtı deseni (`SSH_SESSIONS`)
birebir kopyalanıp `AGENT_OPENED_SESSIONS` (isim-bazlı, çünkü open_session kendi session-id icat
etmiyor) olarak eklendi. `close_session` adresleme için `send_to_session`'la AYNI `resolve_target`
akışını kullanıyor, kapatma için mevcut `closeTerminal` fonksiyonu yeniden kullanıldı — yeni kill
mekanizması yazılmadı. Doğrulama: `cargo test --lib` 259/259 (+2 yeni), `tsc` temiz, `npm test`
102/102, sidecar canlı `tools/list` 21 tool + `close_session` şeması doğru.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-08-22 | src-tauri/src/broker.rs | `AGENT_OPENED_SESSIONS` + register/is_open/release, `handle_open_session` artık kaydediyor, `handle_close_session` (resolve+sahiplik kontrolü), `"close_session"` op, 1 test | AC2, AC3, AC6 |
| 2026-08-22 | src-tauri/src/lib.rs | `release_agent_session` komutu (kayıt) | AC3 |
| 2026-08-22 | src-tauri/src/bin/muya_ssh_mcp.rs | `close_session` tool şema+handler | AC1 |
| 2026-08-22 | src/App.tsx | tab key prefix `agent:`→`aopen:`, `muya://close-agent-session` listener, `closeTerminal`'a release-on-close eklendi (openTerminalsRef ile, stale-closure güvenli) | AC4, AC5 |

## Kararlar
- **İsim-bazlı sahiplik seti (id değil):** `open_session` kendi session-id icat etmiyor (PRD
  agent-session-open kararı) — adresleme `claude agents --json` üzerinden isimle oluyor, sahiplik
  de aynı anahtarla (`name`) takip ediliyor.
- **`openTerminalsRef` kullanıldı, `openTerminals` state'i değil:** `closeTerminal` artık
  `muya://close-agent-session`'ın mount-once (`[]` deps) listener'ından da çağrılabiliyor — stale
  closure'dan kaçınmak için ref şart (kodun geri kalanında zaten kurulu pattern, `App.tsx:717-718`).
- **Fire-and-forget aynı open_session'daki gibi:** broker "ok" dönse bile frontend tab'ı gerçekten
  bulup kapattığının garantisi yok (henüz keşfedilmemişse). Bilinen, belgelenen sınır — yeni bir
  ack/nack round-trip mekanizması bu PRD'nin scope'unda değil.

## Dersler
- `ssh_send`'in sahiplik-kısıtı deseni ikinci kez kullanıldı (önce SSH, şimdi open_session) —
  codebase'te kurulu bir "sadece kendi açtığını değiştirebilirsin" konvansiyonu var, yeni bir
  feature'da güvenlik kararını sıfırdan tasarlamak yerine bunu ara.

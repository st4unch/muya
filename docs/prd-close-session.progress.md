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

## P2 — operatörün "popup'lara cevap verdirebilir miyiz?" sorusu (2026-08-22)
Aynı oturumda, `close_session` bittikten hemen sonra gelen takip talebi. İncelerken **gerçek bir bug**
bulundu ve düzeltildi — kod yazmadan önce test etmese idi fark edilmezdi:

1. **`open_session` ile açılan taze bir oturum, hiç görmediği bir `cwd`'de "bu klasöre güveniyor
   musun?" ekranında TAKILIYORDU** — `--dangerously-skip-permissions` bile bunu atlamıyor (PRD
   agent-session-open'da zaten bilinen sınır olarak not edilmişti). Takılı kaldığı sürece
   `claude agents --json`'a kaydolmuyor → `list_sessions`/`send_to_session` onu bulamıyor → tavuk-
   yumurta. Operatör onayıyla (AskUserQuestion): **open_session artık bu ekranı otomatik "evet,
   güveniyorum" ile geçiyor** (Muya workspace'leri zaten operatörün güvendiği yerler,
   `--dangerously-skip-permissions` zaten daha yüksek bir güven eşiği). Uygulama: `Terminal.tsx`'e
   yeni `autoAcceptTrust` prop'u — ilk komuttan (600ms) sonra, 4.6sn'de (canlı test edilmiş süre:
   claude'nin kendi başlama + trust-prompt render süresi) boş bir Enter daha yazıyor. **Zaten
   güvenilir bir `cwd`'de de zararsız** — canlı test edildi, prompt zaten işlenmeye başlamışken
   gelen fazladan Enter hiçbir şeyi bozmuyor.
2. **`send_to_session(deliver:"muya")` bir onay ekranını cevaplamak için KULLANILAMAZDI** — bu mod
   metni her zaman `"[message from X via Muya] ..."` diye SARIYOR; bu sarma metni menünün üzerine
   YAZILIRDI (her tuş vuruşu menüde işlenir), cevabı değil rastgele karakterleri gönderirdi. Bunu
   fark etmeseydim "popup cevaplama" özelliği yayınlanır ama ilk denemede menüyü bozardı. **Fix:**
   yeni `deliver:"keys"` modu — `text`'i SARMADAN ham tuş vuruşu olarak yazıyor (`broker.rs`
   `muya://deliver-message`'a `raw:true` flag'i, `App.tsx` dinleyicisi buna göre dallanıyor).
3. **`list_sessions` artık `waitingFor` alanını gösteriyor** (`claude agents --json`'ın kendi
   verdiği ama önceden hiç okunmayan bir alan — `agents.rs` `RawAgent`/`AgentSession`'a eklendi) —
   agent bir oturumun NEDEN beklediğini (örn. "permission prompt") görüp `deliver:"keys"` ile
   cevaplayabiliyor.

Doğrulama: `cargo test --lib` 260/260 (+2 yeni: agent_session_registration_gates_close zaten
sayılmıştı, +map_agent_threads_waiting_for_through) / tsc temiz / npm 102 / sidecar canlı tools/list
(21 tool, güncellenmiş şemalar). **Canlı PTY testi** (gerçek `claude` binary, izole süreç, host
Muya'ya dokunulmadı): Muya'nın TAM sekansı (shell spawn → 600ms'de komut yaz → 4.6sn'de boş Enter)
taze/güvenilmeyen bir dizine karşı çalıştırıldı — trust prompt otomatik geçildi, ilk mesaj işlendi
ve "OK" cevabı geldi, oturum adı terminal başlığında doğru göründü. `list_sessions`/`send_to_session`
tool açıklamalarındaki çapraz-referans hatası (list_sessions hâlâ eski `deliver:"muya"`'ya işaret
ediyordu) canlı `tools/list` çıktısını okurken yakalandı, düzeltildi.

İlgili: [[agent-session-open]] (trust-prompt sınırı orada belgeliydi), [[session-messaging]]
(`send_to_session`'ın deliver modları orada tanımlıydı).

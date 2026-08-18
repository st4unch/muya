---
status: done
prd: (mini, no separate doc — small follow-up to prd-ssh-session)
started: 2026-08-18
completed: 2026-08-18
---

## Faz Çıktıları
**P1 (2026-08-18):** Operatör sordu "garbage collector var mı" → araştırdım: yoktu, `agent_ssh` kalıcı
oturumlarının hiçbir otomatik temizliği yoktu (agent unutup kapatmazsa PTY+PSMP bağlantısı süresiz açık
kalırdı). Eklendi: `Session.last_used: Mutex<Instant>` (her `exec` başında güncellenir), `IDLE_TIMEOUT`
(30 dk), `reap_idle(store, timeout)` (idle session'ları `close()` ile kapatır, id listesi döner). `lib.rs`
setup'ta 5 dk'da bir koşan arka plan task'ı (`tauri::async_runtime::spawn` + `spawn_blocking`), reap edilen
id'leri debug log'a yazar.

**Ek kritik fix (aynı incelemede bulundu):** `exec()` önceden **tüm store kilidini** komutun süresi boyunca
(varsayılan 120s'ye kadar) tutuyordu — bir session çalışırken diğer TÜM session'ların open/exec/close'u VE
reaper bloke oluyordu (10-session senaryosunda ciddi). Fix: `exec` artık Arc'lı `writer`/`buffer`'ı çıkarıp
map kilidini HEMEN bırakıyor; sadece o session'ın kendi alt-kilitleri (writer/buffer Mutex) kalıyor.

Doğrulama: **gerçek bash PTY** ile 2 e2e test (`--ignored`, açıkça koşuldu) — mevcut mekanizma testi +
yeni `reap_idle_closes_only_sessions_past_the_timeout` (stale session kapatılır, fresh session hayatta
kalır). cargo check + 251 test yeşil.

## Değişiklikler
| Tarih | Dosya | Ne değişti |
|-------|-------|-----------|
| 2026-08-18 | src-tauri/src/agent_ssh.rs | last_used alanı, IDLE_TIMEOUT, reap_idle, exec lock-erken-bırakma fix, +2 test |
| 2026-08-18 | src-tauri/src/lib.rs | 5dk periyodik reaper task |

## Kararlar
- **30 dk idle timeout:** cömert (gerçek karşılıklı iş kesilmesin) ama sınırlı (unutulan oturum süresiz yaşamaz).
- **exec lock-fix aynı işe dahil edildi (dar kapsam):** reaper'ın gerçekten çalışabilmesi için gerekliydi
  (aksi halde reaper, uzun bir exec süresince map kilidini hiç alamazdı) — pragmatik, tek dosya, düşük risk.

## Dersler

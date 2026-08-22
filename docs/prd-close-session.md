# Mini-PRD: close_session (yeni MCP tool)

- Tarih: 2026-08-22
- Tür: mini-PRD

## 1. Problem
`open_session` (PRD `agent-session-open`, v0.2.38) agent'a yeni bir Claude terminal tab'ı açma
yetkisi verdi ama onu **kapatma** yetkisi vermedi — agent açtığı bir oturumu işi bitince
sonlandıramıyor, tab elde kalıyor.

## 2. Scope
- Dahil: yeni sidecar tool `close_session(target)`; broker `"close_session"` op'u; frontend'de
  tab kapatma event'i; **sahiplik kısıtı** — agent sadece `open_session` ile AÇTIĞI oturumları
  kapatabilir (operatörün elle açtığı ana sohbeti veya "+ New Agent" ile açtığı tab'ları DEĞİL).
- Hariç: ssh oturumlarını kapatma (zaten `ssh_release_session`/UI'dan var); `agent_ssh` (headless
  PTY, Faz 2) kapatma (zaten `ssh_session_close` var, alakasız alt-sistem).

## 3. Kabul Kriterleri (binary) — tümü ✅ done (2026-08-22)
- [x] AC1: Sidecar `close_session(target)` tool'u `tools/list`'te doğru şemayla görünüyor
      (`target` required). **Canlı doğrulandı:** gerçek binary'ye stdio JSON-RPC gönderildi, 21 tool
      döndü, `close_session` şeması beklenen şekilde.
- [x] AC2: Broker `"close_session"` op'u — `target` boşsa reddediliyor; `resolve_target` ile
      çözümleniyor (id/tam-isim/substring, çoklu eşleşmede asla tahmin etmiyor — `send_to_session`
      ile AYNI davranış); çözülen oturum `open_session` ile açılmamışsa **reddediliyor** (sahiplik
      kısıtı — `ssh_send`'in "sadece kendi açtığın session'a yazabilirsin" kısıtıyla aynı desen).
- [x] AC3: `open_session` artık açtığı her ismi bir sahiplik kaydına (`AGENT_OPENED_SESSIONS`,
      `SSH_SESSIONS`'ın aynısı desen) ekliyor; `close_session` başarılı olunca kaydı temizliyor
      (idempotent — test edildi).
- [x] AC4: Frontend, kapatma event'ini dinleyip `sessionIdToKeyRef` üzerinden doğru tab'ı bulup
      MEVCUT `closeTerminal(key)` fonksiyonunu çağırıyor — yeni bir kapatma mekanizması YAZILMADI.
- [x] AC5: Hedef tab henüz `sessionIdToKeyRef`'te yoksa (yeni açılmış, ~15sn'lik keşif penceresi
      henüz dolmamış) veya zaten kapalıysa, no-op (bilinen sınır — ssh_open/open_session'ın
      fire-and-forget davranışıyla aynı, PRD agent-session-open'da zaten belgeli).
- [x] AC6: `cargo test --lib` 259/259, `npm test` 102/102, `npx tsc --noEmit` temiz.

## 4. Koruma Listesi (dokunulmayacak)
- `ssh_send`/`ssh_session_close`/`agent_ssh` — ayrı alt-sistemler, dokunulmuyor.
- Operatörün elle açtığı (ana sohbet, "+ New Agent" butonu) terminaller — `close_session` bunları
  KAPATAMAZ (sahiplik kısıtı, AC2/AC3).
- `closeTerminal`'ın dirty-check/confirm-dialog davranışı (dosya sekmeleri için) — terminal
  kind'inde zaten hep `false` döner, dokunulmuyor.

## 5. Entegrasyon / Harmony (ZORUNLU)
- **Sahiplik deseni:** `broker.rs`'te zaten `SSH_SESSIONS: HashSet<String>` +
  `register_ssh_session`/`ssh_session_is_open`/`release_ssh_session` (broker.rs:56-74) — `ssh_send`
  bunu "sadece açtığın session'a yaz" kısıtı için kullanıyor (broker.rs:711-717, `handle_send`).
  `open_session`'a AYNI desende yeni bir `AGENT_OPENED_SESSIONS: HashSet<String>` eklenir — `name`
  bazlı (open_session zaten kendi session-id icat etmiyor, PRD `agent-session-open`'ın kararı,
  adresleme `claude agents --json` üzerinden isimle oluyor).
- **Adresleme:** `close_session` `resolve_target`+`running_sessions()`'ı `send_to_session` ile
  AYNI şekilde kullanır (broker.rs:915+, `handle_send_to_session`) — çözülen `(id, name)` çiftinden
  `name`'in `AGENT_OPENED_SESSIONS`'ta olup olmadığına bakılır.
- **Tab kapatma:** frontend `sessionIdToKeyRef.current[resolvedId]` → tab key → **mevcut**
  `closeTerminal(key)` (`App.tsx:396-417`) — pty_kill zaten `<AgentTerminal>` unmount'ında tetikleniyor
  (dokunulmuyor, yeniden kullanılıyor).
- **Kırma riski:** yeni event adı (`muya://close-agent-session`) mevcut event isimleriyle
  çakışmıyor (grep ile teyit edilecek implementasyon sırasında). Sahiplik kısıtı olmadan bu tool
  operatörün ana sohbetini kapatabilecek kadar tehlikeli olurdu — AC2/AC3 bunu önlüyor, bu yüzden
  scope'a dahil (kritik güvenlik kararı ama pragmatik/dar — mevcut `ssh_send` deseninin birebir
  kopyası, yeni bir mimari değil, operatöre sorulmadan uygulanıyor).

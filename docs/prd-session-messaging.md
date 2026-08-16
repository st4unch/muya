# Mini-PRD — Agent'a session farkındalığı: list / read / send (muya-mcp)

## 1. Amaç (ne işe yarar)
Kullanıcı "password güçlendirme session'ına son durumu gönder" dediğinde, agent **doğru session'ı bulup** oraya mesajı iletebilsin — 2 değil **10 session** varken de. Muya isimlerin/`cwd`'lerin/durumların otoriter kaydını zaten tutuyor (Sessions sekmesinde kullanıcıya gösteriyor); aynı bilgiyi agent'a da veriyoruz. Ayrıca agent başka bir session'ın **konuşma içeriğini okuyabilsin** (native'de yok) — "şu session ne durumda?" mesaj atmadan cevaplanır.

Native `ListAgents`/`SendMessage` (v2.1.224+) teslimatı kesintisiz yapıyor (*"reads between tool calls"*) ama **isimle** adresliyor ve isimler çakışabiliyor (docs: "Sessions can still share a name"). Muya isim→hedef çözümünü otoriter yapar; teslimatı native'e bırakır.

## 2. Kapsam — 3 tool
- **`list_sessions()`** → çalışan session'lar: `{id, name, cwd, status, isCurrent}`. Muya'nın kaydından (isimler kullanıcının verdiği).
- **`read_session(target, limit?, query?)`** → o session'ın son `limit` turu (default 20) veya `query` ile eşleşen kısımları. Salt-okunur.
- **`send_to_session(target, text, deliver?)`** → `target` (isim/id, fuzzy) tek session'a çözülür:
  - belirsizse → aday listesi döner (agent kullanıcıya sorar),
  - `deliver:"auto"` (default) → **kanonik isim** + "native `SendMessage` ile gönder" direktifi döner (kesintisiz teslimat),
  - `deliver:"muya"` → Muya hedefin terminaline **kendisi** yazar (gönderen etiketiyle) — native yoksa fallback.

## 3. Kapsam dışı
- Teslimat protokolünü yeniden yazmak (native yapıyor). Uzak makine session'ları (aynı makine).
- Başka session'ın dosyalarını/izinlerini değiştirmek — yalnız metin mesajı + salt-okunur transcript.

## 4. Kabul Kriterleri (binary)
- **AC1:** `list_sessions()` yalnız ÇALIŞAN session'ları döner; her biri `{id,name,cwd,status}`; çağıran session `isCurrent:true` ile işaretlenir (kendine göndermesin).
- **AC2:** `read_session(target, limit)` hedefin transcript'inden son `limit` turu döner (user/assistant etiketli). `query` verilirse eşleşen parçalar döner. Transcript yoksa net hata.
- **AC3:** `resolve_target` (saf fonksiyon): tam-id > tam-isim > case-insensitive substring; tek eşleşme → Ok, çok eşleşme → adaylar, sıfır → hata. Unit test.
- **AC4:** `send_to_session(..., deliver:"auto")` tek eşleşmede `{resolved:{id,name}, deliverWith:"SendMessage"}` + agent'a "şu tam isimle SendMessage çağır" metni döner.
- **AC5:** `deliver:"muya"` → Muya hedef sekmenin PTY'sine `[from: <gönderen>] <text>` yazar; hedef bulunamazsa hata.
- **AC6:** Gönderen kimliği her iki yolda da mesaja iliştirilir (agent kendi session'ını `list_sessions`'tan bilir).
- **AC7:** cargo + tsc + npm yeşil; resolve + transcript-tail unit testleri.

## 5. Entegrasyon (harmony — dosya:satır)
- **Session kaydı:** `agents.rs list_agent_sessions_sync` → `AgentSession{id,name,worktree,status}` (`agents.rs:41`). Sessions sekmesi bunu gösteriyor; aynı veri agent'a.
- **Transcript:** `sessions.rs` — `transcript_path(cwd,id)` (:38), `line_text` (:55), streaming okuma (v0.2.27). `read_session` bunları reuse eder (pub(crate) yapılır).
- **Teslimat (muya modu):** `ssh_send` deseni (broker emit → App `pty_write`): App `terminalPtyIds` (key→ptyId) + session poll'daki `sessionByKey` ile claude-session-id → tab key eşlemesi kurulur; broker `muya://deliver-message` emit eder.
- **Broker/sidecar:** `broker.rs` 3 op + `muya_ssh_mcp.rs` 3 tool (iki-hop forward, L36).
- **Koruma:** ssh_* tool'ları, track_plan, session arama/export korunur. Yalnız okuma + metin mesajı; izin/config değişikliği yok.

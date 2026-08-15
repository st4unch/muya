# Mini-PRD — ssh_send: agent kendi açtığı interaktif SSH terminaline yazı gönderir

## 1. Amaç (ne işe yarar)
Agent `ssh_open` ile bir interaktif SSH terminali açtıktan sonra, o terminale **komut/metin yazabilsin** (Playwright'ın sayfaya yazması gibi). Böylece 2FA sonrası veya `ssh_run`'ın kaldıramadığı interaktif akışlarda (TUI, sudo prompt, çok adımlı REPL) agent oturumu sürdürebilir — insan izleyerek.

## 2. Kapsam
- `ssh_open` artık bir **`sessionId`** döndürür (agent bunu saklar).
- Yeni MCP tool **`ssh_send(sessionId, text)`** → o terminalin PTY'sine `text` yazılır (kullanıcı yazmış gibi). `\n` metne dahilse komut çalışır.
- **Güvenlik:** yalnız **bu agent'ın `ssh_open` ile açtığı** session'lara yazılabilir (broker issued-id set'i). Sunucu zaten agent-erişimli olmalı (ssh_open bunu zorluyor). Her `ssh_send` broker log'una audit satırı yazar (sessionId + byte uzunluğu, metin İÇERİĞİ loglanmaz).

## 3. Kapsam dışı
- Terminal ÇIKTISINI agent'a geri döndürmek (bu ssh_run'ın işi; ssh_send fire-and-forget yazımdır — insan ekranda görür). Çıktı okuma ayrı bir gelecek işi.
- Rastgele bir PTY'ye yazma (yalnız agent'ın açtığı ssh session'ları).

## 4. Kabul Kriterleri (binary)
- **AC1:** `ssh_open(alias)` yanıtı `{ok:true, sessionId:"<id>"}` içerir; id broker'ın ürettiği kararlı bir değerdir.
- **AC2:** Broker açılan her `sessionId`'yi bir set'te tutar; `ssh_send` bilinmeyen/başka session'a `err` döner ("unknown or not-yours session").
- **AC3:** `ssh_send(sessionId, "echo hi\n")` çağrısı → App o session'ın PTY'sine metni yazar (`pty_write`), terminalde görünür + komut çalışır.
- **AC4:** `ssh_send` metin içeriğini loglamaz; yalnız `sessionId` + byte sayısı audit'lenir.
- **AC5:** Session kapanınca (tab kapandı) id set'ten düşer; sonraki `ssh_send` `err` döner.
- **AC6:** Sidecar (`muya_ssh_mcp.rs`) `ssh_send` tool şemasını sunar + `structuredContent`'i iki-hop forward eder (L36); `ssh_open` açıklaması sessionId + ssh_send akışını anlatır.
- **AC7:** cargo + tsc + npm yeşil; broker'da issued-set + membership testi.

## 5. Entegrasyon (harmony — dosya:satır)
- **ssh_open akışı:** `broker.rs handle_open` (:353-372) şu an `{ok:true}` döner + `ssh-broker-open {serverId,label}` emit eder → `App.tsx openSshServer` (:854) `ssh:${serverId}:${ts}` key ile tab açar, PTY frontend'de spawn olur. Değişiklik: broker **sessionId üretir** (= tab key ile aynı olacak şekilde `ssh:<serverId>:<nonce>` veya UUID), emit payload'una ekler, `{ok:true, sessionId}` döner; App bu id'yi tab key olarak kullanır (veya map). Broker `issued: Mutex<HashSet<String>>` (yeni WatchState benzeri state) tutar.
- **ssh_send:** yeni `handle_send(app, req)` — issued-set kontrol → `ssh-broker-send {sessionId, text}` emit → App listener `pty_write(ptyId, text)` (mevcut `terminalPtyIds` map: key→ptyId, SessionsPanel'e geçiliyor `App.tsx:2328`). `pty_write` komutu mevcut (`pty.rs`).
- **Kapanış:** App tab kapanınca (`closeTerminal`) broker'a "session kapandı" bildir → issued-set'ten düş. Yeni komut `ssh_broker_session_closed(sessionId)` veya broker'a socket mesajı. (Basit: App `invoke("ssh_session_closed",{sessionId})`.)
- **Sidecar:** `muya_ssh_mcp.rs` tool listesine `ssh_send`; broker'a `{op:"send", sessionId, text}` yollar; yanıtı forward eder (L36 iki-hop).
- **Koruma:** mevcut ssh_run/ssh_open/scp akışları, askpass enjeksiyon, owner-only socket + uid check korunur. Agent yalnız kendi açtığı agent-erişimli session'a yazar.

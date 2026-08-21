---
status: done
prd: docs/prd-agent-session-open.md
started: 2026-08-21
completed: 2026-08-21
---

## Faz Çıktıları
**Tek faz (2026-08-21):** AC1-AC6 tamamı geçti. Sidecar `open_session` tool'u eklendi (`ssh_open`'ın
yerel analogu), broker `"open_session"` op'u + pure `build_open_session_payload` (AppHandle'sız
testlenebilir), frontend `muya://open-agent-session` listener'ı `buildAgentCommand`/`singleQuote`'u
yeniden kullanıyor (yeni quoting kodu yok). Native-vs-custom karşılaştırması PRD §6'ya yazıldı — karar:
`list_sessions`/`read_session`/`send_to_session` KALIYOR, kod değişikliği yok. Doğrulama: `cargo test
--lib` 258/258 (+3 yeni), `tsc` temiz, `npm test` 102/102, sidecar canlı `tools/list` (gerçek stdio
JSON-RPC) 20 tool gösterdi, `open_session` şeması doğru.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-08-21 | src-tauri/src/bin/muya_ssh_mcp.rs | `open_session` tool şeması + handler eklendi | AC1 |
| 2026-08-21 | src-tauri/src/broker.rs | `"open_session"` op, `build_open_session_payload` (pure) + `handle_open_session`, `BrokerReq` `cwd`/`initial_message` alanları, `BrokerReq: Default`, 3 test | AC2, AC5 |
| 2026-08-21 | src/App.tsx | `muya://open-agent-session` listener — `buildAgentCommand`/`singleQuote`/`openTerminal` yeniden kullanıldı | AC3, AC4, AC5 |
| 2026-08-21 | docs/prd-agent-session-open.md | §6 native-vs-custom karar bölümü | AC6 |

## Kararlar
- **Session-id icat etmeye gerek yok:** `list_sessions`/`send_to_session`'ın arkasındaki
  `running_sessions()` doğrudan `claude agents --json`'a dayanıyor — Muya'nın kendi tab/pty
  registry'sinden bağımsız. Yeni açılan `claude --name X` süreci kendi kendine kaydoluyor;
  `open_session` bu yüzden hiçbir senkron registry/nonce mantığı taşımıyor, sadece tab'ı açıp
  `--name` veriyor.
- **İlk mesaj = positional CLI argümanı, gecikmeli ikinci `pty_write` DEĞİL:** `initial_message`
  komut satırına `buildAgentCommand`'ın zaten yaptığı gibi tek pozisyonel argüman olarak ekleniyor —
  claude CLI'nin soğuk-başlama süresini tahmin eden yeni bir timer kodu YOK, race riski yok.
  Var olan kanıtlı 600ms tek-`pty_write` deseni (Terminal.tsx) aynen kullanılıyor.
- **Native vs custom: custom kalıyor.** Resmi docs (cross-session-messaging, 2026-08-21 taze fetch):
  taze bypass-mode (`--dangerously-skip-permissions`) bir oturuma native `SendMessage`'ın varsayılanı
  gönderen de bypass olduğunu bildirmezse **operatör onayına takılıyor** — "sormadan mesaj" garantisi
  YOK. Muya'nın `deliver:"muya"` (doğrudan PTY-write) bu gate'i tamamen bypass ediyor, garanti veriyor.
  Ayrıca native isim-çakışmasına karşı korumasız ("Sessions can still share a name"), `read_session`'ın
  native karşılığı yok. Kod değişikliği yapılmadı — mevcut hibrit zaten doğru tasarlanmıştı.

## Dersler
- [[L45]] — mini-prd'nin "prd-run ile uygulayalım mı?" varsayılan sorusu, operatör zaten net onay
  verdiyse Golden Rule §1'i geçersiz kılmaz; onay netse PRD sonrası durmadan implementasyona geç.
- `running_sessions()`'ın `claude agents --json`'a dayanması (Muya'nın kendi pty/tab registry'sinden
  TAMAMEN bağımsız) — ilk tasarım taslağı yanlışlıkla `register_ssh_session`-stili bir registry
  gerektiğini varsaymıştı; kodu okuyunca (broker.rs:824-830, agents.rs:248-272) bunun gereksiz
  olduğu görüldü. Ders: "X nasıl çalışıyor olmalı" varsayımı yerine önce kodu oku (L128 aynı desen).
- **Canlı doğrulama (2026-08-21, operatör "sen test yapabilirsin sanırım" dedi, haklıydı):**
  gerçek `claude` CLI'ye karşı, bu makinede, PTY üzerinden 4 tur test koştum (host Muya'ya
  DOKUNULMADI — ayrı, izole `pty.fork()` süreçleri, test-adıyla işaretli, temizlendi):
  1. `claude --dangerously-skip-permissions --name X "<prompt>"` gerçekten pozisyonel prompt'u
     REPL hazır olunca kendi işliyor (trust-prompt Enter'dan sonra) — tasarımın kilit varsayımı
     doğrulandı.
  2-3. İlk iki denemede taze session `claude agents --json`'da GÖRÜNMÜYORDU (scratch dizin ve
     gerçek repo dizininde de aynı) — ciddi bir tasarım kırılması gibi göründü.
  4. Kök neden bulundu: test harness'ım kendi ortamının `CLAUDE_CODE_SESSION_ID`/`CLAUDECODE=1`/
     `CLAUDE_CODE_CHILD_SESSION=1` env değişkenlerini spawn edilen sürece SIZDIRIYORDU (python
     `os.execvp` parent env'i miras alır) — taze session kendini benim session'ımın "child"ı sanıp
     bağımsız kayıt olmuyordu. `pty.rs`'nin GERÇEK spawn kodu bu değişkenleri zaten STRIP ediyor
     (`pty_strips_claude_env` testi tam bunu kanıtlıyor, pty.rs:1112+) — env'i taklit ederek
     stripleyince (4. deneme) taze session **anında** `claude agents --json`'da "idle" olarak
     göründü. **Sonuç: tasarım doğru, benim test harness'ım eksikti.** open_session'ın gerçek
     implementasyonu zaten pty.rs üzerinden gidiyor, bu strip zaten var — ek kod gerekmedi.
  **Ders:** Muya dışı bir araçla (python pty.fork vs.) "Muya nasıl davranır" simüle ederken,
  CALLING process'in kendi CLAUDE*/AI_AGENT env'ini spawn edilen sürece SIZDIRMADIĞINDAN emin ol —
  aksi halde yanlış-negatif bir "kırık" sonucuna varılır. Bu genel bir Claude-Code-içinde-Claude-Code
  test etme deseni, sadece bu PRD'ye özgü değil.
  **Ayrı, çözülmemiş edge-case (bilerek scope dışı bırakıldı):** ilk kez görülen bir `cwd`'de
  "trust this folder?" onayı, `--dangerously-skip-permissions` ile bile REPL'i durdurur — pozisyonel
  prompt işlenmeden önce Enter gerekir. Muya'nın workspace'leri operatörün zaten kullandığı/
  güvendiği dizinler olduğundan pratikte nadiren tetiklenir, ama teorik bir gap — ileride
  `open_session`'a otomatik-trust-accept eklenmesi gerekebilir.

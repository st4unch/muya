# Mini-PRD: open_session (yeni MCP tool) + native-vs-custom messaging kararı

- Tarih: 2026-08-21
- Tür: mini-PRD

## 1. Problem
Bir Muya agent'ı, kendi başına yeni bir **yerel** Claude Code oturumu açıp (Muya terminalinde,
`ssh_open`'ın yerel analogu) o oturuma **operatöre sormadan** ilk mesajı gönderebilmeli — bugün
elde sadece `ssh_open` (uzak/ssh hedefler için) ve `list_sessions`/`read_session`/`send_to_session`
(zaten çalışan oturumları adresleme) var; "yeni bir yerel oturum başlat" eksik.

Ayrıca: Muya'nın kendi `list_sessions`/`read_session`/`send_to_session` tool'larının, Claude Code'un
native `ListAgents`/`SendMessage`'ına göre hâlâ gerekli olup olmadığı netleştirilmeli — gerekirse
custom tool'lar kaldırılacak.

## 2. Scope
- Dahil: yeni sidecar tool `open_session(name, cwd?, initial_message?)`; broker `"open_session"` op'u;
  frontend'de yeni tab açma event'i; native-vs-custom karşılaştırma kararı + kanıt.
- Hariç: uzak (ssh/CyberArk) oturum açma (zaten `ssh_open`'da var, dokunulmuyor); oturum kapatma/yönetimi
  (mevcut tab kapatma UI'ı zaten var); `list_sessions`/`read_session`/`send_to_session`'ın kod
  değişikliği (karar: KALIYOR, değişmiyor — bkz. §6).

## 3. Kabul Kriterleri (binary) — tümü ✅ done (2026-08-21)
- [x] AC1: Sidecar (`muya_ssh_mcp.rs`) yeni `open_session` tool'unu `tools/list`'te doğru JSON şemayla
      sunuyor (`name` required, `cwd`/`initial_message` optional). **Canlı doğrulandı:** gerçek
      binary'ye stdio üzerinden `initialize`+`tools/list` JSON-RPC gönderildi, 20 tool döndü,
      `open_session` şeması beklenen şekilde.
- [x] AC2: Broker `"open_session"` op'u — boş `name` reddediliyor (hata döner); geçerli çağrıda
      `muya://open-agent-session` Tauri event'i doğru payload (`name`,`cwd`,`initialMessage`) ile
      emit ediliyor; birim testle (event payload'ı üreten saf fonksiyon `build_open_session_payload`,
      AppHandle'sız) doğrulandı — 3 test.
- [x] AC3: Frontend, bu event'i dinleyip yeni bir terminal tab'ı açıyor; ilk komut
      `claude --dangerously-skip-permissions --name '<name>' [singleQuote(initial_message)]` şeklinde
      kuruluyor — mevcut `buildAgentCommand`/`singleQuote` (src/lib/agent.ts) **yeniden kullanılarak**,
      yeni quoting kodu YAZILMADAN.
- [x] AC4: `cwd` verilmezse mevcut `launchAgent` davranışıyla aynı fallback (`selectedRoot || workspaces[0]`)
      kullanılıyor; hiçbir workspace yoksa event sessizce yok sayılıyor (no-op, açacak yer yok).
- [x] AC5: `cargo test --lib` 258/258, `npm test` 102/102 (yeni eklenen testler dahil), `npx tsc --noEmit` temiz.
- [x] AC6: PRD'ye native-vs-custom karar bölümü (§6) yazıldı — kod değişikliği YOK (karar: koru).

## 4. Koruma Listesi (dokunulmayacak)
- `ssh_open`/`ssh_run`/`ssh_scp` ve credential-store gate mantığı — open_session bunlardan tamamen
  ayrı bir op, ssh/credstore koduna dokunmuyor.
- `list_sessions`/`read_session`/`send_to_session` — davranış AYNEN kalıyor (§6 kararı: kaldırılmıyor).
- `launchAgent`/`buildAgentCommand`'ın mevcut UI-tetiklemeli davranışı (yeni event bunun YANINA
  ekleniyor, üzerine yazmıyor).
- `pty_session_ids` / `SESSION_EVERY` polling döngüsü — open_session bu polling'e bağımlı DEĞİL
  (bkz. §5, keşif mekanizması farklı).

## 5. Entegrasyon / Harmony (ZORUNLU)
> `docs/SYSTEM.md` bu alt-sistemi (MCP broker/sidecar) belgelemiyor (Vault MCP'yi belgeliyor, ayrı
> bir alt-sistem) — kanıt doğrudan koddan, satır numaraları 2026-08-21 itibarıyla doğrulandı.

- **Sidecar → broker taşıma:** `ssh_open` ile aynı iskelet. Sidecar `src-tauri/src/bin/muya_ssh_mcp.rs`
  içinde tool şeması (`ssh_open` örneği :109-120) + handler (`app_call({"op":...})` ile broker'a Unix
  socket üzerinden gönderim, `:375-403`). Yeni `open_session` bu ikisinin yanına eklenir, `own_session_id()`
  (`:79-81`, `CLAUDE_CODE_SESSION_ID` env) çağıran kimliği için zaten mevcut.
- **Broker dispatch:** `handle_request`'in `match req.op.as_str()` bloğu (`broker.rs:388`), `"open"` (:393),
  `"list_sessions"` (:443), `"send_to_session"` (:445) yanına `"open_session" => handle_open_session(app, &req).await` eklenir.
- **Tab açma mekanizması (kanıt: `ssh_open` akışı):** `broker.rs:393-439`'daki `"open"` arm
  `app.emit("ssh-broker-open", {...})` yapıyor; `App.tsx:908-914` bunu dinleyip `openSshServer`'ı
  çağırıyor. `open_session` bunun **daha basit** bir analogunu kullanır — SSH'nin `register_ssh_session`/
  `SSH_SESSIONS` (`broker.rs:56-63`) mekanizmasına **ihtiyaç YOK**: o set sadece "bu ssh tab'ı hâlâ açık
  mı" gate'i için var, mesajlaşma/keşif ile ilgisi yok (doğrulandı, `ssh_session_is_open` sadece ssh
  akışlarında kullanılıyor).
- **Kritik keşif kararı (bu PRD'nin en önemli düzeltmesi — ilk taslak yanlıştı):** `list_sessions`/
  `send_to_session`'ın arkasındaki `running_sessions()` (`broker.rs:824-830`) doğrudan
  `crate::agents::list_agent_sessions_sync` (`agents.rs:248-272`) çağırıyor — bu da gerçek `claude agents
  --json` alt-süreç çağrısı. **Muya'nın kendi tab/pty registry'sinden (SSH_SESSIONS, sessionIdToKeyRef,
  pty_session_ids ~15sn polling) TAMAMEN BAĞIMSIZ.** Yani: `open_session` yeni bir Claude CLI süreci
  (`claude --name X`) başlattığı an, o süreç kendi başına `claude agents --json`'a kaydolur ve
  `list_sessions`/`send_to_session(target=name)` onu **anında** (Muya'nın 15sn'lik UI-polling'ini
  BEKLEMEDEN) bulabilir hale gelir. Sonuç: `open_session`'ın kendi tarafında **hiçbir yeni registry/
  session-id icat etmesine gerek yok** — sadece tab'ı açıp `--name` vermesi yeterli, takip mesajları
  zaten var olan `send_to_session(target=name)` ile çalışır.
- **İlk mesaj (`initial_message`) için race-free tasarım:** Ayrı gecikmeli `pty_write` DENEMEsi yerine
  (claude CLI soğuk-başlama süresi ölçülmedi, riskli), `initial_message` doğrudan komut satırına
  positional prompt argümanı olarak eklenir (`buildAgentCommand` zaten bunu yapıyor —
  `src/lib/agent.ts:19-24`, `refs`+`prompt` → `singleQuote` ile tek pozisyonel arg). Var olan kanıtlı
  600ms tek-`pty_write` deseni (`Terminal.tsx:422-429`, `launchAgent`'ın zaten kullandığı yol) AYNEN
  kullanılır — yeni timing kodu YOK.
- **Frontend reuse:** `App.tsx:1228-1246` `launchAgent(spec: NewAgentSpec)` zaten "workspace seç →
  worktree(opsiyonel) → `buildAgentCommand` → `openTerminal` → `setView('control')`" yapıyor. Yeni
  event listener bu fonksiyonu (veya onun içindeki aynı adımları) çağırır — UI butonuyla tetiklenen
  akışla MCP'yle tetiklenen akış aynı koddan geçer, iki ayrı bakım yükü oluşmaz.
- **Kırma riski:** Yeni event adı (`muya://open-agent-session`) mevcut `ssh-broker-open`/
  `muya://deliver-message`/`muya://open-file` event isimleriyle çakışmıyor (grep'le teyit edilecek,
  implementasyon adımında). `--dangerously-skip-permissions` zaten "+ New Agent" varsayılanı
  (`agent.ts:22`) — yeni bir güvenlik yüzeyi AÇMIYOR, var olanı MCP'den de tetiklenebilir kılıyor.

## 6. Karar: native (ListAgents/SendMessage) vs Muya custom (list_sessions/read_session/send_to_session)

**Karar: Muya'nın custom tool'ları KALIYOR, kaldırılmıyor.** Native "daha iyi" değil — tamamlayıcı;
zaten `send_to_session`'ın varsayılan yolu native'i kullanıyor (rakip implementasyon değil).

Kanıt (docs.claude.com/en/docs/claude-code/cross-session-messaging, 2026-08-21 taze fetch):

| Konu | Native (ListAgents/SendMessage) | Muya custom |
|---|---|---|
| Adresleme | Sadece isim; **"Sessions can still share a name"** — çakışma native'de çözülmüyor | `resolve_target` (broker.rs:785-821): id → tam-isim → substring, **çoklu eşleşmede asla tahmin etmez**, adaylar döner |
| Okuma (mesaj atmadan durum sorma) | **Yok** — SendMessage tek yönlü, transcript okuma API'si yok | `read_session` (broker.rs:866-909) — başka session'ın son turlarını salt-okunur okur |
| Taze bypass-mode oturuma otonom teslimat | **Riskli**: dokümantasyon aynen şöyle diyor — *"The receiving session bypasses permission prompts: Claude Code holds each message for your approval. It delivers one only when the sending session identifies itself as also bypassing."* `open_session`'ın açtığı oturum TAM OLARAK bypass-mode (`--dangerously-skip-permissions`) → gönderen kendini bypass olarak tanıtmazsa mesaj **operatör onayına takılır** — "sormadan mesaj" garantisi YOK | `deliver:"muya"` (broker.rs:950-967) doğrudan `pty_write` ile PTY'ye yazıyor — native SendMessage/permission-hold mekanizmasının tamamen DIŞINDA, garanti oluyor |
| Teslimat kesintisizliği (araya girmeme) | *"receiving Claude reads the message between tool calls, a running tool is never interrupted"* — güçlü yön | `deliver:"auto"` zaten bunu kullanıyor (varsayılan) |

Sonuç: **yeni açılan oturuma ilk/otonom mesaj için `deliver:"muya"` kullanılmalı** (native'in
onay-bekletme riski yüzünden); zaten-oturan/insanla-etkileşen oturumlara ise `deliver:"auto"` (native)
kesintisizlik avantajı için tercih edilmeye devam eder. Bu zaten `docs/prd-session-messaging.md`'nin
tasarladığı hibrit modelle birebir uyumlu — değişiklik gerekmiyor, sadece bu PRD'nin gerekçesiyle
teyit edildi.

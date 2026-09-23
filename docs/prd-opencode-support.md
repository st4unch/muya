# Mini-PRD — opencode agent support

**Durum:** taslak · **Tarih:** 2026-09-23 · **Sahip:** operatör

## 1. Ne işe yarayacak?

Muya bugün yalnızca Claude Code oturumları açıp izleyebiliyor. Bu iş, ikinci bir
ajan CLI'ını — **opencode** — eşit vatandaş yapıyor: kullanıcı opencode terminali
açabilecek, oturumlarını aynı listede görecek, muya-mcp'yi opencode'a da tek
tıkla kurabilecek. Ve bir Claude ajanı, MCP üzerinden **opencode terminali açıp
ona mesaj gönderebilecek** — yan yana iki farklı ajan çalıştırma senaryosu.

Ekranı bölme işi **zaten var** (`src/components/TerminalGrid.tsx:124-173`,
`gridKeys` + sürüklenebilir bölme). Yeni bölme UI'ı yazılmayacak; opencode
terminali açılabilir olunca mevcut bölmede yan yana çalışacak.

## 2. Kapsam

| Var | Yok (bu turda) |
|---|---|
| opencode terminali açma (UI + MCP) | opencode `serve` HTTP API'si üzerinden sürüş |
| Oturum listesinde opencode oturumları | opencode `acp` (nd-JSON) taşıması |
| Sekme/panel ikonlarında ajan ayrımı | opencode agent/subagent yönetimi UI'ı |
| muya-mcp'yi opencode'a kurma | opencode skill/plugin marketplace'i |
| MCP `open_session({agent:"opencode"})` + mesaj | Claude'un `--name` benzeri CLI-düzeyi adlandırma (opencode'da yok) |

## 3. opencode gerçekleri (kanıtlı)

Resmî dokümantasyondan ve bu makinedeki gerçek `~/.config/opencode/opencode.json`
dosyasından doğrulandı:

| Konu | Değer |
|---|---|
| Binary | `opencode` |
| TUI | `opencode [project]` |
| Otomatik onay | `--auto` (Claude'daki `--dangerously-skip-permissions` karşılığı) |
| Oturum listesi | `opencode session list --format json` |
| Devam | `--session <id>` veya `--continue` |
| Oturum deposu | `~/.local/share/opencode/project/<slug>/storage/` |
| MCP config | `~/.config/opencode/opencode.json`, üst anahtar `mcp` |
| MCP girdi şekli | `{"type":"local","command":["<bin>",...],"enabled":true}` |
| Talimat dosyası | `AGENTS.md` (yoksa `CLAUDE.md`'ye düşer) |

**Claude'dan ayrılan iki nokta, tasarımı belirliyor:**

1. **TUI'ye isim verilemiyor.** Claude `--name <ad>` alıyor ve ajan sonradan o
   isimle adresliyor. opencode'da bu yok (`--title` yalnız `run` alt komutunda).
   → opencode oturumları **Muya'nın sekme adıyla** adreslenecek. Mesaj iletimi
   zaten PTY'ye yazarak çalıştığı için (`broker.rs` `deliver:"muya"` →
   `muya://deliver-message` → `src/App.tsx:1034`) bu her TUI için geçerli.
2. **Oturum JSON şeması belgelenmemiş.** `opencode session list --format json`
   çıktısının alan adları dokümante değil ve opencode bu makinede kurulu değil.
   → Ayrıştırma **savunmacı** olacak: alan adları için birden fazla aday
   (`id`/`sessionID`, `title`/`name`), eksik alanlara tolerans, ve **herhangi bir
   hata Claude listesini bozmayacak** (opencode kısmı boş döner). Bu, şemayı
   doğrulayamadığımız gerçeğinin doğrudan sonucu — varsayımla katı ayrıştırma
   yazmak kabul edilemez.

## 4. Kabul kriterleri (ikili)

- **AC1** — `detect_agent()` bir komut satırından ajanı ayırt eder: `claude …`
  → claude, `opencode …` → opencode, `npm run dev` → yok. Kelime sınırına saygı
  duyar (`opencoded` eşleşmez).
- **AC2** — `opencode_bin()` capability-probe ile çözülür (varlık değil yetenek —
  L48); bulunamazsa anlaşılır hata döner, panic yok.
- **AC3** — `install_opencode_mcp_at()` verilen dosyaya
  `mcp.<ad> = {type:"local",command:[…],enabled:true}` yazar; **mevcut diğer
  anahtarları korur** (bu makinedeki gerçek dosyada `mcp.pencil` girdisi var —
  kaybolmamalı); ayrıştırılamayan dosyayı **üzerine yazmaz**, hata döner; yazma
  atomiktir.
- **AC4** — `opencode_session_command()` devam komutunu üretir:
  `opencode --session <id> --auto`.
- **AC5** — Broker `open_session` `agent:"opencode"` alır ve `opencode --auto`
  ile terminal açar; `agent` verilmezse davranış **bugünkü gibi** Claude kalır
  (geriye dönük uyum).
- **AC6** — `send_to_session` opencode oturumuna `deliver:"muya"` ile mesaj
  iletir; adresleme Muya sekme adıyla yapılır.
- **AC7** — Oturum listesi opencode oturumlarını `agent:"opencode"` etiketiyle
  içerir; `opencode` kurulu değilse veya JSON beklenmedikse Claude listesi
  **etkilenmez**.
- **AC8** — Sekme ve oturum panelinde ajan başına ayırt edilebilir ikon; mevcut
  Claude ikonu değişmez.
- **AC9** — Yeni terminal modalinde "opencode" seçeneği; `opencode --auto`
  komutunu üretir.

## 5. Entegrasyon (mevcut koda bağlanma — kanıtlı)

| Dokunulan yer | Mevcut durum (kanıt) | Nasıl bağlanır |
|---|---|---|
| CLI çözümleme | `src-tauri/src/agents.rs:78-141` — `claude_bin()`/`resolve_claude_bin()` + `supports_agents_json()` yetenek probu, `OnceLock` önbellek | Aynı desen genelleştirilir; `claude_bin()` imzası **değişmez** |
| Oturum listesi | `agents.rs:323-339` `list_agent_sessions_sync` → `claude agents --json` | Yanına opencode listeleyici; ikisi birleşip aynı `AgentSession` tipine düşer, yeni `agent` alanıyla |
| Komut kurma | `src/lib/agent.ts:17-23` `buildAgentCommand`, default `claude --dangerously-skip-permissions` | Ajan başına temel komut; default **değişmez** |
| Sekme tipi | `src/App.tsx:116` `isClaude?: boolean`, `:325-326` komuttan regex ile türetilir; `src/lib/tabs.ts:55-62` "volatile/derived, resume gate DEĞİL" | `isClaude` **korunur** (türetilmiş alias), yanına `agent` gelir → kalıcı veri göçü gerekmez |
| Yeni terminal modali | `src/components/NewAgentModal.tsx:6` union `"claude" \| "terminal"` | `"opencode"` eklenir |
| Oturum paneli ikonu | `src/components/SessionsPanel.tsx:8-9,159-164` `isClaude` → Claude işareti | Ajan başına ikon |
| MCP kurulumu | `src-tauri/src/fs.rs:1253-1338` `install_mcp_at` — atomik yazma, ayrıştırılamayan dosyayı reddetme, diğer anahtarları koruma | Aynı güvenlik disiplini opencode şekli için tekrarlanır (şekil farklı, güvence aynı) |
| Broker oturum açma | `src-tauri/src/broker.rs:881-916` `handle_open_session` → `claude --dangerously-skip-permissions --name` | İsteğe bağlı `agent` alanı; yokluğunda bugünkü davranış |
| MCP tool şeması | `src-tauri/src/bin/muya_ssh_mcp.rs:188` açıklaması Claude'a özel | `agent` parametresi + açıklama güncellemesi |

## 6. Koruma listesi (kırılmayacak bitmiş işler)

- Claude oturumu açma/devam etme/durdurma akışı — **davranış birebir aynı kalır**
- `open_session`/`close_session` sahiplik kapısı (`AGENT_OPENED_SESSIONS`)
- SSH/PSMP tarafı (bu iş ona hiç dokunmaz)
- PTY tahliyesi (v0.2.51) ve oturum arama panic düzeltmesi
- `~/.claude.json` yazıcısının güvenlik davranışı

## 7. Doğrulama sınırı (dürüstlük notu)

**opencode bu makinede kurulu değil.** Dolayısıyla uçtan uca (gerçekten terminal
açılıp opencode'un yanıt verdiği) doğrulama **yapılamaz**; yapılabilecekler:

- Saf mantığın tamamı birim testiyle (komut kurma, ajan ayırt etme, JSON şekli,
  oturum ayrıştırma — fixture ile)
- MCP yazıcısı **bu makinedeki gerçek `opencode.json`'un bir kopyasına** karşı
  (mevcut `pencil` girdisinin korunduğu kanıtlanabilir)
- Kurulu-değil yolunun anlaşılır hata verdiği

Uçtan uca doğrulama operatörde kalır ve kapanış özetinde **açıkça** belirtilir.

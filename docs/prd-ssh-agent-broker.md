# Mini-PRD: SSH Agent Broker (Claude agent'ları için MCP plugin)

- Tarih: 2026-07-26
- Tür: mini-PRD (2 fazlı)
- Grounding: `software-architect` gate (opus) — GO, 2 faza böl. Kanıtlar §5.

## 1. Problem

Muya'nın terminallerinde çalışan Claude agent'ları, SSH sunucularına + şifreli
credential store'a **şifreyi hiç görmeden** erişebilmeli. Şu an bir agent ssh'a
bağlanmak isterse şifreyi elle bilmesi/görmesi gerekir; bu hem güvensiz hem de
otomatik iş akışını (agent bir sunucuda komut çalıştırsın) imkânsız kılar.
Çözüm: Muya bir **MCP plugin** yayınlar; agent sunuculara sadece **takma adla**
başvurur, şifre Rust tarafında çözülüp sunucu-tarafında kullanılır.

## 2. Scope

**Dahil:**
- Muya'nın yayınladığı `muya-ssh` MCP sunucusu (stdio proxy binary) — Claude Code
  agent'larına `~/.claude/.mcp.json` üzerinden kaydedilir.
- Yeni **özel Unix domain socket** (0600 + **SO_PEERCRED uid kontrolü**) — proxy,
  çalışan Muya app'ine bu socket üzerinden ulaşır; enjeksiyon/sır app process'inde.
- `Server` modeline **`agentAccess: bool`** alanı (sunucu başına opt-in, varsayılan
  kapalı). UI'da her sunucuya "Agent may use this server" toggle.
- MCP araçları:
  - **Faz 1:** `ssh_list_servers()` (yalnız `agentAccess==true`, takma ad+metadata),
    `ssh_open(alias)` (Muya'da interaktif terminal sekmesi açar — mevcut inject yolu).
  - **Faz 2:** `ssh_run(alias, command)` (tek-seferlik uzak komut, sadece stdout döner;
    şifre sunucu-tarafında enjekte, argv-vektör, `bash -c` YOK).
- Gating: erişim yalnız (a) `agentAccess==true` VE (b) store **insan tarafından
  açıkken** çalışır. İkisi de Rust-tarafı, agent'a güvenilmez.

**Hariç:**
- Audit log UI'ı (operatör seçmedi; app log dosyasına düşük-maliyetli satır opsiyonel).
- İlk-kullanımda insan onay penceresi (operatör seçmedi).
- CyberArk `ssh_run` üzerinden toplu şifre çekme kotası/rate-limit (Faz 2 sonrası).
- Uzak (remote/network) MCP erişimi — sadece yerel, aynı kullanıcı.

## 3. Kabul Kriterleri (binary)

**Faz 1 — temel (düşük risk, çoğu reuse):** (✅ done — 2026-07-26)
- [x] AC1: `Server` struct'ında `agentAccess: bool` var, default `false`; JSON'a
  `agentAccess` olarak serialize olur; mevcut config dosyaları hatasız yüklenir
  (serde `default`). Unit test: eski JSON (alan yok) → `agent_access==false`.
- [x] AC2: UI'da her sunucuya "Agent may use this server" toggle; kaydedince
  `ssh_upsert_server`'a yansır. tsc temiz + vitest render testi.
- [x] AC3: Yeni UDS handler yalnız `getpeereid` (macOS; SO_PEERCRED değil) ile **aynı
  uid** peer'ı kabul eder; farklı uid + getpeereid-fail reddedilir (fail-closed).
  Test: socket 0600 + aynı-process peer uid==getuid() (`broker.rs` ac3 testi).
- [x] AC4: `list_servers` UDS üzerinden yalnız `agentAccess==true` sunucuları
  döner; `agentAccess==false` listede YOK. Store kilitliyken de metadata döner.
  Test: 2 sunucu (biri opt-in), liste 1 döner.
- [x] AC5: `ssh_open(alias)` `ssh-broker-open` event yollar → App.tsx `openSshServer`
  → `sshServerId` tab → mevcut `ssh_pty_connect` inject yolu. `local` kaynak +
  kilitli store → "store is locked" hatası. `agentAccess==false` alias → hata.
- [x] AC6: `muya-ssh` girdisi `~/.claude/.mcp.json`'a `install_mcp` (`register_mcp`)
  ile yazılır; stdio `{command,args}`. Idempotent (install_mcp key-merge).
- [x] AC7: **Sır sızıntısı yok** — `ServerMeta` yalnız alias/host/username/port/
  connectionType taşır. Test (`ac7_meta_has_no_secret`): serialize JSON'da password/
  secret/token/credentialSource/localCredId YOK. Canlı e2e 18/18 (proxy stdout temiz).

**Faz 2 — `ssh_run` (yeni risk yüzeyi):**
- [ ] AC8: `spawn_process`'in **non-interaktif capture varyantı**: PTY'de ssh açar,
  `looks_like_password_prompt` ile enjekte eder, stdout'u sınırlı buffer'da toplar,
  timeout + exit-code ile döner. Docker sshd'ye karşı **canlı e2e test**: `ssh_run`
  ile `echo MUYA_RUN_OK` çalışır, stdout `MUYA_RUN_OK` içerir, sır dönmez.
- [ ] AC9: `command` argümanı argv-vektör olarak geçer (shell yorumlaması YOK);
  `ssh -v`/verbose kapalı, stderr sır-scrub'lı. Test: `command` içinde `; whoami`
  gibi ek komut enjekte edilemez (tek argv arg olarak gider).
- [ ] AC10: Eşzamanlı `ssh_run` sayısı sınırlı (DoS koruması); aşımda net hata.

## 4. Koruma Listesi (dokunulmayacak)

- **Sır invariant'ı (PRD ssh-cyberark §9):** şifre Rust'ta çözülür, PTY'ye enjekte
  edilir; JS'e/argv'ye/env'e/diske düz-metin ASLA düşmez. Bu feature bunu genişletir,
  ihlal etmez.
- **Mevcut chat bridge** (`bridge.rs` UDS, `MUYA_BRIDGE_SOCK`) — ayrı trust domain'i;
  bu feature ONU KULLANMAZ, yeni ayrı socket açar. Chat/exec yolu değişmez.
- **PTY CLAUDE\* env strip** (`pty.rs:122`) — dokunulmaz; MCP kaydı env ile değil
  `.mcp.json` ile yapılır (strip'ten etkilenmez).
- **Mevcut `ssh_pty_connect` / `spawn_process` imzaları** — Faz 1 reuse eder; Faz 2
  ek varyant ekler, mevcut çağrıları kırmaz (14 rust test + canlı inject testi yeşil kalmalı).
- **`~/.claude/.mcp.json`'daki mevcut mcpServers girdileri** — yalnız `muya-ssh` eklenir,
  diğerleri korunur (merge, overwrite değil).

## 5. Entegrasyon / Harmony (ZORUNLU — architect kanıtı)

- **Auth / gate:** İki katman, ikisi de Rust-tarafı:
  (a) store-unlocked gate zaten var — `credstore::secret_for` `credstore.rs:530`
  store `None` (kilitli) ise "store is locked" döner; agent store'u açamaz.
  (b) yeni `agentAccess` alanı `Server`'da (`ssh.rs:40`) — UDS handler kontrol eder.
- **Servis/model:** `Server`/`CredentialSource` (`ssh.rs:40`), `ssh_pty_connect`
  (`ssh.rs:373`), `build_connect_command` (`ssh.rs:314`, argv-vektör, shell string yok),
  `needs_injection` (`ssh.rs:307`). Enjeksiyon: `spawn_process(..., inject_secret)`
  (`pty.rs:90`) + `looks_like_password_prompt` (`pty.rs:54`). CyberArk kaynağı:
  `cyberark::fetch_password`. Unlocked store: `CredStore = Mutex<Option<Unlocked>>`
  (`credstore.rs:120`) — app process'inde yaşar (proxy ayrı process → UDS gerekli).
- **Konvansiyon:**
  - MCP kaydı: `install_mcp` `~/.claude/.mcp.json`'a stdio `{command,args}` yazıyor
    (`fs.rs:996`) — aynı pattern kullanılır (kanıtlı registration substrate).
  - Yerel IPC: `bridge.rs:418` `UnixListener::bind` + 0600 (`bridge.rs:359`),
    `MUYA_BRIDGE_SOCK`-tarzı per-user path (`bridge.rs:354`). Yeni socket bu pattern'ı
    izler ama **ek olarak SO_PEERCRED uid kontrolü** ekler (bridge'de YOK — yeni sertleştirme).
- **Kırma riski:**
  - MCP proxy'nin sırra ulaşması → yalnız UDS + 0600 + SO_PEERCRED (aynı uid). HTTP/
    localhost reddedildi (her yerel proc erişebilir). Chat-bridge reuse reddedildi (trust
    domain karışımı).
  - `command` üzerinden komut enjeksiyonu → argv-vektör, `bash -c` yok (`build_connect_command`
    zaten argv, string değil — aynı disiplin `ssh_run`'da korunur).
  - Sır sızıntısı `ssh -v`/stderr → verbose kapalı, stderr scrub (AC9).
  - Eski config uyumu → `agentAccess` serde `default=false` (AC1).

## Kararlar (architect, opus gate)

- D1 Transport: **stdio MCP proxy binary + yeni özel UDS** (0600 + SO_PEERCRED) app'e
  geri bağlanır. HTTP ve chat-bridge-reuse reddedildi.
- D2 Kayıt: `~/.claude/.mcp.json` (`install_mcp` pattern), env DEĞİL (PTY strip).
- D3 Araçlar: `ssh_list_servers` / `ssh_open` (Faz 1) + `ssh_run` (Faz 2, stdout-only).
- D4 Gating: `Server.agentAccess` + `secret_for` locked-gate, ikisi Rust-tarafı.
- D5 Reuse: `ssh_open` mevcut yolu kullanır; `ssh_run` yeni non-interaktif capture
  varyantı gerektirir (tek gerçek yeni Rust yüzeyi).
- D6 Tehditler: argv-only, verbose-off + stderr scrub, 0600+SO_PEERCRED, unlock-gate,
  eşzamanlılık sınırı.
- Faz bölünmesi: P1 temel (socket+uid+alan+list+open+kayıt+proxy), P2 `ssh_run`.
  P2 yalnız P1'in socket/uid bariyeri contract-test'le kanıtlandıktan sonra.

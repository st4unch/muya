---
status: active
prd: docs/prd-ssh-cyberark.md
started: 2026-07-24
---

## Faz Çıktıları

- **Phase 1 (SYSTEM.md):** `docs/SYSTEM.md` prototip-dönemi içerikten gerçek Tauri mimarisine yenilendi (2026-07-24). Feature'ın dokunduğu alt sistemler cite'lı: view routing (App.tsx:345/1313/1455), command registry (lib.rs:160), persistence (vault.rs JSON pattern), PTY (pty.rs:46), secrets gap (§9 — hiç encryption-at-rest yok). Acceptance inline geçildi (subagent spend-limit).
- **Phase 2 (PRD):** `docs/prd-ssh-cyberark.md` yazıldı. 4 faz, binary AC, 9 risk, decision log (operatör kararları D1-D3 + otonom D4-D6). §0 review inline yapıldı; adversarial bulgular A1-A4 uygulandı.

- **Phase 2c round 2 (opus subagents):** software-architect gate = **NO-GO** (2 required fix: ARCH1 keyring→security-framework, ARCH2 reveal-risk) + prd-devils-advocate (PM1-4, AA1-3, EA1-2). Tümü PRD'ye işlendi (doc-only).
- **Operatör cevapları (scope change):** key auth IN scope (§2.1, D7), CyberArk=şifre, kilit=ekran-kilidi (D8), RADIUS push IN (D9), re-gate evet.
- **Phase 2c round 3 (architect re-gate, opus):** NO-GO — 1 fix: **ARCH-RG1** key-auth `ssh -i` temp dosya diske düz-metin anahtar yazıyor → **ssh-agent-only**'e çevrildi (SSH_AUTH_SOCK, diske hiç). AC2.4 fs-watch ile yeniden yazıldı. 3 minor not da uygulandı. Architect'in binary done-kriteri karşılandı → **efektif GO**; re-gate #4 opsiyonel (O5).

- **Faz 0 impl — DONE 2026-07-24 (main context, (a) yolu):** `src-tauri/src/credstore.rs` yazıldı — AES-256-GCM + Argon2id (m=46MiB, off-thread), atomik temp+rename yazım, init/unlock/lock/status/cred-CRUD/re-key. 3 crate eklendi (aes-gcm/argon2/zeroize). 7 komut `lib.rs`'e kaydedildi. **7 unit test PASS** (AC0.1 round-trip, AC0.2 wrong-pw, AC0.3 nonce-unique×1000, AC0.4 locked-no-data, AC0.6 derive, re-key, diskte-düz-metin-yok). `cargo check` full crate temiz. Keychain/Touch-ID + rekey-command → Faz 1'e alındı (headless test edilemez, Golden §3).

- **Faz 1 impl (kısmi) — 2026-07-24:** `src-tauri/src/ssh.rs` (server/PSMP/CyberArk-config CRUD + dedup, 7 komut, atomik yazım paylaşımlı) + **7 unit test PASS** (dedup, host-case normalizasyon, farklı-user, edit-self-collide, secret-yok, disk round-trip). Frontend `src/components/SshPage.tsx` (3 sekme: Sunucular/CyberArk/Şifre-Store) + App.tsx'e bağlandı (union/nav/render/import, control-view her zaman mount L1 korundu). Doğrulama: tsc temiz, 78 vitest PASS, vite build OK, 14 Rust test PASS. **BEKLEYEN:** (1) Keychain/Touch-ID auto-unlock (security-framework, canlı Touch ID gerekir), (2) çalışan app'te görsel click-through (§2) — dev webview flake riski var.

- **Test altyapısı + Faz 1 devam — 2026-07-24:** (Yol 3 test infra) `src/dev/mockBackend.ts` + `installTauriMock.ts` (tak-çıkar tarayıcı shim, `dev:mock` script, `VITE_BROWSER_MOCK` flag, dynamic-import → release'de YOK, dist grep ile kanıtlı) + `SshPage.test.tsx` (3 flow testi). Toplam **81 vitest PASS**. `credstore_rekey` komutu eklendi (7 credstore test yeşil). **Canlı görsel doğrulama denendi:** gerçek Tauri app + cua-driver → WKWebView **boş render** (kayıtlı flake, kod değil — frontend serve OK, log temiz, bundle kanıtlı). Chrome-shim yolu da eklenti bağlı olmadığı için blocked. → Mac restart veya Chrome-connect gerekiyor. Host muya (29915) korundu.

- **Canlı doğrulama + düzeltmeler — 2026-07-24:** Gerçek Tauri app cua-driver ile ayağa kaldırıldı (pid 89430, host 29915'e dokunulmadı), **WKWebView bu sefer düzgün render etti** — SSH sayfası CANLI doğrulandı (nav'da SSH, 3 sekme, form). Operatör düzeltmeleri: (1) **UI Türkçe→İngilizce** (app'in geri kalanı İngilizce; L22) — SshPage.tsx + test string'leri çevrildi, HMR ile canlı doğrulandı (Servers/CyberArk/Password Store). (2) **Store export** eklendi: `credstore_export(dest)` komutu (şifreli blob'u seçilen yere kopyalar — düz metin sızmaz) + UI "Export backup" (dialog save). NOT: master parola app'te hiç saklanmadığı için (güvenlik) export edilemez; export = şifreli store yedeği (master ile geri yüklenir). tsc temiz, 81 vitest PASS, cargo check temiz.

- **Master/key export-import + reveal — 2026-07-24 (operatör isteği):** Backend komutları: `credstore_export_master(dest,master)` (düz metin, UI uyarılı — app master'ı hiç saklamaz), `credstore_import_key(label,username,srcPath)` (key Rust'ta okunur, JS'e düşmez), `credstore_export_cred(id,dest)` (secret Rust'tan dosyaya, JS'e düşmez), `credstore_export(dest)` (şifreli store yedeği). Frontend: master reveal toggle (göz), "Export master password" (uyarılı), "Import SSH key" (dialog+form), per-cred "Export", "Export backup". CANLI DOĞRULANDI (cua-driver, gerçek app pid 31695): İngilizce UI + reveal toggle + export-master butonu + uyarı + validation. Unlocked ekran (import/export key butonları) vitest render + compile ile doğrulandı — backgrounded WKWebView text-input flake nedeniyle store-create GUI'den sürülemedi (cua-driver sınırı, kod değil). tsc/81 vitest/cargo check yeşil.

- **Reusable CredentialPicker + CyberArk reuse — 2026-07-24 (operatör isteği):** `src/components/CredentialPicker.tsx` (uygulama-geneli reusable): parola alanı olan her yerde "store'dan seç" (referans, sır JS'e düşmez) + "yeni gireni store'a kaydet". CyberArk formuna "Login credential" bölümü olarak bağlandı; `CyberarkConfig.credential_source` eklendi (ssh.rs + frontend). **D2 gevşetildi:** CyberArk parolası artık isteğe bağlı store'dan referansla kullanılabilir (sır Faz 3'te Rust logon anında çekilir, JS'e düşmez); "Ask each time (session-only)" hâlâ default. **82/82 vitest** (yeni test: create store→cred ekle→CyberArk picker'da "From store: prod-db" görünüyor) + tsc + cargo check temiz. Canlı CyberArk screenshot'ı alınamadı — dev app bu session'da ~5+ launch/kill sonrası launch'ta temiz çıkıyor (exit 0, WKWebView/launch flake ağır hali, Mac restart gerek; kod defekti değil). Host 29915 korundu.

- **Faz 2 çekirdek — 2026-07-24:** PSMP SSH syntax web'den DOĞRULANDI (`vaultUser@targetUser[#domain]@targetMachine[#port]@proxyAddress`, `@`/`#` delimiter — EA1/O4 kapandı). `ssh.rs`: `build_connect_command` (PSMP + direct, delimiter/port varyantları, injection flag — sır args'a düşmez) + `ssh_build_connect_cmd(id)` komutu + **5 unit test** (AC2.1 PSMP string, port, injection, hatalı-profil). Frontend: her sunucuya **Connect** butonu → `SshPage onConnect` → App.tsx komutu kurup terminal sekmesinde açar (mevcut `openTerminal`/PTY). tsc/82 vitest/135 rust test yeşil. **KALAN Faz 2 (gerçek app + SSH hedefi gerekir):** direct password PTY-injection, key auth ssh-agent (ARCH-RG1), canlı "gerçekten login oluyor mu" doğrulaması.

- **CANLI uçtan-uca doğrulama — 2026-07-24 (PC restart sonrası):** Restart WKWebView/launch flake'ini çözdü. Dev app (pid 4392) temiz render etti; cua-driver text-input artık WKWebView'a ulaşıyor. Doğrulanan akış: SSH sayfası → Add server (Oracle@10.0.0.5, gerçek Rust backend, `~/.claude/muya-ssh-config.json`'a yazıldı) → **Connect → Control view'da yeni terminal "ssh Oracle@10.0.0.5" açıldı ve PTY'de gerçekten çalıştı.** Faz 2 Connect zinciri (config→build_connect_command→ssh_build_connect_cmd→onConnect→openTerminal→PTY) uçtan uca kanıtlı. Host Muya 1986 korundu.

- **TAM PAKET — bug'lar + injection + ssh-flags + CyberArk motoru — 2026-07-25 (operatör "tek paket"):** Kök bulgu: CyberArk yarısı hiç bağlanmamıştı — `build_connect_command` düz `ssh user@host` üretiyordu, `needs_password_injection` hesaplanıp tüketilmiyordu, Faz 3 (REST) yoktu; bu yüzden CyberArk seçili olsa bile düz ssh açılıp sunucu şifre soruyordu. Çözülenler: (1) CyberArk "Saved ✓" flash; (2) PSMP profili edit (Pencil→form + delim alanları); (3) SshPage her zaman mount + `hidden` → tab geçişinde add/edit form durumu korunuyor (L1); (4) fail sonrası ölü terminal → connect başına `ssh:<id>:<ts>` benzersiz key + eski tab'ları filtrele = React remount → taze PTY; (5) server formunda `CredentialPicker` (store + CyberArk hesabı seçimi, prefixed `local:`/`cyber:` value); (6) **password injection**: `pty.rs` writer `Arc<Mutex>` + reader-thread `looks_like_password_prompt` (prompt tail eşleşince bir kez yaz) + `spawn_process(inject_secret)` + `ssh_pty_connect` komutu; sır Rust'ta çözülür (`credstore::secret_for` / `cyberark::fetch_password`), JS'e düşmez, zeroize; (7) sunucu başına ekstra ssh bayrakları (`sshOptions` → `extra_ssh_opts`, dest öncesi); (8) `cyberark.rs` v10 REST (logon/list/fetch/test + RADIUS 60s + v9 `.svc` fallback), reqwest+rustls, token Rust cache, 5 wiremock testi; (9) CyberArk UI: gerçek "Test connection" + hesap tarayıcı + vault username alanı. **Doğrulama:** tsc temiz, 82 vitest, 142 rust test (+7), vite build OK. **CANLI E2E:** Docker `linuxserver/openssh-server` (127.0.0.1:2222) hedefine `ssh` PTY'de açıldı, injector gerçek `password:` prompt'una şifreyi yazdı, login oldu, remote `echo MUYA_INJECT_OK` çalıştı (`pty_injection_logs_into_real_sshd`, `#[ignore]`). **Bekleyen:** çalışan app'te GUI unlock→Connect görsel teyidi + gerçek PVWA'ya karşı CyberArk (burada wiremock).

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-07-24 | docs/SYSTEM.md | Prototip→gerçek mimari yenileme | — |
| 2026-07-24 | docs/prd-ssh-cyberark.md | PRD oluşturuldu | — |
| 2026-07-24 | docs/prd-ssh-cyberark.md | Round-2 merge: ARCH1/ARCH2 + PM1-4/AA1-3/EA1-2 işlendi | — |
| 2026-07-24 | docs/prd-ssh-cyberark.md | Round-3 architect: ARCH-RG1 ssh-agent-only; operatör scope (key auth/screen-lock/RADIUS) | — |
| 2026-07-24 | src-tauri/src/credstore.rs (yeni) | Faz 0 kripto çekirdeği + 7 test | AC0.1-0.4,0.6 |
| 2026-07-24 | src-tauri/Cargo.toml | aes-gcm/argon2/zeroize | — |
| 2026-07-24 | src-tauri/src/lib.rs | credstore modül + 7 komut kaydı | — |

## Kararlar
- Store = AES-256-GCM şifreli dosya + Keychain-cached anahtar + Touch ID auto-unlock (Model A) — operatör.
- CyberArk master parola session-only, diske asla yazılmaz — operatör.
- SSH = PSMP + doğrudan-enjekte ikisi de; doğrudan best-effort — operatör.
- Crate: aes-gcm, argon2, zeroize, keyring — otonom.
- v10 REST logon + .svc fallback — otonom.

## Bilinen kısıt / bekleyen
- Phase 2a genişletilmiş web araştırması (encrypted-store CVE, OWASP param doğrulama) spend-limit nedeniyle yarım → `[NEEDS-WEB-VERIFY]` tag'leri PRD'de.
- Architect GO gate çalıştırılamadı (spend-limit) → O5: operatör inline review'ı kabul edecek mi yoksa gate'i bekleyecek mi.
- CyberArk gerçek test'i operatörün PVWA'sına karşı yapılacak (AC3.x) — burada mock.

## Dersler
- (henüz yok)

# Step Output — Faz: P1

> Bu dosya append-only'dir. Her implementation/fix turu yeni bir `## Retry N` bloğu olarak eklenir. Önceki retry'ları silmeyin.

---

## Retry 0

**Zaman:** 2026-08-04
**Subagent:** mcp-developer (dispatched directly, not via prd-run-impl)
**Model (probe):** claude-sonnet-5

### Hedeflenen AC'ler
- [x] AC1 — direct-yol-korunur mekanizması yerinde (mevcut PSMP + password: davranışı dokunulmadan bırakıldı); **canlı gerçek-PSMP koşusu operatörde**.
- [x] AC2 — PSMP + OTP/passcode/2FA challenge → parola enjekte edilmez, `ok:false` + "2FA/interactive ... use ssh_open" içeren mesaj. Unit test ile kanıtlandı (enjeksiyon sayacı fiilen 0 — `out.injected == false`).
- [x] AC3 — PSMP + prompt hiç gelmeden timeout → `timedOut:true` + "message" alanında RADIUS push ipucu + ssh_open önerisi.
- [x] AC4 — direct SSH `Password:`/`Passcode:` enjeksiyonu değişmedi (regresyon testiyle kanıtlandı: `ac4_direct_still_injects_on_passcode_prompt`).
- [x] AC5 — `ssh_run` MCP tool description'ı PSMP+2FA sınırını ve ssh_open fallback'ini anlatıyor.
- [ ] AC6 — **operatör-gerekli** canlı e2e (gerçek PSMP veya katmanlı-prompt harness). Bu turda gerçek PSMP erişimi yok; mekanizma yerel bir PTY harness ile (AC2/AC4 testleri, Docker gerektirmez) doğrulandı, ama gerçek CyberArk PSMP'ye karşı KOŞULMADI.

### Değişen Dosyalar
- `src-tauri/src/pty.rs:54-70` — yeni `looks_like_challenge_prompt` (passcode:/verification code:/one-time/otp: trailing match), sadece PSMP yolunda kullanılır.
- `src-tauri/src/pty.rs` `CommandOutput` struct — `+challenge_detected: bool`, `+injected: bool` alanları.
- `src-tauri/src/pty.rs` `run_with_injection(...)` — yeni `is_psmp: bool` parametresi; reader-thread'de challenge sınıflandırması password sınıflandırmasından ÖNCE ve YALNIZ `is_psmp` iken çalışır; challenge tespit edilince outer poll loop `timeout` beklemeden child'ı hemen kill eder.
- `src-tauri/src/pty.rs` testler: `challenge_prompt_matches_2fa_shapes`, `ac2_psmp_challenge_prompt_withholds_injection` (gerçek PTY harness — `sh -c 'printf "Passcode: "; read line; echo "GOT:$line"'`, Docker gerektirmez), `ac4_direct_still_injects_on_passcode_prompt` (regresyon).
- `src-tauri/src/broker.rs` `handle_run` — `is_psmp = server.connection_type == "psmp"`; `run_with_injection` çağrısına iletildi; `challenge_detected` → `err_resp(...)` (AC2 mesajı); PSMP + `timed_out && !injected` → response'a `"message"` alanı eklenir (AC3 mesajı).
- `src-tauri/src/bin/muya_ssh_mcp.rs:97` — `ssh_run` tool `description`'ına PSMP + 2FA sınırı + ssh_open fallback cümlesi eklendi (AC5).

### Concrete Check Sonuçları (özet)
- `cargo check --bin muya`: PASS (yalnız pre-existing dead-code/unused-import uyarıları, hatasız).
- `cargo check --bin muya-ssh-mcp`: PASS (hatasız).
- `cargo test --lib`: PASS — 191 passed; 0 failed; 6 ignored (ignored'lar Docker sshd gerektiren mevcut live testler, bu PRD kapsamında değil).

### LLM Verification Sonuçları
- AC2: PASS ✅ — `pty.rs::ac2_psmp_challenge_prompt_withholds_injection` PSMP+Passcode prompt'unda `injected=false`, `challenge_detected=true`, stdout'ta secret/GOT: yok, ve child ~50ms içinde kill edildi (20s timeout beklenmedi).
- AC3: PASS ✅ (mekanizma) — `broker.rs::handle_run` PSMP + `timed_out && !injected` durumunda `resp["message"]` set ediyor; bu path gerçek-timeout senaryosunda (RADIUS push, prompt hiç gelmeden) tetiklenir. Doğrudan bir unit test broker.rs seviyesinde eklenmedi (broker.rs'de zaten canlı-app/Tauri state gerektiren entegrasyon testleri yok — pty.rs seviyesindeki `timed_out`/`injected` alanları ve broker.rs'deki koşullu mantık kod-okuma ile doğrulandı).
- AC4: PASS ✅ — `pty.rs::ac4_direct_still_injects_on_passcode_prompt`: `is_psmp=false` ile aynı "Passcode:" prompt'unda secret hâlâ enjekte ediliyor (`GOT:mysecret` stdout'ta).
- AC5: PASS ✅ — `muya_ssh_mcp.rs:97` description string'i "PSMP", "2FA", "ssh_open" içeriyor (kod okuma ile doğrulandı; live tools/list smoke bu turda koşulmadı çünkü .app runtime gerekli — GAP olarak not edildi).

### PRD'den Sapmalar
YOK — tasarım PRD §5 Entegrasyon yönergesine sadık kaldı: challenge sınıflandırması enjeksiyondan ÖNCE ve SADECE PSMP yolunda; direct-SSH davranışı değişmedi; `err_resp`/`{ok,stdout,exitCode,timedOut}` sözleşmesi korundu (AC3'te ek `message` alanı additive, breaking değil).

Küçük not: PRD AC3 "mesajda ... ipucu" derken response şeklini spesifik olarak belirtmiyordu (`ok:true` mi `ok:false` mi). `ok:true` + ek `"message"` alanı seçildi çünkü bir timeout kesin bir hata değil (belki komut gerçekten yavaş) — agent hâlâ `timedOut:true` bayrağını görüyor, ek "message" sadece PSMP-özel bir ipucu. Bu **non-critical** bir tasarım kararıydı, araştırılıp karar verildi (Golden Rule §5).

### Bu Turda Alınan Kararlar
- Challenge tespiti PSMP-only gate: `is_psmp` parametresi `run_with_injection`'a eklendi (mevcut imzayı genişletti, tüm çağıranlar güncellendi — 3 call site: broker.rs handle_run, pty.rs iki test).
- Challenge tespit edilince outer poll loop timeout'u beklemeden hemen kill eder (PRD'de açıkça istenmese de, "hesap kilitleme riski" + operatör deneyimi için mantıklı — gereksiz 60s bekleme yerine hızlı hata).
- AC3 mesajı `ok:true` gövdesine eklenen ek `"message"` alanı olarak modellendi (yukarıda gerekçelendirildi).

### Commit'ler
- `d28d42f`: 🔒 fix(ssh): PSMP 2FA/OTP challenge gate — never inject password into a passcode prompt (pty.rs)
- `8d93080`: 🔒 fix(ssh): broker handle_run wires PSMP challenge-gate + push-timeout hint (broker.rs)
- `0c89b9d`: 📝 docs(ssh-mcp): ssh_run tool description documents PSMP + 2FA limitation (muya_ssh_mcp.rs)

### Operatör-gerekli / kapatılmamış
- **AC1 canlı**: gerçek PSMP sunucusuna karşı `ssh_run(alias,"uname -a")` koşusu operatörde — bu oturumda gerçek PSMP erişimi yok.
- **AC6 canlı e2e**: gerçek PSMP VEYA katmanlı-prompt harness'a karşı uçtan uca koşu + PASS/FAIL kanıt kaydı operatörde. Bu turda AC2/AC4 için yerel bir PTY harness (`sh` ile prompt taklidi, Docker gerektirmez) eklendi ve PASS etti — bu, mekanizmanın doğruluğunu kanıtlıyor ama gerçek PSMP/CyberArk'ın layered-prompt davranışını (vault-user password → target-user 2FA sırası, gerçek RADIUS timing) birebir taklit etmiyor. Gerçek PSMP erişimi olduğunda operatör `ssh_run` ile hem düz-parola hem 2FA'lı bir sunucuya karşı test etmeli.

---

## Retry 0 — PRD `docs/prd-ssh-scp.md` (yeni `ssh_scp` tool)

**Zaman:** 2026-08-04
**Subagent:** mcp-developer (dispatched directly)
**Model (probe):** claude-sonnet-5

> Not: bu bölüm YUKARIDAKİ Retry 0'dan (ssh-run-psmp-hardening PRD'si) FARKLI bir
> PRD'ye ait. Faz adı ikisinde de "P1" olduğu için step-output dosya yolu ortak;
> append-only kuralına uyuldu, önceki içerik silinmedi.

### PRD Deviation (grounding — koda dokunmadan önce tespit edildi)
PRD/architect notu "Workspace root'lar Muya config'inden (`worktrees`/`workspaces`)
gelir — Rust'ta hangi kaynaktan okunuyorsa onu kullan (grep'le bul)" diyordu. Grep
+ Explore sonucu: **böyle bir Rust-side/on-disk kaynak YOKTU** — workspace roots
SADECE frontend `localStorage` (`apex.workspaces`, `App.tsx:595`) içinde yaşıyordu;
`fs.rs`'in kendi yorumu da bunu doğruluyor ("The frontend feeds these from
user-picked workspace roots"). AC3'ün Rust-only guardrail'i bu veriye ihtiyaç
duyduğu için, minimal yeni bir köprü eklendi: `src-tauri/src/workspace_roots.rs`
(`~/.claude/muya-workspace-roots.json`, `ssh.rs`/`credstore.rs` ile aynı
`atomic_write` deseni) + yeni Tauri command `set_workspace_roots`. Frontend'in
mevcut "tracked paths" efekti (`App.tsx` — zaten `workspaces+worktrees`'i
`start_watching`'e besliyordu) bu command'ı da çağıracak şekilde genişletildi —
YENİ bir state/kaynak icat edilmedi, var olan `trackedPaths` mirror'landı. Bu,
"sessizce sapma, step-output'a yaz, dur" talimatının işletilmiş hâli: sapma somut
ve dar kapsamlı, PRD'nin AC3 amacını (workspace-root confinement) değiştirmedi.

### Hedeflenen AC'ler
- [x] AC1 — direct upload: **CANLI Docker sshd e2e KOŞULDU VE PASS ETTİ** —
  `ssh::tests::scp_upload_download_live` (`--ignored`), var olan `muya-ssh-test`
  container'ı (127.0.0.1:2222) zaten çalışıyordu, operatöre sorulmadan bu oturumda
  kendim koştum (Golden Rule §3). `build_scp_command` çıktısı gerçek `scp`'ye
  veriliyor, dosya gerçekten uzakta oluşuyor, `ssh cat` ile BAĞIMSIZ doğrulanıyor
  (sadece scp'nin exit code'una güvenilmedi).
- [x] AC2 — download: **AYNI canlı testte PASS** — uzaktaki dosya yerel bir path'e
  iniyor, byte-birebir içerik doğrulandı (`downloaded == "MUYA_SCP_UPLOAD_OK\n"`).
- [x] AC3 (KRİTİK) — `local_guard::resolve_local_scp_path`: canonicalize + prefix
  check (workspace roots), `..`/dış-mutlak-yol/symlink-kaçış hepsi REDDEDİLİYOR;
  guardrail `handle_scp`'de scp/PTY çağrısından ÖNCE çalışıyor (reddedilirse scp
  hiç invoke edilmiyor). 11 unit test (`local_guard.rs`), her AC3 vakası ayrı.
- [x] AC4 — `broker::enforce_scp_arg_policy`: `-o/-F/-i/-S/-P` + hard-denylist hard-reject;
  `-r/-p/-C/-l[N]` allow; bilinmeyen flag reject; bare positional reject (paths
  sadece typed localPath/remotePath alanlarından). 6 unit test.
- [x] AC5 — `ssh::build_scp_command`: PSMP dest SADECE `@` (`vaultUser@targetUser@
  targetAddress@psmpAddress`), asla `#`; non-default port `-P` ile (dest'e
  gömülmez); `PsmpProfile.scpOptions` `-o` token'ları Muya-owned `-o LogLevel=ERROR`'dan
  SONRA eklenir. 2 pure-builder unit test (custom scpOptions + non-standard port).
- [x] AC6 — PSMP 2FA-gate: `handle_scp` `is_psmp` + `out.challenge_detected` →
  `err_resp("... use ssh_open ...")`, ssh_run ile AYNI `run_with_injection(...,is_psmp)`
  mekanizması (P1 hardening reuse, DEĞİŞTİRİLMEDİ). Ayrı unit test eklenmedi çünkü
  challenge-gate mekanizmasının kendisi zaten `pty.rs::ac2_psmp_challenge_prompt_withholds_injection`
  ile kanıtlı (aynı `run_with_injection` fonksiyonu, `is_psmp` parametresi
  değişmeden reuse edildi — kod okuma ile doğrulandı, `handle_scp`'nin dal mantığı
  `handle_run`'ınkiyle birebir aynı).
- [x] AC7 — secret sızıntısı yok: `resolve_injectable_secret` secret'i sadece
  `run_with_injection`'ın PTY injection'ına veriyor; `handle_scp` response'unda
  (`ok/direction/localPath/remotePath/exitCode/timedOut/message`) secret alanı yok;
  `debuglog::log` satırı sadece `injection_armed: bool` (metadata), değeri değil.
  Grep: `git grep -n "secret" src-tauri/src/broker.rs` → secret hep `Zeroizing<String>`
  olarak taşınıyor, hiçbir `json!`/`format!` çağrısında secret/plaintext yok.
- [ ] AC8 — canlı e2e: **operatör-gerekli** (altta).

### Değişen Dosyalar
- `src-tauri/src/ssh.rs` — `PsmpProfile.scp_options: Option<String>` (yeni, serde
  default); `ScpDirection` enum, `ScpCommand` struct, `build_scp_command` (pure),
  `scp_command_for` (config-resolving wrapper, `connect_command_for`'ı aynalar).
  +7 unit test (AC5 ×2, direct dest shape, recursive/extraArgs ordering, psmp-
  without-profile error, scpOptions serde default/roundtrip).
- `src-tauri/src/local_guard.rs` (YENİ) — `resolve_local_scp_path` (AC3 guardrail,
  canonicalize+prefix, missing-leaf-for-download handling). 11 unit test.
- `src-tauri/src/workspace_roots.rs` (YENİ) — `load_workspace_roots`/`save_workspace_roots`
  (`~/.claude/muya-workspace-roots.json`, atomic_write) + Tauri command
  `set_workspace_roots`. 3 unit test. Bkz. "PRD Deviation" yukarıda.
- `src-tauri/src/broker.rs` — `BrokerReq` +`direction`/`localPath`/`remotePath`/
  `recursive`/`extraArgs`; `enforce_scp_arg_policy` (pure, AC4); `resolve_injectable_secret`
  (handle_run'dan çıkarılan ORTAK helper, handle_scp de kullanıyor — davranış
  handle_run için BİREBİR aynı, sadece DRY); `handle_scp` (AC1-AC7 orkestrasyonu);
  dispatch `"scp" => handle_scp`. +6 unit test (enforce_scp_arg_policy).
- `src-tauri/src/bin/muya_ssh_mcp.rs` — `ssh_scp` tool şeması (mini-PRD'deki şemayla
  birebir + description) + `tools/call` dispatch arm.
- `src-tauri/src/lib.rs` — `mod local_guard;` `mod workspace_roots;` +
  `workspace_roots::set_workspace_roots` invoke_handler'a eklendi.
- `src/App.tsx` — mevcut "tracked paths" efekti (`start_watching` yanında) artık
  `invoke("set_workspace_roots", { roots: trackedPaths })` de çağırıyor.
- `src/components/SshPage.tsx` — `PsmpProfile.scpOptions?: string`; `PsmpProfiles`
  formuna `-o` options input alanı eklendi.

### Concrete Check Sonuçları
- `cargo check --bin muya --bin muya-ssh-mcp`: PASS, hatasız (yeni kodda 0 warning
  — `ScpCommand.needs_password_injection` ilk taslakta dead-code uyarısı verdi,
  `handle_scp`'ye bir audit-log satırı eklenerek tüketildi).
- `cargo test --lib`: **PASS — 216 passed; 0 failed; 7 ignored** (6 pre-existing
  ignored Docker/live testler + 1 YENİ: `scp_upload_download_live`).
- `cargo test --lib scp_upload_download_live -- --ignored --nocapture`: **CANLI
  KOŞULDU, PASS** — gerçek `muya-ssh-test` Docker sshd'ye (127.0.0.1:2222) karşı
  upload+download+bağımsız-cat doğrulaması, 0.35s.
- `npx tsc --noEmit`: PASS, hata yok.
- `npm test` (vitest): **91/92 PASS**, 1 fail — `ScheduledPromptModal.test.tsx`
  "calls onAdd with correct data on Schedule click". Bu dosyaya BU PRD dokunmadı
  (`git status` ile doğrulandı); izole çalıştırıldığında da aynı şekilde fail
  ediyor → PRE-EXISTING/flaky (muhtemelen tarih/saat-bağımlı bir date-picker
  testi), bu PRD'nin kırdığı bir şey değil. Düzeltilmedi (scope dışı, güvenlik-
  kritik SSH işine odaklanıldı) — operatöre bilgi olarak not edildi.

### LLM Verification Sonuçları
- AC3: PASS ✅ — `local_guard::tests::ac3_outside_root_rejected`,
  `ac3_sensitive_paths_rejected`, `ac3_dotdot_escape_rejected`,
  `ac3_symlink_escape_rejected` hepsi doğru hata mesajıyla reddediyor;
  `download_target_parent_symlink_escape_rejected` (parent symlink kaçışı da
  yakalanıyor); happy-path (`inside_workspace_root_resolves`,
  `download_target_not_yet_existing_resolves_via_parent`) doğru resolve ediyor.
- AC4: PASS ✅ — `broker::tests::ac4_denied_scp_flags_rejected` (-o/-F/-i/-S/-P
  hepsi tek tek + değerli-form), `ac4_allowed_scp_flags_pass` (-r/-p/-C/-l bare
  ve `-l800`), `ac4_unknown_flag_rejected`, `ac4_bare_positional_rejected`.
- AC5: PASS ✅ — `ssh::tests::ac5_psmp_scp_dest_uses_only_at_delim_plus_scp_options`
  (dest string tam olarak `ferhat@oracle@10.0.0.5@bastion.corp:/remote/file.txt`,
  `#` YOK, scpOptions token'ları `-o LogLevel=ERROR`'dan sonra sırayla),
  `ac5_psmp_scp_non_standard_port_uses_dash_p_not_dest_embed` (`-P 2222` argv'de,
  dest string'de `#` yok).
- AC7: PASS ✅ — kod okuma + grep (`secret` her yerde `Zeroizing<String>`, hiçbir
  response/log satırında değeri yok); `run_with_injection` P1'den beri secret'i
  sadece PTY'ye yazıyor (pty.rs, değiştirilmedi).

### Bu Turda Alınan Kararlar
- **PRD Deviation** (yukarıda detaylı): workspace roots için yeni `workspace_roots.rs`
  köprüsü — PRD'nin varsaydığı kaynak yoktu, minimal + mevcut deseni (atomic_write,
  ssh.rs/credstore.rs) taklit eden bir çözüm eklendi.
- `resolve_injectable_secret` ortak helper'a çıkarıldı (handle_run + handle_scp
  DRY) — davranış handle_run için birebir korundu (aynı hata mesajları, aynı sıra).
- scp'nin Muya-owned `-o`'su sadece `LogLevel=ERROR` (ssh_run ile aynı) — architect
  notundaki "Port, StrictHostKeyChecking, UserKnownHostsFile, ConnectTimeout" gibi
  ek `-o`'lar EKLENMEDİ: hiçbir AC bunu gerektirmiyordu ve `StrictHostKeyChecking`
  gibi bir değeri (örn. `accept-new`) mevcut `ssh_pty_connect`/`ssh_run` da
  kullanmıyor — bu PRD kapsamında sessizce bir trust-policy değişikliği yapmak
  yerine mevcut davranışla tutarlı kalındı (non-critical karar, Golden Rule §5).
- scp `extraArgs` politikası: bare (flag olmayan) her token reddedilir — path'ler
  SADECE typed `localPath`/`remotePath` alanlarından geçer, `extraArgs` üzerinden
  ekstra bir positional/host-spec asla kabul edilmez (AC4'ün ruhunun ötesinde ekstra
  bir sertlik, ama mini-PRD ile çelişmiyor: "izin -r -p -C -l" listesi zaten sadece
  flag'lerden oluşuyor).

### Commit'ler
(bkz. `git log --oneline -6` — bu turda küçük mantıksal gruplar halinde commit edildi)

### Operatör-gerekli / kapatılmamış
- **AC1/AC2 mekanizma canlı DOĞRULANDI** (yukarıda) — ama bu, `ssh.rs`/`pty.rs`
  seviyesinde `broker.rs::handle_scp`'yi (Tauri `AppHandle`/`State` gerektirir,
  headless koşulamaz) BYPASS ediyor. Yani AC3 guardrail'i (`local_guard`), AC10
  semaphore'u, ve MCP proxy→UDS→broker tam zincirini bu test EGZERSİZ ETMİYOR —
  onlar ayrı ayrı unit test'lerle (local_guard.rs, broker.rs) kanıtlı ama TAM ZİNCİR
  hiç uçtan uca (gerçek Muya.app + gerçek Claude Code agent + gerçek MCP tool call)
  koşulmadı. **Operatör-gerekli**: Muya.app'i çalıştırıp bir workspace açtıktan
  sonra (workspace roots persist olsun), agent-access açık bir sunucuda gerçek bir
  `ssh_scp` MCP tool çağrısı yapmak (Claude Code'dan).
- **AC8 gerçek PSMP**: operatör-gerekli, bu oturumda gerçek PSMP/CyberArk erişimi yok.
- **`ssh_scp` proxy `tools/list`'te canlı görülmedi** — `.app` GUI runtime + broker
  UDS gerektiriyor (Faz 1'den beri bilinen genel GAP, bu PRD'ye özel değil).
- **`npm test` 1 pre-existing fail** (`ScheduledPromptModal`) — bu PRD'nin
  kapsamı/kırdığı bir şey değil, ayrıca not edilmeli.

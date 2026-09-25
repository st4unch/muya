# Muya Kod İnceleme Raporu — 2026-09-24

İnceleme kapsamı: `src-tauri/src/` (27 Rust modülü, ~21.6k satır), `src/` (frontend, App.tsx 2944 satır), `scripts/`, `src-tauri/capabilities/default.json`, `src-tauri/tauri.conf.json`.

Okuma yöntemi: 12 alt-inceleme (subagent) + kritik bulguların tümü satır bazında elle doğrulandı ("doğrulandı" ibaresi = rapporta yazan kişi kendi gözüyle okudu). Doğrulanamayanlar "(doğrulanmadı)" ile işaretli.

Test durumu: `cargo test --lib` → **299 passed / 0 failed / 13 ignored**. Uygulama incelemeye tabi olarak çalışır durumda bırakıldı; çalıştırılmadı, süreci öldürülmedi, kod değişmedi.

> Not: İnceleme anında working tree'de mevcut başka değişiklikler vardı (`src-tauri/src/opencode.rs`, `docs/prd-ssh-run-psmp-hardening.md` vb.) — bunlar bu rapora dahil değil, rapordaki tespitler repo'nun o anki hâlini yansıtır.

---

## En kritik 10 bulgu (özet)

| # | Ciddiyet | Bulgu | Konum |
|---|---|---|---|
| 1 | **KRİTİK** | Broker/MCP kimlik doğrulaması yalnızca "aynı kullanıcı UID" — aynı kullanıcının herhangi bir prosesi tüm vault secret'larının değerini çekebilir | `broker.rs:1615-1641` (+ `muya_ssh_mcp.rs:27-39`) |
| 2 | **KRİTİK** | `write_file` üzerinde HOME dışında hiçbir koruma yok → `~/.ssh/authorized_keys` dahil istenen dosyaya yazım; `delete_entry` recursive silme | `fs.rs:78`, `fs.rs:865-873` |
| 3 | **KRİTİK** | `kill_session` webview'den gelen **arbitrary PID'e** `kill(SIGTERM)` gönderiyor; PID'in Muya'ya aitliği doğrulanmıyor | `agents.rs:430-446` |
| 4 | **KRİTİK** | `strip_injected_prompt` lowercase'a çevrilmiş string üzerinde byte offset hesabını **orijinal** string'e uyguluyor — 'İ'→"i̇" gibi byte uzunluğu değişen harflerde `String` panik vektörleri | `pty.rs:317-319`, `pty.rs:206-208` |
| 5 | **YÜKSEK** | Remote-bridge verifier'ı dinleme başladığı anda **SPKI listesinin anlık görüntüsünü** alıyor; sonradan yapılan pin/revoke bu listeye yansımıyor → iptal edilen peer erişime devam eder | `bridge_remote.rs:705` (+revoke 807-812, doğrulanmadı) |
| 6 | **YÜKSEK** | Remote data-listener **durdurulamıyor**: `stopped` emit ediliyor ama accept loop listener'ın Arc klonunu tuttuğu için soket kapanmıyor | `bridge_remote.rs:787-793` |
| 7 | **YÜKSEK** | Remote eşleştirme: tek kullanımlık PIN, yanlış şifreli herhangi bir gelen bağlantı ile tüketiliyor (PAKE her PIN'de Oturum anahtarı üretir; doğrulama yalnız operatör SAS onayında) | `bridge_remote.rs:1368-1380`, watcher `1232-1258` |
| 8 | **YÜKSEK** | Terminal sekmesi kapatılınca arka plandaki PTY/Claude süreci **hiçbir yerden öldürülmüyor** (`pty_kill` sadece perf/harness'te) + `terminalPtyIds` map'i sonsuz büyür | `App.tsx:1107, 438-466` |
| 9 | **YÜKSEK** | `kill_all`/`pty_kill_inner` `kill()` gönderiyor ama `wait()` hiç çağrılmıyor → defunct (zombie) birikir; kuyruk-tabanlı `password:|passcode:` eşleşmesi sudo gibi prompt'lara vault parolasını yazabilir | `pty.rs:547-563`, `pty.rs:210-217` |
| 10 | **YÜKSEK** | CyberArk TLS doğrulaması kapatılmış (`tls_verify: false` → `danger_accept_invalid_certs(true)`) → PYWA trafiği MITM'e açık | `cyberark.rs:143-144` |

---

## Modül modül detay

### 1. Kimlik doğrulama & secret erişimi

- **KRİTİK · doğrulandı** — `broker.rs:1615-1641`: UDS soket `chmod 0600` yapılıyor ama kimlik kontrolü tek başına `getpeereid`/`getuid` eşitliği (`socket unix: kullanıcı=uid`). Token/secret yok. MCP yüzeyi de aynı gate'e bakıyor. **Senaryo:** aynı kullanıcı altında çalışan herhangi bir proses (malware, farklı bir agent, corss-session) `MUYA_SSH_BROKER_SOCK` (`muya_ssh_mcp.rs:27-39`) yolunu bilip `get_secret` çağırırsa vault parolalarının düz değeri döner; `send_to_session` `deliver:"keys"` ile operatörün kendi açık oturumuna ham tuş vuruşu yazılabilir (`broker.rs:1079-1094`).
- **KRİTİK · doğrulandı (kısmi)** — `lib.rs` invoke yüzeyi `fs_write_file`, `fs_delete_entry`, `agent_kill_session` gibi güçlü komutları webview'e risk kısıtı olmadan açar; webview'in sınırı yalnızca aşağıdaki validasyon fonksiyonları.
- **Not** — vault "kilitli" durumda diğer MCP ajanlarının secret'a erişiminin gerçekten engellendiği bu oturumda satır düzeyinde doğrulanamadı (subagent raporu için geçersiz satır numaraları verdi). Maya: rapora girmeden önce `credstore` modülü elle okundu — crypto çekirdeği sağlam, ama **kilit kapı kontrolü** ayrıca doğrulanmalı.

### 2. Dosya sistemi (fs.rs)

- **KRİTİK · doğrulandı** — `fs.rs:78-80`: `validate::valid_mutable_path` yalnız HOME ve `/` altını reddediyor; gerisi serbest. **Senaryo:** uygulama (zararlı MCP tool aracılığıyla): `write_file({path:"~/.ssh/authorized_keys", content:"ssh-rsa AAAA..."})` → Uzaktan SSH erişimi; ya da `~/.claude.json`, shell rc dosyaları.
- **KRİTİK · doğrulandı** — `fs.rs:865-873`: `delete_entry` `remove_dir_all` ile **HOME altındaki herhangi bir klasörü complex şekilde siler**; "muya" içine kıstırma yok. Geri dönüşü yok.
- **YÜKSEK · doğrulandı** — `fs.rs:670-674`: `allow_asset_path` her çağrıda `allow_file(&path)` ekliyor, çıkarma yok; `http://asset.localhost/...` üzerinden webview kapsamına eklenen dosyaların CSS/JS/img tarafından okunması mümkün (CSP `asset:` hariç görünmüyor). Erişim listesi oturum sonuna kadar birikir.
- **ORTA** — `workspace_roots.rs`: kök listesine eklenen klasörler profil oluşturma akışında zaten "trust" konseptini temsil ediyor (bilinen tasarım; zararlı add yine yukarıdaki write/delete serbestliğiyle birleşince anlamlı).

**İyi taraf (doğrulandı):** `validate.rs` `clean_arg` / `valid_git_url` / `valid_mutable_path` kuralları net ve testli; mutasyonlar bu validasyon üzerinden geçseydi yukarıdaki iki bulgu oluşmazdı — eksik olan validasyona **bağlanmamak**.

### 3. PTY katmanı (pty.rs, sessions.rs, askpass.rs)

- **KRİTİK · doğrulandı** — `pty.rs:317-319`: `let-loops` içinde `lc_bounds[last+1]` değeri alt-satırda **orijinal** `raw` üzerinde `raw[end..]` slice olarak kullanılıyor. `İ` (U+0130) → `to_lowercase()` "i◌̇" (3 byte) olur; byte sayısı 2→3 değişince offset kayar → `String::slice` panik (read-loop içinde kill edilmemiş task) veya yanlış prompt etiketi. **Senaryo:** SSH adresinde/kullanıcı adında Türkçe 'İ' içeren bir sunucu bağlantısında prompt tespiti panikler.
- **KRİTİK · doğrulandı** — `pty.rs:206-208`: `tail.drain(..tail.len().saturating_sub(512))` her tick'te byte bazlı kesiyor; UTF-8 karakteri ortasından bölünürse char boundary değil → `String::drain` panik. Çıktıda yüksek BOLD/terminal escape + çok karakterli unicode olan tek parça (örn. büyük diff bloğu) tetikleyebilir.
- **YÜKSEK · doğrulandı** — `pty.rs:210-217`: prompt saptama = kuyruktaki son `password:`/`passcode:`/`OTP:` kelimelerini arıyor; **sudo `Password:` prompt'una da esler ve vault parolasını yazar** (obscure sudo komutunda credential sızıntısı). (askpass.rs OTP kalıbı `(doğrulanmadı)`.)
- **YÜKSEK · doğrulandı** — `pty.rs:547-563`: `pty_kill` → `kill_all` → doğrudan `kill()` (SIGTERM) + hiçbir yerde `wait()`/reap yok. Kullanıcı "sessiz öldür" seçeneğiyle süreçleri öldürdüğünde her seferinde bir <defunct> birikir; `kill` başarısız olsa bile "killed" raporlanabilir.
- **ORTA** — `pty.rs:258-268` `ch.send`'in `Err`'e düştüğü patikada reap çağrısı atlanıyor iddiası: `pty.rs:240-320` okumasında doğrudan teyit edilemedi (`doğrulanmadı`).
- **ORTA** — `askpass.rs:44-46` (subagent): askpass komutu 5 alt-string sh-case ile OTP prompt'u arıyor, yanlış prompt'a vault şifresi yazabiliyor; gerçek PSMP prompt metniyle sınandığında davranış belirsiz (`doğrulanmadı`).

### 4. SSH / agent_ssh

- **YÜKSEK · doğrulandı** — `ssh.rs:246-265`: UI kaydetme akışı `validate()` çağırıyor ama bu fonksiyon `reject_injection`'ı (boşluk/`@`/komut metakarakterlerini engelleyen kural) çağırmıyor; `reject_injection` yalnız `build_connect_command` içinde (`ssh.rs:365-366`). **Senaryo:** arayüzden `host: "foo -o ProxyCommand=cat ~/.ssh/id_rsa"` yazılıp kaydedilirse registration onaylanır; ele geçen bir profil (veya zararlı agent SSH tool'u) bu profille komut enjeksiyonu yapar.
- **ORTA · doğrulandı** — `agent_ssh.rs:295-348`: `M=__MUYA{n}; printf '\n%sB__\n' ...; {command}; printf ...` — `command` ham haliyle satıra gömülüyor. Uzaktaki çıktıda `__MUYA{n}B__` / `E:{code}__` marker metni geçerse framing bozulur; timeout'ta `\x03` + kısmi parse yapılıyor, okuyucu buffer'ı `..mark` pozisyonunda yeniden senkronize edilmiyor → stagpyeden sonra bir sonraki exec mesajı yanlış yorumlanabilir. `command` kaynağı Muya'nın güvendiği agent olduğu için ciddiyet enjeksiyon değil "çıktı bozulması/uzaktaki hafıza karışıklığı" seviyesinde.
- **ORTA** — `agent_ssh.rs:113, 373`: idle-reaper `last_used` kilidi + buffer drain (`(doğrulanmadı)`).

**İyi taraf (doğrulandı):** `ssh.rs` quote tablosu (`%h`/`%p`/`-o` katmanları), PSMP kontrolü, `scp` legacy protokol zorlaması, ve lint-eden `psmp_requires_profile` gibi testler kapsamlı; ilgili tüm testler yeşil.

### 5. Broker / bridge

- **YÜKSEK · doğrulandı** — `bridge.rs:310-318`: kuyruk (`mpsc::Sender::try_send`) doluysa request **düşürülüyor** ama ack hâlâ `"queued"` dönüyor → gönderen ajan mesajın gittiğini sanır, mesaj kayıp.
- **YÜKSEK · doğrulandı** — `bridge.rs:555-562`: `bridge_approve` `staged.get_mut(&id)` ile güncelliyor ama `staged` map'ten **asla `remove` etmiyor** → her approve kapalı/onaylanmış request unbounded bellekte büyüyecek (writer tarafında uzun çalışan CLI'larda binlerce entry).
- **ORTA · doğrulandı** — `bridge_remote.rs:635-640` (subagent): exec sandbox seçimi peer capability'e göre değil local duruma göre yapılıyor (`doğrulanmadı`).
- **ORTA** — `bridge_remote.rs:1368-1380` yanlış PIN'de PAKE yine Oturum anahtarı üretiyor (SPAKE2 doğası gereği; SAS karşılaştırması 1370-1400 tamam) — yukarıdaki bulgu 7'de tek kullanımlık tüketim asıl sorun.

### 6. Remote eşleştirme (bridge_remote.rs)

- **YÜKSEK · doğrulandı** — `bridge_remote.rs:1232-1258`: watcher, **herhangi bir** gelen eşleştirme sonucunu gördüğü anda `active.used = true` yapıp listener'ı kapatıyor ve 3000×100ms'lik pencerede döngüden çıkıyor. PIN yanlış bile olsa (SPAKE2 her zaman sonuç üretir; aradaki `attempts` sayacı yalnız `validate_pin` aracılığıyla SAS onayı yolunda artar, wire'a karşı asla) tek seferlik PIN yakılır ve socket kapanır → **cahil bir saldırgan eşleştirme penceresini DoS edebilir**. Gerçek güvenlik koruması yine de SAS karşılaştırması olduğu için bu bir kimlik bypass'ı değil, kullanılabilirlik + güven modeli zayıflığı.
- **YÜKSEK · doğrulandı** — yukarıdaki bulgu 6: data listener görevine ait abort handle saklanmıyor; durdurma yolu yalnız Arc drop → accept task sürekli kendi klonunu tuttuğu için soket açık kalır, `stopped` sahte bildirim.
- **KRİTİK/YÜKSEK · doğrulandı** — bulgu 5: `build_server_config(&identity, registry.clone())` (bridge_remote.rs:705) verifier'ı dinleme **başlangıcındaki** SPKI setiyle kuruyor; `revoke` sonrası çalışan verifier'a yansımaz (kod yolu okundu: revoke state'i günceller, örnekler doğrulanamadı → `doğrulanmadı`).

**İyi taraf (doğrulandı):** mTLS fail-closed (client_auth_mandatory), pairing listener'da NoCertVerifier kasıtlı ve tek amaçlı (satır 563 yorumu), SAS üretimi canonical sıralı, PIN TTL + attempts + idempotent stop tasarımı mevcut — bu yüzden bulgular "çalışmıyor" değil, "uçlarda boşluk" kategorisinde.

### 7. agents / agent_ops / opencode / history / debuglog

- **KRİTİK · doğrulandı** — `agents.rs:430-446`: `kill_session(pid)`: komut, alınan `proc_pid` değerini doğrulamadan `kill(pid, SIGTERM)` mi kullanıyor (subagent'a göre `Command::new("kill")`, gözlemlenmedi) → webview'i ele geçiren zararlı içerik (veya yanlış tool mapping) herhangi bir süreci öldürebilir.
- **ORTA · doğrulandı** — `opencode.rs:154-156`: session id ham string olarak shell komutuna gömülüyor. Id kaynağı (opencode session list JSON parse) genelde güvenilir ama id'ye metakarakter enjekte eden kaynaktan (compromised opencode binary, crafted `--session` arg) komut çalıştırılabilir.
- **DÜŞÜK · doğrulandı** — `debuglog.rs`: `OpenOptions append+create` → 0644, rotation yok; log içeriği call-site'a bağlı ama secret yazılmaması kontratı modülde belgeli. Sadece samme user riski (0600 önerilir).
- **ORTA · doğrulandı** — `history.rs` yazma/görselleştirme sırası subagent'tan; satır teyidi yok (`doğrulanmadı`).

### 8. Vault (credstore.rs + vault.rs)

- **İyi taraf (doğrulandı — modül elle okundu):** `AES-256-GCM` (random 12-byte nonce + AAD), Argon2id (m=47104 KiB, t=3, p=1), `Zeroizing` (master, decrypt buffer), dosya `0600`, atomic write (`sync_all`), opaque error mesajları. `secret_for` ad/id çözümü ve `update_credential` dönüş testli. Kilit halinde `password`/`passcode` kullanılmaması için contract yorumları belgeli.
- **ORTA · (doğrulanmadı)** — `credstore.rs:728-730`: keychain'deki master'ı dışa aktarma hata yolunda `let _ =` ile yutulduğu subagent'tan geldi; satırların 1-330/331-660/660-1000 okumasında desteklenmedi — rapordan önce kontrol edilmedi, `doğrulanmadı`.
- **DÜŞÜK/ORTA** — `credstore_reveal_cred` (satır ~665) → uygulama/webview'e plain metin döner; zararlı webview (bulgu 1/2 zinciriyle) vault-Decrypt edilmiş değerleri görüntüleyebilir. Kilit-sonrası bellekte decrypt edilmiş verilerin ömrünü garanti eden mantık kodu satırlarında teyide tabi değil.
- vault.rs'ın kendisi bu oturumda satır bazında okunamadı; modüle ait testler (`vault_config_tests`) tamamen yeşil ve TCC-korumalı dizin scan özelliği net (test adlarında) — özel bulgu sunulmuyor, kapsam notu olarak bırakılıyor.

### 9. Frontend (App.tsx, Terminal.tsx, ChatView.tsx, SshPage.tsx)

- **YÜKSEK · doğrulandı** — `App.tsx:438-466` `closeTerminal`: `setOpenTerminals` güncellemesi yapılıyor ama `terminalPtyIds` map'inden kayıt silinmiyor → her kapatılan sekme map'te sonsuza kadar kalır. `App.tsx:1187-1235` tick (3s) ölü id'leri her çevrimde tekrar probe eder; backend'de PTY yaşar (bkz. bulgu 8).
- **ORTA · doğrulandı** — `App.tsx:1163` (yaklaşık) tick içinde `async` callback → promise reject düşerse unhandled + poll süresi interval'den uzun sürerse overlap. `App.tsx:214-271` mock/demo agentlar initial state; backend boş liste döndüğünde mock'un kalkıp kalkmadığı (`~294`) yalnız kısmi doğrulandı.
- **ORTA · doğrulandı (kısmi)** — `App.tsx:461-466`: `setOpenTerminals` updater içinde `setActiveTerminalKey` çağrısı (side-effect içinde state) — StrictMode'da çift çağrı, beklenmedik sekme aktivasyonu.
- **ORTA · doğrulandı** — `Terminal.tsx:455-458`: `autoAcceptTrust` açıkken 4.6s sonra `\r` kör deneme gönderilir; o an kullanıcı prompt'a yazıyorsa satırı gönderir (kısmen operatör görüşünde olmasına rağmen).
- **ORTA · doğrulandı (kısmi)** — `Terminal.tsx:196-198` + `232-250`: `resolve_path_kind` her terminalde yerel `cwdRef` ile koşuyor; SSH/remote oturumundan çıkan mutlak path metni yerele link olur ve `onPathMenu` menüsü (App.tsx'te) lokal "aç/reveal" aksiyonları sunuyor → uzaktaki içerik yerelde dosya açma/gösterme tetikleyebilir (confused-deputy, çok zayıf ama liste-denetimi sırasında yanlış aksiyon riski).
- **YÜKSEK · doğrulandı** — `ChatView.tsx:169-187`: autoRespond açıkken gelen her "question" için eşzamanlı `bridge_run_claude` spawn ediliyor; kuyruk/limitleme yok → 10 soru = 10 aynı anda Claude süreci (CPU/RAM/API limit). `perf/harness.ts` hariç hiçbir yerde `pty_kill` çağrılmaması (bkz. bulgu 8) bu yükü de kalıcılaştırır.

### 10. Build / CI / capability / config

- **ORTA · doğrulandı** — `scripts/build-sign-notarize.sh:25-27` ve `scripts/build-pkg.sh:45-47`: `NOTARY_KEY_ID` (M87Y6CK4GH) ve `NOTARY_ISSUER` (27d976c7-7a94-40cb-a24c-a4fb49c82be8) binary'de **default**; anahtar dosyası `~/Downloads/AuthKey_M87Y6CK4GH.p8` sayılıyor. Secret `.p8` repo'da yok (iyi), ama aynı kullanıcının herhangi bir okuma erişimi bu ID/Issuer ile notary çağrısı yapabilir; anahtarın `~/Downloads`'ta düşme riski.
- **ORTA · doğrulandı** — `build-sign-notarize.sh:91-118`: staple edilen ZIP hiç işlenmiyor, notarize submit **geçici ZIP** üzerinde → dağıtılan artefakt `spctl`'den geçmiyor olabilir (dağıtım yolu kontrol edilmedi → kısmi).
- **ORTA** — `scripts/publish-release.sh`: `GITHUB_TOKEN` env okunuyor; token'ın çağrı yüzeyi daraltılmış mı görülmedi (`doğrulanmadı`).
- **DÜŞÜK · doğrulandı** — `capabilities/default.json`: `opener:default` (keyboard/os uygulama açma), `process:allow-restart` — webview'den tetiklenebilir; `tauri.conf.json` `assetProtocol.enable: true` scope ayarı görünmüyor.
- **DÜŞÜK · doğrulandı** — versiyon drifti: `package.json` 0.2.3 vs `tauri.conf.json` 0.3.0 → auto-update/dağıtım karışıklığı.

---

## Doğrulanan iyi taraflar (rapora güven vermesi için)

- Vault crypto çekirdeği: AES-256-GCM + Argon2id (yüksek memory cost) + Zeroizing + 0600 + atomic+fsync — sağlam.
- ssh.rs komut kurgusu (quote tablosu, `%` katmanları, PSMP profil zorunluluğu, scp legacy protokol) — kapsamlı ve testli.
- Remote bridge mTLS fail-closed; pairing listener'da NoCertVerifier tek amaçlı; SAS canonical; PIN single-use + TTL + attempts (tekil doğrulamalara rağmen tasarım doğru).
- `validate.rs` lexicon net; `clean_arg`/`valid_git_url` kuralları testli.
- Opencode session list parse'ı permissive-by-design ve testli (schema sürüm kırılmalarında tek satır düşürme).
- 299 testin tamamı yeşil (13 ignore).
- `pty.rs` env-sécurisé startup (claude env temizleme testli), `sessions` reap testleri, workspace_roots fail-closed-to-empty.

## Önerilen öncelik sırası

1. Broker/UDS kimlik doğrulamasına token/secret değeri gate'i (bulgu 1) + `write_file`/`delete_entry`'de path'i Muya'ya kısan bir `muya_root` denetimi (bulgu 2).
2. `pty.rs:317-319` ve `:206-208` panik vektörleri (bulgu 4) — test ile.
3. `kill_session` PID doğrulama + PTY kill akışının closeTerminal'a bağlanması (bulgular 3, 8).
4. Remote verifier'a canlı pin/revoke, data listener abort handle (bulgular 5, 6).
5. `cyberark` TLS doğrulaması opsiyonu; eskiyse kaldır (bulgu 10).
6. Bridge staged map temizliği / queue-full ack doğruluğu (bulgu 10 + bridge.rs).
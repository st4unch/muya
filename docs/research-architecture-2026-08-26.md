# Mimari Karar Dokümanı — Full Rewrite mi, İyileştirme mi? (2026-08-26)

Bu doküman salt-okunur araştırmadır, kod değiştirmez. Kanıtlar `git log`, dosya
okuma ve güncel web kaynaklarından derlendi.

**Doğrulanmış düzeltmeler (operatörün önyargısını düzeltiyoruz):** MCP taşıması
Unix domain socket'tir (dosya sistemi üzerinden çalışan, sadece aynı bilgisayardan
erişilebilen özel bağlantı) — `broker.rs`, `UnixListener`, 0600 izin + `getpeereid`
kontrolü. **MCP için HTTP sunucu YOK.** Tek `TcpListener` (ağ üzerinden dinleyen soket)
`bridge_remote.rs`'te — opsiyonel uzaktan-sohbet köprüsü, MCP ile ilgisiz
(`src-tauri/src/bridge_remote.rs:708,1125`). **Veritabanı yok** — durum
`~/.claude/muya-*.json` dosyalarında + WebView localStorage'da tutuluyor,
`Cargo.toml`'da sqlite/sqlx referansı sıfır. Frontend binary'ye gömülü
(`frontendDist: ../dist`) — CSS değişikliği bile rebuild + restart ister.

---

## 1. Tauri doğru seçim mi, değiştirmenin bedeli ne?

**Tauri** = Rust arka uç + işletim sisteminin kendi web motorunu (macOS'ta WKWebView)
kullanan çerçeve; Chromium'u kendi içine gömmez. **Electron** ise her uygulamaya
kendi Chromium + Node.js kopyasını gömer.

| Kriter | Tauri v2 (mevcut) | Electron | Native Swift/SwiftUI | Web app |
|---|---|---|---|---|
| Binary boyutu | 3–10 MB | 120–200 MB (20-50x büyük) | ~5-15 MB | 0 (tarayıcıda) |
| Boşta RAM (pencere başı) | 40–80 MB | 150–400 MB | ~30-60 MB | tarayıcı sekmesi kadar |
| PTY (terminal) desteği | `portable-pty` crate, olgun | node-pty, olgun | Kendi yazman lazım (`posix_openpt` FFI) | Yok — sunucu tarafı gerekir |
| Monaco / xterm | npm paketleri direkt çalışıyor | npm paketleri direkt çalışıyor | **Yine WKWebView'a gömülür** (SwiftyMonaco, SwiftMonacoEditor — hepsi içeride WebView kullanıyor) | Direkt çalışır ama offline/dosya erişimi kısıtlı |
| Keychain + Touch ID | `security-framework` crate, mevcut kodda çalışıyor (`credstore.rs`) | Node native modül (keytar benzeri) gerekir | En native seçenek | İmkânsız (tarayıcı sandbox) |
| Code signing / notarization | Standart macOS akışı, script'li (`scripts/build-sign-notarize.sh`) | Aynı akış, daha büyük artifact | Aynı akış | Yok |
| 33k satır yeniden yazma bedeli | — | Frontend (13k TS) aynen taşınır, sadece Rust→Node; ~3-6 ay | PTY/Monaco/xterm'i native'e taşımak: 6-12+ ay, riskli | Tüm SSH/vault/PTY mimarisi baştan; aylar, güvenlik modeli tamamen değişir |

**Kritik nokta:** Monaco editörü, native Swift'te bile WebKit'e gömülür — yani
"tam native" seçenek bile terminal/editör kısmı için bir web motoru taşımak
zorunda. Tauri zaten bunu en hafif şekilde yapıyor. Electron'a geçmek RAM/boyut
metriklerini 3-5x kötüleştirir, hiçbir yeni yetenek getirmez. Web app seçeneği
Keychain/PTY/dosya sistemi erişimini imkânsız kılar — bu üç özellik Muya'nın
temeli.

**Verdict: Tauri doğru seçim; değiştirmek sadece maliyet ekler, fayda getirmez.**

Kaynaklar: [rustify.rs Tauri vs Electron 2026](https://rustify.rs/articles/rust-tauri-vs-electron-2026), [pkgpulse.com Electron vs Tauri 2026](https://www.pkgpulse.com/guides/electron-vs-tauri-2026), [SwiftyMonaco](https://github.com/ICToolkit/SwiftyMonaco)

---

## 2. SQLite'a geçilmeli mi?

Bugün: JSON dosyaları (`~/.claude/muya-ssh-config.json`, `muya-vault-config.json`,
`muya-workspace-roots.json`) + WebView localStorage (sekmeler, workspace'ler,
layout). Operatör geçen ay bir hatayı teşhis etmek için localStorage'ı elle
UTF-16 çözmek zorunda kalmıştı (`docs/handoff-2026-06-21.md`).

| Boyut | JSON dosya (mevcut) | localStorage (mevcut) | SQLite (önerilen kapsam) |
|---|---|---|---|
| Sorgulanabilirlik | Elle `cat \| jq` | Elle DevTools/hex-decode — kanıtlanmış acı noktası | `SELECT` ile anında |
| Atomiklik/bozulma direnci | `credstore.rs`'te zaten atomic_write var — iyi | Tarayıcı motoru garantisi, WAL yok | WAL modu ile tekli-yazar bile crash-safe |
| Rust + frontend eşzamanlı erişim | Rust tek yazar, sorun yok | Sadece frontend yazar, sorun yok | Tek yazarlı SQLite (WAL) sorunsuz; **çoklu process aynı anda yazarsa dikkat** |
| Migration | Yok (dosya şeması elle) | Yok | `sqlx::migrate!` veya elle `PRAGMA user_version` ile kolay |
| Yedekleme | Dosya kopyası | Yok — tarayıcı verisi, taşınmaz | Tek dosya kopyası, tutarlı |

**Somut öneri — kapsamı ikiye ayır:**
- **SQLite'a taşı:** Session geçmişi + transcript arama, terminal sekme/workspace
  layout (bugün localStorage'da, sorgulanamıyor, UTF-16 kabusu buradan çıktı).
  Bunlar büyüyen, aranan, yapılandırılmış veri — SQL'in güçlü olduğu yer.
- **Dosyada kalsın:** `muya-vault-config.json` (şifreli vault — ayrı, denetlenmiş
  şifreleme akışı var, dokunmaya değmez), `muya-ssh-config.json`,
  `muya-workspace-roots.json` — küçük, nadiren değişen, elle okunabilir config.
  SQLite'a taşımanın getirisi yok, riski var (migration bug'ı = vault kilitlenmesi).

**Crate önerisi:** `rusqlite` (senkron, basit, Tauri'nin zaten senkron/blocking-pool
komut modeliyle uyumlu) — `sqlx` async'tir ama Muya'nın Tauri komutları zaten
`tokio::task::spawn_blocking` ile çalışıyor (`fs.rs`), yani async SQL'in getirisi
yok, sadece karmaşıklık ekler. Her ikisi de 2026 itibarıyla aktif bakımda; rusqlite
daha az bağımlılık ve daha basit hata modeli sunuyor bu kullanım için.

**Verdict: Evet ama dar kapsamda — sadece session geçmişi/arama ve UI-layout state; vault/config JSON'da kalsın.**

Kaynaklar: [Rust DB Libraries 2026](https://medium.com/@tejaswini.nareshit/rust-database-libraries-in-2026-choosing-the-right-tool-without-overengineering-c3d66c534c3b), [sqlx GitHub](https://github.com/transact-rs/sqlx)

---

## 3. "Hepsini tek uygulama olarak sun" — MCP ayrı süreç olmaktan çıkabilir mi?

**Mevcut şekil:** Uygulama içi broker (`broker.rs`, UDS soket) + ayrı bir stdio
sidecar binary (`muya-ssh-mcp`, `src-tauri/src/bin/muya_ssh_mcp.rs`) — dış Claude
Code süreçleri bu ikinciyi spawn ediyor.

**Neden ayrı bir binary var:** MCP'nin stdio taşıması **protokol gereği** böyle
çalışır — istemci (Claude Code) sunucuyu bir alt-süreç olarak başlatır, ikisi
stdin/stdout üzerinden JSON-RPC konuşur, süreç istemciye bağlı yaşar/ölür
([MCP spec, stdio transport](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)).
Yani Claude Code, Muya GUI'sinin *kendisini* değil, spawn edebileceği bir process'i
bekliyor. Muya GUI'si arka planda kapalıyken bile Claude Code bir terminalden
`muya-mcp` çağırabilmeli — bu yüzden sidecar (`app_socket_path()`,
`src-tauri/src/bin/muya_ssh_mcp.rs:27`) sadece ince bir yönlendirici: hiçbir sır
taşımıyor, sadece UDS üzerinden çalışan asıl uygulamaya soruyor, uygulama kapalıysa
"Muya app not running" hatası dönüyor.

**Birleştirilebilir mi?** Hayır — bu MCP'nin mimari zorunluluğu, Muya'nın tasarım
hatası değil. Tek yapılabilecek: sidecar'ı küçük tutmaya devam etmek (bugün zaten
~50 satır, sır taşımıyor) ve "app kapalı" hata mesajını netleştirmek. Zaten öyle.

**Verdict: Sidecar, GUI kapalıyken bile MCP'nin çalışabilmesi için protokol gereği zorunlu; birleştirilemez, birleştirmeye de gerek yok.**

Kaynak: [MCP stdio transport spec](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)

---

## 4. VS Code benzeri UI

VS Code'un kabuğu (workbench) şu sabit bölgelerden oluşur: activity bar (sol
ince ikon şeridi), side bar (Explorer/Search/Git paneli), editor groups (grid
düzeninde sekmeli editör bölgeleri — `SerializableGrid` ile), panel (alt
terminal/output), status bar. Bu, `src/vs/workbench/browser/layout.ts` içinde
merkezi bir layout motoru + her bölge için ayrı modül olarak elle inşa edilmiş —
**hazır bir "VS Code shell" kütüphanesi yok**, VS Code kendi grid/splitview
motorunu yazmış.

Bunun **türetilmiş** açık kaynak hali var: **Dockview** (haftalık 116k indirme,
React/Vue/Angular desteği, "VS Code'un splitview/gridview kodundan esinlenilmiş")
— sekme, grup, grid, sürükle-bırak, yüzen panel hepsi hazır. Alternatif
Golden Layout daha eski, React ile senkronu zor (doğrudan DOM manipülasyonu
mirası).

Muya zaten Monaco + xterm kullanıyor — VS Code'un aynı temel yapı taşları. Bugünkü
React UI'yi Dockview üstüne taşımak; activity bar + side bar + editor-group grid'i
**mevcut bileşenleri (Terminal.tsx, FileEditor.tsx) yeniden kullanarak** yerleştirme
meselesi — sıfırdan yazım değil.

**Kaçınılması gereken:** VS Code'un kendi grid motorunu sıfırdan yazmak (aylar
sürer, Muya'nın 13k satırlık frontend'i için orantısız). Kopyalanmaya değer:
"tek merkezi layout state + region'lar arası net sözleşme" fikri — Muya'nın
bugünkü `App.tsx` büyüklüğü göz önüne alınca (tek dosyada çok state) bu prensip
işe yarar.

**Verdict: Hazır kütüphane var (Dockview) — sıfırdan VS Code klonlamak değil, mevcut Monaco/xterm bileşenlerini Dockview'a yerleştirmek gerçekçi bir orta-vadeli iş.**

Kaynaklar: [VS Code layout.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/layout.ts), [Dockview](https://github.com/mathuo/dockview), [Custom Layout docs](https://code.visualstudio.com/docs/configure/custom-layout)

---

## 5. Dürüst hüküm — full rewrite mi, kademeli mi?

**Son 4 hatanın kök nedeni mimari mi?**

| Hata | Kök neden | Mimari mi? |
|---|---|---|
| Yanlış boolean'a gate (`03cabe0`) | `isClaude` (anlık/volatile) ile `sessionId` (kalıcı) karıştırıldı — durable capability, volatile flag'e bağlanmış | **Hayır** — herhangi bir dilde/framework'te olur, klasik state-modelleme hatası |
| Dosya adı URI parse'ı kırdı (`1e8ebf7`) | `encodeURIComponent` çağrılmamış, Monaco'nun `Uri.parse` beklentisi bilinmiyordu | **Hayır** — kütüphane kontratı ihlali, framework'ten bağımsız |
| Binary resolver eski CLI'ı seçti (`a4e5700`, `382c0f0`, `cd8f3cf`) | Bare `Command::new("claude")`, GUI'nin minimal PATH'i hesaba katılmamış; sonra "var olma" test edildi, "yetenek" test edilmedi | **Hayır** — macOS GUI-process PATH davranışı evrensel, Electron'da da aynı sorun çıkardı |
| Eksik `.trim()` (`bb9d747`) | Arama input'unda whitespace normalize edilmemiş | **Hayır** — tek satırlık, framework'ten tamamen bağımsız |

**Dördü de mimari değil, disiplin/test-kapsamı hatası.** Full rewrite bunların
**hiçbirini** önlemezdi — aynı sınıf hatayı yeni bir framework'te de yazarsınız.
Nitekim `03cabe0`'nın kendi commit mesajı bunu doğruluyor: bu hatalar art arda
gelince operatör `muya-hotfix-verify` skill'ini (blast-radius grep + capability-test
disiplini) ekledi — yani **süreç düzeltmesi** işe yaradı, mimari değişikliği değil.
CHANGELOG'da son 30 sürümün 34 tanesi "Fixed" girdisi taşıyor — bu, aktif geliştirme
hızının yan etkisi, mimari çürümenin kanıtı değil.

**Full rewrite'ın maliyeti karşılığında getirisi yok:** Bölüm 1-4'te gösterildiği
gibi Tauri doğru seçim, MCP'nin sidecar'ı protokol zorunluluğu, DB eksikliği dar
kapsamlı bir ekleme ile çözülür, UI hazır kütüphaneyle kademeli taşınabilir.
Rewrite; 33k satırı, çalışan Keychain/Touch ID/PSMP entegrasyonunu, imzalama
akışını sıfırdan riske atar — hiçbir bulgu bunu haklı çıkarmıyor.

**Tavsiye: Full rewrite YOK. Hedefli refactor + sertleştirme.** (Bölüm 6-7'deki bulgularla birlikte aşağıda güncellendi.)

---

## 6. Canlı / parçalı güncelleme — "her değişiklikte tam restart olmasın"

Bugün frontend derlenip `dist/` klasörü **binary'nin içine gömülüyor**
(`src-tauri/tauri.conf.json:9` — `frontendDist: ../dist`) ve `script-src 'self'`
CSP'si (`tauri.conf.json:17`) sadece bu gömülü, imzalanmış kaynaktan JS
çalıştırılmasına izin veriyor. Bir CSS satırı bile yeni bir imzalı `.app` paketi
demek — bu davranış kazayla değil, **güvenlik sınırının kendisi**.

**Teknik olarak mümkün mü — frontend'i diskten sunmak?** Evet, Tauri'nin
`asset://` özel protokolü ve `assetProtocol.scope` ayarı bunu destekliyor — bir
dizini (`$APPDATA` dahil) webview'e açabilirsiniz. Ama bu özellik **kullanıcı
dosyalarını** (resim, PDF) güvenli göstermek için var; onu "app kabuğunun
kendisini" oradan yüklemek için kullanmak resmî/desteklenen bir kalıp **değil**,
kendi hack'inizi kurmak demek.

**Tauri updater bugün ne yapıyor:** Repo'daki `latest.json` + imzalı
`Muya-x.y.z-arm64.app.tar.gz` — bu **tam paket** güncellemesi, delta/kısmi
güncelleme **desteklenmiyor** ([resmi Tauri updater dokümanı](https://v2.tauri.app/plugin/updater/)).
Restart, updater'ın kendi akışında da opsiyonel zamanlanabilir ("hemen mi,
kullanıcı ne zaman isterse mi") ama **kurulum her zaman tam binary değişimi**.

**Rust tarafı değişince restart kaçınılmaz mı?** **Evet, kesin.** Rust kodu
(PTY, broker, credstore, vault) çalışan process'in belleğinde — recompile
edilmiş bir binary'yi process yeniden başlamadan çalıştıramazsınız. Frontend-only
(sadece CSS/TS) değişiklik için teorik olarak restart'sız yol var (webview'i
`location.reload()` ile yeni JS'i çekmesini sağlamak) ama bu tam olarak bir
sonraki paragrafın güvenlik sorununu açar.

**KRİTİK güvenlik sorusu:** İmzalı `.app` paketinin DIŞINDAN JS indirip
çalıştırmak, notarization'ın verdiği garantiyi fiilen devre dışı bırakır.
Apple'ın notarization'ı **paketi gönderdiğiniz an bir kere** tarar — paket
imzalı olarak kalır, Gatekeeper açılışta imzayı doğrular. Ama uygulama
kendi başına, imzalanmamış bir kaynaktan indirip çalıştırdığı JS'i **Apple hiç
görmedi, hiç taramadı**. Bu, Gatekeeper kuralını ihlal etmez (Electron'un
kendi auto-update'i veya bir tarayıcı eklentisi de teknik olarak aynı şeyi
yapabilir) — ama **notarization'ın var olma amacını** (App çalıştırıldığında
neyin çalıştığını Apple'ın önceden görmüş olması) boşa çıkarır. Muya için bu
soyut değil: bu uygulama AES-GCM+Keychain+Touch ID şifreli kasa ve prod
sunuculara SSH/PSMP erişimi tutuyor. İndirme kanalı (GitHub release, CDN, DNS)
ele geçirilirse veya depolama dizini bir başka process/malware tarafından
yazılırsa, çalıştırılan JS artık Apple'ın hiç taramadığı, sizin de anlık
doğrulayamadığınız koddur — vault'a ve SSH'a doğrudan erişimi olan bir yerde
bu **kabul edilebilir risk değil**.

**Riski almadan restart'ı azaltmanın yolu:** Frontend-only değişiklikler için
gerçek çözüm delta-JS indirmek değil, **release sıklığını/boyutunu küçültmek**
ve restart'ı hızlandırmaktır (state'i geri yükleyip kullanıcıyı olabildiğince
az kesintiye uğratmak) — bu zaten Bölüm 6'nın ikinci önerisiyle örtüşüyor.

**Daha ucuz orta yol — PTY'leri restart'tan bağımsızlaştırmak:** Bugün PTY'ler
uygulamayla birlikte ölüyor (`Terminal.tsx` unmount → `pty_kill`, bkz. lesson
L1). Bunu tmux benzeri bir modelle çözmek **gerçekçi** — ve Muya'da zaten
**aynı desenin bir örneği var**: `broker.rs`'teki UDS (Unix domain socket)
sunucu + `muya-ssh-mcp` sidecar'ının GUI'den ayrı yaşaması. Aynı kalıp PTY'lere
uygulanabilir: PTY'leri tutan küçük, uzun-ömürlü bir arka plan süreci (yeni bir
`muya-pty-daemon` binary'si), GUI restart olduğunda ona UDS üzerinden yeniden
bağlanır, açık scrollback'i tekrar oynatır. **Maliyet orta:** yeni bir process
lifecycle'ı (launchd/systemd benzeri "her zaman ayakta tut"), reattach
handshake'i, ve scrollback replay — haftalar mertebesinde, aylar değil, çünkü
UDS broker deseni zaten kanıtlanmış ve kodda mevcut.

**Verdict: Frontend'i imzalı paketin dışına taşımak notarization'ın güvenlik garantisini fiilen boşa çıkarır — vault+SSH erişimi olan bu uygulamada YAPILMAMALI; Rust-tarafı restart her zaman zorunlu, frontend-only için de aynı imzalı-paket sınırı korunmalı. Gerçek kazanç PTY'leri ayrı bir uzun-ömürlü süreçte tutup restart'ta yeniden bağlanmaktan gelir — mevcut broker/sidecar deseniyle haftalar mertebesinde yapılabilir bir iş.**

Kaynaklar: [Tauri v2 Updater](https://v2.tauri.app/plugin/updater/), [Tauri Asset Protocol Scope](https://v2.tauri.app/security/asset-protocol/), [Apple Gatekeeper docs](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web)

---

## 7. "Kendi terminal ekranımız" — xterm.js'ten vazgeçmeli mi?

**Bugünkü acıların sebebi neydi — kanıt:** `tasks/lessons.md` L1 ve L3, geçmiş iki
gerçek terminal hatasını belgeliyor: (L1) view değişince PTY unmount edilip
`pty_kill` tetiklenmesi, (L3) gizli sekmede resize kaçması + show'da focus
gelmemesi. **İkisi de xterm.js'in kendi kusuru değil** — Muya'nın onu React
lifecycle'ına yanlış bağlamasıydı (conditional unmount, `active` prop'suz
resize/focus mantığı). Kanıt: her ikisi de 2026-06-21'de **xterm.js'i
değiştirmeden**, sadece `active` prop + `requestAnimationFrame` içinde
re-fit/`pty_resize`/`term.focus()` çağrısıyla çözüldü — bugünkü
`src/components/Terminal.tsx:37-62` (`active` prop) ve arama-odaklama deseni
(satır 108-126, `requestAnimationFrame(() => searchInputRef.current?.focus())`)
bunun hâlâ o düzeltilmiş kalıpla çalıştığını gösteriyor. **Sonuç: geçmiş acı
xterm.js'in sınırı değildi, bizim onu kullanma şeklimizdi — ve zaten düzeltildi.**

**xterm.js'i değiştirmek ne kazandırır/kaybettirir?** xterm.js zaten kendi
**GPU-hızlandırmalı renderer eklentisini** (`@xterm/addon-webgl` — Muya bunu
kullanıyor, `package.json`) destekliyor; "GPU'ya geçmek" zaten yapılmış.
Alternatifler: **Zed** kendi editöründen itibaren sıfırdan yazılmış bir GPU
render pipeline'ı üzerine kurulu (terminal de dahil tüm UI aynı motor) —
bu Zed'in **tüm uygulamasının** mimari temeli, tek bir terminal bileşeni
değil. **Warp** da benzer şekilde Rust + özel GPU render + "blocks" UI'sini
uygulamanın merkezine koymuş. İkisi de **"terminal bizim ürünümüzün kalbi"**
diyen ürünler — Muya'da terminal, editör ve dosya ağacının yanında **bir**
bileşen. Muya'nın ölçeğinde (5-10 paralel PTY, VS Code'un da kullandığı
xterm.js) kendi GPU render motoru yazmak, kazanç/maliyet oranı çok kötü bir
yatırım.

**Kendi terminal emülatörü yazmanın gerçek maliyeti:** xterm.js **546 kontrol
dizisi** (VT100/ANSI escape sequence — terminalin "şu rengi kullan", "imleci
şuraya taşı" gibi komutları) uyguluyor; temel bir VT102 uyumluluğu bile ~68
dizi gerektiriyor. Buna ek olarak: kaydırma tamponu (scrollback), metin seçimi,
fare-takip modları (vim/htop gibi TUI programları için — Muya'nın kendi
`mouseTrackingActive` mantığı bunu zaten yönetiyor, `Terminal.tsx:149`),
ligatür/geniş-karakter/emoji render, IME (Asya dilleri için giriş yöntemi)
desteği. Bunların hiçbiri "birkaç hafta" işi değil — xterm.js 10+ yıllık,
onlarca katkıcılı bir proje ve hâlâ köşe-durum hataları çıkıyor. Muya'nın
33k satırlık kod tabanına bunu eklemek, **VS Code'un kendisinin bile
yapmadığı** bir şey (VS Code da xterm.js kullanıyor).

**Verdict: xterm.js değiştirilmemeli — geçmiş resize/focus acıları kütüphanenin değil bizim entegrasyonumuzun hatasıydı ve zaten kalıcı şekilde düzeltildi (L1/L3); kendi terminal emülatörü yazmak, VS Code'un bile üstlenmediği 546-dizi'lik bir mühendislik yükü karşılığında hiçbir somut kazanç getirmez.**

Kaynaklar: [xterm.js GitHub](https://github.com/xtermjs/xterm.js), [Zed terminal docs](https://zed.dev/docs/terminal), `tasks/lessons.md` L1/L3, `src/components/Terminal.tsx`

---

## Öneri — Sıralı Plan (§1-7 birlikte)

1. **Hemen (0-2 hafta):** `muya-hotfix-verify` disiplinini (capability-test, blast-radius grep) her PR'da zorunlu kıl — zaten var, uygulamayı sıkılaştır. Bedelsiz, en yüksek getiri.
2. **Kısa vade (2-6 hafta):** SQLite'ı dar kapsamda ekle — sadece session geçmişi/arama + UI-layout (Bölüm 2). `rusqlite` + tek migration dosyası. Vault/config JSON'a dokunma.
3. **Kısa-orta vade (4-8 hafta):** PTY'leri GUI restart'ından bağımsızlaştıran bir arka plan süreci (Bölüm 6) — mevcut broker/sidecar UDS deseninin doğal uzantısı, restart acısını gerçekten azaltan tek güvenli yol.
4. **Orta vade (2-3 ay):** `App.tsx`'i küçült, UI'yi Dockview üstüne kademeli taşı — önce panel (terminal alanı), sonra editor-group grid'i. Monaco/xterm bileşenlerini olduğu gibi taşı, yeniden yazma.
5. **Dokunma / önerilmez:** Tauri çekirdeği, broker/sidecar MCP mimarisi, Keychain/Touch ID vault akışı, xterm.js, imzalı-paket-dışı JS yükleme — bunların hepsi ya kanıtla doğru ya da güvenlik riskini artırıyor; rewrite/değiştirme listesine girmesin.

# Muya UI Redesign — Birebir Uygulama (Light + Dark)

## Görev

Muya'nın (Tauri v2 + React) arayüzünü `docs/design/redesign-v0.4/` altındaki iki referans tasarıma **birebir** uyacak şekilde yeniden yaz:

- `control.reference.html` → **Control** ekranı (tek agent odaklı)
- `grid.reference.html` → **Grid** ekranı (2×2 paralel izleme)

Referanslar yalnızca **dark** modda çizildi. **Light** modu aşağıdaki token tablosundan üret. İki tema da aynı layout'u, aynı ölçüleri ve aynı bileşenleri kullanır. Temalar arasında yalnızca renkler değişir.

"Birebir" şu anlama gelir: 1440×900 pencerede ölçüler, boşluklar, font boyutları, köşe yarıçapları, sıralama ve metinler referansla piksel düzeyinde aynı olacak. Kendi yorumunu katma, "iyileştirme" yapma, eleman ekleme veya çıkarma. Tek istisna aşağıdaki §6'da tanımlanan tema düğmesi.

## 0. Çalışma kuralları

1. Kod yazmadan önce referans HTML dosyalarının ikisini de baştan sona oku. Sonra mevcut frontend yapısını incele: routing, layout, terminal bileşeni ve state (agent/session verisinin nereden geldiği). Ardından bir plan yaz: hangi bileşenler, hangi dosyalar, hangi sırayla. **Planı onayıma sun, onay gelmeden başlama.**
2. Ayrı bir branch'te çalış: `feat/ui-redesign-v0.4`.
3. Backend'e dokunma: `src-tauri/`, `pty.rs`, `agents.rs` ve IPC komutları aynı kalacak. UI mevcut Tauri komutlarını ve event'lerini kullanır. Bir veri gerçekten yoksa (örneğin agent'ın "izin bekliyor" durumu) uydurma. `tasks/todo.md` dosyasına ekle ve bana bildir.
4. Referanslardaki köşeli parantezli değerler (`[süre]`, `[dosya yolu]`, `[terminal çıktısı]` vb.) ve örnek agent durumları sahte veridir. Bunların yerine gerçek veriyi bağla.
5. Mevcut testler geçmeye devam etmeli. Yeni bileşenler için en az render/snapshot testi yaz.

## 1. Tema altyapısı (önce bunu yap)

- Tek bir `tokens.css` dosyası oluştur. `:root[data-theme="dark"]` ve `:root[data-theme="light"]` altında aynı CSS değişkenleri tanımlanacak.
- **Bileşenlerde hiçbir hex rengi hardcode edilmeyecek.** Her renk bir `var(--…)` üzerinden gelecek. İş bitince `grep -rE '#[0-9a-fA-F]{3,8}' src/` komutu, `tokens.css` ve xterm tema dosyası dışında sonuç döndürmemeli.
- Tema tercihi üç değer alır: `system | light | dark`. Varsayılan `system` olur ve `prefers-color-scheme` değişikliğini canlı olarak dinler. Seçim kalıcı olarak saklanır (mevcut settings mekanizmasını kullan). İlk boyamada tema yanıp sönmemeli: `data-theme` değeri render'dan önce set edilmeli.
- Fontlar: **IBM Plex Sans** (400/500/600) ve **JetBrains Mono** (400/500/700). Uygulama offline çalışıyor, bu yüzden Google Fonts linkini kullanma. `@fontsource/ibm-plex-sans` ve `@fontsource/jetbrains-mono` ile fontları bundle et.

### 1.1 Token tablosu

Referans dosyalardaki her hex değeri aşağıdaki token'lardan birine karşılık gelir. Uygularken referanstaki hex'i bu tablodan bulup ilgili `var(--token)` ile değiştir.

| Token | Dark (referans hex) | Light | Kullanım |
|---|---|---|---|
| `--bg-app` | `#0F1115` | `#F4F5F7` | Uygulama zemini, main alanı |
| `--bg-chrome` | `#13161B` | `#FFFFFF` | Header, rail, footer, composer alanı |
| `--bg-panel` | `#14171C` | `#F9FAFB` | Agent listesi ve inspector panelleri, grid panel başlığı |
| `--bg-terminal` | `#0B0D11` | `#FFFFFF` | Terminal ve grid panel gövdesi |
| `--bg-input` | `#171A20` | `#FFFFFF` | Arama, composer kutusu |
| `--bg-control` | `#1A1E25` | `#FFFFFF` | İkincil butonlar, kullanıcı mesaj vurgusu |
| `--bg-segment` | `#1B1F27` | `#EEF0F3` | Segment kontrol zemini |
| `--bg-segment-active` | `#2A303C` | `#FFFFFF` | Aktif segment (light'ta ek `box-shadow: 0 1px 2px rgba(16,24,40,.08)`) |
| `--bg-rail-active` | `#232936` | `#E8ECF4` | Rail'de aktif öğe |
| `--bg-table-head` | `#161920` | `#F4F5F7` | Terminal tablo başlığı |
| `--bg-selected` | `#1C2436` | `#EAF0FD` | Seçili agent kartı |
| `--bg-selected-head` | `#161B26` | `#F1F5FE` | Grid'de odaktaki panel başlığı |
| `--border` | `#262B35` | `#E3E6EB` | Panel ayırıcıları |
| `--border-control` | `#2A2F3A` | `#D5DAE1` | Buton ve input kenarları |
| `--border-strong` | `#333946` | `#C5CBD4` | Composer, kbd kenarı |
| `--border-subtle` | `#1E232C` | `#ECEEF1` | Terminal alt progress çizgisi |
| `--border-selected` | `#3B5B9A` | `#9DB5EE` | Seçili kart / odak panel |
| `--text` | `#E6E8EC` | `#1A1D23` | Ana metin |
| `--text-strong` | `#FFFFFF` | `#0B0D11` | Başlık, aktif sekme, vurgu |
| `--text-secondary` | `#C9D1DC` | `#3D4452` | Kart aktivite satırı |
| `--text-tertiary` | `#B4BCC8` | `#4A5261` | Pasif segment, kbd, chip metni |
| `--text-muted` | `#9AA3B2` | `#5E6675` | Yol, meta, etiket |
| `--text-faint` | `#7C8595` | `#8A93A3` | Boşta nokta çerçevesi, ayraç `/` |
| `--text-terminal` | `#D4D9E1` | `#2A2F38` | Terminal gövde metni |
| `--accent` | `#8FB3FF` | `#2F5BD3` | Link, dosya adı vurgusu, focus ring |
| `--accent-hover` | `#B8CEFF` | `#1E45B0` | Link hover |
| `--primary-bg` | `#E6E8EC` | `#1A1D23` | Birincil buton (Yeni agent, Gönder), logo kutusu |
| `--primary-fg` | `#0F1115` | `#FFFFFF` | Birincil buton metni |
| `--success` | `#4FD1A5` | `#1E9E72` | Çalışıyor noktası, onay ikonu |
| `--success-text` | `#7BE3BF` | `#127A56` | Çalışıyor metni, "301 test geçiyor" |
| `--success-bg` | `#15322A` | `#E3F5EE` | Çalışıyor pill zemini |
| `--success-card-bg` | `#172420` | `#EEF8F3` | Çakışma yok kartı |
| `--success-card-border` | `#24463B` | `#BDE3D1` | 〃 |
| `--success-card-text` | `#CFF5E7` | `#0E5E43` | 〃 başlık |
| `--warning` | `#F2B34B` | `#D9921A` | Bekliyor noktası, bildirim rozeti, bekleyen panel kenarı |
| `--warning-label` | `#F2B34B` | `#9A6400` | "SENİ BEKLİYOR", "ONAY BEKLİYOR" başlıkları ve bekliyor metinleri |
| `--warning-btn-bg` | `#F2B34B` | `#E9A23B` | "İzin ver" butonu |
| `--warning-btn-fg` | `#1A1206` | `#1A1206` | 〃 metni |
| `--warning-bg` | `#251F13` | `#FFF6E6` | Bekleyen agent kartı |
| `--warning-card-bg` | `#211B10` | `#FFF8EA` | Onay kartı, grid bekleyen panel başlığı |
| `--warning-border` | `#5C4A22` | `#EBCB8B` | 〃 kenarları, Reddet butonu kenarı |
| `--warning-text` | `#E9D6AE` | `#6E4A05` | Onay kartı içi metinler |
| `--warning-code-bg` | `#17130B` | `#FBEFD6` | Onay kartındaki kod satırı |
| `--danger-text` | `#FFA8A0` | `#B42318` | Bypass rozeti, Durdur, Kritik |
| `--danger-pill-bg` | `#3A1D1D` | `#FDECEA` | Bypass pill zemini |
| `--danger-btn-bg` | `#2A1716` | `#FEF3F2` | Durdur butonu, mod chip'i |
| `--danger-border` | `#6B2E2A` | `#F3B8B2` | 〃 kenar |
| `--danger-kbd` | `#D98B84` | `#C4453B` | Durdur içindeki `esc` |

Kontrast kuralı: light temada metin/zemin çiftleri en az 4.5:1 olmalı. Uygulamayı bitirdikten sonra her metin token'ını kendi zeminine karşı hesapla ve sonucu tablo olarak raporla. 4.5:1'in altında kalan bir çift çıkarsa light değerini koyulaştır ve bana bildir.

Ek kural (light): segment aktif ve beyaz kartlar zeminden ayrılmazsa yalnızca `--border` ve belirtilen gölgeyi kullan. Başka gölge ekleme.

### 1.2 Terminal (xterm) teması

Terminal içeriği gerçek PTY çıktısıdır. Referanstaki renkli tablo, ANSI renklerinin nasıl görüneceğini gösteren bir örnek. Terminal içeriğini HTML ile yeniden çizmeye çalışma. Değişecek olanlar yalnızca xterm `theme` nesnesi, font ve padding:

- Font: `JetBrains Mono`, `fontSize: 13`, `lineHeight: 1.6`. Terminal kabının padding'i `20px 28px`.
- Tema değiştiğinde xterm teması da canlı olarak güncellenir (`terminal.options.theme = …`).

| Alan | Dark | Light |
|---|---|---|
| background | `#0B0D11` | `#FFFFFF` |
| foreground | `#D4D9E1` | `#2A2F38` |
| cursor | `#E6E8EC` | `#1A1D23` |
| selectionBackground | `#2A3A5C` | `#CFDDFB` |
| black / brightBlack | `#1A1E25` / `#7C8595` | `#2A2F38` / `#5E6675` |
| red / brightRed | `#F07167` / `#FFA8A0` | `#C4302B` / `#B42318` |
| green / brightGreen | `#4FD1A5` / `#7BE3BF` | `#127A56` / `#1E9E72` |
| yellow / brightYellow | `#F2B34B` / `#F7CC7F` | `#8A5A00` / `#9A6400` |
| blue / brightBlue | `#8FB3FF` / `#B8CEFF` | `#2F5BD3` / `#1E45B0` |
| magenta / brightMagenta | `#C9A0FF` / `#DCC2FF` | `#7A3FC4` / `#6330A8` |
| cyan / brightCyan | `#6FD6E8` / `#A3E6F2` | `#0F7C8C` / `#0B6573` |
| white / brightWhite | `#D4D9E1` / `#FFFFFF` | `#4A5261` / `#0B0D11` |

## 2. Uygulama iskeleti (her iki ekran)

Pencere `flex-direction: column`:

1. **Header**: 48px yükseklik, `--bg-chrome`, alt kenar `1px --border`, padding `0 16px 0 88px` (sol 88px macOS trafik ışıkları için ayrılıyor; Tauri'de `titleBarStyle: Overlay` / `hiddenTitle` ile başlık çubuğunu bu header'a dönüştür, header'ı `data-tauri-drag-region` yap, butonlar drag dışı kalsın).
2. **Gövde**: `flex: 1`, yatay flex.
3. **Footer / durum çubuğu**: 28px, `--bg-chrome`, üst kenar `1px --border`, 12px `--text-muted`, gap 18px.

**Sol rail** (her iki ekranda): 64px, `--bg-chrome`, sağ kenar `--border`, padding `12px 0`, gap 6px. Öğeler 48×48, radius 10, ikon 18px + 10px etiket (gap 3px). Sıra: Control, Queue, Kanban, Kaynak (Resources), SSH, Chat, boşluk, Ayarlar (yalnızca ikon). Aktif öğe `--bg-rail-active` + `--text-strong`, diğerleri transparan + `--text-muted`. İkonlar referanstaki inline SVG path'leri ile aynı olacak (stroke 1.8, round cap/join). Mevcut projede lucide-react varsa aynı ikonları kullanabilirsin: `SquareTerminal`, `List`, `Kanban`-benzeri sütun ikonu, `Activity`, `Server`, `MessageSquare`, `Settings`. Görsel sonuç birebir aynı olmalı.

Mevcut üst sekme çubuğu (Control/Sessions/Queue/Resources/Kanban/SSH/Chat) **kaldırılacak**. Sessions sayfası Control'e katılıyor; route kalabilir ama rail'de görünmez.

## 3. Control ekranı — `control.reference.html`

Gövde soldan sağa: Rail 64 · Agent listesi 296 · Main (flex 1) · Inspector 320.

**Header içeriği** (gap 16): logo (26×26 radius 7 `--primary-bg`, "M" 14px/700) + "Muya" 15px/600 · Workspace butonu (32px yükseklik, radius 8, "Workspace" muted + ad 500 + "· 3" muted + chevron) · ortada 440px arama/komut paleti butonu ("Agent, dosya veya komut ara…" + `⌘K` kbd) · CPU/RAM/saat (mono 12px) · Bildirim butonu 32×32 (bekleyen varsa sağ üstte 8px `--warning` nokta).
- `⌘K` gerçek bir komut paleti açmalı: agent'lar, dosyalar ve komutlar arasında arama yapılabilmeli. Mevcut bir palet yoksa basit bir cmdk sürümü yaz.

**Agent listesi**: `--bg-panel`, sağ kenar.
- Başlık satırı (padding `16px 16px 10px`): "Agentlar" 14/600 + sayı muted, "+ Yeni agent" birincil buton (30px, radius 7, 12px/600).
- Segment (margin `0 16px 12px`, padding 3, radius 8): Tümü / Bekleyen N / Çalışan N. Filtreler gerçekten çalışmalı.
- Gruplar sırasıyla: **SENİ BEKLİYOR** (`--warning-label`), **ÇALIŞIYOR** (`--success`), **BOŞTA** (`--text-muted`). Grup başlıkları 11px/600, letter-spacing .06em. Boş grup gösterilmez.
- Bekleyen/çalışan kart: padding `10px 12px`, radius 10, 3 satır (nokta 8px + ad 13/600 + sağda süre 11px · aktivite 12px · yol mono 11px muted). Bekleyen kart `--warning-bg` + `--warning-border`. Seçili kart `--bg-selected` + `--border-selected` + `aria-current`.
- Boşta satırı tek satır (padding `8px 12px`, radius 8): içi boş 8px halka (`1.5px --text-faint`) + ad 13px + sağda mono 11px yol.
- Alt bar: "Sürükle-bırak ile sırala" / `⌘1–7`. Sıralama ve kısayollar çalışmalı.
- Kart tıklanınca main alanda o agent açılır.

**Main**:
- Oturum başlığı (padding `12px 20px`, alt kenar): ad (h1 17/600) + durum pill'i (22px, radius 11: Çalışıyor = `--success-bg`/`--success-text`, Bekliyor = `--warning-card-bg`/`--warning-label`, Boşta = `--bg-segment`/`--text-muted`) + **bypass permissions açıksa** kırmızı "Bypass permissions açık" pill'i (uyarı ikonu 12px). Altında mono 12px `yol · branch`. Sağda Compact, "Grid'e böl", Durdur (danger, `esc` kbd), "…" butonları (32px, radius 8). Durdur = interrupt (esc ile aynı); Compact = `/compact` gönderir.
- Terminal: `--bg-terminal`, §1.2.
- Progress şeridi (padding `8px 28px`, üst `--border-subtle`, 12px): durum + mono süre/token/düşünme. Sağda güncelleme hazırsa "Güncelleme hazır" + "Yeniden başlat" butonu. Veriyi Claude Code'un status çıktısından parse edebiliyorsan bağla; edemiyorsan yalnızca süreyi göster ve bunu `todo.md`'ye yaz.
- Composer (dış padding `14px 20px 16px`, `--bg-chrome`): kutu radius 12, `--border-strong`, `--bg-input`, padding `10px 12px`. Textarea 14px, 2 satır. Chip'ler 26px radius 13: Mod (bypass iken danger stili; tıklayınca default/acceptEdits/plan/bypass seçimi; shift+tab ile aynı döngü), "@ Dosya ekle", "/ Komutlar". Sağda "⏎ gönder · ⇧⏎ satır" ve 32×32 gönder butonu. Enter PTY'ye yazar.

**Inspector**:
- Onay bekleyen herhangi bir agent varsa en üstte **ONAY BEKLİYOR** bölümü (padding 16, alt kenar). Kart: `--warning-card-bg` + `--warning-border`, radius 10, padding 12. İçerik: "**ad** dosya yazmak istiyor", mono kod satırı (`--warning-code-bg`), butonlar İzin ver / Reddet / Aç (32px). Butonlar ilgili PTY'ye onay/ret tuşunu gönderir. "Aç" o agent'a geçer. Birden fazla bekleyen varsa kartlar alt alta dizilir.
- Sekmeler (40px, gap 18, aktifte 2px alt çizgi `--text`): Değişiklikler N / Dosyalar / Aktivite.
  - Değişiklikler: mono 12px satırlar (git durum harfi M = `--warning`, A = `--success`, D = `--danger-text`) + "+ N dosya daha" + "Diff'i incele" / "Commit…" butonları. Veri: aktif worktree'nin `git status` çıktısı.
  - Dosyalar: mevcut dosya ağacı bileşeni buraya taşınır.
  - Aktivite: mevcut edit/lock telemetrisi.
- En altta çakışma kartı: çakışma yoksa success stili ("Dosya çakışması yok" / "N worktree izleniyor · N değişiklik"). Çakışma varsa aynı kart danger token'larıyla ve çakışan dosyaların listesiyle gösterilir.

**Footer**: yeşil nokta + Hazır · N workspace · "N agent · N çalışıyor · N bekliyor" (success/warning renkli) · N çakışma · boşluk · UTF-8 · Muya vX. Tüm sayılar aynı state kaynağından gelmeli; eski "Sessions: 4 / 7 terminal" tutarsızlığı kalmamalı.

## 4. Grid ekranı — `grid.reference.html`

- Header: logo + "/ Grid" + "N panel" · sağda düzen segmenti (1 / 1×2 / 2×2 / 3×2) · "Bekleyenleri öne al" · "Hepsine yayınla…" (tüm seçili agent'lara aynı mesajı gönderir; göndermeden önce onay modalı gösterir).
- Rail aynı. Grid alanı: padding 16, gap 12, `grid-template-columns: repeat(2, minmax(0,1fr))` (seçili düzene göre değişir).
- Panel: radius 12, `--bg-terminal`, overflow hidden. Başlık (padding `10px 14px`, alt kenar): nokta + ad 14/600 + durum 12px + (bypass ise küçük danger chip) + sağda token/yol veya büyüt butonu.
  - Bekleyen panel: kenar `2px --warning`, başlık `--warning-card-bg`. Altta onay çubuğu: İzin ver (Y), Reddet (N), "Bu oturumda hep izin ver" (34px). Panel odaktayken Y/N kısayolları çalışır.
  - Odaktaki panel: kenar `--border-selected`, başlık `--bg-selected-head`.
  - Diğer paneller: kenar `--border`, başlık `--bg-panel`.
  - Boşta panel: ortalanmış "Görev bekliyor" + "Queue'dan görev ata" / "Paneli değiştir".
  - Her panelin altında tek satırlık composer bulunur (34px, radius 8).
- Panel içerikleri gerçek xterm örnekleridir. Aynı PTY'ye bağlanır, yeni PTY açmaz.
- "Bekleyenleri öne al" bekleyen agent'ları grid'in başına taşır. Footer'da "Tab ile paneller arası · ⌘⏎ büyüt" yazar ve bu kısayollar çalışır.

## 5. Etkileşim ve erişilebilirlik

- Tüm tıklanabilir öğeler gerçek `<button>` veya `<a>` olmalı. İkon butonlarında `aria-label` bulunmalı. Sekme/segment yapıları `role="tablist"`/`tab` kullanmalı.
- Focus ring: `2px solid var(--accent)`, offset 2px (`:focus-visible`).
- Hover durumları: ikincil butonlar `--bg-segment`, rail öğesi `--bg-segment`, boşta satırı `--bg-segment`. Geçişler 120ms. Başka animasyon ekleme.
- Minimum pencere boyutu 1280×800. Bu boyutta inspector 280px'e, agent listesi 264px'e iner. Daha küçük boyutlarda inspector toggle ile gizlenir. 1440×900'de ölçüler birebir referanstaki gibi kalır.

## 6. Tek ek: tema düğmesi

Header'da bildirim butonunun **soluna** aynı stilde (32×32, radius 8, `--border-control`, `--bg-control`) bir tema butonu ekle. Tıklandıkça system → light → dark sırasıyla döner. İkonlar: monitor / sun / moon (18px değil 16px, stroke 1.8). Ayarlar sayfasına da aynı seçim için bir radio grubu ekle. Referansta olmayan tek eleman budur.

## 7. Doğrulama (bitirmeden önce zorunlu)

1. Referans HTML'leri 1440×900 viewport'ta Playwright ile render et. Uygulamanın web build'ini de aynı boyutta, aynı temsili veriyle (mock store: 7 agent, 1 bekleyen, 2 çalışan, 4 boşta) render et. Dark modda her iki ekran için referansla piksel diff al (`pixelmatch`, threshold 0.1). Terminal içeriği farklı olacağı için terminal gövdesini maskele. Kalan fark %1'i geçmemeli. Diff görsellerini `docs/design/redesign-v0.4/diff/` altına kaydet.
2. Light mod için referans yok. Light ekran görüntülerini `docs/design/redesign-v0.4/light/` altına kaydet ve §1.1 kontrast raporunu ekle.
3. `grep` hex kontrolü (§1) temiz olmalı.
4. `cargo test` ve frontend testleri geçmeli.
5. Sonunda bana şunları raporla: değişen dosyalar, bağlayamadığın veriler (`todo.md`'ye yazdıkların), diff yüzdeleri ve kontrast tablosu. Commit'le, PR açma. PR'ı ben açacağım.

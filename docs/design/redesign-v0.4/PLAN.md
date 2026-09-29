# Muya UI Redesign v0.4 — Uygulama Planı

Kaynak: `PROMPT.md`, `control.reference.html`, `grid.reference.html` (bu klasör).
Branch: `feat/ui-redesign-v0.4` (main'den). PR açılmaz; commit'lenir.

## Mevcut durum (ölçüldü)

| Konu | Bulgu |
|---|---|
| Yapı | `src/App.tsx` 2944 satır; tüm layout + state burada. Sayfa geçişi `view` state'i (`control/sessions/tools/queue/prd/ssh/chat`), sayfalar `hidden` ile mount'lu kalıyor (L1). |
| Renk | `src/` altında **195 sabit hex** (23 dosya) + **1094 `dark:`** Tailwind sınıfı. Tema `.dark` sınıfıyla (`apex.theme` localStorage, `system/light/dark` zaten var). |
| Font | `index.css` Google Fonts `@import` ediyor — ama Tauri CSP'si `font-src 'self' data:` olduğu için **uygulamada zaten yüklenmiyor**; sistem fontuna düşüyor. fontsource bunu düzeltir. |
| Pencere | `tauri.conf.json` standart başlık çubuğu (Overlay yok). |
| Agent durumu | `pty_session_ids` → her sekme için `working / waiting-for-input / idle / stopped` + `waitingFor` ("permission prompt"). `claude agents --json`: `name, cwd, pid, startedAt, status`. |
| Yok (backend'de) | Token sayısı, "Unfurling…" aktivite satırı, izin isteğinin araç adı + dosya yolu, çalışma modu (bypass/plan/acceptEdits). |
| Var ama başka yerde | `git_status(root)`, `pm_collisions`, CPU/RAM, güncelleme kontrolü, dosya ağacı, edit/lock telemetrisi. |
| Grid | `viewMode: "grid"` en fazla 4 terminal; aynı `AgentTerminal` örnekleri CSS grid ile yerleştiriliyor (yeni PTY yok). |

## Eksik veriler — nasıl bağlanacak

Backend'e dokunulmadığı için bu bilgiler **terminal ekranından okunacak** (xterm buffer'ı zaten
frontend'de; kullanıcının gördüğü metnin aynısı — uydurma değil):

| Veri | Kaynak | Güvenilirlik |
|---|---|---|
| Durum (çalışıyor/bekliyor/boşta) | `pty_session_ids` | Kesin |
| Bekleme süresi ("1 dk") | Durumun `waiting`e geçtiği an (frontend'de kaydedilir) | Kesin |
| Çalışma süresi, token, düşünme | Claude'un spinner satırı (`✻ Unfurling… (4m 15s · ↓ 16.9k tokens · thought for 3s)`) | Ekran-parse; format değişirse düşer → yalnız süre |
| İzin isteği aracı + hedef | Claude'un izin kutusu metni | Ekran-parse; bulunamazsa `waitingFor` metni |
| Mod (bypass/plan/accept) | Claude alt satırı ("bypass permissions on" vb.) + başlatma bayrağı | Ekran-parse |
| İzin ver / Reddet / Hep izin ver | PTY'ye `1` / `3`(Esc) / `2` — gerçek izin kutusunda doğrulanacak | Canlı test gerek |

Parse edilemeyenler `tasks/todo.md`'ye yazılır. Parser gerçek Claude ekran örnekleriyle birim-testlenir.

## Fazlar (her faz ayrı commit)

**F0 — Hazırlık**
- Branch; paketler: `@fontsource/ibm-plex-sans`, `@fontsource/jetbrains-mono`, `cmdk`,
  dev: `@playwright/test`, `pixelmatch`, `pngjs`.
- Web build için **mock IPC** (`@tauri-apps/api/mocks` → `mockIPC`), `?mock=1` ile açılır:
  7 agent / 1 bekleyen / 2 çalışan / 4 boşta — referanstaki metinlerin aynısı. Sadece tarayıcı
  doğrulaması için; Tauri build'ine girmez.

**F1 — Tema altyapısı**
- `src/styles/tokens.css`: §1.1'deki 48 token, `:root[data-theme=dark|light]`.
- `index.html`'e render öncesi küçük script: kayıtlı tercihi + `prefers-color-scheme`'i okuyup
  `data-theme`'i set eder → ilk boyamada yanıp sönme yok.
- `useTheme()`: `system|light|dark`, sistem değişikliğini canlı dinler, mevcut `apex.theme`
  anahtarında saklar (geriye uyumlu). `.dark` sınıfı da senkron tutulur — Queue/Kanban/SSH/Chat/
  Kaynak/Ayarlar sayfalarının `dark:` sınıfları çalışmaya devam etsin.
- `src/theme/terminalThemes.ts`: §1.2 xterm temaları; tema değişince `term.options.theme` canlı.
- **195 hex'in tamamı** token'a taşınır (tüm sayfalar, `index.css` markdown stilleri dahil).
  Diğer sayfaların yerleşimi değişmez, yalnız renk kaynağı değişir.
- Fontlar fontsource ile bundle; Google Fonts `@import` kaldırılır.

**F2 — İskelet**
- `AppShell`: Header 48 · gövde · Footer 28. `Rail` 64 (7 öğe, referans SVG path'leri).
- Üst sekme çubuğu kaldırılır. Sessions rail'de görünmez (⌘K'dan açılır).
- Başlık çubuğu: `titleBarStyle: Overlay` + `hiddenTitle`, header `data-tauri-drag-region`.

**F3 — Agent modeli (tek kaynak)**
- `useAgentModel()`: sekmeler + oturum durumu + ekran-parse → her agent için
  `{status, since, activity, tokens, mode, pendingApproval, cwd, branch}`.
  Agent listesi, header, inspector, grid ve **footer sayıları** hepsi buradan okur
  (eski "Sessions: 4 / 7 terminal" tutarsızlığı biter).
- `screenState.ts` parser + testler.

**F4 — Control ekranı**
- `AgentList` (gruplar, segment filtreleri, sürükle-bırak sıralama, ⌘1–7), `SessionHeader`
  (pill'ler, Compact=`/compact`, Grid'e böl, Durdur=Esc, …), terminal (padding 20/28, 13px/1.6),
  `ProgressStrip` (+ güncelleme hazır), `Composer` (mod chip'i = Shift+Tab döngüsü, @, /,
  Enter→PTY), `Inspector` (Onay bekliyor kartları, Değişiklikler=`git_status`, Dosyalar=mevcut
  ağaç, Aktivite=mevcut telemetri, çakışma kartı=`pm_collisions`).

**F5 — Grid ekranı**
- Düzen segmenti 1 / 1×2 / 2×2 / 3×2, "Bekleyenleri öne al", "Hepsine yayınla…" (onay modalı).
- Paneller aynı xterm örneklerini kullanır: terminal DOM'u Control ↔ Grid arasında **taşınır**,
  yeniden oluşturulmaz (PTY asla ikinci kez açılmaz, L1).
- Bekleyen panelde Y/N/hep-izin çubuğu; Tab ile panel gezinme; ⌘⏎ büyüt.

**F6 — ⌘K paleti, tema düğmesi, Ayarlar'da radio grubu, 1280×800 daralma, focus/hover kuralları.**

**F7 — Doğrulama**
- Playwright 1440×900: referans HTML'ler (Google Fonts isteği yerel fontsource'a yönlendirilir —
  aynı glif) vs `?mock=1` web build. Terminal gövdesi maskelenir. `pixelmatch` threshold 0.1,
  hedef ≤%1. Diff'ler `diff/`, light görüntüler `light/`.
- Kontrast raporu (her metin token'ı kendi zeminine karşı, WCAG formülü) — script ile.
- `grep` hex kontrolü, `cargo test`, `vitest`.
- Ek: gerçek uygulamada canlı kontrol (izin kutusu tuşları, tema geçişi, grid taşıma) — ekran
  açıkken cua-driver ile.

## Referanslarda fark ettiklerim

- Grid referansının rail'inde **Ayarlar butonu yok**, footer'da **UTF-8 yok**; prompt "Rail aynı"
  diyor. İki ekranda rail'i aynı (Ayarlar'lı) yapıyorum; grid diff'inde bu 48×48 alan fark olarak
  görünür (~%0,2, sınırın içinde). Footer'ı her referansa göre ayrı tutuyorum.
- Referanslar `./support.js` yüklüyor; zip'te yok. Stiller satır içi olduğu için render etkilenmiyor.

## Kararlar (2026-09-30, operatör)

1. **Açılan dosyalar main alanında** görünür: terminalin yerini alır; oturum başlığı stilinde
   dosya adı + yol + "Kapat" (agent'a döner). Referansa eklenen tek öğe "Kapat" butonu.
2. **`tauri.conf.json` yalnız pencere ayarı** değişir: `titleBarStyle: Overlay`, `hiddenTitle`,
   `minWidth/minHeight` 1280×800 + pencere sürükleme izni (capabilities). Rust koduna dokunulmaz.
3. **Eksik veriler ekrandan okunur** (token, aktivite, izin detayı, mod); okunamazsa sade gösterim
   + `tasks/todo.md` notu.

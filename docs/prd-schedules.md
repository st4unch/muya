# Mini-PRD: Schedules — scheduled headless Claude prompts

- Tarih: 2026-10-14
- Tür: mini-PRD

## 1. Problem
Operatör, Claude prompt'larını belirli zamanlarda (her N dakikada, her gün, haftanın seçili günlerinde) seçilen bir klasörde, ekranda terminal açmadan (headless) çalıştırmak istiyor. Çalışırken kullanıcının tüm MCP sunucuları ve skill'leri açık olmalı. Her işin başarılı/başarısız durumu, kaç kez çalıştığı ve geçmiş çıktıları küçük kartlarla rapor olarak görünmeli.

## 2. Scope
- Dahil:
  - Rail'de SSH'in altında yeni "Schedules" sayfası.
  - İş = ad + prompt + klasör + zamanlama (interval ≥5 dk / günlük HH:MM / haftalık gün+HH:MM) + timeout.
  - İşlemler: Enable/Disable anahtarı, Run now, Edit, Delete (onaylı).
  - Rust zamanlayıcı Muya açıkken çalışır. Muya kapalıyken kaçan çalışmalar atlanır.
  - Çalıştırma: kullanıcının login shell'i üzerinden `claude -p <prompt> --output-format json --dangerously-skip-permissions`, cwd = klasör. Bu sayede kullanıcı ayarları, MCP'ler ve skill'ler yüklenir.
  - Geçmiş: iş başına son 100 çalışma (durum, süre, maliyet, çıktı ≤64 KB).
  - Rapor: üstte özet kartları (iş sayısı, toplam çalışma, başarı oranı, son hata). İş kartlarında son durum, çalışma sayısı (✓/✗) ve sonraki çalışma zamanı. Karta tıklayınca geçmiş listesi ve çıktı görünür.
- Hariç: Muya kapalıyken çalışma (launchd), cron ifadesi, uzak (SSH) sunucuda çalışma, bildirim/e-posta, mevcut tek seferlik "Schedule prompt" (terminale yazma) özelliğine dokunmak.

## 3. Kabul Kriterleri (binary)
- [ ] AC1: Rail'de SSH'in hemen altında "Schedules" öğesi var ve sayfayı açıyor.
- [ ] AC2: Yeni iş formu ad, prompt, klasör (Choose… ile seçilir), zamanlama ve timeout alanlarını içerir. Göreli klasör veya boş prompt kaydedilmez.
- [ ] AC3: İşler `~/.claude/muya-schedules.json` dosyasında saklanır (atomik yazım) ve uygulama yeniden açıldığında yerinde durur.
- [ ] AC4: `next_run` hesaplaması interval, daily ve weekly için birim testlerle doğrulanır (gün/hafta geçişi ve kapalı iş = none dahil).
- [ ] AC5: Etkin iş zamanı gelince bir kez çalışır. Aynı iş zaten çalışıyorsa ikinci kez başlatılmaz.
- [ ] AC6: Run now, iş kapalı olsa bile hemen bir çalışma başlatır.
- [ ] AC7: Çalıştırma kullanıcının login shell'i üzerinden `claude -p` ile yapılır. Prompt argv'dir, shell'e gömülmez. Testle kanıtlanır: sahte claude ile argv ve cwd doğru gelir, `;rm` içeren prompt çalıştırılmaz.
- [ ] AC8: Çıkış kodu 0 ve JSON `is_error != true` ise success; aksi halde failed; süre aşılırsa timeout. Süre aşımında süreç grubu öldürülür.
- [ ] AC9: Her çalışma `~/.claude/muya-schedule-runs/<id>.jsonl` dosyasına (0600) yazılır. İş başına en fazla 100 kayıt tutulur ve çıktı 64 KB ile kesilir.
- [ ] AC10: Kartlar son durumu, ✓/✗ sayılarını, son ve sonraki çalışma zamanını gösterir. Özet satırında iş sayısı, toplam çalışma ve başarı oranı yer alır.
- [ ] AC11: Geçmiş panelinde her çalışmanın zamanı, durumu, süresi ve çıktısı görünür.
- [ ] AC12: Enable/Disable anahtarı ve Edit kalıcıdır. Delete onay ister ve işin geçmişini de siler.
- [ ] AC13: Formda "headless çalışır, izin sormadan (bypass) çalışır" uyarısı görünür.
- [ ] AC14: Tüm renkler var(--token) ile verilir, UI metni İngilizcedir ve dağıtılan kodda operatöre özel yol yoktur.

## 4. Koruma Listesi (dokunulmayacak)
- Mevcut `ScheduledPromptModal` (açık terminale tek seferlik prompt) ve ⌘K "Schedule prompt" komutu.
- SSH sayfası, `agents::claude_bin()` çözümleme mantığı (yalnızca çağrılır).
- Diğer rail öğelerinin sırası ve davranışı.

## 5. Entegrasyon / Harmony
- Auth: Yeni auth yok. Local-only Tauri komutları, mevcut `generate_handler!` listesine eklenir (`src-tauri/src/lib.rs`).
- Servis/Tablo: Claude ikilisi `agents::claude_bin()` ile bulunur (`src-tauri/src/agents.rs:82`). Login shell deseni `bin_via_login_shell` ile aynıdır (`agents.rs:162`). Saklama, `~/.claude/muya-*.json` desenini izler (`vault.rs:100-111`).
- Konvansiyon:
  - Sayfa bağlama: `View` union (`src/App.tsx:141`), `pageClass` + `mountedViews` (`App.tsx:2355`, `:411`), rail eşlemesi (`App.tsx:1881`, `:2059`).
  - Rail öğeleri `src/redesign/Rail.tsx:24-32`, `RailItem` tipi `src/redesign/types.ts:110`.
  - Stil: `src/components/sshStyles.ts` (CARD, INPUT, BTN, BTN_GHOST, ICON_BTN, LABEL) ve `Switch` (`SettingsModal.tsx:428`).
- Kırma riski:
  - Rail'e öğe eklemek rail testlerini değiştirebilir; testler güncellenir.
  - Headless claude, GUI'nin minimal PATH'iyle MCP'leri başlatamaz; bu yüzden login shell kullanılır.
  - Zamanlayıcı ana thread'i bloklamamalı; tokio task ve `spawn_blocking` kullanılır.

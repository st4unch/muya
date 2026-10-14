# Apex Mission Control — Test Plan

> **Tarih:** 2026-06-20 · **Durum:** taslak (onay bekliyor)
> **Amaç:** Şu ana kadar ad-hoc cargo smoke test + manuel GUI ile doğruladık. Bunu
> **agnostic** (makineye gömülü yol yok), tekrarlanabilir bir test stratejisine çevir.

## 1. Test piramidi (bu uygulama için)

```
        ┌───────────────────────────┐
   az   │  E2E / golden-path (manuel │  macOS WKWebView WebDriver YOK →
        │  checklist + opsiyonel)    │  çoğunlukla manuel + ufak otomasyon
        ├───────────────────────────┤
  orta  │  Frontend (Vitest + RTL,  │  invoke mock'lanır; component davranışı
        │  invoke mock)              │
        ├───────────────────────────┤
  çok   │  Rust backend (hermetik    │  temp git repo'lar + saf-fonksiyon unit
        │  cargo test)               │  → en yüksek değer, tam otomatik, agnostik
        └───────────────────────────┘
```

**Kök ilke (agnostic):** Mevcut smoke testler `~/...` ve canlı `claude`
oturumlarına bağlı — başka makinede çalışmaz. Bunları **kendi içinde temp git repo
kuran** hermetik testlerle değiştir. Hiçbir test makineye/oturuma bağlı olmamalı.

## 2. Rust backend (P0 — en yüksek öncelik)

### 2a. Saf-fonksiyon unit testleri (I/O yok)
İlgili saf mantığı çıkar/test et (girdi→çıktı, sistem çağrısı yok):
- `fs::branch_kind` (main/release→PRD, feature/fix→WIP, diğer→OPEN)
- `fs::track_to_status` (ahead/behind/diverged/synced)
- `agents::map_status`, `agents::disambiguate_names` (çakışan ad→`(shortid)`)
- `pm::base_branch` mantığı (sentetik), `pm::status` parse'ları
- `metrics`/`history` format yardımcıları (duration, relTime karşılığı)

### 2b. Hermetik git integration testleri (temp repo)
Her test `tempfile::TempDir` içinde `git init` + config + commit + branch + worktree
kurar; sonra komutu çağırıp sonucu assert eder. **Makineden bağımsız.**

| Test | Kurulum | Assert |
|---|---|---|
| `list_branches` | main + feature/x (1 commit ahead) | branch sayısı, type, status=ahead |
| `compute_parents` | main → feature/a → feature/b | b.parent=a, a.parent=main, main.parent=None |
| `pm_status` | dirty dosya + ahead commit | ahead/behind/dirty/changed doğru |
| `pm_check_merge` | çakışan iki branch | clean=false; çakışmayanda clean=true |
| `pm_collisions` | 2 worktree, aynı dosya dirty | 1 collision; ayrı dosyalarda 0 |
| `create_worktree`/`remove_worktree` | repo + branch | worktree oluşur/silinir, .env kopyalanır |
| `read_head_file` | commit'li + untracked dosya | HEAD içeriği / boş |

### 2c. PTY + env (zaten var, korunur)
- `pty_echo_roundtrip`, `pty_strips_claude_env` — hermetik, kalsın.
- `app_metrics`/`claude agents` gibi canlı-sisteme bağlı olanlar: **`#[ignore]`** ile
  işaretle (opsiyonel manuel), CI'da koşma.

**Komut:** `cargo test` (+ `cargo clippy -- -D warnings` lint).

## 3. Frontend (P1 — Vitest + React Testing Library)
Kurulum: `vitest`, `@testing-library/react`, `jsdom`. `@tauri-apps/api/core` `invoke`
**mock**'lanır (fixture döndürür); `@tauri-apps/api/event`/`plugin-dialog` stub.

### 3a. Saf util testleri
- `QueuePage.relTime`, `FileEditor.langFromPath`, `SessionsPage` formatları
- `App.loadList`/`loadTabs` (terminal `initialCommand` düşürme sanitizasyonu)
- localStorage persist/restore (workspaces, queue, openTabs)

### 3b. Component davranışı (invoke mock'lu)
| Component | Senaryo |
|---|---|
| `NewAgentModal` | prompt+files → command'a `@path` + tek-tırnak quote doğru eklenir; default `claude --dangerously-skip-permissions` |
| `QueuePage` | add/remove queue; Push/Merge **iki-tık onay**; merge sonrası worktree auto-remove invoke'u |
| `SessionsPage` | attachable→`claude attach`, history→`claude --resume` spec'i; stop yalnız bg'de |
| `Terminal` | mount→`pty_spawn`, unmount→`pty_kill`; disposed guard (write-after-dispose throw etmez) |
| `FileEditor` | load→`read_file`, Save→`write_file`, Diff toggle→`read_head_file` |
| `App` | panel toggle (left/right render), view switch (control/sessions/queue), tab persistence |

**Komut:** `npm run test` (vitest) + `npm run build` (tsc typecheck zaten gate).

## 4. E2E / golden-path (P2)
**Kısıt (araştırma):** macOS WKWebView'in WebDriver'ı yok (Tauri resmi + tauri-driver
issue #7068). Seçenekler:
- **A — Manuel golden-path checklist (öneri, şimdilik):** Golden Rule §2 gereği uçtan
  uca gözle. Aşağıdaki akışlar her sürümde elle koşulur (checklist §5).
- **B — Frontend E2E (Playwright + `vite dev` + invoke shim):** UI akışları tarayıcıda,
  backend mock'lu. Gerçek entegrasyonu test etmez ama UI regresyonunu yakalar.
- **C — `tauri-plugin-webdriver` (deneysel, Şub 2026):** macOS WebDriver'ı gömer.
  Olgunlaşınca değerlendir; şimdilik riskli.

## 5. Manuel golden-path checklist (her sürüm)
1. + Workspace → git repo ekle → dosya ağacı gerçek dosyaları gösterir.
2. New agent (branch'li) → worktree oluşur + terminalde `claude --dangerously-skip-permissions` başlar.
3. Background session'a tıkla → terminal `claude attach <id>` ile bağlanır; sekmeler arası gez → TUI kaybolmaz.
4. Dosya aç → Monaco; düzenle+Save; Diff → HEAD'e karşı fark.
5. Queue → Add → ready/conflict rozeti; Merge (iki-tık) → merge + worktree auto-remove.
6. Aynı dosyayı 2 worktree'de değiştir → sol panelde collision (kırmızı).
7. Header CPU/RAM gerçek değer oynar; footer sayıları gerçek.
8. Uygulamayı kapat-aç → workspaces/worktrees/queue/sekmeler geri gelir.

## 6. CI (git init sonrası)
GitHub Actions (macOS runner): `cargo test` + `cargo clippy` + `npm ci && npm run build && npm run test`.
E2E manuel/gated. (Not: önce `git init` + ilk commit gerekli — repo henüz git değil.)

## 7. Fazlama
- **P0:** Rust saf-unit + hermetik git testleri (makine-bağımlı smoke'ları değiştir).
- **P1:** Vitest kurulum + util + kritik component testleri.
- **P2:** Manuel checklist'i formalize et; CI; E2E seçeneği değerlendir.

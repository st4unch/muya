---
status: active
feature: apex-mission-control
prd: docs/prd-apex-mission-control.md
created: 2026-06-16
---

# Apex Mission Control — İlerleme

## Kararlar
- **2026-06-16** — Stack: Tauri v2 (Electron değil). Gerekçe: bellek/bundle, capability güvenlik modeli, frontend yeniden-yazımsız taşıma. Kaynak: `compass_artifact...md`.
- **2026-06-16** — Kapsam: tam vizyon (Phase 0-4), fazlı milestone'lar halinde tek PRD. (Operatör kararı.)
- **2026-06-16** — Orkestrasyon: baştan tam (uygulama worktree+tmux+claude başlatır/durdurur), izleme değil. (Operatör kararı.)
- **2026-06-16** — Prototip referansı `_prototype_ref/` altına çıkarıldı (`agent-control-plane-layout.zip`). TS tipleri kontrat olarak korunacak.

## Faz durumu
- [x] P0 — Sarma ✅ 2026-06-17 — Tauri v2 + React 19 + Vite 7 + Tailwind v4 scaffold; prototip (App.tsx/BranchDAG/index.css) köke taşındı; `@google/genai`/express/dotenv yok; `npm run build` temiz; `tauri dev` native pencere açıp prototipi serve ediyor (PID doğrulandı, Vite 1420 + Cargo build + binary running). AC-1/2/3 PASS.
- [~] P1a — Gerçek terminal + canlı agent (kısmen) ⏳ 2026-06-17:
    - ✅ Canlı agent listesi: `claude agents --json` → Rust `list_agent_sessions` → UI (mock kalktı). cargo test ile 2 gerçek session doğrulandı (AC-13 çekirdeği).
    - ✅ Gerçek terminal: `portable-pty` ile el-yazımı PTY (`pty_spawn/write/resize/kill`) + xterm.js `AgentTerminal`; seçili session'ın cwd'sinde login shell. PTY mekanizması cargo test (`apex-pty-ok`) ile doğrulandı. UI'da görsel test kullanıcıya bırakıldı.
    - ✅ Workspace ekleme + gerçek dosya ağacı: native klasör seçici (`tauri-plugin-dialog`) ile birden çok proje kökü eklenir; sol panelde lazy `FileTree` (`list_dir` Rust komutu) gerçek dosyaları gösterir. cargo test ile doğrulandı.
    - ⏳ Kalan P1a: Monaco editör + DiffEditor (dosyaya tıklayınca aç/diff); dosya ağacında lock/conflict rozetleri (Faz 4 collision ile gelir); react-arborist'e geçiş (şu an hafif custom lazy tree — virtualization gerekirse).
- [~] Faz 1b — Yeni agent spawn (app-managed, 2026-06-18):
    - **Kritik bulgu:** makinede tmux YOK, workspace'ler çoğu git repo değil, claude'un bg-spawn CLI'ı yok → PRD'nin tmux orkestrasyonu tutmuyor. Operatör kararı: **app-managed PTY** (tmux'a geçilmedi). PRD NG/orkestrasyon bu yönde revize.
    - ✅ Sağ panel Sessions tab'ında "Yeni agent" formu: workspace seç + opsiyonel branch. Branch varsa `create_worktree` (git worktree + .env kopya); sonra uygulama PTY'sinde `claude` başlatan terminal sekmesi açılır. Uygulama kapanınca oturum ölür (kabul, NG).
- ✅ BranchDAG canlı (2026-06-18): `list_branches` (for-each-ref, `\x1f` ayraç, upstream:track→synced/ahead/diverged, name→PRD/WIP/OPEN heuristik). Seçili agent'ın repo'sundan (yoksa ilk git workspace) 5sn poll. Gerçek git repo'da test edildi (main/master parse OK).
- ✅ UI İngilizceye çevrildi (2026-06-18): tüm görünür string/placeholder/title İngilizce (kod yorumları TR kalabilir). Kullanıcı isteği: uygulamada Türkçe alan olmasın.
- ✅ Yeni-agent modal (2026-06-18): "+ New agent" → popup; alanlar Workspace, Branch(ops→worktree), Title(ops), Prompt(ops), Files(path-only, dialog ile ekle), Command (default `claude --dangerously-skip-permissions`). Prompt+files → `@path` ref'leri + prompt tek-tırnak quote'lanıp command'a eklenir.
- [~] Project Manager + Push/Merge Queue (2026-06-19):
    - **Karar:** Python yerine **Rust** (operatör — agnostic öncelik; Python runtime bağımlılığı istemiyoruz). Stateless compute-on-demand, arka plan daemon yok. `docs/design-project-manager.md`.
    - ✅ Backend `pm.rs`: `pm_status(paths)` (branch/base-tespit/ahead/behind/dirty/changed/lastActivity), `pm_check_merge` (git merge-tree trial — working tree'ye dokunmaz), `pm_merge` (local, base'e switch+merge), `pm_push` (operatör onaylı). cargo test ile gerçek repo'da doğrulandı (ahead=9, changed=39, base=main tespit).
    - ✅ Üst nav **Queue** + `QueuePage`: izlenen projeler (workspaces) canlı durum + FIFO kuyruk + trial-merge ready/conflict rozeti + Push/Merge (iki-tık onay) / Remove. Kuyruk localStorage'da.
    - Agnostic: hiç hardcoded path yok, git PATH'ten, base branch tespit. İzlenen path'ler şimdilik workspaces (oluşturulan worktree'leri de eklemek sonraki adım).
- ✅ Panel toggle + worktree lifecycle (2026-06-19):
    - Sol/sağ paneller aç/kapa (header'da PanelLeft/PanelRight; resize YOK — focus toggle). Center boşalan alana yayılır.
    - New-agent'ın oluşturduğu worktree'ler `worktrees` state'ine eklenip Queue'da workspaces ile birlikte izlenir.
    - `remove_worktree` (git-common-dir → main repo → `git worktree remove --force`); QueuePage tracked-projects'te worktree girişlerinde Trash (iki-tık onay) → klasör silinir.
- ✅ Gerçek app metriği + auto-remove + notify (2026-06-19):
    - Header CPU/RAM artık mock değil: `sysinfo` ile uygulamanın **kendi process'inin** CPU% + RSS (MB/GB). `app_metrics` komutu, kalıcı System state, 2.5sn poll. (Not: ana process; ayrı WebKit content process sayılmaz.)
    - Merge sonrası worktree ise **otomatik remove** (QueuePage `doRemoveWt`, merge başarısında).
    - `notify` watcher (`watcher.rs`): tracked path'leri izler, debounce'lı (400ms) + node_modules/.git/target filtreli `fs-changed` event → frontend anlık refresh (branch + Queue). `start_watching` komutu.
- ✅ Last-session memory + canlı dosya ağacı (2026-06-19):
    - workspaces + worktrees localStorage'a kalıcı (`apex.workspaces`/`apex.worktrees`) → app restart sonrası geri yüklenir. (Tauri webview localStorage app data dir'de kalır; agnostic, backend gerekmez.)
    - FileTree `fs-changed`'e bağlandı: dosya değişince açık/yüklü dizinler anında yeniden okunur (canlı ağaç).
- ✅ Açık sekme restore (2026-06-19): openTerminals localStorage'a kalıcı (`apex.openTabs`). Restart'ta editör sekmeleri dosyayı yeniden açar; terminal sekmeleri cwd'de **temiz shell** açar (initialCommand düşürülür — yanlış re-launch/attach olmasın). Aktif sekme ilk restore'a set edilir.
- ✅ Gerçek collision telemetry + mock temizliği (2026-06-20):
    - LOCK/EDIT FILE TELEMETRY artık gerçek: `pm_collisions(paths)` — aynı repo-relative dosya 2+ worktree'de uncommitted ise çakışma (git status --porcelain, hook gerektirmez, agnostic). Sol panelde kırmızı liste + "N uncommitted tracked". fsTick + 5sn poll.
    - Map Details / branch listelerindeki mock badge'ler kaldırıldı (Deploy: Ready, Auto-Release Hook, Locked, Stale, Spin Agent) — sadece gerçek veri (branch/commit/author/sync). BranchDAG metrikleri branchList'ten türetilir.
- ✅ BranchDAG gerçek lineage (2026-06-20): `list_branches` her branch için gerçek **parent**'ı hesaplar (en yakın diverjans — min commit since merge-base, base'e tie-break; ≤40 branch cap). BranchDAG mock heuristic yerine `node.parent`'ı kullanır. cargo test: main→None, master→main. 
- ✅ P0 backend test suite (2026-06-20): `testutil.rs` hermetik temp-git repo helper'ı (agnostic — makine yolu yok). 14 test: fs (branch_kind, track_to_status, list_dir, list_branches+parents, read_head_file, create/remove_worktree), pm (status, non-git, check_merge clean/conflict, collisions), agents (map_status, disambiguate), pty (echo, env-strip). Makine-bağımlı smoke'lar `#[ignore]`. `tempfile` dev-dep.
- **Testler 3 GERÇEK bug yakaladı + düzeltildi:** (1) `read_head_file` symlink'li path'te `strip_prefix` patlıyordu → canonicalize. (2) `compute_parents` descendant'ı (count==0) parent sanıyordu → skip. (3) `pm_collisions` porcelain'i trim'li `git()` ile okuyup ilk dosyanın adından bir harf düşürüyordu → `git_raw` (trim'siz). Plan: `docs/test-plan.md`.
- ✅ P1 frontend testleri (2026-06-20): Vitest 4 + RTL + jsdom (`vitest.config.ts`, `src/test/setup.ts`, `npm run test`). Saf util'ler lib'e çıkarıldı + duplikasyon temizliği (`src/lib/format.ts`, `src/lib/agent.ts`). **14 test geçti** (format, agent command-build/escape, NewAgentModal onLaunch). `npm run build` temiz. Backend P0 (14) + frontend P1 (14) = 28 test.
- ✅ P2 — git + CI (2026-06-20): repo **git init + ilk commit** (`b4af552`, 80 dosya, local; node_modules/target/cert sızmadı). `.github/workflows/ci.yml`: frontend (npm ci/build/test) + backend (cargo clippy -D warnings/test) macOS'ta. clippy uyarıları temizlendi (testutil çift cfg, dir RAII allow). Golden-path checklist plan §5'te. **Remote push YAPILMADI** — §6 gereği project-manager onayı + remote kurulumu gerekir; CI push'ta çalışır.
- Karar: Stack Tauri'de KALDI (kullanıcı onayı 2026-06-17) — Electron'a geçilmedi. Terminal `tauri-plugin-pty` yerine doğrudan `portable-pty` (dayanıklılık).
- Gereksinim: uygulama çok-makineli olmalı (şirket/aile PC). `.node-ca.pem` sadece bu makinedeki kurumsal TLS-proxy için yerel build workaround'u (public kök sertifikalar, secret değil, gitignore, üründe yok). Windows hedefi olursa PRD NG1 (macOS-only) revize edilmeli.
- [ ] P2 — Canlı status + hooks
- [ ] P3 — Kanban
- [ ] P4 — Monitor + collision

- [~] Sessions sayfası (P4/monitor erken parçası) ⏳ 2026-06-17:
    - ✅ Üst nav'da Control ↔ Sessions geçişi (router yok, view state — TanStack Router sonraya).
    - ✅ Canlı oturumlar: `claude agents --json --all`. Geçmiş oturumlar: `~/.claude/projects/*/*.jsonl` tarama (`list_session_history` Rust, cwd transcript ilk satırından). cargo test ile doğrulandı (8 geçmiş).
    - ✅ Aksiyonlar: canlı → Attach/Aç (terminal sekmesi açar); geçmiş → Resume (`claude --resume <id>` ile yeni terminal). Terminal prop'u `attachId` → genel `initialCommand`.
    - Açıklama (kullanıcı sorusu): `claude agents --json` tüm CANLI oturumları gösteriyor; `ps`'teki ekstra claude prosesleri oturum değil (daemon + pre-warm spare host'ları). Yetim-oturum güvence ağı eklenmedi (gerek görülmedi).

- [~] Monaco editör + Sessions stop (2026-06-18):
    - ✅ Monaco editör: soldan dosya tıkla → terminal sekmeleriyle aynı şeritte editör sekmesi açılır (kind: terminal|editor). `read_file`/`write_file` Rust komutları; Cmd/Ctrl+S kaydeder. Monaco **yerel** yüklenir (CDN yok — güvenlik), Vite worker kurulumu. Bundle ~4.3MB (desktop'ta yerel, kabul).
    - ✅ Sessions stop: background oturumlarda Stop butonu → `stop_agent` (`claude stop <id>`). Destructive olduğu için canlı test edilmedi (kullanıcı tetikler).
    - ✅ DiffEditor: editör toolbar'ında "Diff" toggle → Monaco DiffEditor (HEAD vs çalışma kopyası). Backend `read_head_file` (`git show HEAD:<rel>`, untracked→boş). Non-git workspace'te tümü-eklendi gösterir.
    - ⏳ Kalan: geçmiş oturum transcript detayı; gerçek "Yeni agent başlat" (worktree+spawn, Faz 1b).

## Gotcha (önemli — gelecekte tekrar etmesin)
- **PTY spawn'da CLAUDE* env temizliği zorunlu.** Uygulama bir Claude Code oturumunun içinden başlatılırsa (özellikle dev'de `tauri dev`'i agent başlatınca), `CLAUDECODE`/`CLAUDE_CODE_CHILD_SESSION`/`CLAUDE_CODE_SESSION_ID` vb. miras kalır → terminalde başlatılan `claude` kendini "child session" sanıp **session persistence'ı kapatır** → "Cannot background — session persistence is disabled" hatası. Çözüm: `pty_spawn`'da `CLAUDE*` + `AI_AGENT` env'lerini `env_remove` ile temizle (pty.rs). Test: `pty_strips_claude_env` (`CC=[]` doğrular).
- Terminal yok-edildikten sonra Channel çıktısı gelirse xterm.write hata fırlatır → `disposed` guard + try/catch (Terminal.tsx).
- **Gizli sekmede fit/resize yapma.** Kalıcı (hidden, display:none) terminal sekmesinde ResizeObserver 0×0'da `fit()` çağırırsa PTY ~0 satıra küçülür ve `claude attach` gibi tam-ekran TUI bozulur (sekmeye dönünce içerik kaybolur). Çözüm: `el.offsetWidth===0||offsetHeight===0` ise resize'ı atla (Terminal.tsx).

- [x] Düzeltmeler (2026-06-18):
    - ✅ Ad ayrımı: aynı isimli oturumlara backend kısa id/pid suffix ekler (`disambiguate_names`).
    - ✅ Her oturum durdurulabilir: `kill_session` (bg→`claude stop`, interactive→pid SIGTERM). pid AgentSession'a eklendi.
    - ✅ Monitor sağ panele 2. tab oldu ("Sessions" / "Branch & WIP"); her kartta Stop. Center artık tam-yükseklik terminal/editör.

## Lesson (2026-06-18 — düzeltme)
- **Paralel varlıkları benzersiz olmayan türetilmiş etiketle gösterme.** Agent kartları/sekmeleri cwd-basename ile adlandırıldı; aynı dizinde birden çok oturum olunca adlar çakıştı, kullanıcı ayırt edemedi (kontrol panelinin tüm amacı ayırt etmek). Kural: parallel session listesinde ad çakışırsa kısa id/pid ekle; her oturum görsel olarak benzersiz olmalı.
- **Her oturum durdurulabilir olmalı.** İlk Stop sadece background (`claude stop <id>`) içindi; interactive oturumların id'si yok → durdurulamıyordu. Çözüm: pid taşı, interactive için pid-kill.

## Açık sorular
- O1 — `/control` dış kabuk kütüphanesi (Allotment vs react-resizable-panels) — P0/P1.
- O2 — Kanban board kütüphanesi (dnd-kit vs flex) — P3.
- O3 — Orkestrasyon `claude` CLI doğrudan mı, tmux içinden mi — P1 spike.

## Log
- 2026-06-16 — Brainstorming + ilk PRD taslağı.
- 2026-06-16 — `/spec-first-feature` pipeline: SYSTEM.md yazıldı (`docs/SYSTEM.md`), Phase 1 inline review+gate GO. PRD prod-ready'e yükseltildi (§0-§18, Risk Register 8, Failure Modes, 3 use case, Decision Log D1-D9, threat model). Phase 2c inline review+gate GO.
- 2026-06-16 — **Blocker:** otonom subagent review/gate'leri ve Phase 3 `/prd-run` Anthropic session limit'ine takıldı (reset 5:40 Europe/Istanbul). Inline yürütüldü. `/prd-run` (Sonnet impl + Opus verify) kota açılınca başlatılacak.

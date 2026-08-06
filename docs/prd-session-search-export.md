# Mini-PRD: Sessions — içerik araması + Markdown export

- Tarih: 2026-08-06
- Tür: mini-PRD

## 1. Problem
Sessions sayfasındaki arama yalnızca **isim + worktree**'yi tarıyor (SessionsPage.tsx:116-127).
Operatör bir konuşmanın **içeriğinde** geçen bir kelimeyle o session'ı bulamıyor. Ayrıca bir
session'ın konuşmasını dışarı almanın (paylaşma/arşiv) yolu yok. İki ihtiyaç: (a) transcript
**içeriğinde** ara, (b) bir konuşmayı **Markdown** olarak export et. İkisi de aynı veri kaynağını
(`~/.claude/projects/<cwd→->/<sessionId>.jsonl`) kullanır.

## 2. Scope
- **Dahil:**
  - Backend `search_session_contents(query, sessions)`: verilen session'ların (id + cwd) transcript
    dosyalarını query için grep'ler; eşleşen `sessionId` + kısa **snippet** (ilk eşleşen satır özeti) +
    eşleşme sayısı döner. **spawn_blocking** (L31), dosya-boyut cap'i + sonuç cap'i, case-insensitive.
  - SessionsPage araması: mevcut isim/worktree filtresine **içerik eşleşmesini** ekle (debounce ~300ms,
    query ≥ 2 karakter). İçerikten eşleşen session listede snippet ile gösterilir.
  - Backend `export_session_markdown(sessionId, cwd, dest)`: transcript'i okur, her satırı parse edip
    kullanıcı/asistan turlarını + tool çağrılarını **Markdown**'a çevirir, kullanıcının seçtiği `dest`
    yoluna yazar. UTF-8 korunur.
  - SessionsPage'de her session için **Export .md** aksiyonu (buton/menü) → save dialog → backend yazar.
- **Hariç:**
  - Full-text index / arama motoru (basit grep yeterli — transcript'ler zaten diskte).
  - Global (tüm projeler) arama; yalnız **listelenen** session'lar (live + history) taranır.
  - PDF/HTML export, streaming, transcript düzenleme.

## 3. Kabul Kriterleri (binary)
- [ ] **AC1** (içerik araması): bir session'ın konuşmasında geçen ama **isim/worktree'de OLMAYAN** bir
  kelime aratıldığında o session listede belirir. `search_session_contents` o `sessionId`'yi döner.
- [ ] **AC2** (perf — L31): `search_session_contents` **spawn_blocking**'te çalışır (tokio worker'ı
  bloklamaz); dosya-boyut cap'i (>N MB atla/parçala) + sonuç cap'i var; frontend debounce'lu. Kod + test.
- [ ] **AC3** (snippet): içerikten eşleşen session, eşleşen metnin **kısa alıntısını** (± bağlam) listede
  gösterir; isim/worktree eşleşmesinden ayırt edilir.
- [ ] **AC4** (export): bir session için "Export .md" → save dialog → seçilen yola **.md dosyası yazılır**;
  dosya diskte oluşur ve boş değildir.
- [ ] **AC5** (md kalitesi): export edilen Markdown iyi biçimli — user/assistant turları etiketli, tool
  çağrıları özetli, okunur; UTF-8 içerik bozulmaz. Bilinen bir transcript'te unit/gözle doğrulama.
- [ ] **AC6** (graceful): transcript yok / boş session → arama: eşleşme yok (crash yok); export: net hata,
  dosya-sistemi bozulmaz. Test.

## 4. Koruma Listesi (dokunulmayacak)
- Mevcut isim/worktree araması (SessionsPage.tsx:116-127) çalışmaya devam eder — içerik araması **ek**tir.
- `list_agent_sessions` / session listeleme akışı + mount-once/refresh davranışı.
- Transcript dosyaları **salt-okunur** — arama/export asla yazmaz/değiştirmez (yalnız export, kullanıcının
  seçtiği HARİCİ dest'e yazar).
- Rust-only secret modeli etkilenmez (transcript'ler kullanıcının kendi verisi; secret store'a dokunulmaz).

## 5. Entegrasyon / Harmony (ZORUNLU)
- **Veri kaynağı:** transcript yolu `~/.claude/projects/{cwd.replace('/','-')}/{sessionId}.jsonl`
  (kanıt: bu oturumun dosyası `-Users-staunch-Documents-claude-control-plane/9d210ed5-….jsonl`).
  Session'ın `id` + `worktree` alanları `AgentSession`'da mevcut (agents.rs:42,45). JSONL satırları
  `type` + `message.role`/`message.content` taşıyor (grep kanıtı).
- **Perf konvansiyonu:** git/subprocess/fs-ağır komutlar spawn_blocking'e (L31 — bu oturumda git_status,
  pm_status, list_agent_sessions aynı şekilde düzeltildi). Yeni komutlar da öyle olacak.
- **Arama entegrasyonu:** SessionsPage `query` state'i (satır 58) + `filteredLive`/`filteredHistory`
  (116-127) genişletilir; içerik-eşleşme id-set'i backend'den gelir, mevcut filtreyle OR'lanır.
- **Export dialog:** SshPage'deki `pickSavePath` (tauri dialog plugin) pattern'i yeniden kullanılır.
- **Backend komut kaydı:** yeni `#[tauri::command(async)]`'ler `lib.rs` invoke_handler'a eklenir (mevcut
  fs/pm komutları gibi).
- **Kırma riski:** büyük transcript'leri (10+ MB) tek seferde okumak UI/CPU'yu zorlayabilir → dosya-boyut
  cap'i + spawn_blocking + debounce (AC2). Transcript'lere yanlışlıkla yazmak → export SADECE harici
  dest'e yazar, kaynak dosyaya asla dokunmaz (koruma listesi).

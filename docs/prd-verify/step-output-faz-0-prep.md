## Retry 0

### AC Bazında Yapılanlar

**AC-0-1 (Cargo deps)**
- `tokio` features genişletildi: `net` + `macros` eklendi.
- `rustls = "0.23"`, `tokio-rustls = "0.26"`, `dirs-next = "2"` bağımlılıkları eklendi.
- `cargo update tokio` ile `tokio-macros v2.7.0` lock'a eklendi (1.52.3 locked versiyonu `macros` feature için gerekli).

**AC-0-2 (bridge.rs + lib.rs)**
- `src-tauri/src/bridge.rs` oluşturuldu: `BridgeState(Mutex<Option<(UnixListener, PathBuf)>>)` managed state, `bridge_local_listen(enable: bool)` Tauri command.
  - `true`: per-user app-data dir altında `muya/bridge/bridge.sock` oluşturulur, mode 0600 set edilir, listener handle state'de tutulur.
  - `false`: listener drop edilir, socket dosyası silinir.
- `lib.rs`: `mod bridge;` eklendi, `.manage(bridge::BridgeState::default())` satırı eklendi (l.135 civarı), `bridge::bridge_local_listen` generate_handler'a eklendi.
- `#[cfg(test)]` modülü `bridge.rs` içinde: bind → chmod 0600 → mode assert → drop → remove → dosya yokluğu assert.

**AC-0-3 (App.tsx chat view)**
- `useState<"control"|"sessions"|"queue"|"tools"|"prd"|"chat">` union'a `"chat"` eklendi.
- Kanban'ın hemen arkasına "Chat" nav butonu eklendi (aynı Tailwind class stili).
- `{view === "chat" && ...}` bloğu: flex column, iki eşit bölüm (flex-1), üstte **Remote** başlıklı bölüm, altta **Local** başlıklı bölüm; her biri kendi header bar'ı ve placeholder metniyle.

### Değiştirilen / Oluşturulan Dosyalar

| Dosya | İşlem |
|---|---|
| `src-tauri/Cargo.toml` | deps eklendi |
| `src-tauri/Cargo.lock` | güncellendi |
| `src-tauri/src/bridge.rs` | oluşturuldu |
| `src-tauri/src/lib.rs` | mod + manage + handler eklendi |
| `src/App.tsx` | view union, nav button, chat view |

### Test Komutları ve Sonuçlar

| Komut | Sonuç |
|---|---|
| `cargo build` (src-tauri) | PASS — Finished dev profile |
| `cargo test` (src-tauri) | PASS — 31 passed, 0 failed |
| `npx tsc --noEmit` | PASS — no output (no errors) |
| `npm test -- --run` | PASS — 8 test files, 49 tests passed |

### Bu Turda Alınan Kararlar

- `macros` feature tokio'ya eklendi: `#[tokio::test]` makrosu bu feature'ı gerektiriyor, PRD bunu belirtmemiş ama test scaffold AC-0-2 hard constraint'i.
- `dirs-next` seçildi (yerine `dirs` crate'i de kullanılabilirdi): proje `Cargo.lock`'ta zaten transitif olarak mevcut değildi, `dirs-next` daha aktif maintainer geçmişine sahip.
- Bridge module'e `tokio-rustls` / `rustls` doğrudan import edilmedi (AC-0-2 socket-only, Faz 1'de kullanılacak) — bağımlılıklar AC-0-1 kapsamında eklendi, kullanım Faz 1'e bırakıldı.
- Git commit'ler her AC için ayrı atıldı: `200901f` (AC-0-1), `0d2ca07` (AC-0-2), `08e6887` (AC-0-3).

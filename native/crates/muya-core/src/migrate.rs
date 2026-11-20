//! First-launch migration of the Tauri app's UI state into the native app's store
//! (PRD AC18, D12, §6): **copy only**. Nothing under the Tauri app's data is written,
//! moved or deleted, so the Tauri build keeps working (downgrade path, AC27).
//!
//! Sources:
//! - WebKit `localStorage` of the Tauri webview
//!   (`~/Library/WebKit/com.staunch.muya/WebsiteData/Default/*/*/LocalStorage/localstorage.sqlite3`):
//!   tabs, workspaces, layout, theme, terminal prefs. Keys start with `muya.` or `apex.`;
//!   values are UTF-16 blobs.
//! - `~/.claude/muya-*.json` (vault config, schedules, servers, settings…) are *shared as
//!   they are* — the native side reads the very same files, so they are only listed in the
//!   marker (never copied, never touched).
//!
//! Target: `~/Library/Application Support/com.staunch.muya/native/`
//! - `ui-prefs.json` — `{ "<localStorage key>": "<value as the string the webview stored>" }`
//! - `migrated.json` — version marker; its presence makes `run` a no-op.
//!
//! The sqlite file is read from a temporary copy (WAL mode: even a read-only open may touch
//! `-shm`), through the system `sqlite3`, so no byte of the original changes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};

/// Bumped when the migration learns to copy more; an older marker triggers a re-run
/// (re-running only rewrites the native side's own files).
pub const MIGRATION_VERSION: u32 = 1;

/// Only the system sqlite3 is used (macOS-only crate; absent = migration reports `Unreadable`
/// and retries on the next launch).
const SQLITE3: &str = "/usr/bin/sqlite3";

/// localStorage key prefixes written by the Tauri app.
const KEY_PREFIXES: [&str; 2] = ["muya.", "apex."];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Copied `keys` entries into the native store.
    Migrated { keys: usize },
    /// A marker of this version (or newer) already exists; nothing was done.
    AlreadyDone,
    /// No Tauri localStorage exists (fresh install): marker written, nothing to copy.
    NothingToMigrate,
    /// The Tauri database could not be read (corrupt, no sqlite3…). Nothing written, so the
    /// next launch tries again.
    Unreadable(String),
}

#[derive(Serialize, Deserialize)]
struct Marker {
    version: u32,
    keys: usize,
    /// Shared `~/.claude/muya-*.json` file names that existed at migration time (not copied).
    shared_files: Vec<String>,
}

pub fn native_store_dir(home: &Path) -> PathBuf {
    home.join("Library/Application Support/com.staunch.muya/native")
}

pub fn ui_prefs_path(home: &Path) -> PathBuf {
    native_store_dir(home).join("ui-prefs.json")
}

fn marker_path(home: &Path) -> PathBuf {
    native_store_dir(home).join("migrated.json")
}

/// Read the migrated UI prefs (empty when not migrated or unreadable).
pub fn load_ui_prefs(home: &Path) -> BTreeMap<String, String> {
    std::fs::read_to_string(ui_prefs_path(home))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

/// Run the migration for `home`. Idempotent; never prompts; never writes outside the native dir.
pub fn run(home: &Path) -> Outcome {
    if let Ok(s) = std::fs::read_to_string(marker_path(home)) {
        if let Ok(m) = serde_json::from_str::<Marker>(&s) {
            if m.version >= MIGRATION_VERSION {
                return Outcome::AlreadyDone;
            }
        }
    }

    let keys = match find_localstorage(home) {
        None => BTreeMap::new(),
        Some(db) => match read_localstorage(&db) {
            Ok(k) => k,
            Err(e) => return Outcome::Unreadable(e),
        },
    };

    let nothing = keys.is_empty();
    if !nothing {
        if let Err(e) = write_private(&ui_prefs_path(home), &keys) {
            return Outcome::Unreadable(format!("write ui-prefs.json: {e}"));
        }
    }
    let marker = Marker {
        version: MIGRATION_VERSION,
        keys: keys.len(),
        shared_files: shared_files(home),
    };
    if let Err(e) = write_private(&marker_path(home), &marker) {
        return Outcome::Unreadable(format!("write migrated.json: {e}"));
    }
    if nothing {
        Outcome::NothingToMigrate
    } else {
        Outcome::Migrated { keys: keys.len() }
    }
}

fn shared_files(home: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(home.join(".claude"))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| n.starts_with("muya-") && n.ends_with(".json"))
        .collect();
    v.sort();
    v
}

/// The Tauri webview's localStorage db with the most recent write (several origin
/// directories can exist, e.g. dev `localhost` and the bundled `tauri://localhost`).
fn find_localstorage(home: &Path) -> Option<PathBuf> {
    let root = home.join("Library/WebKit/com.staunch.muya/WebsiteData/Default");
    let mut best: Option<(std::time::SystemTime, PathBuf)> = None;
    for a in std::fs::read_dir(&root).ok()?.flatten() {
        for b in std::fs::read_dir(a.path()).into_iter().flatten().flatten() {
            let db = b.path().join("LocalStorage/localstorage.sqlite3");
            let Ok(meta) = std::fs::metadata(&db) else {
                continue;
            };
            let t = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
            if best.as_ref().is_none_or(|(bt, _)| t > *bt) {
                best = Some((t, db));
            }
        }
    }
    best.map(|(_, p)| p)
}

fn read_localstorage(db: &Path) -> Result<BTreeMap<String, String>, String> {
    // Work on a copy: the original (and its -wal/-shm) must stay byte-identical.
    let tmp = tempfile::tempdir().map_err(|e| e.to_string())?;
    let copy = tmp.path().join("ls.sqlite3");
    std::fs::copy(db, &copy).map_err(|e| format!("copy db: {e}"))?;
    for suffix in ["-wal", "-shm"] {
        let mut src = db.as_os_str().to_owned();
        src.push(suffix);
        let mut dst = copy.as_os_str().to_owned();
        dst.push(suffix);
        if Path::new(&src).exists() {
            std::fs::copy(&src, &dst).map_err(|e| format!("copy {suffix}: {e}"))?;
        }
    }
    let out = Command::new(SQLITE3)
        .arg("-readonly")
        .arg(&copy)
        .arg("SELECT key, hex(value) FROM ItemTable")
        .output()
        .map_err(|e| format!("sqlite3: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "sqlite3 failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let mut keys = BTreeMap::new();
    for line in text.lines() {
        // `key|HEX` — hex never contains '|', keys might, so split from the right.
        let Some((key, hex)) = line.rsplit_once('|') else {
            continue;
        };
        if !KEY_PREFIXES.iter().any(|p| key.starts_with(p)) {
            continue;
        }
        if let Some(value) = decode_value(hex) {
            keys.insert(key.to_string(), value);
        }
    }
    Ok(keys)
}

fn unhex(hex: &str) -> Option<Vec<u8>> {
    if hex.len() % 2 != 0 {
        return None;
    }
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).ok())
        .collect()
}

/// WebKit stores localStorage values as UTF-16LE; some builds store pure-Latin1 strings as
/// single bytes, which shows up as an odd byte count.
fn decode_value(hex: &str) -> Option<String> {
    let bytes = unhex(hex)?;
    if bytes.len() % 2 == 0 {
        let units: Vec<u16> = bytes
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        String::from_utf16(&units).ok()
    } else {
        Some(bytes.iter().map(|&b| b as char).collect())
    }
}

fn write_private<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let dir = path.parent().ok_or("bad path")?;
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let bytes = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| e.to_string())?;
    f.write_all(&bytes).map_err(|e| e.to_string())?;
    f.sync_all().map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    fn utf16_hex(s: &str) -> String {
        s.encode_utf16()
            .flat_map(|u| u.to_le_bytes())
            .map(|b| format!("{b:02X}"))
            .collect()
    }

    /// Synthetic Tauri data set under `home` (never real user data): a WebKit localStorage db
    /// in WAL mode with UTF-16 values, plus shared `~/.claude/muya-*.json` files.
    pub(crate) fn build_tauri_fixture(home: &Path) {
        let ls = home
            .join("Library/WebKit/com.staunch.muya/WebsiteData/Default/hashA/hashB/LocalStorage");
        std::fs::create_dir_all(&ls).unwrap();
        let db = ls.join("localstorage.sqlite3");
        let rows = [
            (
                "apex.workspaces",
                r#"[{"path":"/work/demo","name":"demo"}]"#,
            ),
            ("apex.openTabs", r#"["tab-1","tab-2"]"#),
            ("apex.theme", "dark"),
            ("muya.autoSave", "1"),
            ("muya.gridLayout", r#"{"cols":2,"rows":1}"#),
            ("muya.terminal.fontSize", "14"),
            ("muya.unicode", "Türkçe ğüşiöç — 日本語 🙂"),
            ("unrelated.key", "must not be copied"),
        ];
        let mut sql = String::from(
            "PRAGMA journal_mode=WAL; CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB NOT NULL ON CONFLICT FAIL);",
        );
        for (k, v) in rows {
            sql.push_str(&format!(
                "INSERT INTO ItemTable VALUES('{k}', X'{}');",
                utf16_hex(v)
            ));
        }
        let st = Command::new(SQLITE3).arg(&db).arg(sql).output().unwrap();
        assert!(
            st.status.success(),
            "{}",
            String::from_utf8_lossy(&st.stderr)
        );

        let claude = home.join(".claude");
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::write(
            claude.join("muya-schedules.json"),
            r#"[{"id":"j1","name":"nightly"}]"#,
        )
        .unwrap();
        std::fs::write(claude.join("muya-ssh-config.json"), r#"{"servers":[]}"#).unwrap();
        std::fs::write(
            claude.join("muya-vault-config.json"),
            r#"{"vault_path":null}"#,
        )
        .unwrap();
        std::fs::write(
            claude.join("muya-app.json"),
            r#"{"keepRunningInBackground":true}"#,
        )
        .unwrap();
    }

    /// sha256 of every regular file under `root` (relative path → digest), to prove "byte-identical".
    pub(crate) fn digest_tree(root: &Path) -> BTreeMap<String, String> {
        fn walk(dir: &Path, root: &Path, out: &mut BTreeMap<String, String>) {
            for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
                let p = e.path();
                if p.is_dir() {
                    walk(&p, root, out);
                } else if let Ok(b) = std::fs::read(&p) {
                    let d = Sha256::digest(&b);
                    out.insert(
                        p.strip_prefix(root).unwrap().display().to_string(),
                        d.iter().map(|b| format!("{b:02x}")).collect::<String>(),
                    );
                }
            }
        }
        let mut m = BTreeMap::new();
        walk(root, root, &mut m);
        m
    }

    #[test]
    fn migrates_prefixed_keys_and_leaves_tauri_files_byte_identical() {
        let home = tempfile::tempdir().unwrap();
        build_tauri_fixture(home.path());
        let before = digest_tree(home.path());
        assert!(
            before
                .keys()
                .any(|k| k.ends_with("localstorage.sqlite3-wal")),
            "fixture is WAL"
        );

        assert_eq!(run(home.path()), Outcome::Migrated { keys: 7 });

        let prefs = load_ui_prefs(home.path());
        assert_eq!(prefs.len(), 7);
        assert_eq!(prefs["apex.theme"], "dark");
        assert_eq!(prefs["apex.openTabs"], r#"["tab-1","tab-2"]"#);
        assert_eq!(prefs["muya.unicode"], "Türkçe ğüşiöç — 日本語 🙂");
        assert!(!prefs.contains_key("unrelated.key"));

        // Every file that existed before is untouched; the only new files are the native dir's.
        let after = digest_tree(home.path());
        for (path, digest) in &before {
            assert_eq!(after.get(path), Some(digest), "{path} changed");
        }
        for path in after.keys().filter(|p| !before.contains_key(*p)) {
            assert!(
                path.starts_with("Library/Application Support/com.staunch.muya/native/"),
                "stray file {path}"
            );
        }
    }

    #[test]
    fn second_run_is_a_noop_and_does_not_rewrite() {
        let home = tempfile::tempdir().unwrap();
        build_tauri_fixture(home.path());
        assert!(matches!(run(home.path()), Outcome::Migrated { .. }));
        let first = digest_tree(&native_store_dir(home.path()));
        assert_eq!(run(home.path()), Outcome::AlreadyDone);
        assert_eq!(digest_tree(&native_store_dir(home.path())), first);
    }

    #[test]
    fn marker_lists_shared_files_without_copying_them() {
        let home = tempfile::tempdir().unwrap();
        build_tauri_fixture(home.path());
        run(home.path());
        let m: Marker =
            serde_json::from_str(&std::fs::read_to_string(marker_path(home.path())).unwrap())
                .unwrap();
        assert_eq!(m.version, MIGRATION_VERSION);
        assert!(m.shared_files.contains(&"muya-schedules.json".to_string()));
        assert!(!native_store_dir(home.path())
            .join("muya-schedules.json")
            .exists());
    }

    /// Carry-over audit (docs/prd-native-beta-offer.md §4): a classic-style HOME, first Native launch, then
    /// what Native reads is what classic left. Workspaces/layout come through the one-way copy; schedules, the
    /// SSH list and the settings files are read in place, byte for byte.
    #[test]
    fn classic_data_is_visible_to_native_after_first_launch() {
        use crate::schedules::{JobInput, Schedule, ScheduleState};
        let home = tempfile::tempdir().unwrap();
        let claude = home.path().join(".claude");
        build_tauri_fixture(home.path());
        // Classic's own writers produce the shared files (same muya-core code, so the real on-disk format).
        let classic = ScheduleState::client_at(&claude);
        classic
            .save(JobInput {
                id: None,
                name: "nightly".into(),
                prompt: "summarise".into(),
                folder: home.path().to_string_lossy().into_owned(),
                schedule: Schedule::Interval { minutes: 30 },
                enabled: true,
                timeout_min: 5,
                bypass: false,
                agent: false,
                model: String::new(),
                effort: String::new(),
                chrome: false,
                target: None,
            })
            .unwrap();
        std::fs::write(
            claude.join("muya-ssh-config.json"),
            r#"{"version":1,"servers":[{"id":"s1","label":"build box","host":"10.0.0.5","port":22,"username":"ops","connectionType":"direct"}],"psmpProfiles":[]}"#,
        )
        .unwrap();
        std::fs::write(claude.join("muya-settings.json"), r#"{"debugLog":true}"#).unwrap();
        let shared_before: BTreeMap<_, _> = digest_tree(&claude);

        assert!(matches!(run(home.path()), Outcome::Migrated { .. }));

        // Workspaces / tabs / layout: copied to Native's own store.
        let prefs = load_ui_prefs(home.path());
        assert_eq!(prefs["apex.workspaces"], r#"[{"path":"/work/demo","name":"demo"}]"#);
        assert_eq!(prefs["muya.gridLayout"], r#"{"cols":2,"rows":1}"#);
        // Schedules: a fresh Native-side handle lists the job classic saved.
        let seen = ScheduleState::client_at(&claude).list().unwrap();
        assert_eq!(seen.jobs.len(), 1);
        // SSH list: Native's loader sees the server.
        let ssh_cfg = crate::ssh::load_from(&crate::ssh::config_path_under(home.path().to_str().unwrap()));
        assert_eq!(ssh_cfg.servers.len(), 1);
        assert_eq!(ssh_cfg.servers[0].host, "10.0.0.5");
        // Settings, vault config and the rest: untouched, and the marker lists them as shared.
        assert_eq!(digest_tree(&claude), shared_before, "migration must not touch ~/.claude");
        let marker: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(marker_path(home.path())).unwrap()).unwrap();
        let listed: Vec<&str> = marker["shared_files"].as_array().unwrap().iter().filter_map(|v| v.as_str()).collect();
        for f in ["muya-settings.json", "muya-app.json", "muya-ssh-config.json", "muya-vault-config.json"] {
            assert!(listed.contains(&f), "{f} not listed as shared");
        }
    }

    #[test]
    fn fresh_install_without_tauri_data_writes_marker_only() {
        let home = tempfile::tempdir().unwrap();
        assert_eq!(run(home.path()), Outcome::NothingToMigrate);
        assert!(marker_path(home.path()).exists());
        assert!(!ui_prefs_path(home.path()).exists());
        assert_eq!(run(home.path()), Outcome::AlreadyDone);
    }

    #[test]
    fn corrupt_database_is_reported_and_retried_later() {
        let home = tempfile::tempdir().unwrap();
        let ls = home
            .path()
            .join("Library/WebKit/com.staunch.muya/WebsiteData/Default/a/b/LocalStorage");
        std::fs::create_dir_all(&ls).unwrap();
        std::fs::write(
            ls.join("localstorage.sqlite3"),
            b"this is not a sqlite database at all",
        )
        .unwrap();
        let before = digest_tree(home.path());

        assert!(matches!(run(home.path()), Outcome::Unreadable(_)));
        assert!(
            !marker_path(home.path()).exists(),
            "no marker → retried next launch"
        );
        assert_eq!(digest_tree(home.path()), before, "nothing written");

        // The database heals (fixture replaces it) → next run migrates.
        std::fs::remove_dir_all(home.path().join("Library/WebKit")).unwrap();
        build_tauri_fixture(home.path());
        assert!(matches!(run(home.path()), Outcome::Migrated { .. }));
    }

    #[test]
    fn older_marker_version_reruns() {
        let home = tempfile::tempdir().unwrap();
        build_tauri_fixture(home.path());
        write_private(
            &marker_path(home.path()),
            &Marker {
                version: 0,
                keys: 0,
                shared_files: vec![],
            },
        )
        .unwrap();
        assert!(matches!(run(home.path()), Outcome::Migrated { .. }));
    }

    #[test]
    fn decode_handles_utf16_and_latin1_blobs() {
        assert_eq!(decode_value(&utf16_hex("hé")).as_deref(), Some("hé"));
        assert_eq!(decode_value("6869").as_deref(), Some("\u{6968}")); // 2 bytes = 1 UTF-16 unit
        assert_eq!(decode_value("686921").as_deref(), Some("hi!")); // odd length → Latin1
        assert_eq!(decode_value("zz"), None);
    }
}

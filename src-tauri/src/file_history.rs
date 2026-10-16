// Created by Claude — Classification: INTERNAL
//
// Local version history for files edited in Muya (docs/prd-file-versions.md).
// Each version is a full copy of the text under
// `~/.claude/muya-file-history/<sha256(path)>/<id>.txt`, listed in `index.json`.
// Nothing is written inside the user's project.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const MAX_VERSIONS: usize = 100;
const MAX_BYTES: usize = 2_000_000;
const KINDS: &[&str] = &["opened", "draft", "saved", "before-restore"];

static LOCK: Mutex<()> = Mutex::new(());

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FileVersion {
    pub id: String,
    /// Unix milliseconds.
    pub at: u64,
    pub size: usize,
    pub kind: String,
    #[serde(skip_serializing)]
    #[serde(default)]
    hash: String,
}

#[derive(Serialize, Deserialize, Default)]
struct Index {
    path: String,
    versions: Vec<StoredVersion>,
}

/// On-disk form keeps the hash (dedupe); the command result leaves it out.
#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct StoredVersion {
    id: String,
    at: u64,
    size: usize,
    kind: String,
    hash: String,
}

impl From<&StoredVersion> for FileVersion {
    fn from(v: &StoredVersion) -> Self {
        FileVersion {
            id: v.id.clone(),
            at: v.at,
            size: v.size,
            kind: v.kind.clone(),
            hash: v.hash.clone(),
        }
    }
}

fn base_dir() -> Option<PathBuf> {
    Some(dirs_next::home_dir()?.join(".claude/muya-file-history"))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn dir_for(base: &Path, path: &str) -> PathBuf {
    base.join(&hex(&Sha256::digest(path.as_bytes()))[..32])
}

/// Files that hold credentials are never copied out of their folder.
fn is_secret_like(path: &str) -> bool {
    let name = Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    name.starts_with(".env")
        || name.starts_with("id_")
        || [".pem", ".key", ".p8", ".p12", ".pfx", ".keystore"]
            .iter()
            .any(|e| name.ends_with(e))
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 32 && id.chars().all(|c| c.is_ascii_digit() || c == '-')
}

fn read_index(dir: &Path) -> Index {
    fs::read(dir.join("index.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

fn write_private(path: &Path, body: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let tmp = path.with_extension("tmp");
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(body)?;
    fs::rename(tmp, path)
}

fn ensure_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::create_dir_all(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn snapshot_in(
    base: &Path,
    path: &str,
    content: &str,
    kind: &str,
) -> Result<Option<FileVersion>, String> {
    if !Path::new(path).is_absolute() {
        return Err("path must be absolute".into());
    }
    if !KINDS.contains(&kind) {
        return Err("unknown kind".into());
    }
    if content.len() > MAX_BYTES || is_secret_like(path) {
        return Ok(None);
    }
    let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let dir = dir_for(base, path);
    let mut index = read_index(&dir);
    let hash = hex(&Sha256::digest(content.as_bytes()));
    if index.versions.last().is_some_and(|v| v.hash == hash) {
        return Ok(None);
    }
    ensure_dir(base)
        .and_then(|_| ensure_dir(&dir))
        .map_err(|e| format!("history dir: {e}"))?;
    let mut at = now_ms();
    if let Some(last) = index.versions.last() {
        at = at.max(last.at + 1); // ids stay unique and ordered
    }
    let v = StoredVersion {
        id: at.to_string(),
        at,
        size: content.len(),
        kind: kind.into(),
        hash,
    };
    write_private(&dir.join(format!("{}.txt", v.id)), content.as_bytes())
        .map_err(|e| format!("write version: {e}"))?;
    index.path = path.to_string();
    index.versions.push(v.clone());
    while index.versions.len() > MAX_VERSIONS {
        let old = index.versions.remove(0);
        let _ = fs::remove_file(dir.join(format!("{}.txt", old.id)));
    }
    let body = serde_json::to_vec(&index).map_err(|e| e.to_string())?;
    write_private(&dir.join("index.json"), &body).map_err(|e| format!("write index: {e}"))?;
    Ok(Some((&v).into()))
}

fn list_in(base: &Path, path: &str) -> Vec<FileVersion> {
    let mut v: Vec<FileVersion> = read_index(&dir_for(base, path))
        .versions
        .iter()
        .map(Into::into)
        .collect();
    v.reverse();
    v
}

fn read_in(base: &Path, path: &str, id: &str) -> Result<String, String> {
    if !valid_id(id) {
        return Err("invalid version id".into());
    }
    fs::read_to_string(dir_for(base, path).join(format!("{id}.txt")))
        .map_err(|e| format!("read version: {e}"))
}

/// Keep `content` as a version of `path` (unless it equals the newest one).
#[tauri::command(async)]
pub fn file_history_snapshot(
    path: String,
    content: String,
    kind: String,
) -> Result<Option<FileVersion>, String> {
    snapshot_in(&base_dir().ok_or("no home dir")?, &path, &content, &kind)
}

/// Versions of `path`, newest first.
#[tauri::command(async)]
pub fn file_history_list(path: String) -> Result<Vec<FileVersion>, String> {
    Ok(list_in(&base_dir().ok_or("no home dir")?, &path))
}

/// Text of one version.
#[tauri::command(async)]
pub fn file_history_read(path: String, id: String) -> Result<String, String> {
    read_in(&base_dir().ok_or("no home dir")?, &path, &id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_list_read_and_dedupe() {
        let d = tempfile::tempdir().unwrap();
        let b = d.path();
        let p = "/proj/a.ts";
        assert!(snapshot_in(b, p, "one", "opened").unwrap().is_some());
        assert!(
            snapshot_in(b, p, "one", "draft").unwrap().is_none(),
            "same text twice is one version"
        );
        assert!(snapshot_in(b, p, "two", "saved").unwrap().is_some());
        let l = list_in(b, p);
        assert_eq!(l.len(), 2);
        assert_eq!(
            (l[0].kind.as_str(), l[1].kind.as_str()),
            ("saved", "opened")
        );
        assert!(l[0].at > l[1].at);
        assert_eq!(read_in(b, p, &l[1].id).unwrap(), "one");
        assert!(list_in(b, "/proj/other.ts").is_empty());
    }

    #[test]
    fn skips_large_secret_and_rejects_bad_input() {
        let d = tempfile::tempdir().unwrap();
        let b = d.path();
        assert!(
            snapshot_in(b, "/p/big.txt", &"x".repeat(MAX_BYTES + 1), "saved")
                .unwrap()
                .is_none()
        );
        for s in [
            "/p/.env",
            "/p/.env.local",
            "/p/server.key",
            "/p/AuthKey.p8",
            "/home/u/.ssh/id_ed25519",
        ] {
            assert!(
                snapshot_in(b, s, "secret", "saved").unwrap().is_none(),
                "{s}"
            );
        }
        assert!(snapshot_in(b, "relative.txt", "x", "saved").is_err());
        assert!(snapshot_in(b, "/p/a", "x", "bogus").is_err());
        assert!(read_in(b, "/p/a", "../../etc/passwd").is_err());
    }

    #[test]
    fn keeps_the_newest_hundred_and_private_modes() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let b = d.path();
        let p = "/p/many.txt";
        for i in 0..(MAX_VERSIONS + 5) {
            snapshot_in(b, p, &format!("v{i}"), "draft").unwrap();
        }
        let l = list_in(b, p);
        assert_eq!(l.len(), MAX_VERSIONS);
        assert_eq!(
            read_in(b, p, &l[0].id).unwrap(),
            format!("v{}", MAX_VERSIONS + 4)
        );
        let dir = dir_for(b, p);
        assert_eq!(fs::read_dir(&dir).unwrap().count(), MAX_VERSIONS + 1); // + index.json
        assert_eq!(
            fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(dir.join("index.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}

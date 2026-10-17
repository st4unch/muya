//! Careful edits of the user's `~/.claude/settings.json` (Claude Code's own settings).
//!
//! Muya changes two things there, each only when the operator turned it on:
//! `statusLine` (docs/prd-statusline-user-settings.md) and `cleanupPeriodDays`
//! (docs/prd-session-housekeeping.md). Everything else in the file is the user's:
//!
//! - other keys keep their values and their order (serde_json `preserve_order`);
//! - a file that is not valid JSON is never overwritten — the edit fails instead;
//! - a symlinked settings file (dotfiles repos) is written through to its target;
//! - the write is atomic (temp file + rename in the same folder), mode kept;
//! - the first time Muya changes the file, a copy of the original is kept.

use serde_json::{Map, Value};
use std::fs;
use std::path::{Path, PathBuf};

/// `~/.claude/settings.json` under `home`.
pub(crate) fn path_under(home: &Path) -> PathBuf {
    home.join(".claude").join("settings.json")
}

/// The settings object, or an empty one when the file does not exist.
/// Err when it exists but is not a JSON object — then Muya must leave it alone.
pub(crate) fn read(path: &Path) -> Result<Map<String, Value>, String> {
    match fs::read_to_string(path) {
        Ok(text) if text.trim().is_empty() => Ok(Map::new()),
        Ok(text) => match serde_json::from_str::<Value>(&text) {
            Ok(Value::Object(m)) => Ok(m),
            Ok(_) => Err("~/.claude/settings.json is not a JSON object".into()),
            Err(e) => Err(format!("~/.claude/settings.json is not valid JSON ({e})")),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Map::new()),
        Err(e) => Err(format!("can't read ~/.claude/settings.json: {e}")),
    }
}

/// Apply `edit` to the settings and save them when it reports a change.
/// `backup`: where to keep a copy of the original file the first time (never overwritten).
/// Returns whether the file changed.
pub(crate) fn update(
    path: &Path,
    backup: Option<&Path>,
    edit: impl FnOnce(&mut Map<String, Value>) -> bool,
) -> Result<bool, String> {
    // One Muya edit at a time (the footer switch and the retention select can overlap).
    // Claude Code writes this file too; read→rename is kept as short as possible.
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut map = read(path)?;
    if !edit(&mut map) {
        return Ok(false);
    }
    // Write where the file really lives, so a symlink stays a symlink.
    let target = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if let Some(b) = backup {
        if !b.exists() && target.is_file() {
            if let Some(dir) = b.parent() {
                let _ = fs::create_dir_all(dir);
            }
            fs::copy(&target, b).map_err(|e| format!("backup failed: {e}"))?;
        }
    }
    let dir = target.parent().ok_or("bad settings path")?;
    fs::create_dir_all(dir).map_err(|e| format!("can't create {}: {e}", dir.display()))?;
    let mut bytes = serde_json::to_vec_pretty(&Value::Object(map)).map_err(|e| e.to_string())?;
    bytes.push(b'\n');
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = dir.join(format!(".settings.json.muya-{}-{n}.tmp", std::process::id()));
    fs::write(&tmp, &bytes).map_err(|e| format!("write failed: {e}"))?;
    if let Ok(meta) = fs::metadata(&target) {
        let _ = fs::set_permissions(&tmp, meta.permissions());
    }
    fs::rename(&tmp, &target).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        format!("save failed: {e}")
    })?;
    Ok(true)
}

// ── cleanupPeriodDays (Claude deletes sessions older than this at startup) ──────

/// Values Muya offers. Claude's own default is 30.
pub(crate) const CLEANUP_DAYS: [u32; 7] = [7, 14, 30, 60, 90, 180, 365];

fn home() -> Result<PathBuf, String> {
    dirs_next::home_dir().ok_or_else(|| "No home folder.".to_string())
}

fn backup_path(home: &Path) -> PathBuf {
    crate::statusline::stable_dir_under(home).join("settings.before-muya.json")
}

pub(crate) fn cleanup_days_at(path: &Path) -> Option<u64> {
    read(path).ok()?.get("cleanupPeriodDays")?.as_u64()
}

pub(crate) fn set_cleanup_days_at(
    path: &Path,
    backup: Option<&Path>,
    days: u32,
) -> Result<(), String> {
    if !CLEANUP_DAYS.contains(&days) {
        return Err(format!("unsupported value: {days} days"));
    }
    update(path, backup, |m| {
        let v = Value::from(days);
        if m.get("cleanupPeriodDays") == Some(&v) {
            return false;
        }
        m.insert("cleanupPeriodDays".into(), v);
        true
    })
    .map(|_| ())
}

/// Claude's `cleanupPeriodDays`: the saved value, or null when unset (Claude uses 30).
#[tauri::command]
pub fn claude_cleanup_days_get() -> Option<u64> {
    cleanup_days_at(&path_under(&home().ok()?))
}

#[tauri::command(async)]
pub fn claude_cleanup_days_set(days: u32) -> Result<(), String> {
    let h = home()?;
    set_cleanup_days_at(&path_under(&h), Some(&backup_path(&h)), days)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edits_keep_other_keys_and_their_order_and_back_up_once() {
        let d = tempfile::tempdir().unwrap();
        let p = path_under(d.path());
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        let original =
            r#"{"zeta":1,"model":"opus","permissions":{"allow":["Bash(ls)"]},"alpha":true}"#;
        fs::write(&p, original).unwrap();
        let b = d.path().join("bk/settings.before-muya.json");
        set_cleanup_days_at(&p, Some(&b), 60).unwrap();
        let text = fs::read_to_string(&p).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["cleanupPeriodDays"], 60);
        assert_eq!(v["permissions"]["allow"][0], "Bash(ls)");
        let keys: Vec<_> = v.as_object().unwrap().keys().cloned().collect();
        assert_eq!(
            keys,
            ["zeta", "model", "permissions", "alpha", "cleanupPeriodDays"]
        );
        assert_eq!(fs::read_to_string(&b).unwrap(), original, "original kept");
        set_cleanup_days_at(&p, Some(&b), 90).unwrap();
        assert_eq!(
            fs::read_to_string(&b).unwrap(),
            original,
            "backup never overwritten"
        );
        assert_eq!(cleanup_days_at(&p), Some(90));
    }

    #[test]
    fn missing_file_is_created_invalid_json_is_never_overwritten() {
        let d = tempfile::tempdir().unwrap();
        let p = path_under(d.path());
        set_cleanup_days_at(&p, None, 30).unwrap();
        assert_eq!(cleanup_days_at(&p), Some(30));
        fs::write(&p, "{ not json").unwrap();
        assert!(set_cleanup_days_at(&p, None, 7).is_err());
        assert_eq!(fs::read_to_string(&p).unwrap(), "{ not json");
        assert!(
            set_cleanup_days_at(&p, None, 5).is_err(),
            "only the offered values"
        );
    }

    #[test]
    fn a_symlinked_settings_file_stays_a_symlink() {
        let d = tempfile::tempdir().unwrap();
        let real = d.path().join("dotfiles/settings.json");
        fs::create_dir_all(real.parent().unwrap()).unwrap();
        fs::write(&real, r#"{"a":1}"#).unwrap();
        let p = path_under(d.path());
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&real, &p).unwrap();
        set_cleanup_days_at(&p, None, 14).unwrap();
        assert!(fs::symlink_metadata(&p).unwrap().file_type().is_symlink());
        let v: Value = serde_json::from_str(&fs::read_to_string(&real).unwrap()).unwrap();
        assert_eq!(v["cleanupPeriodDays"], 14);
        assert_eq!(v["a"], 1);
    }
}

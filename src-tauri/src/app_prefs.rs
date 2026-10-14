//! App-wide preferences the Rust side needs before the UI loads, kept in
//! `~/.claude/muya-app.json` (docs/prd-schedules-background.md).
//!
//! Its own file: `debuglog.rs` rewrites `muya-settings.json` whole, so a key put
//! there would be lost on the next debug-log change.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AppPrefs {
    /// The red close button hides the window and Muya keeps running (sessions and
    /// schedules stay alive). Off: closing the window quits, as before 4.2.
    #[serde(default = "yes")]
    pub keep_running_in_background: bool,
}

fn yes() -> bool {
    true
}

impl Default for AppPrefs {
    fn default() -> Self {
        AppPrefs {
            keep_running_in_background: true,
        }
    }
}

/// Read once at startup and on every change, so the close handler never touches disk.
static KEEP_RUNNING: AtomicBool = AtomicBool::new(true);

fn path_under(home: &Path) -> PathBuf {
    home.join(".claude").join("muya-app.json")
}

fn prefs_path() -> Option<PathBuf> {
    dirs_next::home_dir().map(|h| path_under(&h))
}

fn read_at(path: &Path) -> AppPrefs {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn write_at(path: &Path, prefs: &AppPrefs) -> Result<(), String> {
    let dir = path.parent().ok_or("bad path")?;
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(prefs).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, bytes).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

/// Apply the saved preferences. Called once from setup.
pub fn load() {
    let prefs = prefs_path().map(|p| read_at(&p)).unwrap_or_default();
    KEEP_RUNNING.store(prefs.keep_running_in_background, Ordering::Relaxed);
}

#[cfg(test)]
pub fn set_keep_running_for_test(on: bool) {
    KEEP_RUNNING.store(on, Ordering::Relaxed);
}

pub fn keep_running_in_background() -> bool {
    KEEP_RUNNING.load(Ordering::Relaxed)
}

#[tauri::command]
pub fn app_prefs_get() -> AppPrefs {
    prefs_path().map(|p| read_at(&p)).unwrap_or_default()
}

#[tauri::command]
pub fn app_prefs_set(prefs: AppPrefs) -> Result<(), String> {
    let path = prefs_path().ok_or("No home folder.")?;
    write_at(&path, &prefs)?;
    KEEP_RUNNING.store(prefs.keep_running_in_background, Ordering::Relaxed);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_or_old_file_keeps_running_and_a_save_round_trips() {
        let home = std::env::temp_dir().join(format!("muya-prefs-{}", std::process::id()));
        let path = path_under(&home);
        assert!(read_at(&path).keep_running_in_background, "no file → on");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "{}").unwrap();
        assert!(
            read_at(&path).keep_running_in_background,
            "unknown keys → on"
        );
        let off = AppPrefs {
            keep_running_in_background: false,
        };
        write_at(&path, &off).unwrap();
        assert_eq!(read_at(&path), off);
        let _ = std::fs::remove_dir_all(&home);
    }
}

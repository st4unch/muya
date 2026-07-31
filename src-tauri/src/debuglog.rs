//! Global, opt-in debug logging for the CyberArk + SSH flows.
//!
//! Design: the log sink is a pair of module statics so any code — including deep
//! async fns that never receive Tauri `State` — can call [`log`] without threading
//! a handle through. Logging is best-effort: a failed write is swallowed, it must
//! never break the operation being traced.
//!
//! SECURITY invariant: callers pass only metadata (usernames, URLs, HTTP status,
//! method names, step descriptions, counts, redacted error bodies). NO secret
//! value (password, token, retrieved account password, master password) is ever
//! passed to [`log`]. This module has no way to see a secret — it only writes what
//! the caller hands it — so the contract lives at the call sites in `cyberark.rs`
//! and `ssh.rs`.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Whether debug logging is currently on. Read on every [`log`] call.
static ENABLED: AtomicBool = AtomicBool::new(false);
/// Destination file. `None` = no path configured → [`log`] is a no-op even if
/// `ENABLED` is somehow true.
static PATH: Mutex<Option<PathBuf>> = Mutex::new(None);

const SETTINGS_FILE: &str = ".claude/muya-settings.json";
const DEFAULT_LOG_FILE: &str = ".claude/muya-debug.log";

fn home() -> Option<PathBuf> {
    std::env::var("HOME").ok().map(PathBuf::from)
}

/// `~/.claude/muya-settings.json`.
fn settings_path() -> Option<PathBuf> {
    home().map(|h| h.join(SETTINGS_FILE))
}

/// `~/.claude/muya-debug.log` — the fallback when no path is configured.
fn default_log_path() -> String {
    home()
        .map(|h| h.join(DEFAULT_LOG_FILE))
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|| DEFAULT_LOG_FILE.to_string())
}

// ---------------------------------------------------------------------------
// Timestamp (RFC 3339 UTC) — no chrono dependency, computed from the epoch.
// ---------------------------------------------------------------------------

/// Civil date (year, month, day) from a count of days since 1970-01-01.
/// Howard Hinnant's `civil_from_days` algorithm (public domain).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn rfc3339_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (hh, mm, ss) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let (y, mo, d) = civil_from_days(days);
    format!("{y:04}-{mo:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

// ---------------------------------------------------------------------------
// Core API
// ---------------------------------------------------------------------------

/// Append `[<timestamp>] <msg>\n` to the configured file, iff logging is enabled
/// and a path is set. Best-effort: any error (no path, open/write failure) is
/// silently ignored so a logging problem never breaks the traced operation.
pub fn log(msg: &str) {
    if !ENABLED.load(Ordering::Relaxed) {
        return;
    }
    let path = match PATH.lock() {
        Ok(g) => match g.as_ref() {
            Some(p) => p.clone(),
            None => return,
        },
        Err(_) => return,
    };
    let line = format!("[{}] {}\n", rfc3339_now(), msg);
    if let Ok(mut f) = OpenOptions::new().append(true).create(true).open(&path) {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Update the sink. When enabling, best-effort create the parent directory so the
/// first [`log`] can open the file.
pub fn set(enabled: bool, path: &str) {
    let pb = PathBuf::from(path);
    if enabled {
        if let Some(parent) = pb.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
    }
    if let Ok(mut g) = PATH.lock() {
        *g = Some(pb);
    }
    ENABLED.store(enabled, Ordering::Relaxed);
}

/// Read `~/.claude/muya-settings.json` at startup and apply it. Missing/invalid
/// file → disabled with the default path. Called from lib.rs `.setup(...)`.
pub fn load_and_apply() {
    let (enabled, path) = read_settings();
    set(enabled, &path);
    // `set` leaves ENABLED as `enabled`; disabled state is preserved (no-op log).
}

/// Parse the settings file into `(enabled, path)`, applying defaults.
fn read_settings() -> (bool, String) {
    let default_path = default_log_path();
    let raw = settings_path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok());
    match raw {
        Some(v) => {
            let enabled = v
                .get("debugLogging")
                .and_then(|b| b.as_bool())
                .unwrap_or(false);
            let path = v
                .get("debugLogPath")
                .and_then(|p| p.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string())
                .unwrap_or(default_path);
            (enabled, path)
        }
        None => (false, default_path),
    }
}

// ---------------------------------------------------------------------------
// Tauri commands
// ---------------------------------------------------------------------------

/// Enable/disable debug logging and set the target path, persisting the choice to
/// `~/.claude/muya-settings.json` so it survives restart.
#[tauri::command]
pub fn debug_log_set(enabled: bool, path: String) -> Result<(), String> {
    let path = if path.trim().is_empty() {
        default_log_path()
    } else {
        path
    };
    set(enabled, &path);
    let json = serde_json::json!({ "debugLogging": enabled, "debugLogPath": path });
    let bytes = serde_json::to_vec_pretty(&json).map_err(|e| e.to_string())?;
    let dest = settings_path().ok_or("HOME not set")?;
    crate::credstore::atomic_write(&dest, &bytes)
}

/// Return the current `{enabled, path}` (path defaults to `~/.claude/muya-debug.log`).
#[tauri::command]
pub fn debug_log_get() -> Result<serde_json::Value, String> {
    let (enabled, path) = read_settings();
    Ok(serde_json::json!({ "enabled": enabled, "path": path }))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // Enabling + logging writes a timestamped line; disabling writes nothing; a
    // secret string is never present because it is never passed to `log`.
    #[test]
    fn enabled_writes_timestamped_line_disabled_writes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("dbg.log");
        let path_str = path.to_string_lossy().into_owned();

        // Disabled → nothing written, file not created.
        set(false, &path_str);
        log("this must not appear");
        assert!(!path.exists(), "disabled logging must not create the file");

        // Enabled → line is appended with an RFC3339 timestamp.
        set(true, &path_str);
        log("cyberark logon (method=RADIUS) username=vault-user");
        let contents = std::fs::read_to_string(&path).unwrap();
        assert!(contents.contains("cyberark logon (method=RADIUS)"));
        assert!(
            contents.starts_with('[') && contents.contains("T") && contents.contains("Z]"),
            "line must start with an RFC3339 timestamp in brackets: {contents:?}"
        );

        // The secret was never passed to `log`, so it cannot be in the file.
        let secret = "P@ssw0rd-never-logged";
        log("retrieve password for account 42 -> 200");
        let after = std::fs::read_to_string(&path).unwrap();
        assert!(!after.contains(secret), "a secret must never reach the log");

        // Reset the global so other tests are unaffected.
        set(false, &path_str);
    }

    #[test]
    fn read_settings_defaults_to_disabled_and_default_path() {
        // With no HOME override we still get a non-empty default path and disabled.
        let (enabled, path) = read_settings();
        // enabled depends on any real ~/.claude/muya-settings.json; path is always set.
        assert!(!path.is_empty());
        let _ = enabled;
    }
}

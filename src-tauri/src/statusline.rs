//! Claude Code status-line capture (PRD `statusline-footer`).
//!
//! Claude Code hands its status-line command a JSON blob with the session's model,
//! context, cost, rate limits, … (https://code.claude.com/docs/en/statusline). Muya wants
//! that data in its footer, per tab, without touching the user's own settings:
//!
//! - Muya launches its `claude` sessions with `--settings <dir>/settings.json`, whose
//!   `statusLine` runs `<dir>/tap.sh`.
//! - Every PTY gets `MUYA_STATUS_FILE=<dir>/<pty-id>.json`; `tap.sh` copies stdin there,
//!   then runs the user's own status line (copied verbatim to `user-statusline.sh`) with
//!   the same JSON, so what the user sees in the terminal doesn't change.
//! - The frontend reads a tab's file with `statusline_get`.
//!
//! PC-agnostic: the dir is `<system temp>/muya-status-<pid>` (per instance, 0700), the
//! scripts are plain POSIX `sh` (no jq), and every path is quoted for `sh`.

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

const DIR_PREFIX: &str = "muya-status-";
const MAX_JSON_BYTES: u64 = 256 * 1024;

static DIR: OnceLock<Option<PathBuf>> = OnceLock::new();

const TAP_SH: &str = r#"#!/bin/sh
# Muya status-line tap: keep Claude's status JSON for Muya's footer, then show the
# user's own status line (if they have one) exactly as Claude would.
d=$(dirname "$0")
f="${MUYA_STATUS_FILE:-}"
if [ -n "$f" ] && cat > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null; then
  [ -f "$d/user-statusline.sh" ] && exec sh "$d/user-statusline.sh" < "$f"
  exit 0
fi
[ -f "$d/user-statusline.sh" ] && exec sh "$d/user-statusline.sh"
exit 0
"#;

/// This instance's status dir (created by `init`); None if it couldn't be created.
pub(crate) fn dir() -> Option<&'static Path> {
    DIR.get().and_then(|d| d.as_deref())
}

/// `MUYA_STATUS_FILE` for a PTY, when capture is set up.
pub(crate) fn status_file_for(pty_id: &str) -> Option<PathBuf> {
    dir().map(|d| d.join(format!("{pty_id}.json")))
}

/// Quote `s` for POSIX sh: '…' with each ' as '\''.
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// The settings JSON Muya passes to its `claude` sessions. Carries over the user's own
/// `padding` / `refreshInterval` so their status line behaves the same.
fn settings_json(dir: &Path, user: Option<&Value>) -> Value {
    let tap = dir.join("tap.sh");
    let mut sl = serde_json::json!({
        "type": "command",
        "command": format!("sh {}", sh_quote(&tap.to_string_lossy())),
    });
    if let Some(u) = user {
        for k in ["padding", "refreshInterval"] {
            if let Some(v) = u.get(k) {
                sl[k] = v.clone();
            }
        }
    }
    serde_json::json!({ "statusLine": sl })
}

/// The user's `statusLine` object from `~/.claude/settings.json`, if it is a command.
fn user_statusline(home: &Path) -> Option<Value> {
    let text = fs::read_to_string(home.join(".claude/settings.json")).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    let sl = v.get("statusLine")?.clone();
    let cmd = sl.get("command")?.as_str()?;
    (!cmd.trim().is_empty()).then_some(sl)
}

/// Write tap.sh, user-statusline.sh (when the user has one) and settings.json into `dir`.
fn write_files(dir: &Path, home: Option<&Path>) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::create_dir_all(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    fs::write(dir.join("tap.sh"), TAP_SH)?;
    let user = home.and_then(user_statusline);
    let user_script = dir.join("user-statusline.sh");
    match user
        .as_ref()
        .and_then(|u| u.get("command"))
        .and_then(Value::as_str)
    {
        Some(cmd) => fs::write(&user_script, format!("{cmd}\n"))?,
        None => {
            let _ = fs::remove_file(&user_script);
        }
    }
    let settings = settings_json(dir, user.as_ref());
    fs::write(
        dir.join("settings.json"),
        serde_json::to_vec_pretty(&settings).unwrap_or_default(),
    )?;
    Ok(())
}

/// Remove `muya-status-<pid>` dirs under `base` whose pid is no longer running.
fn sweep_stale(base: &Path, alive: impl Fn(u32) -> bool) {
    let Ok(entries) = fs::read_dir(base) else {
        return;
    };
    for e in entries.flatten() {
        let name = e.file_name();
        let Some(pid) = name
            .to_str()
            .and_then(|n| n.strip_prefix(DIR_PREFIX))
            .and_then(|p| p.parse::<u32>().ok())
        else {
            continue;
        };
        if pid != std::process::id() && !alive(pid) {
            let _ = fs::remove_dir_all(e.path());
        }
    }
}

/// Startup: sweep dead instances' dirs, create this one's. Failure only disables the feature.
pub(crate) fn init() {
    let base = std::env::temp_dir();
    sweep_stale(&base, crate::ssh::process_alive);
    let dir = base.join(format!("{DIR_PREFIX}{}", std::process::id()));
    let home = dirs_next::home_dir();
    let ok = write_files(&dir, home.as_deref()).is_ok();
    let _ = DIR.set(ok.then_some(dir));
}

/// Quit: drop this instance's dir.
pub(crate) fn cleanup() {
    if let Some(d) = dir() {
        let _ = fs::remove_dir_all(d);
    }
}

fn valid_pty_id(id: &str) -> bool {
    id.strip_prefix("pty-")
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

fn read_status(dir: &Path, pty_id: &str) -> Option<Value> {
    if !valid_pty_id(pty_id) {
        return None;
    }
    let path = dir.join(format!("{pty_id}.json"));
    let meta = fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() || meta.len() > MAX_JSON_BYTES {
        return None;
    }
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

/// Absolute path of the settings file to pass as `claude --settings`.
#[tauri::command]
pub fn statusline_settings_path() -> Option<String> {
    dir().map(|d| d.join("settings.json").to_string_lossy().into_owned())
}

/// The latest status JSON Claude produced in this PTY, or None.
#[tauri::command]
pub fn statusline_get(pty_id: String) -> Option<Value> {
    read_status(dir()?, &pty_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    #[test]
    fn quotes_paths_with_spaces_and_quotes() {
        assert_eq!(sh_quote("/a b/c"), "'/a b/c'");
        assert_eq!(sh_quote("/it's"), r"'/it'\''s'");
    }

    #[test]
    fn pty_ids_are_validated() {
        assert!(valid_pty_id("pty-12"));
        for bad in ["pty-", "pty-1/../x", "../pty-1", "pty-1a", "x"] {
            assert!(!valid_pty_id(bad), "{bad}");
        }
    }

    #[test]
    fn settings_carry_user_padding_and_refresh() {
        let user = serde_json::json!({"type":"command","command":"x","padding":2,"refreshInterval":5,"other":1});
        let s = settings_json(Path::new("/t d"), Some(&user));
        assert_eq!(s["statusLine"]["command"], "sh '/t d/tap.sh'");
        assert_eq!(s["statusLine"]["padding"], 2);
        assert_eq!(s["statusLine"]["refreshInterval"], 5);
        assert!(s["statusLine"].get("other").is_none());
    }

    /// End to end with a HOME containing a space: the tap stores the JSON and still
    /// prints the user's own status line from the same input.
    #[test]
    fn tap_stores_json_and_chains_the_user_statusline() {
        let home = tempfile::tempdir().unwrap();
        let home = home.path().join("my home");
        fs::create_dir_all(home.join(".claude")).unwrap();
        fs::write(
            home.join(".claude/settings.json"),
            r#"{"statusLine":{"type":"command","command":"read -r l; printf 'USER:%s' \"$l\""}}"#,
        )
        .unwrap();
        let dir = home.join("status dir");
        write_files(&dir, Some(&home)).unwrap();

        let settings: Value =
            serde_json::from_slice(&fs::read(dir.join("settings.json")).unwrap()).unwrap();
        let cmd = settings["statusLine"]["command"]
            .as_str()
            .unwrap()
            .to_string();
        let out_file = dir.join("pty-7.json");
        let json = r#"{"model":{"display_name":"Opus"}}"#;
        let mut child = Command::new("sh")
            .arg("-c")
            .arg(&cmd)
            .env("MUYA_STATUS_FILE", &out_file)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        use std::io::Write;
        child
            .stdin
            .take()
            .unwrap()
            .write_all(json.as_bytes())
            .unwrap();
        let out = child.wait_with_output().unwrap();
        assert_eq!(String::from_utf8_lossy(&out.stdout), format!("USER:{json}"));
        assert_eq!(
            read_status(&dir, "pty-7").unwrap()["model"]["display_name"],
            "Opus"
        );
    }

    #[test]
    fn tap_without_a_user_statusline_prints_nothing() {
        let home = tempfile::tempdir().unwrap();
        let dir = home.path().join("s");
        write_files(&dir, Some(home.path())).unwrap();
        assert!(!dir.join("user-statusline.sh").exists());
        let out = Command::new("sh")
            .arg(dir.join("tap.sh"))
            .env("MUYA_STATUS_FILE", dir.join("pty-1.json"))
            .stdin(fs::File::open(dir.join("settings.json")).unwrap())
            .output()
            .unwrap();
        assert!(out.stdout.is_empty());
        assert!(read_status(&dir, "pty-1").is_some());
    }

    #[test]
    fn oversized_or_bad_json_is_ignored() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("pty-1.json"), "not json").unwrap();
        assert!(read_status(d.path(), "pty-1").is_none());
        fs::write(
            d.path().join("pty-2.json"),
            vec![b' '; (MAX_JSON_BYTES + 1) as usize],
        )
        .unwrap();
        assert!(read_status(d.path(), "pty-2").is_none());
    }

    #[test]
    fn sweep_removes_only_dead_instances() {
        let base = tempfile::tempdir().unwrap();
        for n in ["muya-status-111", "muya-status-222", "other-333"] {
            fs::create_dir(base.path().join(n)).unwrap();
        }
        sweep_stale(base.path(), |pid| pid == 222);
        assert!(!base.path().join("muya-status-111").exists());
        assert!(base.path().join("muya-status-222").exists());
        assert!(base.path().join("other-333").exists());
    }
}

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
//!
//! Since 4.1.12 (docs/prd-statusline-user-settings.md) the tap normally lives at a stable
//! per-user place and `~/.claude/settings.json`'s own `statusLine` points at it, so no
//! `--settings` flag is needed and a hand-typed `claude` inside Muya feeds the footer too.
//! The per-launch `--settings` file above is only the fallback when that edit fails.

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

const DIR_PREFIX: &str = "muya-status-";
const MAX_JSON_BYTES: u64 = 256 * 1024;

static DIR: OnceLock<PathBuf> = OnceLock::new();
/// The tap is wired into `~/.claude/settings.json` — no `--settings` flag needed.
static IN_USER_SETTINGS: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// The operator turned the footer data off (app_prefs): no tap, no flag.
static DISABLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Serialises `ensure` so two launches never rebuild the dir at the same time.
static ENSURE: std::sync::Mutex<()> = std::sync::Mutex::new(());

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

/// This instance's status dir (set by `init`). It may not exist on disk: macOS clears
/// old files from the temp folder while the app keeps running — see `ensure`.
pub(crate) fn dir() -> Option<&'static Path> {
    DIR.get().map(PathBuf::as_path)
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
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    // Created 0700 in one step (no umask window). A leftover of the same name (pid
    // reuse, or a planted symlink — remove_dir_all removes the link, never its target)
    // is removed first; create() then fails if anything re-appears in between.
    if fs::symlink_metadata(dir).is_ok() {
        fs::remove_dir_all(dir)?;
    }
    fs::DirBuilder::new()
        .recursive(false)
        .mode(0o700)
        .create(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    write_private(&dir.join("tap.sh"), TAP_SH.as_bytes())?;
    let user = home.and_then(user_statusline);
    let user_script = dir.join("user-statusline.sh");
    match user
        .as_ref()
        .and_then(|u| u.get("command"))
        .and_then(Value::as_str)
    {
        Some(cmd) => write_private(&user_script, format!("{cmd}\n").as_bytes())?,
        None => {
            let _ = fs::remove_file(&user_script);
        }
    }
    let settings = settings_json(dir, user.as_ref());
    write_private(
        &dir.join("settings.json"),
        &serde_json::to_vec_pretty(&settings).unwrap_or_default(),
    )?;
    Ok(())
}

/// Write a new 0600 file (create_new: never follows or overwrites a planted link).
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    f.write_all(bytes)
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

/// Startup: sweep dead instances' dirs, create this one's (status files + fallback
/// settings), then wire the tap into the user's settings when the operator wants it.
/// Failure only disables the feature.
pub(crate) fn init() {
    let base = std::env::temp_dir();
    sweep_stale(&base, crate::ssh::process_alive);
    let dir = base.join(format!("{DIR_PREFIX}{}", std::process::id()));
    let home = dirs_next::home_dir();
    let _ = write_files(&dir, home.as_deref());
    let _ = DIR.set(dir);
    let _ = apply(crate::app_prefs::claude_status_in_footer());
}

// ── The tap in the user's own settings ─────────────────────────────────────────

/// `~/Library/Application Support/com.staunch.muya/statusline` under `home`.
pub(crate) fn stable_dir_under(home: &Path) -> PathBuf {
    home.join("Library/Application Support/com.staunch.muya/statusline")
}

/// The marker that tells Muya's own `statusLine` command apart from anyone else's.
const MARK: &str = "/com.staunch.muya/statusline/tap.sh";

fn is_ours(sl: &Value) -> bool {
    sl.get("command").and_then(Value::as_str).is_some_and(|c| c.contains(MARK))
}

/// What goes into `statusLine.command`: run Muya's tap while it exists, else the user's
/// own command — so removing Muya never leaves them without their status line.
fn wrapped_command(tap: &Path, user_cmd: Option<&str>) -> String {
    let fallback = user_cmd.map(str::trim).filter(|c| !c.is_empty()).unwrap_or(":");
    format!(
        "f={}; [ -f \"$f\" ] && exec sh \"$f\"; {fallback}",
        sh_quote(&tap.to_string_lossy())
    )
}

/// The user's own `statusLine`, as Muya found it before wrapping it (`null` = none).
fn saved_user_statusline(stable: &Path) -> Option<Option<Value>> {
    let v: Value = serde_json::from_slice(&fs::read(stable.join("user-statusline.json")).ok()?).ok()?;
    Some((!v.is_null()).then_some(v))
}

/// The user's command as embedded in Muya's wrapper (the part after the tap), so it is
/// never lost even when Muya's saved copy is gone (folder deleted, reinstall).
fn user_from_wrapper(sl: &Value) -> Option<Value> {
    let cmd = sl.get("command")?.as_str()?;
    let rest = cmd.split_once("exec sh \"$f\"; ")?.1.trim();
    if rest.is_empty() || rest == ":" {
        return None;
    }
    let mut u = sl.clone();
    u["command"] = Value::from(rest);
    Some(u)
}

/// Theirs, for a statusLine that is Muya's: the saved copy, else what the wrapper holds.
fn user_of_ours(stable: &Path, sl: &Value) -> Option<Value> {
    match saved_user_statusline(stable) {
        Some(saved) => saved,
        None => user_from_wrapper(sl),
    }
}

/// (Re)write the stable dir: tap.sh, the user's script and their saved statusLine.
fn write_stable(stable: &Path, user: Option<&Value>) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    if fs::symlink_metadata(stable).is_ok_and(|m| !m.is_dir()) {
        fs::remove_file(stable)?;
    }
    fs::DirBuilder::new().recursive(true).mode(0o700).create(stable)?;
    fs::set_permissions(stable, fs::Permissions::from_mode(0o700))?;
    for name in ["tap.sh", "user-statusline.sh", "user-statusline.json"] {
        let _ = fs::remove_file(stable.join(name));
    }
    write_private(&stable.join("tap.sh"), TAP_SH.as_bytes())?;
    if let Some(cmd) = user.and_then(|u| u.get("command")).and_then(Value::as_str) {
        write_private(&stable.join("user-statusline.sh"), format!("{cmd}\n").as_bytes())?;
    }
    let saved = user.cloned().unwrap_or(Value::Null);
    write_private(
        &stable.join("user-statusline.json"),
        &serde_json::to_vec_pretty(&saved).unwrap_or_default(),
    )
}

/// Point `statusLine` in `home`'s settings at Muya's tap (wrapping the user's own).
/// Running it again changes nothing. Err leaves the settings file as it was.
pub(crate) fn install_at(home: &Path) -> Result<(), String> {
    let settings = crate::claude_settings::path_under(home);
    let stable = stable_dir_under(home);
    let current = crate::claude_settings::read(&settings)?;
    let sl = current.get("statusLine").cloned();
    // Theirs: what Muya saved when it wrapped it, or what is there now if it isn't ours.
    let user = match &sl {
        Some(v) if is_ours(v) => user_of_ours(&stable, v),
        Some(v) if v.get("command").and_then(Value::as_str).is_some_and(|c| !c.trim().is_empty()) => Some(v.clone()),
        _ => None,
    };
    write_stable(&stable, user.as_ref()).map_err(|e| format!("can't write {}: {e}", stable.display()))?;
    let tap = stable.join("tap.sh");
    let user_cmd = user.as_ref().and_then(|u| u.get("command")).and_then(Value::as_str);
    // Keep the user's other statusLine keys (padding, refreshInterval, …).
    let mut wanted = user.clone().filter(Value::is_object).unwrap_or_else(|| serde_json::json!({}));
    wanted["type"] = Value::from("command");
    wanted["command"] = Value::from(wrapped_command(&tap, user_cmd));
    crate::claude_settings::update(&settings, Some(&stable.join("settings.before-muya.json")), |m| {
        if m.get("statusLine") == Some(&wanted) {
            return false;
        }
        m.insert("statusLine".into(), wanted);
        true
    })?;
    Ok(())
}

/// Put the user's own `statusLine` back (or remove Muya's when they had none).
pub(crate) fn uninstall_at(home: &Path) -> Result<(), String> {
    let settings = crate::claude_settings::path_under(home);
    let stable = stable_dir_under(home);
    crate::claude_settings::update(&settings, None, |m| {
        let Some(sl) = m.get("statusLine").filter(|v| is_ours(v)) else {
            return false; // not Muya's (any more): leave it
        };
        match &user_of_ours(&stable, sl) {
            Some(u) => m.insert("statusLine".into(), u.clone()),
            None => m.remove("statusLine"),
        };
        true
    })?;
    Ok(())
}

/// Turn the footer data on or off (startup and the Settings switch).
pub(crate) fn apply(on: bool) -> Result<(), String> {
    use std::sync::atomic::Ordering;
    DISABLED.store(!on, Ordering::Relaxed);
    let home = dirs_next::home_dir().ok_or("No home folder.")?;
    if on {
        let r = install_at(&home);
        IN_USER_SETTINGS.store(r.is_ok(), Ordering::Relaxed);
        if let Err(e) = &r {
            eprintln!("[muya] statusline: {e} — falling back to --settings per launch");
        }
        r
    } else {
        IN_USER_SETTINGS.store(false, Ordering::Relaxed);
        uninstall_at(&home)
    }
}

/// Make sure `dir` still holds settings.json and tap.sh, rebuilding it when they're
/// gone. Muya can run for days, and macOS removes old files from the temp folder in
/// the meantime; `claude --settings <missing file>` then refuses to start at all.
fn ensure(dir: &Path, home: Option<&Path>) -> bool {
    let intact = fs::symlink_metadata(dir).is_ok_and(|m| m.is_dir())
        && dir.join("settings.json").is_file()
        && dir.join("tap.sh").is_file();
    intact || write_files(dir, home).is_ok()
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

/// Absolute path of the settings file to pass as `claude --settings`, checked (and
/// rebuilt if needed) right before each launch. None when it can't be made: the
/// session then starts without the status tap rather than not at all.
#[tauri::command]
pub fn statusline_settings_path() -> Option<String> {
    use std::sync::atomic::Ordering;
    if DISABLED.load(Ordering::Relaxed) || IN_USER_SETTINGS.load(Ordering::Relaxed) {
        return None;
    }
    let d = dir()?;
    let _guard = ENSURE.lock().unwrap_or_else(|e| e.into_inner());
    ensure(d, dirs_next::home_dir().as_deref())
        .then(|| d.join("settings.json").to_string_lossy().into_owned())
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
    fn ensure_rebuilds_files_the_os_cleared() {
        let home = tempfile::tempdir().unwrap();
        let dir = home.path().join("s");
        // Nothing there yet, then only the dir left, then one file missing.
        assert!(ensure(&dir, Some(home.path())));
        assert!(dir.join("settings.json").is_file() && dir.join("tap.sh").is_file());
        fs::remove_file(dir.join("settings.json")).unwrap();
        fs::remove_file(dir.join("tap.sh")).unwrap();
        assert!(ensure(&dir, Some(home.path())));
        assert!(dir.join("settings.json").is_file() && dir.join("tap.sh").is_file());
        fs::remove_dir_all(&dir).unwrap();
        assert!(ensure(&dir, Some(home.path())));
        assert!(dir.join("settings.json").is_file());
        // An intact dir is left alone (a running session's status file survives).
        fs::write(dir.join("pty-3.json"), "{}").unwrap();
        assert!(ensure(&dir, Some(home.path())));
        assert!(dir.join("pty-3.json").exists());
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
    fn files_are_private_and_a_planted_symlink_is_never_followed() {
        use std::os::unix::fs::PermissionsExt;
        let home = tempfile::tempdir().unwrap();
        let dir = home.path().join("s");
        write_files(&dir, Some(home.path())).unwrap();
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&dir), 0o700);
        assert_eq!(mode(&dir.join("tap.sh")), 0o600);
        assert_eq!(mode(&dir.join("settings.json")), 0o600);
        // A planted symlink in place of the dir is not followed.
        let target = home.path().join("elsewhere");
        fs::create_dir(&target).unwrap();
        let link = home.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        write_files(&link, Some(home.path())).unwrap();
        assert!(
            !target.join("tap.sh").exists(),
            "never writes through the link"
        );
        assert!(
            fs::symlink_metadata(&link).unwrap().file_type().is_dir(),
            "a fresh real dir replaced it"
        );
        assert_eq!(mode(&link), 0o700);
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

    /// Run the installed `statusLine.command` the way Claude does: `sh -c`, JSON on stdin.
    fn run_statusline(home: &Path, json: &str, status_file: Option<&Path>) -> String {
        let v: Value = serde_json::from_str(
            &fs::read_to_string(crate::claude_settings::path_under(home)).unwrap(),
        )
        .unwrap();
        let cmd = v["statusLine"]["command"].as_str().unwrap().to_string();
        let mut c = Command::new("sh");
        c.arg("-c").arg(&cmd).env_remove("MUYA_STATUS_FILE");
        if let Some(f) = status_file {
            c.env("MUYA_STATUS_FILE", f);
        }
        let mut child = c
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        use std::io::Write;
        child.stdin.take().unwrap().write_all(json.as_bytes()).unwrap();
        String::from_utf8_lossy(&child.wait_with_output().unwrap().stdout).into_owned()
    }

    #[test]
    fn install_wraps_the_users_statusline_keeps_other_keys_and_is_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("my home");
        let settings = crate::claude_settings::path_under(&home);
        fs::create_dir_all(settings.parent().unwrap()).unwrap();
        let original = r#"{"model":"opus","statusLine":{"type":"command","command":"read -r l; printf 'USER:%s' \"$l\"","padding":1},"hooks":{}}"#;
        fs::write(&settings, original).unwrap();
        install_at(&home).unwrap();
        let after = fs::read_to_string(&settings).unwrap();
        let v: Value = serde_json::from_str(&after).unwrap();
        assert!(is_ours(&v["statusLine"]));
        assert_eq!(v["statusLine"]["padding"], 1);
        assert_eq!(v["model"], "opus");
        let keys: Vec<_> = v.as_object().unwrap().keys().cloned().collect();
        assert_eq!(keys, ["model", "statusLine", "hooks"]);
        let stable = stable_dir_under(&home);
        assert_eq!(fs::read_to_string(stable.join("settings.before-muya.json")).unwrap(), original);
        // Again: nothing changes (the user's command is not wrapped twice).
        install_at(&home).unwrap();
        assert_eq!(fs::read_to_string(&settings).unwrap(), after);

        let json = r#"{"model":{"display_name":"Opus"}}"#;
        // Inside Muya: the JSON is kept for the footer and the user's line still prints.
        let f = tmp.path().join("pty-9.json");
        assert_eq!(run_statusline(&home, json, Some(&f)), format!("USER:{json}"));
        assert!(fs::read_to_string(&f).unwrap().contains("Opus"));
        // Outside Muya: only the user's line.
        assert_eq!(run_statusline(&home, json, None), format!("USER:{json}"));
        // Muya gone (tap deleted): the user's line still prints.
        fs::remove_dir_all(&stable).unwrap();
        assert_eq!(run_statusline(&home, json, None), format!("USER:{json}"));
    }

    #[test]
    fn uninstall_puts_back_exactly_what_the_user_had() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let settings = crate::claude_settings::path_under(home);
        fs::create_dir_all(settings.parent().unwrap()).unwrap();
        let theirs = serde_json::json!({"type":"command","command":"echo mine","refreshInterval":5});
        fs::write(&settings, serde_json::json!({"a":1,"statusLine":theirs}).to_string()).unwrap();
        install_at(home).unwrap();
        uninstall_at(home).unwrap();
        let v: Value = serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
        assert_eq!(v["statusLine"], theirs);
        assert_eq!(v["a"], 1);

        // No status line of their own: Muya's is removed, nothing else touched.
        fs::write(&settings, r#"{"a":2}"#).unwrap();
        install_at(home).unwrap();
        assert!(run_statusline(home, "{}", None).is_empty());
        uninstall_at(home).unwrap();
        let v: Value = serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
        assert!(v.get("statusLine").is_none());
        assert_eq!(v["a"], 2);
    }

    #[test]
    fn a_later_status_line_of_their_own_gets_wrapped_and_a_broken_file_is_left_alone() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let settings = crate::claude_settings::path_under(home);
        fs::create_dir_all(settings.parent().unwrap()).unwrap();
        fs::write(&settings, "{}").unwrap();
        install_at(home).unwrap();
        // The user sets a new one by hand.
        fs::write(&settings, r#"{"statusLine":{"type":"command","command":"printf NEW"}}"#).unwrap();
        install_at(home).unwrap();
        assert_eq!(run_statusline(home, "{}", None), "NEW");
        uninstall_at(home).unwrap();
        let v: Value = serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
        assert_eq!(v["statusLine"]["command"], "printf NEW");

        fs::write(&settings, "{ broken").unwrap();
        assert!(install_at(home).is_err());
        assert_eq!(fs::read_to_string(&settings).unwrap(), "{ broken");
    }

    #[test]
    fn the_users_line_survives_when_muyas_saved_copy_is_gone() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let settings = crate::claude_settings::path_under(home);
        fs::create_dir_all(settings.parent().unwrap()).unwrap();
        fs::write(&settings, r#"{"statusLine":{"type":"command","command":"printf MINE","padding":2}}"#).unwrap();
        install_at(home).unwrap();
        fs::remove_dir_all(stable_dir_under(home)).unwrap(); // folder deleted / reinstall
        install_at(home).unwrap();
        assert_eq!(run_statusline(home, "{}", None), "MINE");
        fs::remove_dir_all(stable_dir_under(home)).unwrap();
        uninstall_at(home).unwrap();
        let v: Value = serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
        assert_eq!(v["statusLine"]["command"], "printf MINE");
        assert_eq!(v["statusLine"]["padding"], 2);
    }
}

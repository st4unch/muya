//! Per-terminal command history.
//!
//! Every terminal tab keeps its own zsh history, so ↑ in a tab shows that tab's
//! commands (also after Muya restarts and restores the tab), and the Sessions page
//! lists each terminal's history.
//!
//! macOS `/etc/zshrc` sets `HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history` on every start,
//! so an env var alone can't move the history. Instead the shell starts with
//! `ZDOTDIR=<base>/zdotdir`, whose four startup files each run the user's own file
//! (with `ZDOTDIR` pointing at the user's folder while it runs, the way VS Code's shell
//! integration does it), then point `HISTFILE` at `MUYA_HISTFILE`. `.zlogin` gives the
//! user their `ZDOTDIR` back, so nested shells behave as usual.
//!
//! Files: `<data dir>/com.staunch.muya/term-history/<key>.hist` (+ `<key>.json`:
//! name and folder at the last spawn). Directory 0700, files written by zsh/us.
//! Only zsh is covered; other shells keep their normal shared history.

use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

/// Only the end of a history file is read (about the last few thousand commands).
const TAIL_BYTES: u64 = 512 * 1024;
/// The Sessions page lists at most this many terminals (most recently used)…
const MAX_TERMINALS: usize = 100;
/// …with this many of each one's newest commands; "View all" and download fetch
/// one terminal in full.
const PREVIEW_ENTRIES: usize = 200;

const STARTUP_FILES: [&str; 4] = [".zshenv", ".zprofile", ".zshrc", ".zlogin"];

fn base_dir() -> Option<PathBuf> {
    dirs_next::data_dir().map(|d| d.join("com.staunch.muya").join("term-history"))
}

/// A tab key safe to use as a file name.
pub(crate) fn valid_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 128
        && !key.starts_with('.')
        && key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

fn startup_file(name: &str) -> String {
    let mut s = format!(
        "# Written by Muya: run your own {name}, then keep this terminal's history separate.\n\
         MUYA_WRAP_ZDOTDIR=$ZDOTDIR\n\
         ZDOTDIR=${{MUYA_USER_ZDOTDIR:-$HOME}}\n\
         [[ -r $ZDOTDIR/{name} ]] && . $ZDOTDIR/{name}\n\
         MUYA_USER_ZDOTDIR=$ZDOTDIR\n\
         ZDOTDIR=$MUYA_WRAP_ZDOTDIR\n"
    );
    if name == ".zshrc" || name == ".zlogin" {
        // zsh reads the history file right after .zshrc, so setting it here is what
        // loads this tab's past commands; .zlogin repeats it in case the user's own
        // .zlogin moved it.
        // INC_APPEND: write each command as it runs (macOS zsh otherwise saves only
        // when the shell exits, so a terminal killed with its tab never saved).
        // EXTENDED: a timestamp per command, for the Sessions page's date view.
        s.push_str("[[ -n $MUYA_HISTFILE ]] && { HISTFILE=$MUYA_HISTFILE; setopt INC_APPEND_HISTORY EXTENDED_HISTORY; }\n");
    }
    if name == ".zlogin" {
        s.push_str(
            "if [[ $MUYA_USER_ZDOTDIR == $HOME ]]; then unset ZDOTDIR; else export ZDOTDIR=$MUYA_USER_ZDOTDIR; fi\n\
             unset MUYA_WRAP_ZDOTDIR MUYA_USER_ZDOTDIR\n",
        );
    }
    s
}

fn write_private(path: &Path, body: &str) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let tmp = path.with_extension("tmp");
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(body.as_bytes())?;
    fs::rename(tmp, path)
}

fn ensure_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::create_dir_all(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
}

/// Write the zsh startup wrappers into `<base>/zdotdir`. Returns that folder.
fn ensure_wrappers(base: &Path) -> std::io::Result<PathBuf> {
    ensure_dir(base)?;
    let wrap = base.join("zdotdir");
    ensure_dir(&wrap)?;
    for name in STARTUP_FILES {
        let body = startup_file(name);
        let path = wrap.join(name);
        if fs::read_to_string(&path).ok().as_deref() != Some(body.as_str()) {
            write_private(&path, &body)?;
        }
    }
    Ok(wrap)
}

#[derive(Serialize, Deserialize, Default)]
struct Meta {
    name: String,
    cwd: String,
}

/// Env vars that give a zsh started for tab `key` its own history. Empty for other
/// shells, an invalid key, or when the folder can't be prepared (history then stays
/// shared, as before).
pub(crate) fn spawn_env(
    key: &str,
    name: Option<&str>,
    cwd: Option<&str>,
    shell: &str,
) -> Vec<(String, String)> {
    if !valid_key(key) || Path::new(shell).file_name().and_then(|s| s.to_str()) != Some("zsh") {
        return Vec::new();
    }
    let Some(base) = base_dir() else {
        return Vec::new();
    };
    spawn_env_in(&base, key, name, cwd)
}

fn spawn_env_in(
    base: &Path,
    key: &str,
    name: Option<&str>,
    cwd: Option<&str>,
) -> Vec<(String, String)> {
    let Ok(wrap) = ensure_wrappers(base) else {
        return Vec::new();
    };
    let meta = Meta {
        name: name.unwrap_or_default().to_string(),
        cwd: cwd.unwrap_or_default().to_string(),
    };
    if let Ok(json) = serde_json::to_string(&meta) {
        let _ = write_private(&base.join(format!("{key}.json")), &json);
    }
    let mut env = vec![
        ("ZDOTDIR".to_string(), wrap.to_string_lossy().into_owned()),
        (
            "MUYA_HISTFILE".to_string(),
            base.join(format!("{key}.hist"))
                .to_string_lossy()
                .into_owned(),
        ),
    ];
    // Muya itself started with a ZDOTDIR: the wrappers must read the user's files there.
    if let Ok(user) = std::env::var("ZDOTDIR") {
        if !user.is_empty() {
            env.push(("MUYA_USER_ZDOTDIR".to_string(), user));
        }
    }
    env
}

/// zsh "metafies" some bytes in its history file: 0x83 followed by (byte ^ 32).
fn unmetafy(raw: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(raw.len());
    let mut it = raw.iter();
    while let Some(&b) = it.next() {
        if b == 0x83 {
            if let Some(&n) = it.next() {
                out.push(n ^ 32);
            }
        } else {
            out.push(b);
        }
    }
    out
}

/// One command and, with EXTENDED_HISTORY, when it started (seconds since epoch).
#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct Entry {
    pub ts: Option<u64>,
    pub cmd: String,
}

/// Commands in a zsh history file, oldest first, with each one's timestamp when the
/// file has it. Handles EXTENDED_HISTORY lines (`: <time>:<dur>;cmd`) and multi-line
/// commands (lines ending in `\`).
pub(crate) fn parse_entries(raw: &[u8]) -> Vec<Entry> {
    let text = String::from_utf8_lossy(&unmetafy(raw)).into_owned();
    let mut out: Vec<Entry> = Vec::new();
    let mut pending: Option<Entry> = None;
    let mut push = |e: Entry| {
        if !e.cmd.trim().is_empty() {
            out.push(e);
        }
    };
    for line in text.lines() {
        let mut entry = match pending.take() {
            Some(mut p) => {
                p.cmd.push('\n');
                p.cmd.push_str(line);
                p
            }
            None => match line.strip_prefix(": ").and_then(|r| r.split_once(';')) {
                Some((stamp, cmd))
                    if stamp
                        .split(':')
                        .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit())) =>
                {
                    Entry {
                        ts: stamp.split(':').next().and_then(|t| t.parse().ok()),
                        cmd: cmd.to_string(),
                    }
                }
                _ => Entry {
                    ts: None,
                    cmd: line.to_string(),
                },
            },
        };
        if let Some(cont) = entry.cmd.strip_suffix('\\') {
            entry.cmd = cont.to_string();
            pending = Some(entry);
            continue;
        }
        push(entry);
    }
    if let Some(p) = pending {
        push(p);
    }
    out
}

fn read_tail(path: &Path) -> std::io::Result<Vec<u8>> {
    let mut f = fs::File::open(path)?;
    let len = f.metadata()?.len();
    let start = len.saturating_sub(TAIL_BYTES);
    f.seek(SeekFrom::Start(start))?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf)?;
    if start > 0 {
        // Started mid-file: drop the partial first line.
        if let Some(i) = buf.iter().position(|&b| b == b'\n') {
            buf.drain(..=i);
        }
    }
    Ok(buf)
}

/// One terminal's commands with timestamps, for the Sessions page's date view.
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct TermEntries {
    pub key: String,
    pub name: String,
    pub cwd: String,
    /// Last write, ms since epoch.
    pub updated_ms: u64,
    /// Commands in the part of the file that was read (may exceed `entries.len()`).
    pub total: usize,
    /// Oldest first; only the newest ones when the list was capped.
    pub entries: Vec<Entry>,
}

/// `<key>.hist` files, most recently written first. Only metadata is read here, so
/// terminals beyond the cap are never opened.
fn hist_files(base: &Path) -> Vec<(String, PathBuf, u64)> {
    let Ok(rd) = fs::read_dir(base) else {
        return Vec::new();
    };
    let mut out: Vec<(String, PathBuf, u64)> = rd
        .flatten()
        .filter_map(|e| {
            let path = e.path();
            if path.extension().and_then(|s| s.to_str()) != Some("hist") {
                return None;
            }
            let key = path.file_stem()?.to_str()?.to_string();
            if !valid_key(&key) {
                return None;
            }
            let mtime = e
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_millis() as u64);
            Some((key, path, mtime))
        })
        .collect();
    out.sort_by(|a, b| b.2.cmp(&a.2));
    out
}

/// Read and parse one history file (its tail), keeping the newest `limit` commands.
/// `None` when it can't be read or holds no commands.
fn load(
    base: &Path,
    key: String,
    path: &Path,
    updated_ms: u64,
    limit: Option<usize>,
) -> Option<TermEntries> {
    let mut entries = parse_entries(&read_tail(path).ok()?);
    if entries.is_empty() {
        return None;
    }
    let total = entries.len();
    if let Some(n) = limit {
        entries.drain(..total.saturating_sub(n));
    }
    let meta: Meta = fs::read_to_string(base.join(format!("{key}.json")))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    Some(TermEntries {
        key,
        name: meta.name,
        cwd: meta.cwd,
        updated_ms,
        total,
        entries,
    })
}

/// The `max_terms` most recently used terminals with at least one command, each with
/// its newest `per_term` commands.
fn entries_in(base: &Path, max_terms: usize, per_term: usize) -> Vec<TermEntries> {
    hist_files(base)
        .into_iter()
        .filter_map(|(key, path, mtime)| load(base, key, &path, mtime, Some(per_term)))
        .take(max_terms)
        .collect()
}

/// One terminal's whole (tail-read) history, for "View all" and download.
fn full_in(base: &Path, key: &str) -> Option<TermEntries> {
    let path = base.join(format!("{key}.hist"));
    let mtime = fs::metadata(&path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_millis() as u64);
    load(base, key.to_string(), &path, mtime, None)
}

/// The Sessions page's list: capped so that months of terminals stay cheap to send.
#[tauri::command]
pub async fn term_history_entries() -> Vec<TermEntries> {
    tokio::task::spawn_blocking(|| {
        base_dir()
            .map(|b| entries_in(&b, MAX_TERMINALS, PREVIEW_ENTRIES))
            .unwrap_or_default()
    })
    .await
    .unwrap_or_default()
}

/// One terminal in full ("View all", download).
#[tauri::command]
pub async fn term_history_full(key: String) -> Result<Option<TermEntries>, String> {
    if !valid_key(&key) {
        return Err("invalid terminal key".into());
    }
    tokio::task::spawn_blocking(move || base_dir().and_then(|b| full_in(&b, &key)))
        .await
        .map_err(|e| e.to_string())
}

/// Largest download accepted (a terminal's tail is at most TAIL_BYTES of history).
const MAX_EXPORT_BYTES: usize = 8 * 1024 * 1024;

/// Checks for a download destination: a plain `.txt` file (new, or an existing regular
/// file — never a symlink) in an existing folder outside Muya's history folder. The
/// folder is resolved to its real path first, so `..` or a symlinked parent can't
/// smuggle the write into the history folder (whose wrapper files zsh runs).
fn export_target(dest: &Path, base: Option<&Path>) -> Result<PathBuf, String> {
    if !dest.is_absolute() {
        return Err("destination must be an absolute path".into());
    }
    if dest
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
        != Some("txt")
    {
        return Err("destination must be a .txt file".into());
    }
    let name = dest.file_name().ok_or("destination has no file name")?;
    let parent = dest
        .parent()
        .ok_or("destination has no folder")?
        .canonicalize()
        .map_err(|e| format!("destination folder: {e}"))?;
    if let Some(base) = base {
        let base = base.canonicalize().unwrap_or_else(|_| base.to_path_buf());
        if parent.starts_with(&base) {
            return Err("refusing to write inside Muya's history folder".into());
        }
    }
    let target = parent.join(name);
    if let Ok(m) = fs::symlink_metadata(&target) {
        if !m.file_type().is_file() {
            return Err("destination exists and is not a regular file".into());
        }
    }
    Ok(target)
}

/// Save text the page built (a terminal's commands) to a .txt file the user picked
/// in the save dialog. Readable by the owner only, like the history itself.
#[tauri::command]
pub async fn term_history_export(dest: String, text: String) -> Result<(), String> {
    if text.len() > MAX_EXPORT_BYTES {
        return Err("history too large to export".into());
    }
    tokio::task::spawn_blocking(move || {
        let base = base_dir();
        let target = export_target(Path::new(&dest), base.as_deref())?;
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&target)
            .map_err(|e| e.to_string())?;
        f.write_all(text.as_bytes()).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Delete one terminal's history.
#[tauri::command]
pub fn term_history_delete(key: String) -> Result<(), String> {
    if !valid_key(&key) {
        return Err("invalid terminal key".into());
    }
    let base = base_dir().ok_or("no data folder")?;
    for ext in ["hist", "json"] {
        match fs::remove_file(base.join(format!("{key}.{ext}"))) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entries_keep_timestamps() {
        let raw = b": 1700000000:0;git status\nls\n: 1700000100:3;echo a \\\nb\n";
        assert_eq!(
            parse_entries(raw),
            vec![
                Entry {
                    ts: Some(1_700_000_000),
                    cmd: "git status".into()
                },
                Entry {
                    ts: None,
                    cmd: "ls".into()
                },
                Entry {
                    ts: Some(1_700_000_100),
                    cmd: "echo a \nb".into()
                },
            ]
        );
    }

    #[test]
    fn keys_must_be_plain_file_names() {
        assert!(valid_key("term-1712345678901"));
        assert!(valid_key("claude-17.a_b"));
        for bad in ["", "../x", "a/b", ".hidden", "a b", &"x".repeat(129)] {
            assert!(!valid_key(bad), "{bad:?}");
        }
    }

    #[test]
    fn parses_plain_extended_multiline_and_metafied() {
        let mut raw = b"ls -la\n: 1700000000:0;git status\necho one \\\ntwo\n\n".to_vec();
        // "é" is 0xC3 0xA9; zsh writes 0x83 before bytes it metafies (here 0xA9 as 0x89).
        raw.extend_from_slice(&[b'c', b'd', b' ', 0xC3, 0x83, 0x89, b'\n']);
        let cmds: Vec<String> = parse_entries(&raw).into_iter().map(|e| e.cmd).collect();
        assert_eq!(cmds, vec!["ls -la", "git status", "echo one \ntwo", "cd é"]);
    }

    #[test]
    fn spawn_env_writes_wrappers_meta_and_points_at_the_tab_file() {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().join("th");
        let env = spawn_env_in(&base, "term-1", Some("api"), Some("/w"));
        let get = |k: &str| env.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        assert_eq!(
            get("ZDOTDIR").unwrap(),
            base.join("zdotdir").to_string_lossy()
        );
        assert_eq!(
            get("MUYA_HISTFILE").unwrap(),
            base.join("term-1.hist").to_string_lossy()
        );
        for f in STARTUP_FILES {
            assert!(base.join("zdotdir").join(f).is_file(), "{f}");
        }
        let zlogin = fs::read_to_string(base.join("zdotdir/.zlogin")).unwrap();
        assert!(zlogin.contains("HISTFILE=$MUYA_HISTFILE") && zlogin.contains("unset ZDOTDIR"));
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&base).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let meta: Meta =
            serde_json::from_str(&fs::read_to_string(base.join("term-1.json")).unwrap()).unwrap();
        assert_eq!((meta.name.as_str(), meta.cwd.as_str()), ("api", "/w"));
    }

    #[test]
    fn list_skips_empty_orders_newest_first_and_caps() {
        let dir = tempfile::tempdir().unwrap();
        let b = dir.path();
        fs::write(b.join("old.hist"), "a\nb\n").unwrap();
        fs::write(b.join("empty.hist"), "\n").unwrap();
        fs::write(b.join("new.hist"), "x\ny\nz\n").unwrap();
        fs::write(b.join("new.json"), r#"{"name":"api","cwd":"/w"}"#).unwrap();
        let old = fs::File::options()
            .write(true)
            .open(b.join("old.hist"))
            .unwrap();
        old.set_modified(UNIX_EPOCH + std::time::Duration::from_secs(1_000))
            .unwrap();
        let keys = |l: &[TermEntries]| l.iter().map(|t| t.key.clone()).collect::<Vec<_>>();
        let cmds = |t: &TermEntries| t.entries.iter().map(|e| e.cmd.clone()).collect::<Vec<_>>();

        let list = entries_in(b, 10, 10);
        assert_eq!(keys(&list), vec!["new", "old"]);
        assert_eq!((list[0].name.as_str(), list[0].total), ("api", 3));

        // Capped: only the newest terminal, only its newest 2 commands, total kept.
        let capped = entries_in(b, 1, 2);
        assert_eq!(keys(&capped), vec!["new"]);
        assert_eq!(
            (cmds(&capped[0]), capped[0].total),
            (vec!["y".to_string(), "z".to_string()], 3)
        );

        // Full read of one terminal is not capped.
        assert_eq!(cmds(&full_in(b, "new").unwrap()), vec!["x", "y", "z"]);
        assert!(full_in(b, "missing").is_none());
    }

    #[test]
    fn export_target_rejects_unsafe_destinations() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let base = root.join("th");
        fs::create_dir_all(base.join("zdotdir")).unwrap();
        let out = root.join("out");
        fs::create_dir_all(&out).unwrap();
        let ok = export_target(&out.join("h.txt"), Some(&base)).unwrap();
        assert_eq!(ok, out.join("h.txt"));
        // Relative, not .txt, the history folder (also via ..), a missing folder.
        assert!(export_target(Path::new("h.txt"), Some(&base)).is_err());
        assert!(export_target(&out.join(".zshrc"), Some(&base)).is_err());
        assert!(export_target(&base.join("zdotdir/x.txt"), Some(&base)).is_err());
        assert!(export_target(&out.join("../th/zdotdir/x.txt"), Some(&base)).is_err());
        assert!(export_target(&root.join("nope/x.txt"), Some(&base)).is_err());
        // A symlinked folder pointing into the history folder, and a symlinked file.
        std::os::unix::fs::symlink(base.join("zdotdir"), out.join("link")).unwrap();
        assert!(export_target(&out.join("link/x.txt"), Some(&base)).is_err());
        std::os::unix::fs::symlink(root.join("elsewhere.txt"), out.join("s.txt")).unwrap();
        assert!(export_target(&out.join("s.txt"), Some(&base)).is_err());
    }

    /// Cost of opening the Terminal History tab after months of use:
    /// `cargo test --release --lib term_history::tests::bench_many -- --ignored --nocapture`
    #[test]
    #[ignore = "benchmark"]
    fn bench_many() {
        let dir = tempfile::tempdir().unwrap();
        let b = dir.path();
        let mut line = String::new();
        for i in 0..3000 {
            line.push_str(&format!(
                ": {}:0;git commit -m \"change number {i}\" && cargo test --lib\n",
                1_700_000_000 + i * 60
            ));
        }
        for t in 0..300 {
            fs::write(b.join(format!("terminal-{t}.hist")), &line).unwrap();
            fs::write(
                b.join(format!("terminal-{t}.json")),
                r#"{"name":"t","cwd":"/w"}"#,
            )
            .unwrap();
        }
        let t0 = std::time::Instant::now();
        let all = entries_in(b, MAX_TERMINALS, PREVIEW_ENTRIES);
        let took = t0.elapsed();
        let json = serde_json::to_vec(&all).unwrap();
        let n: usize = all.iter().map(|t| t.entries.len()).sum();
        println!(
            "BENCH terminals={} commands={n} time={took:?} json={} KB",
            all.len(),
            json.len() / 1024
        );
    }

    /// The wrappers in a real zsh: the user's .zshrc still runs, history goes to the
    /// tab file (not ~/.zsh_history), and ZDOTDIR is handed back.
    #[test]
    fn real_zsh_uses_the_tab_file() {
        if !Path::new("/bin/zsh").exists() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        fs::create_dir_all(&home).unwrap();
        fs::write(
            home.join(".zshrc"),
            "export FROMRC=yes\nHISTFILE=$HOME/.zsh_history\n",
        )
        .unwrap();
        let env = spawn_env_in(&dir.path().join("th"), "t1", None, None);
        let out = std::process::Command::new("/bin/zsh")
            .args([
                "-l",
                "-i",
                "-c",
                "print -r -- \"$FROMRC|$HISTFILE|${ZDOTDIR-unset}\"",
            ])
            .env_clear()
            .env("HOME", &home)
            .env("PATH", "/usr/bin:/bin")
            .envs(env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .output()
            .unwrap();
        let s = String::from_utf8_lossy(&out.stdout);
        let hist = dir.path().join("th/t1.hist");
        assert!(s.contains(&format!("yes|{}|unset", hist.display())), "{s}");
    }
}

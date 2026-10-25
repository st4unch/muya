//! Session history reader. Every past Claude Code session leaves a transcript at
//! `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. This scans those files so
//! the Sessions page can show full history, not just what the live daemon retains.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::UNIX_EPOCH;

use serde::Serialize;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionHistoryEntry {
    pub session_id: String,
    /// Real working directory (read from the transcript), best-effort.
    pub cwd: String,
    /// Last activity, ms epoch (transcript file mtime).
    pub last_modified: i64,
    /// When the last real user/assistant message was written, ms epoch. Unlike the
    /// mtime, a `claude --resume` does not move it (resume appends untimed records).
    pub last_message_at: Option<i64>,
    pub size_bytes: u64,
    /// The session's `<id>/` folder next to the transcript (subagents, tool output).
    pub extra_bytes: u64,
    /// Absolute transcript path — feed to `read_session_transcript`.
    pub path: String,
    /// The session's own name: the latest `/rename` (custom-title), else the agent
    /// name, else Claude's auto title. None when the transcript has none.
    pub name: Option<String>,
}

/// Name records, best first. Claude appends them as their own JSONL lines, which
/// always start with the type key, so a prefix check finds them without parsing the
/// (often megabyte-long) message lines.
const NAME_RECORDS: [(&[u8], &str); 3] = [
    (b"{\"type\":\"custom-title\"", "customTitle"),
    (b"{\"type\":\"agent-name\"", "agentName"),
    (b"{\"type\":\"ai-title\"", "aiTitle"),
];

#[derive(Clone, Default)]
struct NameScan {
    len: u64,
    mtime: i64,
    /// (rank in NAME_RECORDS, name) — lower rank wins; the later record wins a tie.
    best: Option<(usize, String)>,
}

/// Scan `path` from `from` for name records, folding them into `best`.
fn scan_names(
    path: &Path,
    from: u64,
    mut best: Option<(usize, String)>,
) -> Option<(usize, String)> {
    let Ok(mut f) = std::fs::File::open(path) else {
        return best;
    };
    if from > 0 && f.seek(SeekFrom::Start(from)).is_err() {
        return best;
    }
    let mut r = BufReader::with_capacity(1 << 20, f);
    let mut line = Vec::new();
    loop {
        line.clear();
        match r.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        for (rank, (prefix, field)) in NAME_RECORDS.iter().enumerate() {
            if !line.starts_with(prefix) {
                continue;
            }
            let name = serde_json::from_slice::<serde_json::Value>(&line)
                .ok()
                .and_then(|v| {
                    v.get(*field)
                        .and_then(|n| n.as_str())
                        .map(|n| n.trim().to_string())
                })
                .filter(|n| !n.is_empty());
            if let Some(name) = name {
                if best.as_ref().map_or(true, |(r, _)| rank <= *r) {
                    best = Some((rank, name));
                }
            }
            break;
        }
    }
    best
}

/// The session's name, cached per transcript. A transcript only ever grows, so when
/// it got longer only the new tail is read; anything else (shrunk, rewritten) rescans.
fn session_name(path: &Path, len: u64, mtime: i64) -> Option<String> {
    static CACHE: OnceLock<Mutex<HashMap<PathBuf, NameScan>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let prev = cache.lock().ok().and_then(|c| c.get(path).cloned());
    let scan = match prev {
        Some(p) if p.len == len && p.mtime == mtime => p,
        Some(p) if len > p.len => NameScan {
            len,
            mtime,
            best: scan_names(path, p.len, p.best),
        },
        _ => NameScan {
            len,
            mtime,
            best: scan_names(path, 0, None),
        },
    };
    let name = scan.best.as_ref().map(|(_, n)| n.clone());
    if let Ok(mut c) = cache.lock() {
        c.insert(path.to_path_buf(), scan);
    }
    name
}

/// Pull `"cwd":"..."` from the first chunk of a JSONL transcript (cheap — no full parse).
fn cwd_from_transcript(path: &Path) -> Option<String> {
    let mut f = std::fs::File::open(path).ok()?;
    let mut buf = vec![0u8; 8192];
    let n = f.read(&mut buf).ok()?;
    let head = String::from_utf8_lossy(&buf[..n]);
    let key = "\"cwd\":\"";
    let start = head.find(key)? + key.len();
    let rest = &head[start..];
    let end = rest.find('"')?;
    Some(rest[..end].replace("\\/", "/"))
}

/// A transcript's cwd never changes, so once found it is read once per file. Not found
/// yet (a brand-new session whose first lines carry no cwd) is not remembered.
fn cached_cwd(path: &Path) -> Option<String> {
    static CACHE: OnceLock<Mutex<HashMap<PathBuf, String>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(hit) = cache.lock().ok().and_then(|c| c.get(path).cloned()) {
        return Some(hit);
    }
    let cwd = cwd_from_transcript(path)?;
    if let Ok(mut c) = cache.lock() {
        c.insert(path.to_path_buf(), cwd.clone());
    }
    Some(cwd)
}

/// Bytes under `dir` (recursive, symlinks not followed). 0 when it doesn't exist.
fn dir_bytes(dir: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    entries
        .flatten()
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => dir_bytes(&e.path()),
            Ok(t) if t.is_file() => e.metadata().map(|m| m.len()).unwrap_or(0),
            _ => 0,
        })
        .sum()
}

/// Size of the session's `<id>/` folder. Re-measured when the transcript changed, and at
/// least every 5 minutes: a long subagent can fill the folder while the parent transcript
/// sits still waiting for it.
fn cached_extra_bytes(path: &Path, len: u64, mtime: i64) -> u64 {
    const FRESH: std::time::Duration = std::time::Duration::from_secs(300);
    static CACHE: OnceLock<Mutex<HashMap<PathBuf, (u64, i64, u64, std::time::Instant)>>> =
        OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some((l, m, b, at)) = cache.lock().ok().and_then(|c| c.get(path).copied()) {
        if l == len && m == mtime && at.elapsed() < FRESH {
            return b;
        }
    }
    let bytes = dir_bytes(&path.with_extension(""));
    if let Ok(mut c) = cache.lock() {
        c.insert(
            path.to_path_buf(),
            (len, mtime, bytes, std::time::Instant::now()),
        );
    }
    bytes
}

/// Trust boundary for any transcript path that came from the webview (or was derived
/// from webview-supplied cwd/id): only `.jsonl` files under ~/.claude/projects, after
/// resolving symlinks and `..`. Returns the canonical path.
pub(crate) fn checked_transcript_path(path: &Path) -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    checked_transcript_path_in(&Path::new(&home).join(".claude/projects"), path)
}

pub(crate) fn checked_transcript_path_in(projects: &Path, path: &Path) -> Result<PathBuf, String> {
    let projects_root = projects
        .canonicalize()
        .map_err(|e| format!("projects dir: {e}"))?;
    let canon = path.canonicalize().map_err(|e| format!("bad path: {e}"))?;
    if !canon.starts_with(&projects_root) {
        return Err("path is outside ~/.claude/projects".into());
    }
    if canon.extension().and_then(|e| e.to_str()) != Some("jsonl") {
        return Err("not a .jsonl transcript".into());
    }
    if !canon.is_file() {
        return Err("not a file".into());
    }
    Ok(canon)
}

/// Enumerate all past sessions from `~/.claude/projects/*/*.jsonl`, newest first.
#[tauri::command(async)]
pub fn list_session_history() -> Result<Vec<SessionHistoryEntry>, String> {
    let home = std::env::var_os("HOME").ok_or("HOME not set")?;
    list_in(&Path::new(&home).join(".claude/projects"))
}

/// Every `<root>/<project>/<id>.jsonl`, newest first.
fn list_in(projects: &Path) -> Result<Vec<SessionHistoryEntry>, String> {
    if !projects.is_dir() {
        return Ok(vec![]);
    }
    let mut out = Vec::new();
    let project_dirs = std::fs::read_dir(projects).map_err(|e| format!("read_dir: {e}"))?;
    for proj in project_dirs.filter_map(|r| r.ok()) {
        let pdir = proj.path();
        if !pdir.is_dir() {
            continue;
        }
        let files = match std::fs::read_dir(&pdir) {
            Ok(f) => f,
            Err(_) => continue,
        };
        for entry in files.filter_map(|r| r.ok()) {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let session_id = path
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();
            let meta = match entry.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };
            let last_modified = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            let cwd = cached_cwd(&path).unwrap_or_else(|| {
                // Fall back to the encoded directory name.
                pdir.file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default()
            });
            let name = session_name(&path, meta.len(), last_modified);
            out.push(SessionHistoryEntry {
                session_id,
                cwd,
                last_modified,
                last_message_at: cached_last_message_at(&path, meta.len(), last_modified),
                size_bytes: meta.len(),
                extra_bytes: cached_extra_bytes(&path, meta.len(), last_modified),
                path: path.to_string_lossy().into_owned(),
                name,
            });
        }
    }
    out.sort_by(|a, b| b.last_modified.cmp(&a.last_modified));
    Ok(out)
}

/// How much of a transcript's end is searched for its last message.
const LAST_MESSAGE_TAIL: u64 = 512 * 1024;

/// The `timestamp` of the last user/assistant line in the transcript's tail, ms epoch.
fn last_message_at(path: &Path, len: u64) -> Option<i64> {
    let mut f = std::fs::File::open(path).ok()?;
    let from = len.saturating_sub(LAST_MESSAGE_TAIL);
    f.seek(SeekFrom::Start(from)).ok()?;
    let mut buf = Vec::new();
    f.take(LAST_MESSAGE_TAIL).read_to_end(&mut buf).ok()?;
    // When we started mid-file, the first line is partial: skip it.
    let body = if from > 0 {
        let nl = buf.iter().position(|&b| b == b'\n')?;
        &buf[nl + 1..]
    } else {
        &buf[..]
    };
    body.split(|&b| b == b'\n').rev().find_map(|line| {
        if line.is_empty() {
            return None;
        }
        let v: serde_json::Value = serde_json::from_slice(line).ok()?;
        if !matches!(v.get("type")?.as_str()?, "user" | "assistant") {
            return None;
        }
        let ts = chrono::DateTime::parse_from_rfc3339(v.get("timestamp")?.as_str()?).ok()?;
        Some(ts.timestamp_millis())
    })
}

/// `last_message_at`, re-read only when the transcript's size or mtime changed.
fn cached_last_message_at(path: &Path, len: u64, mtime: i64) -> Option<i64> {
    static CACHE: OnceLock<Mutex<HashMap<PathBuf, (u64, i64, Option<i64>)>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(&(l, m, at)) = cache.lock().ok()?.get(path) {
        if l == len && m == mtime {
            return at;
        }
    }
    let at = last_message_at(path, len);
    if let Ok(mut c) = cache.lock() {
        c.insert(path.to_path_buf(), (len, mtime, at));
    }
    at
}

// ── Transcript reader ───────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptMessage {
    /// "user" | "assistant"
    pub role: String,
    pub text: String,
    /// ISO timestamp from the transcript line, if present.
    pub timestamp: Option<String>,
}

/// Render a message `content` value (string or block array) into plain text.
/// Tool activity is compressed to one-line markers so conversations stay readable.
fn content_to_text(content: &serde_json::Value) -> String {
    match content {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Array(blocks) => {
            let mut parts: Vec<String> = Vec::new();
            for b in blocks {
                match b.get("type").and_then(|t| t.as_str()) {
                    Some("text") => {
                        if let Some(t) = b.get("text").and_then(|t| t.as_str()) {
                            parts.push(t.to_string());
                        }
                    }
                    Some("tool_use") => {
                        let name = b.get("name").and_then(|n| n.as_str()).unwrap_or("tool");
                        parts.push(format!("🔧 [{name}]"));
                    }
                    // tool_result payloads are usually huge command output — skip.
                    _ => {}
                }
            }
            parts.join("\n")
        }
        _ => String::new(),
    }
}

/// One transcript line as a displayable message, or None (meta lines, tool dumps, …).
fn parse_message(line: &str) -> Option<TranscriptMessage> {
    const MAX_TEXT_CHARS: usize = 4000;
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    let kind = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
    if kind != "user" && kind != "assistant" {
        return None;
    }
    if v.get("isMeta").and_then(|m| m.as_bool()).unwrap_or(false) {
        return None;
    }
    let message = v.get("message")?;
    let role = message
        .get("role")
        .and_then(|r| r.as_str())
        .unwrap_or(kind)
        .to_string();
    let raw = message
        .get("content")
        .map(content_to_text)
        .unwrap_or_default();
    let text = raw.trim();
    if text.is_empty() {
        return None;
    }
    let mut text = text.to_string();
    if text.chars().count() > MAX_TEXT_CHARS {
        text = text.chars().take(MAX_TEXT_CHARS).collect::<String>() + "\n… [truncated]";
    }
    Some(TranscriptMessage {
        role,
        text,
        timestamp: v
            .get("timestamp")
            .and_then(|t| t.as_str())
            .map(String::from),
    })
}

/// The newest `cap` messages of a transcript, read from the END of the file: a window
/// of the last 4 MB, growing ×4 until it holds `cap` messages or the whole file. A
/// 200 MB marathon session no longer has to be read (and parsed) whole to show its end.
fn tail_messages(
    path: &Path,
    cap: usize,
    first_window: u64,
) -> Result<Vec<TranscriptMessage>, String> {
    let mut f = std::fs::File::open(path).map_err(|e| format!("read failed: {e}"))?;
    let len = f.metadata().map_err(|e| format!("read failed: {e}"))?.len();
    let mut window = first_window.max(1);
    loop {
        let start = len.saturating_sub(window);
        f.seek(SeekFrom::Start(start))
            .map_err(|e| format!("read failed: {e}"))?;
        let mut buf = Vec::with_capacity((len - start) as usize);
        (&mut f)
            .take(len - start)
            .read_to_end(&mut buf)
            .map_err(|e| format!("read failed: {e}"))?;
        // Mid-file, the first line is cut: start after its newline.
        let body = if start == 0 {
            &buf[..]
        } else {
            match buf.iter().position(|&b| b == b'\n') {
                Some(i) => &buf[i + 1..],
                None => &[][..],
            }
        };
        let text = String::from_utf8_lossy(body);
        let mut msgs: Vec<TranscriptMessage> = text.lines().filter_map(parse_message).collect();
        if msgs.len() >= cap || start == 0 {
            if msgs.len() > cap {
                msgs.drain(..msgs.len() - cap);
            }
            return Ok(msgs);
        }
        window = window.saturating_mul(4);
    }
}

/// Parse a Claude Code JSONL transcript into displayable messages (user/assistant
/// turns only; meta lines and tool-result dumps skipped). Returns the LAST
/// `max_messages` turns so multi-MB transcripts stay cheap to ship to the UI.
#[tauri::command(async)]
pub fn read_session_transcript(
    path: String,
    max_messages: Option<usize>,
) -> Result<Vec<TranscriptMessage>, String> {
    // Trust boundary: the webview supplies the path (a live or an archived transcript).
    let canon = checked_transcript_path(Path::new(&path))
        .or_else(|_| checked_archived_path(Path::new(&path)))?;
    tail_messages(&canon, max_messages.unwrap_or(500), 4 << 20)
}

// ── Archive / Trash / Restore (docs/prd-session-housekeeping.md) ───────────────

/// Where archived sessions go: same `<project>/<id>.jsonl` + `<id>/` layout as
/// `~/.claude/projects`, outside Claude's folder (so Claude's own cleanup never sees them).
fn archive_root_under(home: &Path) -> PathBuf {
    home.join("Library/Application Support/com.staunch.muya/session-archive")
}

fn home_dir() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME not set".into())
}

fn checked_archived_path(path: &Path) -> Result<PathBuf, String> {
    let root = archive_root_under(&home_dir()?);
    checked_transcript_path_in(&root, path)
}

/// A transcript written to in the last 10 minutes is treated as in use.
const IN_USE_MS: u128 = 10 * 60 * 1000;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HousekeepingResult {
    pub done: usize,
    /// (path, why) for every transcript left as it was.
    pub skipped: Vec<(String, String)>,
}

/// Why `canon` must not be moved, if anything: it is live, or was written just now.
fn in_use(canon: &Path, live_ids: &[String]) -> Option<String> {
    let id = canon.file_stem()?.to_string_lossy().into_owned();
    if live_ids.iter().any(|l| l == &id) {
        return Some("session is running".into());
    }
    let age = std::fs::metadata(canon)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.elapsed().ok())?;
    (age.as_millis() < IN_USE_MS).then(|| "used in the last 10 minutes".into())
}

/// Move `<from_root>/<project>/<id>.jsonl` and its `<id>/` folder to the same place under
/// `to_root` — both or neither: the folder goes first, and comes back if the transcript
/// can't follow.
fn move_session(canon: &Path, from_root: &Path, to_root: &Path) -> Result<(), String> {
    let rel = canon
        .strip_prefix(from_root)
        .map_err(|_| "outside its folder".to_string())?;
    let dest = to_root.join(rel);
    let side = canon.with_extension("");
    let side_dest = dest.with_extension("");
    let has_side = side.is_dir();
    if dest.exists() || (has_side && side_dest.exists()) {
        return Err("already there".into());
    }
    let dest_dir = dest.parent().ok_or("bad path")?;
    std::fs::create_dir_all(dest_dir).map_err(|e| e.to_string())?;
    if has_side {
        std::fs::rename(&side, &side_dest)
            .map_err(|e| format!("its folder can't be moved: {e}"))?;
    }
    if let Err(e) = std::fs::rename(canon, &dest) {
        if has_side {
            let _ = std::fs::rename(&side_dest, &side);
        }
        return Err(e.to_string());
    }
    Ok(())
}

fn archive_in(
    projects: &Path,
    archive: &Path,
    paths: &[String],
    live_ids: &[String],
) -> HousekeepingResult {
    let mut r = HousekeepingResult {
        done: 0,
        skipped: vec![],
    };
    let Ok(root) = projects.canonicalize() else {
        r.skipped = paths
            .iter()
            .map(|p| (p.clone(), "no projects folder".into()))
            .collect();
        return r;
    };
    for p in paths {
        let res =
            checked_transcript_path_in(projects, Path::new(p)).and_then(|canon| {
                match in_use(&canon, live_ids) {
                    Some(why) => Err(why),
                    None => move_session(&canon, &root, archive),
                }
            });
        match res {
            Ok(()) => r.done += 1,
            Err(e) => r.skipped.push((p.clone(), e)),
        }
    }
    r
}

fn restore_in(projects: &Path, archive: &Path, paths: &[String]) -> HousekeepingResult {
    let mut r = HousekeepingResult {
        done: 0,
        skipped: vec![],
    };
    let Ok(root) = archive.canonicalize() else {
        r.skipped = paths
            .iter()
            .map(|p| (p.clone(), "no archive".into()))
            .collect();
        return r;
    };
    for p in paths {
        let res = checked_transcript_path_in(archive, Path::new(p))
            .and_then(|canon| move_session(&canon, &root, projects));
        match res {
            Ok(()) => r.done += 1,
            Err(e) => r.skipped.push((p.clone(), e)),
        }
    }
    r
}

/// Put one file or folder in the macOS Trash (recoverable from Finder).
fn to_trash(path: &Path) -> Result<(), String> {
    use objc2_foundation::{NSFileManager, NSString, NSURL};
    let url = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
    let fm = NSFileManager::defaultManager();
    fm.trashItemAtURL_resultingItemURL_error(&url, None)
        .map_err(|e| e.localizedDescription().to_string())
}

/// Move sessions out of `~/.claude/projects` into Muya's archive (running or just-used ones are skipped).
#[tauri::command(async)]
pub fn archive_sessions(
    paths: Vec<String>,
    live_ids: Vec<String>,
) -> Result<HousekeepingResult, String> {
    let home = home_dir()?;
    Ok(archive_in(
        &home.join(".claude/projects"),
        &archive_root_under(&home),
        &paths,
        &live_ids,
    ))
}

#[tauri::command(async)]
pub fn restore_sessions(paths: Vec<String>) -> Result<HousekeepingResult, String> {
    let home = home_dir()?;
    Ok(restore_in(
        &home.join(".claude/projects"),
        &archive_root_under(&home),
        &paths,
    ))
}

/// Archived sessions, newest first (same shape as the history list).
#[tauri::command(async)]
pub fn list_archived_sessions() -> Result<Vec<SessionHistoryEntry>, String> {
    list_in(&archive_root_under(&home_dir()?))
}

/// Move sessions (live-history or archived) to the Trash, with their `<id>/` folders.
#[tauri::command(async)]
pub fn trash_sessions(
    paths: Vec<String>,
    live_ids: Vec<String>,
) -> Result<HousekeepingResult, String> {
    let mut r = HousekeepingResult {
        done: 0,
        skipped: vec![],
    };
    for p in &paths {
        let res = checked_transcript_path(Path::new(p))
            .and_then(|canon| match in_use(&canon, &live_ids) {
                Some(why) => Err(why),
                None => Ok(canon),
            })
            .or_else(|e| checked_archived_path(Path::new(p)).map_err(|_| e))
            .and_then(|canon| {
                // Folder first: if it can't go, the session stays whole.
                let side = canon.with_extension("");
                if side.is_dir() {
                    to_trash(&side).map_err(|e| format!("its folder can't be moved: {e}"))?;
                }
                to_trash(&canon)
            });
        match res {
            Ok(()) => r.done += 1,
            Err(e) => r.skipped.push((p.clone(), e)),
        }
    }
    Ok(r)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "machine-specific: reads ~/.claude"]
    fn names_live_scan_cost() {
        let t = std::time::Instant::now();
        let a = list_session_history().unwrap();
        let cold = t.elapsed();
        let t = std::time::Instant::now();
        let _ = list_session_history().unwrap();
        let warm = t.elapsed();
        let named: Vec<_> = a.iter().filter_map(|e| e.name.clone()).collect();
        println!(
            "{} transcripts, {} named, cold {cold:?}, warm {warm:?}, e.g. {:?}",
            a.len(),
            named.len(),
            &named[..named.len().min(6)]
        );
    }

    #[test]
    fn last_message_at_ignores_the_untimed_records_a_resume_appends() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("s.jsonl");
        let lines = [
            r#"{"type":"user","timestamp":"2026-10-23T10:00:00.000Z","message":{"role":"user","content":"hi"}}"#.to_string(),
            r#"{"parentUuid":"a","type":"assistant","timestamp":"2026-10-23T10:05:00.000Z","message":{"role":"assistant"}}"#.to_string(),
            "x".repeat(600_000), // a huge (here unparseable) line pushes the start out of the tail
            r#"{"type":"assistant","timestamp":"2026-10-23T11:00:00.000Z","message":{"role":"assistant"}}"#.to_string(),
            // what `claude --resume` appends: no timestamp, other types
            r#"{"type":"mode","mode":"normal"}"#.to_string(),
            r#"{"type":"bridge-session","id":"x"}"#.to_string(),
            r#"{"type":"cost-state","timestamp":"2026-10-25T23:09:00.000Z"}"#.to_string(),
        ];
        std::fs::write(&p, lines.join("\n") + "\n").unwrap();
        let len = std::fs::metadata(&p).unwrap().len();
        let want = chrono::DateTime::parse_from_rfc3339("2026-10-23T11:00:00.000Z")
            .unwrap()
            .timestamp_millis();
        assert_eq!(last_message_at(&p, len), Some(want));

        std::fs::write(&p, "{\"type\":\"mode\"}\n").unwrap();
        assert_eq!(
            last_message_at(&p, std::fs::metadata(&p).unwrap().len()),
            None
        );
    }

    #[test]
    fn session_name_prefers_rename_then_agent_then_ai_title_and_reads_only_new_tail() {
        use std::io::Write;
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("s.jsonl");
        let big = "x".repeat(200_000); // a long message line must not hide a record after it
        let write = |s: &str, append: bool| {
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .write(true)
                .append(append)
                .truncate(!append)
                .open(&p)
                .unwrap();
            f.write_all(s.as_bytes()).unwrap();
        };
        let meta = |p: &Path| {
            let m = std::fs::metadata(p).unwrap();
            (
                m.len(),
                m.modified()
                    .unwrap()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_millis() as i64,
            )
        };
        write(&format!("{{\"type\":\"user\",\"message\":\"{big}\"}}\n{{\"type\":\"ai-title\",\"aiTitle\":\"Auto title\"}}\n"), false);
        let (l, m) = meta(&p);
        assert_eq!(session_name(&p, l, m).as_deref(), Some("Auto title"));

        write(
            "{\"type\":\"agent-name\",\"agentName\":\"muya-all\"}\n",
            true,
        );
        let (l, m) = meta(&p);
        assert_eq!(session_name(&p, l, m).as_deref(), Some("muya-all"));

        // A later /rename wins; an ai-title after it does not override it.
        write("{\"type\":\"custom-title\",\"customTitle\":\"release v4.1\"}\n{\"type\":\"ai-title\",\"aiTitle\":\"Other\"}\n", true);
        let (l, m) = meta(&p);
        assert_eq!(session_name(&p, l, m).as_deref(), Some("release v4.1"));

        let none = dir.path().join("n.jsonl");
        std::fs::write(&none, "{\"type\":\"user\"}\n").unwrap();
        let (l, m) = meta(&none);
        assert_eq!(session_name(&none, l, m), None);
    }

    #[test]
    fn content_to_text_handles_shapes() {
        // Plain string content.
        assert_eq!(content_to_text(&serde_json::json!("hello")), "hello");
        // Block array: text + tool_use, tool_result skipped.
        let blocks = serde_json::json!([
            { "type": "text", "text": "answer" },
            { "type": "tool_use", "name": "Bash", "input": {} },
            { "type": "tool_result", "content": "huge output" }
        ]);
        assert_eq!(content_to_text(&blocks), "answer\n🔧 [Bash]");
        // Unknown shape → empty.
        assert_eq!(content_to_text(&serde_json::json!(42)), "");
    }

    #[test]
    fn transcript_rejects_outside_paths() {
        let err = read_session_transcript("/etc/passwd".into(), None);
        assert!(err.is_err());
        let err = read_session_transcript("/tmp/fake.jsonl".into(), None);
        assert!(err.is_err());
    }

    #[test]
    #[ignore = "machine-specific: reads ~/.claude"]
    fn transcript_smoke() {
        // Read the newest real transcript end-to-end and sanity-check the shape.
        let h = list_session_history().expect("history ok");
        let first = h.first().expect("at least one session");
        let msgs = read_session_transcript(first.path.clone(), Some(50)).expect("transcript ok");
        println!(
            "transcript {} → {} msgs",
            &first.session_id[..8],
            msgs.len()
        );
        assert!(!msgs.is_empty(), "expected displayable messages");
        for m in msgs.iter().take(3) {
            println!(
                "  [{}] {}…",
                m.role,
                m.text.chars().take(60).collect::<String>()
            );
        }
        assert!(msgs
            .iter()
            .all(|m| m.role == "user" || m.role == "assistant"));
    }

    #[test]
    #[ignore = "machine-specific: reads ~/.claude"]
    fn history_smoke() {
        let h = list_session_history().expect("ok");
        println!("history entries: {}", h.len());
        for e in h.iter().take(5) {
            println!(
                "  {} cwd={} size={}",
                &e.session_id[..e.session_id.len().min(8)],
                e.cwd,
                e.size_bytes
            );
        }
    }

    fn full_read(path: &Path, cap: usize) -> Vec<(String, String)> {
        let text = std::fs::read_to_string(path).unwrap();
        let mut m: Vec<_> = text
            .lines()
            .filter_map(parse_message)
            .map(|m| (m.role, m.text))
            .collect();
        if m.len() > cap {
            m.drain(..m.len() - cap);
        }
        m
    }

    #[test]
    fn tail_reader_matches_a_full_read_even_with_lines_longer_than_the_window() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("t.jsonl");
        let mut s = String::new();
        for i in 0..300 {
            let body = if i % 50 == 7 {
                "y".repeat(3000)
            } else {
                format!("msg {i}")
            };
            let role = if i % 2 == 0 { "user" } else { "assistant" };
            s.push_str(&format!(
                "{{\"type\":\"{role}\",\"message\":{{\"role\":\"{role}\",\"content\":\"{body}\"}}}}\n"
            ));
            s.push_str("{\"type\":\"progress\",\"data\":\"noise\"}\n");
        }
        std::fs::write(&p, &s).unwrap();
        for (cap, window) in [(10, 64), (120, 256), (500, 1000), (5, 1 << 20)] {
            let tail: Vec<_> = tail_messages(&p, cap, window)
                .unwrap()
                .into_iter()
                .map(|m| (m.role, m.text))
                .collect();
            assert_eq!(tail, full_read(&p, cap), "cap {cap} window {window}");
        }
    }

    fn fake_session(projects: &Path, project: &str, id: &str, age_secs: u64) -> PathBuf {
        let pdir = projects.join(project);
        std::fs::create_dir_all(pdir.join(id).join("subagents")).unwrap();
        std::fs::write(pdir.join(id).join("subagents/a.jsonl"), "x".repeat(100)).unwrap();
        let p = pdir.join(format!("{id}.jsonl"));
        std::fs::write(&p, "{\"type\":\"user\",\"cwd\":\"/w\"}\n").unwrap();
        let t = std::time::SystemTime::now() - std::time::Duration::from_secs(age_secs);
        std::fs::File::options()
            .write(true)
            .open(&p)
            .unwrap()
            .set_modified(t)
            .unwrap();
        p
    }

    #[test]
    fn archive_and_restore_move_the_transcript_and_its_folder_and_skip_what_is_in_use() {
        let d = tempfile::tempdir().unwrap();
        let projects = d.path().join("projects");
        let archive = d.path().join("archive");
        let old = fake_session(&projects, "-w", "old", 3 * 86400);
        let recent = fake_session(&projects, "-w", "recent", 60);
        let live = fake_session(&projects, "-w", "live", 3 * 86400);
        let outside = d.path().join("evil.jsonl");
        std::fs::write(&outside, "{}").unwrap();

        let listed = list_in(&projects).unwrap();
        let e = listed.iter().find(|e| e.session_id == "old").unwrap();
        assert_eq!(e.extra_bytes, 100);
        assert_eq!(e.cwd, "/w");

        let paths: Vec<String> = [&old, &recent, &live, &outside]
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        let r = archive_in(&projects, &archive, &paths, &["live".to_string()]);
        assert_eq!(r.done, 1);
        let why: Vec<_> = r.skipped.iter().map(|(_, w)| w.as_str()).collect();
        assert_eq!(why.len(), 3);
        assert!(
            why[0].contains("10 minutes")
                && why[1].contains("running")
                && why[2].contains("outside"),
            "{why:?}"
        );
        assert!(!old.exists() && !projects.join("-w/old").exists());
        let moved = archive.join("-w/old.jsonl");
        assert!(moved.is_file() && archive.join("-w/old/subagents/a.jsonl").is_file());
        assert_eq!(list_in(&archive).unwrap().len(), 1);

        let r = restore_in(&projects, &archive, &[moved.to_string_lossy().into_owned()]);
        assert_eq!(r.done, 1);
        assert!(old.is_file() && projects.join("-w/old/subagents/a.jsonl").is_file());
        assert!(!moved.exists());
    }

    #[test]
    fn a_session_moves_whole_or_not_at_all() {
        let d = tempfile::tempdir().unwrap();
        let projects = d.path().join("projects");
        let archive = d.path().join("archive");
        let p = fake_session(&projects, "-w", "s1", 3 * 86400);
        // A leftover folder of the same name already in the archive.
        std::fs::create_dir_all(archive.join("-w/s1")).unwrap();
        let r = archive_in(
            &projects,
            &archive,
            &[p.to_string_lossy().into_owned()],
            &[],
        );
        assert_eq!(r.done, 0);
        assert!(r.skipped[0].1.contains("already there"));
        assert!(p.is_file() && projects.join("-w/s1/subagents/a.jsonl").is_file());
    }

    #[test]
    fn a_cwd_not_written_yet_is_found_later() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("n.jsonl");
        std::fs::write(&p, "{\"type\":\"summary\"}\n").unwrap();
        assert_eq!(cached_cwd(&p), None);
        std::fs::write(
            &p,
            "{\"type\":\"summary\"}\n{\"type\":\"user\",\"cwd\":\"/w/x\"}\n",
        )
        .unwrap();
        assert_eq!(cached_cwd(&p).as_deref(), Some("/w/x"));
    }
}

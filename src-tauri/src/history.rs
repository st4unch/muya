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
    pub size_bytes: u64,
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
fn scan_names(path: &Path, from: u64, mut best: Option<(usize, String)>) -> Option<(usize, String)> {
    let Ok(mut f) = std::fs::File::open(path) else { return best };
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
                .and_then(|v| v.get(*field).and_then(|n| n.as_str()).map(|n| n.trim().to_string()))
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
        Some(p) if len > p.len => NameScan { len, mtime, best: scan_names(path, p.len, p.best) },
        _ => NameScan { len, mtime, best: scan_names(path, 0, None) },
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
    let projects = Path::new(&home).join(".claude/projects");
    if !projects.is_dir() {
        return Ok(vec![]);
    }
    let mut out = Vec::new();
    let project_dirs = std::fs::read_dir(&projects).map_err(|e| format!("read_dir: {e}"))?;
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
            let cwd = cwd_from_transcript(&path).unwrap_or_else(|| {
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
                size_bytes: meta.len(),
                path: path.to_string_lossy().into_owned(),
                name,
            });
        }
    }
    out.sort_by(|a, b| b.last_modified.cmp(&a.last_modified));
    Ok(out)
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

/// Parse a Claude Code JSONL transcript into displayable messages (user/assistant
/// turns only; meta lines and tool-result dumps skipped). Returns the LAST
/// `max_messages` turns so multi-MB transcripts stay cheap to ship to the UI.
#[tauri::command(async)]
pub fn read_session_transcript(
    path: String,
    max_messages: Option<usize>,
) -> Result<Vec<TranscriptMessage>, String> {
    // Trust boundary: the webview supplies the path.
    let canon = checked_transcript_path(Path::new(&path))?;

    const MAX_TEXT_CHARS: usize = 4000;
    let cap = max_messages.unwrap_or(500);

    let content = std::fs::read_to_string(&canon).map_err(|e| format!("read failed: {e}"))?;
    let mut msgs: Vec<TranscriptMessage> = Vec::new();
    for line in content.lines() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let kind = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
        if kind != "user" && kind != "assistant" {
            continue;
        }
        if v.get("isMeta").and_then(|m| m.as_bool()).unwrap_or(false) {
            continue;
        }
        let Some(message) = v.get("message") else {
            continue;
        };
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
            continue;
        }
        let mut text = text.to_string();
        if text.chars().count() > MAX_TEXT_CHARS {
            text = text.chars().take(MAX_TEXT_CHARS).collect::<String>() + "\n… [truncated]";
        }
        msgs.push(TranscriptMessage {
            role,
            text,
            timestamp: v
                .get("timestamp")
                .and_then(|t| t.as_str())
                .map(String::from),
        });
    }
    // Keep the newest `cap` turns (tail), preserving order.
    if msgs.len() > cap {
        msgs.drain(..msgs.len() - cap);
    }
    Ok(msgs)
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
        println!("{} transcripts, {} named, cold {cold:?}, warm {warm:?}, e.g. {:?}", a.len(), named.len(), &named[..named.len().min(6)]);
    }

    #[test]
    fn session_name_prefers_rename_then_agent_then_ai_title_and_reads_only_new_tail() {
        use std::io::Write;
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("s.jsonl");
        let big = "x".repeat(200_000); // a long message line must not hide a record after it
        let write = |s: &str, append: bool| {
            let mut f = std::fs::OpenOptions::new().create(true).write(true).append(append).truncate(!append).open(&p).unwrap();
            f.write_all(s.as_bytes()).unwrap();
        };
        let meta = |p: &Path| {
            let m = std::fs::metadata(p).unwrap();
            (m.len(), m.modified().unwrap().duration_since(UNIX_EPOCH).unwrap().as_millis() as i64)
        };
        write(&format!("{{\"type\":\"user\",\"message\":\"{big}\"}}\n{{\"type\":\"ai-title\",\"aiTitle\":\"Auto title\"}}\n"), false);
        let (l, m) = meta(&p);
        assert_eq!(session_name(&p, l, m).as_deref(), Some("Auto title"));

        write("{\"type\":\"agent-name\",\"agentName\":\"muya-all\"}\n", true);
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
}

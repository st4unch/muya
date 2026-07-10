//! Session history reader. Every past Claude Code session leaves a transcript at
//! `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. This scans those files so
//! the Sessions page can show full history, not just what the live daemon retains.

use std::io::Read;
use std::path::Path;
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
            out.push(SessionHistoryEntry {
                session_id,
                cwd,
                last_modified,
                size_bytes: meta.len(),
                path: path.to_string_lossy().into_owned(),
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
    // Trust boundary: the webview supplies the path. Only transcripts under
    // ~/.claude/projects may be read through this command.
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    let projects_root = Path::new(&home)
        .join(".claude/projects")
        .canonicalize()
        .map_err(|e| format!("projects dir: {e}"))?;
    let canon = Path::new(&path)
        .canonicalize()
        .map_err(|e| format!("bad path: {e}"))?;
    if !canon.starts_with(&projects_root) {
        return Err("path is outside ~/.claude/projects".into());
    }
    if canon.extension().and_then(|e| e.to_str()) != Some("jsonl") {
        return Err("not a .jsonl transcript".into());
    }

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

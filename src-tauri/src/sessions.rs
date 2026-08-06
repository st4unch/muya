//! Session transcript search + Markdown export (PRD `session-search-export`).
//!
//! Claude Code stores each session as JSONL at
//! `~/.claude/projects/<cwd-with-slashes-as-dashes>/<sessionId>.jsonl`. These commands
//! read those transcripts READ-ONLY: `search_session_contents` greps the visible
//! sessions' transcripts for a query (so a word from the conversation, not just the
//! name/cwd, surfaces the session), and `export_session_markdown` renders one
//! conversation to a Markdown file the operator picks. Both run on the blocking pool
//! (L31) so their file work never occupies a tokio worker thread.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Skip transcripts bigger than this when searching (keeps a keystroke cheap); export
/// has no cap since it's a one-off explicit action.
const SEARCH_FILE_CAP: u64 = 25 * 1024 * 1024;
/// Stop after this many matching sessions (search is for narrowing, not exhaustive).
const MAX_MATCHES: usize = 200;
const SNIPPET_RADIUS: usize = 60;

/// A session to look at: its id + the cwd it ran in (both from `AgentSession`).
#[derive(Debug, Deserialize)]
pub struct SessionRef {
    pub id: String,
    pub cwd: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionMatch {
    pub session_id: String,
    pub snippet: String,
    pub match_count: u32,
}

/// `~/.claude/projects/<cwd '/'→'-'>/<sessionId>.jsonl`.
fn transcript_path(cwd: &str, session_id: &str) -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    if cwd.is_empty() || session_id.is_empty() {
        return None;
    }
    let encoded = cwd.replace('/', "-");
    Some(
        Path::new(&home)
            .join(".claude/projects")
            .join(encoded)
            .join(format!("{session_id}.jsonl")),
    )
}

/// Pull the human-readable text out of one transcript JSON line (message.content is
/// either a plain string or an array of blocks; we keep `text` blocks and note tool
/// uses). Non-message lines (meta) yield empty.
fn line_text(v: &serde_json::Value) -> String {
    let content = match v.get("message").and_then(|m| m.get("content")) {
        Some(c) => c,
        None => return String::new(),
    };
    if let Some(s) = content.as_str() {
        return s.to_string();
    }
    let mut out = String::new();
    if let Some(arr) = content.as_array() {
        for block in arr {
            match block.get("type").and_then(|t| t.as_str()) {
                Some("text") => {
                    if let Some(t) = block.get("text").and_then(|t| t.as_str()) {
                        out.push_str(t);
                        out.push('\n');
                    }
                }
                Some("tool_use") => {
                    let name = block.get("name").and_then(|n| n.as_str()).unwrap_or("tool");
                    out.push_str(&format!("[tool: {name}]\n"));
                }
                Some("tool_result") => {
                    if let Some(t) = block.get("content").and_then(|c| c.as_str()) {
                        out.push_str(t);
                        out.push('\n');
                    } else if let Some(arr) = block.get("content").and_then(|c| c.as_array()) {
                        for b in arr {
                            if let Some(t) = b.get("text").and_then(|t| t.as_str()) {
                                out.push_str(t);
                                out.push('\n');
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    }
    out
}

fn make_snippet(text: &str, needle_lower: &str) -> Option<String> {
    let lower = text.to_lowercase();
    let pos = lower.find(needle_lower)?;
    let start = text[..pos]
        .char_indices()
        .rev()
        .nth(SNIPPET_RADIUS)
        .map(|(i, _)| i)
        .unwrap_or(0);
    let end = text[pos..]
        .char_indices()
        .nth(needle_lower.len() + SNIPPET_RADIUS)
        .map(|(i, _)| pos + i)
        .unwrap_or(text.len());
    let mut s = text[start..end].replace('\n', " ");
    s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if start > 0 {
        s.insert_str(0, "…");
    }
    if end < text.len() {
        s.push('…');
    }
    Some(s)
}

fn search_one(cwd: &str, id: &str, needle_lower: &str) -> Option<SessionMatch> {
    let path = transcript_path(cwd, id)?;
    let meta = std::fs::metadata(&path).ok()?;
    if meta.len() > SEARCH_FILE_CAP {
        return None;
    }
    let raw = std::fs::read_to_string(&path).ok()?;
    // Fast reject: if the query isn't anywhere in the file, skip the per-line parse.
    if !raw.to_lowercase().contains(needle_lower) {
        return None;
    }
    let mut count = 0u32;
    let mut snippet: Option<String> = None;
    for line in raw.lines() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let text = line_text(&v);
        if text.is_empty() {
            continue;
        }
        let lower = text.to_lowercase();
        if lower.contains(needle_lower) {
            count += lower.matches(needle_lower).count() as u32;
            if snippet.is_none() {
                snippet = make_snippet(&text, needle_lower);
            }
        }
    }
    if count == 0 {
        return None; // the raw hit was JSON structure, not conversation text
    }
    Some(SessionMatch {
        session_id: id.to_string(),
        snippet: snippet.unwrap_or_default(),
        match_count: count,
    })
}

/// Grep the given sessions' transcripts for `query`; returns the ones whose
/// CONVERSATION TEXT contains it, with a snippet. Blocking-pool'd (L31).
#[tauri::command(async)]
pub async fn search_session_contents(
    query: String,
    sessions: Vec<SessionRef>,
) -> Result<Vec<SessionMatch>, String> {
    let q = query.trim().to_lowercase();
    if q.len() < 2 {
        return Ok(vec![]);
    }
    tokio::task::spawn_blocking(move || {
        let mut out = Vec::new();
        for s in &sessions {
            if let Some(m) = search_one(&s.cwd, &s.id, &q) {
                out.push(m);
                if out.len() >= MAX_MATCHES {
                    break;
                }
            }
        }
        out
    })
    .await
    .map_err(|e| format!("search task failed: {e}"))
}

fn role_heading(v: &serde_json::Value) -> Option<&'static str> {
    match v.get("type").and_then(|t| t.as_str()) {
        Some("user") => Some("## 👤 User"),
        Some("assistant") => Some("## 🤖 Assistant"),
        _ => match v
            .get("message")
            .and_then(|m| m.get("role"))
            .and_then(|r| r.as_str())
        {
            Some("user") => Some("## 👤 User"),
            Some("assistant") => Some("## 🤖 Assistant"),
            _ => None,
        },
    }
}

/// Render a session transcript to Markdown text (pure, testable).
fn transcript_to_markdown(raw: &str, session_id: &str, cwd: &str) -> String {
    let mut md = format!("# Session `{session_id}`\n\n> Working directory: `{cwd}`\n\n---\n\n");
    for line in raw.lines() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let heading = match role_heading(&v) {
            Some(h) => h,
            None => continue, // meta line (custom-title, mode, summary, …)
        };
        let text = line_text(&v);
        if text.trim().is_empty() {
            continue;
        }
        md.push_str(heading);
        md.push_str("\n\n");
        md.push_str(text.trim_end());
        md.push_str("\n\n");
    }
    md
}

/// Export one session's conversation as Markdown to `dest` (a path the operator chose
/// via a save dialog). The transcript itself is only read. Blocking-pool'd (L31).
#[tauri::command(async)]
pub async fn export_session_markdown(
    session_id: String,
    cwd: String,
    dest: String,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let path = transcript_path(&cwd, &session_id)
            .ok_or_else(|| "could not resolve the session transcript path".to_string())?;
        if !path.exists() {
            return Err(format!("no transcript found for session {session_id}"));
        }
        // Never let `dest` be the transcript itself (would corrupt the source).
        if Path::new(&dest).canonicalize().ok() == path.canonicalize().ok() {
            return Err("refusing to overwrite the source transcript".to_string());
        }
        let raw = std::fs::read_to_string(&path).map_err(|e| format!("read transcript: {e}"))?;
        let md = transcript_to_markdown(&raw, &session_id, &cwd);
        std::fs::write(&dest, md).map_err(|e| format!("write markdown: {e}"))
    })
    .await
    .map_err(|e| format!("export task failed: {e}"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{"type":"custom-title","customTitle":"x","sessionId":"s1"}
{"type":"user","message":{"role":"user","content":"deploy the çş widget now"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Running the deploy."},{"type":"tool_use","name":"Bash","input":{"command":"deploy"}}]}}
{"type":"mode","mode":"x","sessionId":"s1"}"#;

    #[test]
    fn line_text_extracts_string_and_blocks() {
        let user: serde_json::Value = serde_json::from_str(SAMPLE.lines().nth(1).unwrap()).unwrap();
        assert!(line_text(&user).contains("çş widget"));
        let asst: serde_json::Value = serde_json::from_str(SAMPLE.lines().nth(2).unwrap()).unwrap();
        let t = line_text(&asst);
        assert!(t.contains("Running the deploy."));
        assert!(t.contains("[tool: Bash]"));
    }

    #[test]
    fn snippet_centers_on_match_and_marks_truncation() {
        let s = make_snippet("please deploy the çş widget now to prod", "çş").unwrap();
        assert!(s.to_lowercase().contains("çş"));
    }

    #[test]
    fn markdown_labels_turns_and_skips_meta() {
        let md = transcript_to_markdown(SAMPLE, "s1", "/tmp/proj");
        assert!(md.contains("# Session `s1`"));
        assert!(md.contains("## 👤 User"));
        assert!(md.contains("çş widget")); // UTF-8 preserved
        assert!(md.contains("## 🤖 Assistant"));
        assert!(md.contains("[tool: Bash]"));
        assert!(!md.contains("custom-title")); // meta lines skipped
    }

    #[test]
    fn transcript_path_encodes_cwd() {
        std::env::set_var("HOME", "/home/u");
        let p = transcript_path("/Users/x/proj", "abc").unwrap();
        assert!(p.ends_with("-Users-x-proj/abc.jsonl"), "{p:?}");
    }

    #[test]
    fn search_short_query_returns_empty() {
        // <2 chars → no work.
        let out = tokio_test_block(search_session_contents("a".into(), vec![])).unwrap();
        assert!(out.is_empty());
    }

    // tiny blocking helper so the async command can be unit-tested without a full runtime.
    fn tokio_test_block<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(f)
    }
}

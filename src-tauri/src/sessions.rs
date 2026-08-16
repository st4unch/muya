//! Session transcript search + Markdown export (PRD `session-search-export`).
//!
//! Claude Code stores each session as JSONL at
//! `~/.claude/projects/<cwd-with-slashes-as-dashes>/<sessionId>.jsonl`. These commands
//! read those transcripts READ-ONLY: `search_session_contents` greps the visible
//! sessions' transcripts for a query (so a word from the conversation, not just the
//! name/cwd, surfaces the session), and `export_session_markdown` renders one
//! conversation to a Markdown file the operator picks. Both run on the blocking pool
//! (L31) so their file work never occupies a tokio worker thread.

use std::io::BufRead;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Skip transcripts bigger than this when searching. Long marathon sessions routinely
/// pass 40 MB, and the whole point of content search is to find them — so the cap is
/// generous and we stream line-by-line (never load the whole file) to keep it cheap.
const SEARCH_FILE_CAP: u64 = 512 * 1024 * 1024;
/// Stop after this many matching sessions (search is for narrowing, not exhaustive).
const MAX_MATCHES: usize = 200;
const SNIPPET_RADIUS: usize = 60;

/// A session to look at: its id + the cwd it ran in (both from `AgentSession`).
/// `path` is the exact transcript path when the caller already knows it (history
/// rows do) — always preferred over re-deriving from `cwd`, because Claude Code's
/// project-dir encoding is not a simple `/`→`-` for every path (dots, etc.), so
/// derivation silently misses. Live sessions omit `path` and fall back to derivation.
#[derive(Debug, Deserialize)]
pub struct SessionRef {
    pub id: String,
    pub cwd: String,
    #[serde(default)]
    pub path: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionMatch {
    pub session_id: String,
    pub snippet: String,
    pub match_count: u32,
}

/// `~/.claude/projects/<cwd '/'→'-'>/<sessionId>.jsonl`.
pub(crate) fn transcript_path(cwd: &str, session_id: &str) -> Option<PathBuf> {
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
pub(crate) fn line_text(v: &serde_json::Value) -> String {
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

fn search_one(path: &Path, id: &str, needle_lower: &str) -> Option<SessionMatch> {
    let meta = std::fs::metadata(path).ok()?;
    if meta.len() > SEARCH_FILE_CAP {
        return None;
    }
    // Stream line-by-line so a 40 MB+ transcript never lands in memory whole. Each JSONL
    // line is one message; we only parse lines whose raw bytes already contain the needle
    // (cheap reject per line, replacing the old whole-file read_to_string).
    let file = std::fs::File::open(path).ok()?;
    let reader = std::io::BufReader::new(file);
    let mut count = 0u32;
    let mut snippet: Option<String> = None;
    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break, // non-UTF-8 / read error — stop scanning this file
        };
        // Per-line fast reject on the raw JSON bytes before the (costlier) parse.
        if !line.to_lowercase().contains(needle_lower) {
            continue;
        }
        let v: serde_json::Value = match serde_json::from_str(&line) {
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

/// Resolve a session's transcript path: the caller-supplied exact `path` if it exists,
/// otherwise derive `~/.claude/projects/<cwd '/'→'-'>/<id>.jsonl` from the cwd.
fn resolve_transcript(s: &SessionRef) -> Option<PathBuf> {
    if let Some(p) = &s.path {
        let pb = PathBuf::from(p);
        if pb.is_file() {
            return Some(pb);
        }
    }
    let derived = transcript_path(&s.cwd, &s.id)?;
    derived.is_file().then_some(derived)
}

/// Read the last `limit` conversation turns of a session's transcript as plain labelled
/// text (PRD `session-messaging`): lets an agent SEE what another session is doing
/// without messaging it. When `query` is set, only matching turns are kept (still the
/// last `limit` of them). Streams line-by-line; the transcript is never modified.
pub(crate) fn read_transcript_tail(
    cwd: &str,
    session_id: &str,
    limit: usize,
    query: Option<&str>,
) -> Result<String, String> {
    let path = transcript_path(cwd, session_id)
        .filter(|p| p.is_file())
        .ok_or_else(|| format!("no transcript found for session '{session_id}'"))?;
    let file = std::fs::File::open(&path).map_err(|e| format!("open transcript: {e}"))?;
    let reader = std::io::BufReader::new(file);
    let needle = query.map(|q| q.to_lowercase());
    let mut turns: std::collections::VecDeque<String> = std::collections::VecDeque::new();
    for line in reader.lines() {
        let Ok(line) = line else { break };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        let Some(heading) = role_heading(&v) else {
            continue; // meta line
        };
        let text = line_text(&v);
        if text.trim().is_empty() {
            continue;
        }
        if let Some(n) = &needle {
            if !text.to_lowercase().contains(n) {
                continue;
            }
        }
        // Keep each turn compact — an agent wants the gist, not a 40 MB dump.
        let mut body = text.trim().to_string();
        if body.chars().count() > 2000 {
            body = body.chars().take(2000).collect::<String>() + "…";
        }
        turns.push_back(format!("{heading}\n{body}"));
        while turns.len() > limit {
            turns.pop_front();
        }
    }
    if turns.is_empty() {
        return Ok(match query {
            Some(q) => format!("(no turns matching '{q}' in this session)"),
            None => "(this session has no conversation turns yet)".to_string(),
        });
    }
    Ok(turns.into_iter().collect::<Vec<_>>().join("\n\n"))
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
            let Some(path) = resolve_transcript(s) else {
                continue;
            };
            if let Some(m) = search_one(&path, &s.id, &q) {
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

pub(crate) fn role_heading(v: &serde_json::Value) -> Option<&'static str> {
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

    #[test]
    fn search_one_matches_content_via_explicit_path_and_streams() {
        // Real transcript on disk; matched by the CONVERSATION text, not JSON structure.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s1.jsonl");
        std::fs::write(
            &path,
            concat!(
                r#"{"type":"user","message":{"role":"user","content":"please deploy the widget"}}"#, "\n",
                r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"deploy done"}]}}"#, "\n",
                r#"{"type":"custom-title","title":"unrelated"}"#, "\n",
            ),
        )
        .unwrap();
        let m = search_one(&path, "s1", "deploy").expect("content match");
        assert_eq!(m.session_id, "s1");
        assert_eq!(m.match_count, 2); // "deploy" appears in two message turns
        assert!(m.snippet.to_lowercase().contains("deploy"));
    }

    #[test]
    fn search_one_rejects_when_needle_only_in_json_keys() {
        // "content"/"role" are JSON keys, never conversation text → no match.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s2.jsonl");
        std::fs::write(
            &path,
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello there\"}}\n",
        )
        .unwrap();
        assert!(search_one(&path, "s2", "role").is_none());
    }

    #[test]
    fn resolve_transcript_prefers_explicit_path_over_derivation() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("real.jsonl");
        std::fs::write(&path, "{}\n").unwrap();
        let s = SessionRef {
            id: "x".into(),
            cwd: "/nonexistent/derives/nowhere".into(),
            path: Some(path.to_string_lossy().into_owned()),
        };
        assert_eq!(resolve_transcript(&s).unwrap(), path);
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

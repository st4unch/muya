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
use std::sync::atomic::{AtomicBool, Ordering};

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

/// `~/.claude/projects/<cwd '/'→'-'>/<sessionId>.jsonl`. Claude names the folder after the
/// real path, so a symlinked cwd (macOS /tmp -> /private/tmp) is canonicalized first.
pub fn transcript_path(cwd: &str, session_id: &str) -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    transcript_path_in(Path::new(&home), cwd, session_id)
}

fn transcript_path_in(home: &Path, cwd: &str, session_id: &str) -> Option<PathBuf> {
    if cwd.is_empty() || session_id.is_empty() {
        return None;
    }
    let real = std::fs::canonicalize(cwd)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| cwd.to_string());
    Some(
        home.join(".claude/projects")
            .join(real.replace('/', "-"))
            .join(format!("{session_id}.jsonl")),
    )
}

/// Pull the human-readable text out of one transcript JSON line (message.content is
/// either a plain string or an array of blocks; we keep `text` blocks and note tool
/// uses). Non-message lines (meta) yield empty.
pub fn line_text(v: &serde_json::Value) -> String {
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

/// Build the `…match…` preview around the first case-insensitive hit.
///
/// The offsets here are the whole problem. The previous version searched a
/// `to_lowercase()` COPY and then sliced the ORIGINAL string with the index it
/// found. Unicode lowercasing is not length-preserving — 'İ' (U+0130, 2 bytes)
/// lowercases to "i̇" (U+0069 + U+0307, 3 bytes) — so after any such character
/// the two strings no longer agree on byte offsets, and slicing the original at
/// the copy's index lands mid-character. Rust panics rather than mangling:
/// `byte index 8340 is not a char boundary; it is inside 'ı'`. Turkish text
/// trips it immediately; the session-search poller panicked on the same skill
/// file roughly once an hour for weeks.
///
/// So lowercase character by character while remembering where each piece came
/// from, and translate the hit back to an ORIGINAL offset before slicing.
fn make_snippet(text: &str, needle_lower: &str) -> Option<String> {
    let mut lower = String::with_capacity(text.len());
    // (offset in `lower`, offset in `text`) at every character boundary.
    let mut offsets: Vec<(usize, usize)> = Vec::new();
    for (orig_i, ch) in text.char_indices() {
        offsets.push((lower.len(), orig_i));
        for lc in ch.to_lowercase() {
            lower.push(lc);
        }
    }
    // Sentinel, so a hit at the very end still maps to a real boundary.
    offsets.push((lower.len(), text.len()));

    let lpos = lower.find(needle_lower)?;
    // A match always begins at a character boundary, so the owning entry is the
    // last one at or before it.
    let idx = offsets
        .partition_point(|&(lo, _)| lo <= lpos)
        .saturating_sub(1);
    let pos = offsets[idx].1;

    let start = text[..pos]
        .char_indices()
        .rev()
        .nth(SNIPPET_RADIUS)
        .map(|(i, _)| i)
        .unwrap_or(0);
    // Characters, not bytes: `needle_lower.len()` is a BYTE count, so a non-ASCII
    // search term used to stretch the window well past its intended width.
    let needle_chars = needle_lower.chars().count();
    let end = text[pos..]
        .char_indices()
        .nth(needle_chars + SNIPPET_RADIUS)
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
    search_one_c(path, id, needle_lower, &AtomicBool::new(false))
}

/// [`search_one`] that gives up (None) as soon as `cancel` is set, also in the middle of a big file.
fn search_one_c(path: &Path, id: &str, needle_lower: &str, cancel: &AtomicBool) -> Option<SessionMatch> {
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
        if cancel.load(Ordering::Relaxed) {
            return None;
        }
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
/// otherwise derive `~/.claude/projects/<cwd '/'→'-'>/<id>.jsonl` from the cwd. Both
/// come from the webview, so either must pass the transcript trust boundary — without
/// it the content search grepped ANY readable file (a substring oracle on e.g. ~/.ssh).
fn resolve_transcript(s: &SessionRef) -> Option<PathBuf> {
    if let Some(p) = &s.path {
        // A live transcript or one in Muya's archive; nothing else the caller names is ever opened.
        if let Ok(pb) = crate::history::checked_transcript_path(Path::new(p))
            .or_else(|_| crate::history::checked_archived_path(Path::new(p)))
        {
            return Some(pb);
        }
    }
    let derived = transcript_path(&s.cwd, &s.id)?;
    crate::history::checked_transcript_path(&derived).ok()
}

/// Read the last `limit` conversation turns of a session's transcript as plain labelled
/// text (PRD `session-messaging`): lets an agent SEE what another session is doing
/// without messaging it. When `query` is set, only matching turns are kept (still the
/// last `limit` of them). Streams line-by-line; the transcript is never modified.
pub fn read_transcript_tail(
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

/// Blocking, cancellable content search for a daemon thread: the matches found so far when `cancel`
/// is set (the caller decides whether a partial result is still shown). Same rules as
/// [`search_session_contents`] (>= 2 characters, at most 200 matches, transcripts only).
pub fn search_sessions_blocking(query: &str, sessions: &[SessionRef], cancel: &AtomicBool) -> Vec<SessionMatch> {
    let q = query.trim().to_lowercase();
    let mut out = Vec::new();
    if q.chars().count() < 2 {
        return out;
    }
    for s in sessions {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        let Some(path) = resolve_transcript(s) else { continue };
        if let Some(m) = search_one_c(&path, &s.id, &q, cancel) {
            out.push(m);
            if out.len() >= MAX_MATCHES {
                break;
            }
        }
    }
    out
}

pub fn role_heading(v: &serde_json::Value) -> Option<&'static str> {
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
pub async fn export_session_markdown(
    session_id: String,
    cwd: String,
    dest: String,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || export_session_markdown_blocking(&session_id, &cwd, None, &dest, true))
        .await
        .map_err(|e| format!("export task failed: {e}"))?
}

/// [`export_session_markdown`] for a thread that may block. `path` is the exact transcript path when
/// the caller has it (history rows do); it must lie inside `~/.claude/projects` like for search.
pub fn export_session_markdown_blocking(session_id: &str, cwd: &str, path: Option<&str>, dest: &str, overwrite: bool) -> Result<(), String> {
    let r = SessionRef { id: session_id.to_string(), cwd: cwd.to_string(), path: path.map(str::to_string) };
    let path = resolve_transcript(&r).ok_or_else(|| "could not resolve the session transcript path".to_string())?;
    if !path.exists() {
        return Err(format!("no transcript found for session {session_id}"));
    }
    // Never let `dest` be the transcript itself (would corrupt the source).
    if Path::new(dest).canonicalize().ok() == path.canonicalize().ok() {
        return Err("refusing to overwrite the source transcript".to_string());
    }
    let raw = std::fs::read_to_string(&path).map_err(|e| format!("read transcript: {e}"))?;
    let md = transcript_to_markdown(&raw, session_id, cwd);
    write_export(Path::new(dest), md.as_bytes(), overwrite)
}

/// Writes the export. Without `overwrite` the file must not exist yet (`create_new` also refuses a symlink in its
/// place), so an export can never replace a file nobody agreed to replace; the app passes `overwrite` only after
/// its save panel asked the operator.
fn write_export(dest: &Path, bytes: &[u8], overwrite: bool) -> Result<(), String> {
    use std::io::Write;
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true);
    if overwrite {
        opts.create(true).truncate(true);
    } else {
        opts.create_new(true);
    }
    let mut f = opts.open(dest).map_err(|e| {
        if e.kind() == std::io::ErrorKind::AlreadyExists { format!("{} already exists", dest.display()) } else { format!("write markdown: {e}") }
    })?;
    f.write_all(bytes).map_err(|e| format!("write markdown: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn export_never_replaces_a_file_unless_told_to() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("out.md");
        write_export(&f, b"one", false).unwrap();
        assert_eq!(std::fs::read(&f).unwrap(), b"one");
        let err = write_export(&f, b"two", false).unwrap_err();
        assert!(err.contains("already exists"), "{err}");
        assert_eq!(std::fs::read(&f).unwrap(), b"one", "the file is untouched");
        write_export(&f, b"three", true).unwrap();
        assert_eq!(std::fs::read(&f).unwrap(), b"three");
        // A symlink in the way is not followed without overwrite.
        let target = dir.path().join("precious");
        std::fs::write(&target, b"keep").unwrap();
        let link = dir.path().join("link.md");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(write_export(&link, b"x", false).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"keep");
    }

    #[test]
    fn snippet_survives_turkish_text_whose_lowercase_is_longer() {
        // The exact crash: 'İ' is 2 bytes but lowercases to 3, so an index found
        // in the lowercased copy pointed one byte into the next character of the
        // ORIGINAL — here, straight into 'ı'. The old code sliced there and Rust
        // panicked: "byte index N is not a char boundary; it is inside 'ı'".
        let out = make_snippet("İıabc", "ıabc").expect("needle is present");
        assert!(out.contains("ıabc"), "{out}");

        // The shape that actually did it in the wild — a Turkish skill file.
        let text = "İmaj oluşturulurken Jenkins'te bir MCP sunucu imajını derliyoruz";
        let out = make_snippet(text, "imajını").expect("needle is present");
        assert!(out.contains("imajını"), "{out}");
    }

    #[test]
    fn snippet_still_finds_and_trims_ordinary_text() {
        // Non-vacuous: the ordinary path must keep working, case-insensitively,
        // with the original casing preserved in the output.
        let text = "The QUICK brown fox jumps over the lazy dog";
        let out = make_snippet(text, "quick").expect("needle is present");
        assert!(out.contains("QUICK"), "original casing must survive: {out}");

        // A needle that is not there yields nothing rather than a bogus window.
        assert!(make_snippet(text, "zebra").is_none());
    }

    #[test]
    fn snippet_window_is_measured_in_characters_not_bytes() {
        // needle_lower.len() is a BYTE count; a non-ASCII term used to stretch the
        // window past its intended width. Guard the boundary arithmetic itself.
        let filler = "ş".repeat(200);
        let text = format!("{filler}ARANAN{filler}");
        let out = make_snippet(&text, "aranan").expect("needle is present");
        assert!(out.contains("ARANAN"), "{out}");
        assert!(
            out.starts_with('…') && out.ends_with('…'),
            "must be elided both ends: {out}"
        );
    }

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
    fn transcript_path_resolves_symlinked_cwd() {
        let d = tempfile::tempdir().unwrap();
        let real = d.path().join("real");
        std::fs::create_dir(&real).unwrap();
        let link = d.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let home = Path::new("/h");
        let a = transcript_path_in(home, link.to_str().unwrap(), "s").unwrap();
        let b = transcript_path_in(home, real.to_str().unwrap(), "s").unwrap();
        assert_eq!(a, b);
    }

    /// The content search takes transcript paths from the webview; it must only ever
    /// grep transcripts, never an arbitrary file (a substring oracle on ~/.ssh etc.).
    #[test]
    fn transcript_paths_from_the_webview_stay_inside_projects() {
        use crate::history::checked_transcript_path_in;
        let home = tempfile::tempdir().unwrap();
        let projects = home.path().join("projects");
        std::fs::create_dir_all(projects.join("-p")).unwrap();
        let good = projects.join("-p").join("s.jsonl");
        std::fs::write(&good, "{}\n").unwrap();
        let secret = home.path().join("id_rsa.jsonl");
        std::fs::write(&secret, "{}\n").unwrap();
        let not_jsonl = projects.join("-p").join("notes.txt");
        std::fs::write(&not_jsonl, "x").unwrap();

        assert_eq!(
            checked_transcript_path_in(&projects, &good).unwrap(),
            good.canonicalize().unwrap()
        );
        assert!(
            checked_transcript_path_in(&projects, &secret).is_err(),
            "outside the projects dir"
        );
        assert!(
            checked_transcript_path_in(&projects, &projects.join("-p/../../id_rsa.jsonl")).is_err(),
            "`..` escape"
        );
        assert!(
            checked_transcript_path_in(&projects, &not_jsonl).is_err(),
            "not a transcript"
        );
        #[cfg(unix)]
        {
            let link = projects.join("-p").join("link.jsonl");
            std::os::unix::fs::symlink(&secret, &link).unwrap();
            assert!(
                checked_transcript_path_in(&projects, &link).is_err(),
                "symlink out of the dir"
            );
        }
        // The real resolver refuses a tempdir path (it is not under ~/.claude/projects).
        let s = SessionRef {
            id: "x".into(),
            cwd: "/nonexistent".into(),
            path: Some(secret.to_string_lossy().into_owned()),
        };
        assert!(resolve_transcript(&s).is_none());
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

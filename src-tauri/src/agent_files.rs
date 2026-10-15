// Created by Claude — Classification: INTERNAL
//
//! Files a Claude session's agent read and changed, for the Inspector's Activity tab
//! (docs/prd-activity-agent-files.md). Source is the session transcript: every Read /
//! Edit / Write / MultiEdit / NotebookEdit is a `tool_use` block with the file path in
//! its input. Parsing is incremental — the panel polls every few seconds and a
//! transcript can be tens of MB, so each call only reads the bytes added since the last.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TouchedFile {
    pub path: String,
    /// "modified" or "read". A file that was read and then changed is "modified".
    pub action: String,
    pub count: u32,
    /// Transcript timestamp of the latest touch (RFC 3339), "" when absent.
    pub last_at: String,
}

#[derive(Default)]
struct Parsed {
    offset: u64,
    /// path → (modified?, count, last_at, order of last touch)
    files: HashMap<String, (bool, u32, String, u64)>,
    seq: u64,
}

static CACHE: Mutex<Option<HashMap<PathBuf, Parsed>>> = Mutex::new(None);

fn action_of(tool: &str) -> Option<bool> {
    match tool {
        "Edit" | "Write" | "MultiEdit" | "NotebookEdit" => Some(true),
        "Read" => Some(false),
        _ => None,
    }
}

/// Fold one transcript line into `p`. Relative paths are joined to `cwd`.
fn absorb_line(p: &mut Parsed, line: &str, cwd: &str) {
    // Cheap pre-filter: most lines are text / tool results.
    if !line.contains("\"tool_use\"") {
        return;
    }
    let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
        return;
    };
    let ts = v.get("timestamp").and_then(|t| t.as_str()).unwrap_or("");
    let Some(blocks) = v
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(|c| c.as_array())
    else {
        return;
    };
    for b in blocks {
        if b.get("type").and_then(|t| t.as_str()) != Some("tool_use") {
            continue;
        }
        let Some(modified) = b.get("name").and_then(|n| n.as_str()).and_then(action_of) else {
            continue;
        };
        let input = b.get("input");
        let Some(raw) = input
            .and_then(|i| i.get("file_path").or_else(|| i.get("notebook_path")))
            .and_then(|f| f.as_str())
            .filter(|s| !s.is_empty())
        else {
            continue;
        };
        let path = if Path::new(raw).is_absolute() || cwd.is_empty() {
            raw.to_string()
        } else {
            Path::new(cwd).join(raw).to_string_lossy().into_owned()
        };
        p.seq += 1;
        let e = p.files.entry(path).or_insert((false, 0, String::new(), 0));
        e.0 |= modified;
        e.1 += 1;
        e.2 = ts.to_string();
        e.3 = p.seq;
    }
}

/// Read `path` from `p.offset`, consuming only complete lines. A file shorter than the
/// offset was rewritten — start over.
fn absorb_file(p: &mut Parsed, path: &Path, cwd: &str) -> std::io::Result<()> {
    let mut f = std::fs::File::open(path)?;
    let len = f.metadata()?.len();
    if len < p.offset {
        *p = Parsed::default();
    }
    if len == p.offset {
        return Ok(());
    }
    f.seek(SeekFrom::Start(p.offset))?;
    let mut buf = Vec::with_capacity((len - p.offset) as usize);
    f.take(len - p.offset).read_to_end(&mut buf)?;
    let Some(last_nl) = buf.iter().rposition(|&b| b == b'\n') else {
        return Ok(()); // no complete line yet
    };
    for line in buf[..last_nl].split(|&b| b == b'\n') {
        if let Ok(s) = std::str::from_utf8(line) {
            absorb_line(p, s, cwd);
        }
    }
    p.offset += last_nl as u64 + 1;
    Ok(())
}

fn snapshot(p: &Parsed) -> Vec<TouchedFile> {
    let mut v: Vec<_> = p.files.iter().collect();
    v.sort_by(|a, b| b.1 .3.cmp(&a.1 .3));
    v.into_iter()
        .map(|(path, (m, c, ts, _))| TouchedFile {
            path: path.clone(),
            action: if *m { "modified" } else { "read" }.into(),
            count: *c,
            last_at: ts.clone(),
        })
        .collect()
}

/// Session ids are UUIDs; anything else never reaches the filesystem.
fn valid_session_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// Claude Code's project-dir encoding is not always `/`→`-` (dots and other characters
/// are replaced too), so when the derived path is missing, look for `<id>.jsonl` in
/// every project dir — session ids are unique.
fn find_transcript(cwd: &str, session_id: &str) -> Option<PathBuf> {
    if let Some(p) = crate::sessions::transcript_path(cwd, session_id).filter(|p| p.is_file()) {
        return Some(p);
    }
    let home = std::env::var_os("HOME")?;
    let projects = Path::new(&home).join(".claude/projects");
    let name = format!("{session_id}.jsonl");
    std::fs::read_dir(projects)
        .ok()?
        .flatten()
        .map(|d| d.path().join(&name))
        .find(|p| p.is_file())
}

/// Files the agent of session `session_id` (started in `cwd`) read and changed,
/// newest touch first. Empty when the transcript doesn't exist yet.
#[tauri::command(async)]
pub fn session_touched_files(cwd: String, session_id: String) -> Result<Vec<TouchedFile>, String> {
    if !valid_session_id(&session_id) {
        return Err("invalid session id".into());
    }
    let Some(found) = find_transcript(&cwd, &session_id) else {
        return Ok(vec![]);
    };
    let path = crate::history::checked_transcript_path(&found)?;
    let mut guard = CACHE.lock().map_err(|_| "cache poisoned".to_string())?;
    let cache = guard.get_or_insert_with(HashMap::new);
    let parsed = cache.entry(path.clone()).or_default();
    absorb_file(parsed, &path, &cwd).map_err(|e| format!("read transcript: {e}"))?;
    Ok(snapshot(parsed))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn tool(name: &str, input: &str, ts: &str) -> String {
        format!(
            r#"{{"type":"assistant","timestamp":"{ts}","message":{{"content":[{{"type":"tool_use","name":"{name}","input":{input}}}]}}}}"#
        )
    }

    #[test]
    fn collects_reads_and_changes_modified_wins_newest_first() {
        let mut p = Parsed::default();
        for l in [
            tool("Read", r#"{"file_path":"/w/a.rs"}"#, "t1"),
            tool("Bash", r#"{"command":"ls"}"#, "t2"),
            tool("Read", r#"{"file_path":"src/b.ts"}"#, "t3"),
            tool("Edit", r#"{"file_path":"/w/a.rs","old_string":"x"}"#, "t4"),
            tool("NotebookEdit", r#"{"notebook_path":"/w/n.ipynb"}"#, "t5"),
            r#"{"type":"user","message":{"content":"plain text"}}"#.to_string(),
        ] {
            absorb_line(&mut p, &l, "/w");
        }
        let got = snapshot(&p);
        assert_eq!(
            got.iter()
                .map(|f| (f.path.as_str(), f.action.as_str(), f.count))
                .collect::<Vec<_>>(),
            vec![
                ("/w/n.ipynb", "modified", 1),
                ("/w/a.rs", "modified", 2),
                ("/w/src/b.ts", "read", 1)
            ]
        );
        assert_eq!(got[1].last_at, "t4");
    }

    #[test]
    fn incremental_skips_partial_line_and_restarts_when_shrunk() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.jsonl");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(f, "{}", tool("Read", r#"{"file_path":"/a"}"#, "t1")).unwrap();
        write!(f, "{}", &tool("Write", r#"{"file_path":"/b"}"#, "t2")[..20]).unwrap(); // half a line
        f.flush().unwrap();
        let mut p = Parsed::default();
        absorb_file(&mut p, &path, "").unwrap();
        assert_eq!(snapshot(&p).len(), 1, "partial line must wait");

        // finish the line: only the new bytes are parsed, /a is not counted twice
        let full = tool("Write", r#"{"file_path":"/b"}"#, "t2");
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap();
        writeln!(f, "{}", &full[20..]).unwrap();
        absorb_file(&mut p, &path, "").unwrap();
        let got = snapshot(&p);
        assert_eq!(got.len(), 2);
        assert_eq!(
            (got[0].path.as_str(), got[0].action.as_str()),
            ("/b", "modified")
        );
        assert_eq!(got[1].count, 1);

        // rewritten shorter → re-read from 0
        std::fs::write(
            &path,
            format!("{}\n", tool("Read", r#"{"file_path":"/c"}"#, "t3")),
        )
        .unwrap();
        absorb_file(&mut p, &path, "").unwrap();
        assert_eq!(
            snapshot(&p)
                .iter()
                .map(|f| f.path.as_str())
                .collect::<Vec<_>>(),
            vec!["/c"]
        );
    }

    #[test]
    fn session_id_must_be_uuid_like() {
        assert!(valid_session_id("3f2a9c1e-0b7d-4e55-9a51-1c2d3e4f5a6b"));
        for bad in ["", "../x", "a/b", "id.jsonl", "a b"] {
            assert!(!valid_session_id(bad), "{bad}");
        }
    }
}

/// Manual check against a real transcript:
/// `MUYA_SID=<session id> MUYA_CWD=<cwd> cargo test --lib agent_files_live -- --ignored --nocapture`
#[cfg(test)]
#[test]
#[ignore]
fn agent_files_live() {
    let sid = std::env::var("MUYA_SID").unwrap();
    let cwd = std::env::var("MUYA_CWD").unwrap_or_default();
    let t = std::time::Instant::now();
    let first = session_touched_files(cwd.clone(), sid.clone()).unwrap();
    let cold = t.elapsed();
    let t = std::time::Instant::now();
    let again = session_touched_files(cwd, sid).unwrap();
    println!("files={} cold={cold:?} warm={:?}", first.len(), t.elapsed());
    assert_eq!(first, again);
    for f in first.iter().take(12) {
        println!("{:9} x{:<3} {}", f.action, f.count, f.path);
    }
}

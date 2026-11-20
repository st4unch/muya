//! Read-only git and the plan (Kanban) store behind `git.*` / `plan.*` Rpc methods.
//!
//! Every folder the app names must lie inside one of Muya's roots: the folders the app pushed with
//! `workspace.set_roots`, the working directories of the sessions this daemon spawned, and the git
//! worktrees of either. Output is bounded; git runs with `GIT_OPTIONAL_LOCKS=0` (never writes) and
//! is killed on cancel or after [`GIT_TIMEOUT`].

use muya_core::{fs as core_fs, workspace_roots};
use serde_json::{json, Value};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const GIT_TIMEOUT: Duration = Duration::from_secs(20);
/// Largest git output kept (a diff beyond this is cut and flagged `truncated`).
pub const MAX_OUTPUT: usize = 2 << 20;
pub const MAX_LOG: usize = 1000;
const OUTSIDE: &str = "that folder is not one of Muya's workspaces";

/// Runs `git -C dir args…`; stdout capped at `max` bytes (the rest is drained and dropped).
/// Returns `(stdout, truncated)`; a failing git is an Err with its first stderr line.
pub fn run_git(
    dir: &Path,
    args: &[&str],
    max: usize,
    cancel: &AtomicBool,
) -> Result<(Vec<u8>, bool), String> {
    let mut child = Command::new("git")
        .args(["-c", "core.quotepath=false", "-c", "color.ui=never", "-C"])
        .arg(dir)
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_PAGER", "cat")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("git not found: {e}"))?;
    let mut out = child.stdout.take().ok_or("git stdout")?;
    let mut err = child.stderr.take().ok_or("git stderr")?;
    let reader = std::thread::spawn(move || {
        let (mut kept, mut truncated, mut buf) = (Vec::new(), false, [0u8; 64 * 1024]);
        while let Ok(n) = out.read(&mut buf) {
            if n == 0 {
                break;
            }
            let room = max.saturating_sub(kept.len());
            if n > room {
                truncated = true;
            }
            kept.extend_from_slice(&buf[..n.min(room)]);
        }
        (kept, truncated)
    });
    let stderr_reader = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = (&mut err).take(8192).read_to_string(&mut s);
        s
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(st)) => break st,
            Ok(None) => {}
            Err(e) => return Err(format!("git: {e}")),
        }
        if cancel.load(Ordering::Relaxed) || started.elapsed() > GIT_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            let _ = stderr_reader.join();
            return Err(if cancel.load(Ordering::Relaxed) {
                "cancelled".into()
            } else {
                "git took too long".into()
            });
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    let (kept, truncated) = reader.join().map_err(|_| "git reader failed")?;
    let stderr = stderr_reader.join().unwrap_or_default();
    if !status.success() {
        let first = stderr.lines().next().unwrap_or("git failed");
        return Err(first.to_string());
    }
    Ok((kept, truncated))
}

fn text(dir: &Path, args: &[&str], cancel: &AtomicBool) -> Result<String, String> {
    let (b, _) = run_git(dir, args, MAX_OUTPUT, cancel)?;
    Ok(String::from_utf8_lossy(&b).trim().to_string())
}

/// One entry of `git worktree list --porcelain`.
fn worktrees_of(dir: &Path, cancel: &AtomicBool) -> Vec<Value> {
    let Ok((b, _)) = run_git(
        dir,
        &["worktree", "list", "--porcelain"],
        256 * 1024,
        cancel,
    ) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut cur: Option<serde_json::Map<String, Value>> = None;
    let flush = |cur: &mut Option<serde_json::Map<String, Value>>, out: &mut Vec<Value>| {
        if let Some(m) = cur.take() {
            out.push(Value::Object(m));
        }
    };
    for line in String::from_utf8_lossy(&b).lines() {
        if let Some(p) = line.strip_prefix("worktree ") {
            flush(&mut cur, &mut out);
            let mut m = serde_json::Map::new();
            m.insert("path".into(), json!(p));
            m.insert("head".into(), Value::Null);
            m.insert("branch".into(), Value::Null);
            m.insert("bare".into(), json!(false));
            m.insert("detached".into(), json!(false));
            m.insert("locked".into(), json!(false));
            cur = Some(m);
        } else if let Some(m) = cur.as_mut() {
            if let Some(h) = line.strip_prefix("HEAD ") {
                m.insert("head".into(), json!(h));
            } else if let Some(r) = line.strip_prefix("branch ") {
                m.insert(
                    "branch".into(),
                    json!(r.strip_prefix("refs/heads/").unwrap_or(r)),
                );
            } else if line == "bare" {
                m.insert("bare".into(), json!(true));
            } else if line == "detached" {
                m.insert("detached".into(), json!(true));
            } else if line == "locked" || line.starts_with("locked ") {
                m.insert("locked".into(), json!(true));
            }
        }
    }
    flush(&mut cur, &mut out);
    out
}

fn canon(p: &str) -> Option<PathBuf> {
    std::fs::canonicalize(p).ok()
}

/// `dir` (canonicalised) when it lies inside one of `roots` or one of their git worktrees.
pub fn guard_dir(dir: &str, roots: &[String], cancel: &AtomicBool) -> Result<PathBuf, String> {
    if dir.trim().is_empty() || !dir.starts_with('/') {
        return Err("cwd must be an absolute folder path".into());
    }
    let want = canon(dir).ok_or_else(|| "That folder doesn't exist.".to_string())?;
    if !want.is_dir() {
        return Err("That folder doesn't exist.".into());
    }
    let canon_roots: Vec<PathBuf> = roots.iter().filter_map(|r| canon(r)).collect();
    if canon_roots.iter().any(|r| want.starts_with(r)) {
        return Ok(want);
    }
    // Not under a root directly: it may be a linked worktree of one.
    for r in &canon_roots {
        for w in worktrees_of(r, cancel) {
            if let Some(wp) = w["path"].as_str().and_then(canon) {
                if want.starts_with(&wp) {
                    return Ok(want);
                }
            }
        }
    }
    Err(OUTSIDE.into())
}

/// The roots to check against: the pushed workspace roots plus the spawned sessions' folders.
pub fn all_roots(spawned: Vec<String>) -> Vec<String> {
    let mut r = workspace_roots::load_workspace_roots().unwrap_or_default();
    r.extend(spawned);
    r
}

pub fn status(dir: &Path, cancel: &AtomicBool) -> Result<Value, String> {
    let root = text(dir, &["rev-parse", "--show-toplevel"], cancel)?;
    let branch = text(dir, &["rev-parse", "--abbrev-ref", "HEAD"], cancel).unwrap_or_default();
    // Core's git_status is async (tokio::process); drive it on a throw-away runtime.
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("runtime: {e}"))?;
    let files = rt.block_on(core_fs::git_status(root.clone()))?;
    let files: Vec<Value> = files
        .into_iter()
        .take(5000)
        .map(|(path, status)| json!({ "path": path, "status": status }))
        .collect();
    Ok(json!({ "root": root, "branch": branch, "files": files }))
}

pub fn diff(
    dir: &Path,
    path: Option<&str>,
    staged: bool,
    cancel: &AtomicBool,
) -> Result<Value, String> {
    let mut args = vec!["diff", "--no-ext-diff", "--no-textconv"];
    if staged {
        args.push("--cached");
    }
    let rel;
    if let Some(p) = path.filter(|p| !p.is_empty()) {
        let abs = if p.starts_with('/') {
            PathBuf::from(p)
        } else {
            dir.join(p)
        };
        // The file may be deleted: canonicalise its parent. It must stay inside the folder.
        let parent = abs
            .parent()
            .and_then(|x| std::fs::canonicalize(x).ok())
            .ok_or("path is outside the folder")?;
        if !parent.starts_with(dir) || abs.file_name().is_none() {
            return Err("path is outside the folder".into());
        }
        rel = parent
            .join(abs.file_name().unwrap_or_default())
            .strip_prefix(dir)
            .map_err(|_| "path is outside the folder")?
            .to_string_lossy()
            .into_owned();
        args.push("--");
        args.push(&rel);
        let (b, truncated) = run_git(dir, &args, MAX_OUTPUT, cancel)?;
        return Ok(json!({ "diff": String::from_utf8_lossy(&b), "truncated": truncated }));
    }
    let (b, truncated) = run_git(dir, &args, MAX_OUTPUT, cancel)?;
    Ok(json!({ "diff": String::from_utf8_lossy(&b), "truncated": truncated }))
}

pub fn worktrees(dir: &Path, cancel: &AtomicBool) -> Result<Value, String> {
    Ok(Value::Array(worktrees_of(dir, cancel)))
}

pub fn branches(dir: &Path) -> Result<Value, String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("runtime: {e}"))?;
    let list = rt.block_on(core_fs::list_branches(dir.to_string_lossy().into_owned()))?;
    serde_json::to_value(list).map_err(|e| format!("encode: {e}"))
}

pub fn log(dir: &Path, limit: usize, skip: usize, cancel: &AtomicBool) -> Result<Value, String> {
    let limit = limit.clamp(1, MAX_LOG).to_string();
    let skip = skip.min(10_000_000).to_string();
    let fmt = "--format=%H%x1f%P%x1f%an%x1f%at%x1f%s%x1f%D%x1e";
    let (b, _) = run_git(
        dir,
        &["log", "--max-count", &limit, "--skip", &skip, fmt],
        MAX_OUTPUT,
        cancel,
    )?;
    let mut out = Vec::new();
    for rec in String::from_utf8_lossy(&b).split('\u{1e}') {
        let f: Vec<&str> = rec.trim_start_matches('\n').split('\u{1f}').collect();
        if f.len() < 6 {
            continue;
        }
        out.push(json!({
            "hash": f[0],
            "parents": f[1].split_whitespace().collect::<Vec<_>>(),
            "author": f[2],
            "date": f[3].parse::<i64>().unwrap_or(0),
            "subject": f[4],
            "refs": f[5].split(", ").filter(|r| !r.is_empty()).collect::<Vec<_>>(),
        }));
    }
    Ok(Value::Array(out))
}

// ── plan (Kanban) store: docs/prd-<slug>.progress.md frontmatter `status:` ───────────────────

pub const PLAN_STATUSES: [&str; 5] = ["draft", "active", "blocked", "review", "done"];

fn valid_slug(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 100
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
}

pub fn plan_list(dir: &Path) -> Result<Value, String> {
    let docs = core_fs::scan_prd_docs(vec![dir.to_string_lossy().into_owned()]);
    serde_json::to_value(docs).map_err(|e| format!("encode: {e}"))
}

/// Sets `status:` in `docs/prd-<slug>.progress.md` (frontmatter), creating the progress file next to an
/// existing PRD the way `track_plan` does. The PRD itself is never touched.
pub fn plan_set_status(dir: &Path, slug: &str, status: &str) -> Result<Value, String> {
    if !valid_slug(slug) {
        return Err("bad plan slug".into());
    }
    if !PLAN_STATUSES.contains(&status) {
        return Err(format!(
            "status must be one of {}",
            PLAN_STATUSES.join(", ")
        ));
    }
    let docs = dir.join("docs");
    let prd = docs.join(format!("prd-{slug}.md"));
    let progress = docs.join(format!("prd-{slug}.progress.md"));
    // docs/ itself must not be a symlink out of the folder.
    let real_docs =
        std::fs::canonicalize(&docs).map_err(|_| "this folder has no docs/ plans".to_string())?;
    if !real_docs.starts_with(dir) {
        return Err(OUTSIDE.into());
    }
    let new_text = match std::fs::read_to_string(&progress) {
        Ok(old) => set_frontmatter_status(&old, status),
        Err(_) if prd.is_file() => {
            format!("---\nstatus: {status}\nprd: docs/prd-{slug}.md\n---\n\n## Progress\n")
        }
        Err(_) => return Err("no such plan".into()),
    };
    let tmp = docs.join(format!(".prd-{slug}.progress.md.tmp{}", std::process::id()));
    std::fs::write(&tmp, new_text).map_err(|e| format!("write: {e}"))?;
    std::fs::rename(&tmp, &progress).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("write: {e}")
    })?;
    Ok(json!({ "slug": slug, "status": status }))
}

/// Replaces (or adds) `status:` inside the leading `---` block; text without a block gets one.
pub fn set_frontmatter_status(old: &str, status: &str) -> String {
    let line = format!("status: {status}");
    if let Some(rest) = old.strip_prefix("---\n") {
        if let Some(end) = rest.find("\n---") {
            let (front, tail) = rest.split_at(end);
            let mut replaced = false;
            let mut lines: Vec<String> = front
                .lines()
                .map(|l| {
                    if !replaced && l.trim_start().starts_with("status:") {
                        replaced = true;
                        line.clone()
                    } else {
                        l.to_string()
                    }
                })
                .collect();
            if !replaced {
                lines.push(line);
            }
            return format!("---\n{}{}", lines.join("\n"), tail);
        }
    }
    format!("---\n{line}\n---\n\n{old}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frontmatter_status_is_replaced_added_or_created() {
        assert_eq!(
            set_frontmatter_status("---\nstatus: active\nprd: x\n---\n\nbody\n", "done"),
            "---\nstatus: done\nprd: x\n---\n\nbody\n"
        );
        assert_eq!(
            set_frontmatter_status("---\nprd: x\n---\nbody", "draft"),
            "---\nprd: x\nstatus: draft\n---\nbody"
        );
        assert_eq!(
            set_frontmatter_status("no front", "active"),
            "---\nstatus: active\n---\n\nno front"
        );
    }

    #[test]
    fn slugs_are_plain() {
        assert!(valid_slug("native-rewrite") && valid_slug("a_b"));
        assert!(!valid_slug("../x") && !valid_slug("a/b") && !valid_slug("") && !valid_slug("-rf"));
    }
}

// ── P6: branch detail, branch file pair, worktrees, file history ───────────────────────────────
//
// Same names/payload shapes as the Tauri commands (`branch_detail`, `git_branch_file_pair`,
// `create_worktree`, `remove_worktree`, `file_history_*`), exposed as `git.*` / `file_history.*`.
// Every folder the caller names goes through `guard` (workspace roots + linked worktrees).

#[derive(serde::Deserialize)]
struct BranchParams {
    cwd: String,
    branch: String,
}

#[derive(serde::Deserialize)]
struct PairParams {
    cwd: String,
    base: String,
    branch: String,
    path: String,
}

#[derive(serde::Deserialize)]
struct WorktreeParams {
    worktree: String,
}

#[derive(serde::Deserialize)]
struct HistSnapParams {
    path: String,
    content: String,
    #[serde(default)]
    kind: String,
}

#[derive(serde::Deserialize)]
struct HistListParams {
    path: String,
}

#[derive(serde::Deserialize)]
struct HistReadParams {
    path: String,
    id: String,
}

fn p<T: serde::de::DeserializeOwned>(params: &str) -> Result<T, String> {
    serde_json::from_str(params).map_err(|e| format!("bad parameters: {e}"))
}

/// A file the caller named: its folder must be inside the roots (the file itself may not exist).
fn guard_file(
    path: &str,
    guard: &dyn Fn(&str) -> Result<PathBuf, String>,
) -> Result<(), String> {
    if !path.starts_with('/') {
        return Err("path must be absolute".into());
    }
    let parent = Path::new(path)
        .parent()
        .and_then(|d| d.to_str())
        .ok_or("path has no folder")?;
    guard(parent).map(|_| ())
}

/// `None` when `method` isn't one of the P6 methods.
pub fn call_p6(
    method: &str,
    params: &str,
    guard: &dyn Fn(&str) -> Result<PathBuf, String>,
) -> Option<Result<Value, String>> {
    let r = match method {
        "git.branch_detail" => (|| {
            let a: BranchParams = p(params)?;
            let dir = guard(&a.cwd)?;
            let d = core_fs::branch_detail(dir.to_string_lossy().into_owned(), a.branch)?;
            serde_json::to_value(d).map_err(|e| format!("encode: {e}"))
        })(),
        "git.branch_file_pair" => (|| {
            let a: PairParams = p(params)?;
            let dir = guard(&a.cwd)?;
            let (old, new) =
                core_fs::git_branch_file_pair(dir.to_string_lossy().into_owned(), a.base, a.branch, a.path)?;
            Ok(json!([old, new]))
        })(),
        "git.create_worktree" => (|| {
            let a: BranchParams = p(params)?;
            let dir = guard(&a.cwd)?;
            // The new worktree is created next to the repo's top level, so the top level itself
            // must be one of Muya's folders (a root nested inside a bigger repo is refused).
            let top = std::process::Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(["rev-parse", "--show-toplevel"])
                .output()
                .map_err(|e| format!("git not found: {e}"))?;
            if !top.status.success() {
                return Err("workspace is not a git repository".into());
            }
            let top = String::from_utf8_lossy(&top.stdout).trim().to_string();
            guard(&top)?;
            let wt = core_fs::create_worktree(top, a.branch)?;
            Ok(json!(wt))
        })(),
        "git.remove_worktree" => (|| {
            let a: WorktreeParams = p(params)?;
            let dir = guard(&a.worktree)?;
            let msg = core_fs::remove_worktree(dir.to_string_lossy().into_owned())?;
            Ok(json!(msg))
        })(),
        "file_history.snapshot" => (|| {
            let a: HistSnapParams = p(params)?;
            guard_file(&a.path, guard)?;
            let kind = if a.kind.is_empty() { "saved".to_string() } else { a.kind };
            let v = muya_core::file_history::file_history_snapshot(a.path, a.content, kind)?;
            serde_json::to_value(v).map_err(|e| format!("encode: {e}"))
        })(),
        "file_history.list" => (|| {
            let a: HistListParams = p(params)?;
            guard_file(&a.path, guard)?;
            let v = muya_core::file_history::file_history_list(a.path)?;
            serde_json::to_value(v).map_err(|e| format!("encode: {e}"))
        })(),
        "file_history.read" => (|| {
            let a: HistReadParams = p(params)?;
            guard_file(&a.path, guard)?;
            Ok(json!(muya_core::file_history::file_history_read(a.path, a.id)?))
        })(),
        _ => return None,
    };
    Some(r)
}

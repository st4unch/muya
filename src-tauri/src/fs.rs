//! Scoped filesystem reads for the workspace file tree. Custom commands over
//! `std::fs` (not the fs plugin) so we own the security check: directory listing is
//! only ever lazy and read-only. The frontend feeds these from user-picked workspace
//! roots.

use std::path::Path;
use std::process::Command;

use serde::Serialize;

/// A single directory entry for the file tree.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirEntry {
    pub name: String,
    pub path: String,
    pub is_directory: bool,
}

/// List the immediate children of a directory. Directories first, then files, each
/// alphabetical. Hidden entries (dotfiles) and heavy build dirs are included but the
/// frontend may choose to fold them. Errors (missing dir, permission) return Err.
#[tauri::command(async)]
pub fn list_dir(path: String) -> Result<Vec<DirEntry>, String> {
    let p = Path::new(&path);
    // `Path::is_dir()` swallows the error and answers `false`, so a folder the
    // operator is merely BLOCKED from used to be reported as "not a directory" —
    // the one diagnosis guaranteed to send them looking in the wrong place.
    // Ask for the metadata directly so EPERM stays distinguishable from ENOENT.
    match std::fs::metadata(p) {
        Ok(m) if m.is_dir() => {}
        Ok(_) => return Err(format!("not a directory: {path}")),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            return Err(access_denied_message(&path))
        }
        Err(e) => return Err(format!("cannot read {path}: {e}")),
    }
    let mut entries: Vec<DirEntry> = std::fs::read_dir(p)
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::PermissionDenied {
                access_denied_message(&path)
            } else {
                format!("read_dir failed: {e}")
            }
        })?
        .filter_map(|res| res.ok())
        .map(|e| {
            let is_directory = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
            DirEntry {
                name: e.file_name().to_string_lossy().into_owned(),
                path: e.path().to_string_lossy().into_owned(),
                is_directory,
            }
        })
        .collect();
    entries.sort_by(|a, b| {
        b.is_directory
            .cmp(&a.is_directory)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(entries)
}

/// Read a UTF-8 text file for the editor. Rejects very large files to keep the
/// editor responsive.
#[tauri::command(async)]
pub fn read_file(path: String) -> Result<String, String> {
    let p = Path::new(&path);
    let meta = std::fs::metadata(p).map_err(|e| format!("stat failed: {e}"))?;
    if meta.len() > 5_000_000 {
        return Err("file too large (>5MB) to open in the editor".into());
    }
    std::fs::read_to_string(p).map_err(|e| format!("read failed: {e}"))
}

/// Write text back to a file (editor save).
#[tauri::command(async)]
pub fn write_file(path: String, content: String) -> Result<(), String> {
    let path = crate::validate::valid_mutable_path(&path)?;
    std::fs::write(Path::new(&path), content).map_err(|e| format!("write failed: {e}"))
}

/// Create a new, empty file (File > New File). Never truncates: if the path already
/// exists it's left untouched (the caller just opens it). Parent dirs are created.
#[tauri::command(async)]
pub fn create_file(path: String) -> Result<(), String> {
    let path = crate::validate::valid_mutable_path(&path)?;
    let p = Path::new(&path);
    if p.exists() {
        return Ok(()); // open the existing file rather than overwrite it
    }
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir failed: {e}"))?;
    }
    std::fs::write(p, "").map_err(|e| format!("create failed: {e}"))
}

/// Classify a dropped path so the frontend can route it: a directory becomes a
/// workspace root, a file opens in the editor. Returns "dir", "file", or "missing".
#[tauri::command(async)]
pub fn path_kind(path: String) -> String {
    match std::fs::metadata(Path::new(&path)) {
        Ok(m) if m.is_dir() => "dir".into(),
        Ok(_) => "file".into(),
        Err(_) => "missing".into(),
    }
}

/// Create a new directory (File tree > New Folder). Idempotent: an existing dir is
/// left untouched. Parent dirs are created as needed.
#[tauri::command(async)]
pub fn create_dir(path: String) -> Result<(), String> {
    let path = crate::validate::valid_mutable_path(&path)?;
    std::fs::create_dir_all(Path::new(&path)).map_err(|e| format!("mkdir failed: {e}"))
}

/// Read a file's committed (HEAD) version for diffing against the working tree.
/// Returns the HEAD content, or an empty string if the file is untracked/new (so the
/// diff shows it as fully added). Errors only if the path isn't inside a git repo.
#[tauri::command(async)]
pub fn read_head_file(path: String) -> Result<String, String> {
    // Canonicalize so it matches git's (also-canonical) toplevel even when the path
    // contains symlinks (e.g. macOS /var → /private/var).
    let canon = Path::new(&path).canonicalize().ok();
    let p = canon.as_deref().unwrap_or_else(|| Path::new(&path));
    let dir = p.parent().ok_or("invalid path")?;
    let root_out = Command::new("git")
        .args(["-C"])
        .arg(dir)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .map_err(|e| format!("git not found: {e}"))?;
    if !root_out.status.success() {
        return Err("not inside a git repository".into());
    }
    let root = String::from_utf8_lossy(&root_out.stdout).trim().to_string();
    let rel = p
        .strip_prefix(&root)
        .map(|r| r.to_string_lossy().into_owned())
        .map_err(|_| "file outside repo root".to_string())?;
    let show = Command::new("git")
        .args(["-C", &root, "show", &format!("HEAD:{rel}")])
        .output()
        .map_err(|e| format!("git show failed: {e}"))?;
    if !show.status.success() {
        // Untracked / new file → no HEAD version; diff against empty.
        return Ok(String::new());
    }
    Ok(String::from_utf8_lossy(&show.stdout).into_owned())
}

/// Create an isolated git worktree for a new agent branch and copy gitignored env
/// files into it. Returns the worktree path. Requires `repo` to be inside a git repo.
#[tauri::command(async)]
pub fn create_worktree(repo: String, branch: String) -> Result<String, String> {
    let branch = crate::validate::valid_branch(&branch)?;
    let branch = branch.as_str();
    let root_out = Command::new("git")
        .args(["-C", &repo, "rev-parse", "--show-toplevel"])
        .output()
        .map_err(|e| format!("git not found: {e}"))?;
    if !root_out.status.success() {
        return Err("workspace is not a git repository".into());
    }
    let root = String::from_utf8_lossy(&root_out.stdout).trim().to_string();
    let root_path = Path::new(&root);
    let repo_name = root_path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "repo".into());
    let safe_branch = branch.replace('/', "-");
    let wt = root_path
        .parent()
        .ok_or("repo has no parent dir")?
        .join(format!("{repo_name}-worktrees"))
        .join(&safe_branch);
    let wt_str = wt.to_string_lossy().into_owned();

    // Try creating a new branch; if it already exists, attach to it without -b.
    let add = Command::new("git")
        .args(["-C", &root, "worktree", "add", "-b", branch, &wt_str])
        .output()
        .map_err(|e| format!("git worktree add failed: {e}"))?;
    if !add.status.success() {
        let retry = Command::new("git")
            .args(["-C", &root, "worktree", "add", &wt_str, branch])
            .output()
            .map_err(|e| format!("git worktree add failed: {e}"))?;
        if !retry.status.success() {
            return Err(format!(
                "git worktree add failed: {}",
                String::from_utf8_lossy(&add.stderr)
            ));
        }
    }

    // Copy gitignored env files the new worktree won't get from git.
    for f in [".env", ".env.local"] {
        let src = root_path.join(f);
        if src.exists() {
            let _ = std::fs::copy(&src, wt.join(f));
        }
    }
    Ok(wt_str)
}

/// A git branch mapped onto the frontend `GitBranchState` contract.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitBranchState {
    pub name: String,
    /// PRD (main/release) | WIP (feature/fix) | OPEN (everything else)
    #[serde(rename = "type")]
    pub kind: String,
    pub last_commit: String,
    pub author: String,
    /// synced | ahead | diverged
    pub status: String,
    /// Branch this most likely forked from (closest divergence); None for the root.
    pub parent: Option<String>,
}

/// `has_worktree`: true when a `git worktree` (linked or primary) currently has this
/// branch checked out — the real signal that someone (a person or an agent) is
/// actively working on it, regardless of naming convention. Falls back to common
/// prefix conventions for branches without a worktree the app happens to know about,
/// so a bare-checkout `feature/x` still classifies sensibly.
fn branch_kind(name: &str, has_worktree: bool) -> &'static str {
    if name == "main" || name == "master" || name.starts_with("release/") {
        "PRD"
    } else if has_worktree
        || name.starts_with("feature/")
        || name.starts_with("feat/")
        || name.starts_with("fix/")
        || name.starts_with("bugfix/")
        || name.starts_with("hotfix/")
        || name.starts_with("wip/")
        || name.starts_with("chore/")
    {
        "WIP"
    } else {
        "OPEN"
    }
}

/// Branches currently checked out in any worktree of `repo` (primary + linked).
/// Best-effort: an empty set on any git failure just means nothing gets the
/// worktree-based WIP bump, falling back to prefix-only classification.
fn worktree_branches(repo: &str) -> std::collections::HashSet<String> {
    let mut set = std::collections::HashSet::new();
    let out = match Command::new("git")
        .args(["-C", repo, "worktree", "list", "--porcelain"])
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return set,
    };
    let text = String::from_utf8_lossy(&out.stdout);
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("branch ") {
            let name = rest.strip_prefix("refs/heads/").unwrap_or(rest);
            set.insert(name.to_string());
        }
    }
    set
}

fn track_to_status(track: &str) -> &'static str {
    let ahead = track.contains("ahead");
    let behind = track.contains("behind");
    if ahead && behind {
        "diverged"
    } else if ahead {
        "ahead"
    } else {
        "synced"
    }
}

/// List local branches of a repo for the topology view. Returns empty if not a git
/// repo (UI just shows nothing rather than erroring).
#[tauri::command(async)]
pub async fn list_branches(repo: String) -> Result<Vec<GitBranchState>, String> {
    // `git for-each-ref` subprocess — run on the blocking pool so this (polled)
    // command never occupies a tokio worker thread (L31).
    tokio::task::spawn_blocking(move || list_branches_sync(repo))
        .await
        .map_err(|e| format!("list_branches join: {e}"))?
}

fn list_branches_sync(repo: String) -> Result<Vec<GitBranchState>, String> {
    let fmt = "%(refname:short)\x1f%(upstream:track)\x1f%(authorname)\x1f%(subject)";
    let out = Command::new("git")
        .args(["-C", &repo, "for-each-ref", "--format", fmt, "refs/heads/"])
        .output()
        .map_err(|e| format!("git not found: {e}"))?;
    if !out.status.success() {
        return Ok(vec![]); // not a git repo
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let wt_branches = worktree_branches(&repo);
    let mut branches = Vec::new();
    for line in text.lines().filter(|l| !l.is_empty()) {
        let parts: Vec<&str> = line.split('\x1f').collect();
        let name = parts.first().copied().unwrap_or("").to_string();
        if name.is_empty() {
            continue;
        }
        let track = parts.get(1).copied().unwrap_or("");
        branches.push(GitBranchState {
            kind: branch_kind(&name, wt_branches.contains(&name)).to_string(),
            status: track_to_status(track).to_string(),
            author: parts.get(2).copied().unwrap_or("").to_string(),
            last_commit: parts.get(3).copied().unwrap_or("").to_string(),
            name,
            parent: None,
        });
    }
    compute_parents(&repo, &mut branches);
    Ok(branches)
}

/// One commit row for the branch-detail card.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BranchCommit {
    pub hash: String,
    pub subject: String,
    pub author: String,
    pub rel_date: String,
}

/// Branch detail relative to the repo base (main/master): ahead/behind counts, recent
/// commits unique to the branch, and the files it changed. Powers the Queue page card.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BranchDetail {
    pub name: String,
    pub base: String,
    pub ahead: u32,
    pub behind: u32,
    pub commits: Vec<BranchCommit>,
    pub changed_files: Vec<String>,
}

#[tauri::command(async)]
pub fn branch_detail(repo: String, branch: String) -> Result<BranchDetail, String> {
    // Validate the branch is a real local ref before feeding it to git. This both
    // surfaces a clear error for a bad repo/branch (instead of a silently empty card)
    // and closes git option-injection: every ref below is the fully-qualified
    // `refs/heads/<name>` form, which can never be parsed as a `-`-leading option.
    let bref = format!("refs/heads/{branch}");
    if git_capture(&repo, &["rev-parse", "--verify", "--quiet", &bref]).is_none() {
        return Err(format!("unknown branch: {branch}"));
    }

    // Compare against main, else master — but never the branch itself.
    let base = ["main", "master"]
        .iter()
        .copied()
        .find(|&b| {
            b != branch.as_str()
                && git_capture(
                    &repo,
                    &[
                        "rev-parse",
                        "--verify",
                        "--quiet",
                        &format!("refs/heads/{b}"),
                    ],
                )
                .is_some()
        })
        .map(str::to_string)
        .unwrap_or_default();
    let baseref = format!("refs/heads/{base}");

    // ahead/behind via the symmetric range base...branch (left = base-only = behind,
    // right = branch-only = ahead). With no base (e.g. inspecting main itself) a branch
    // has nothing ahead of itself → leave both at 0.
    let (mut ahead, mut behind) = (0u32, 0u32);
    if !base.is_empty() {
        if let Some(counts) = git_capture(
            &repo,
            &[
                "rev-list",
                "--left-right",
                "--count",
                &format!("{baseref}...{bref}"),
            ],
        ) {
            let mut it = counts.split_whitespace();
            behind = it.next().and_then(|s| s.parse().ok()).unwrap_or(0);
            ahead = it.next().and_then(|s| s.parse().ok()).unwrap_or(0);
        }
    }

    // Up to 20 commits unique to the branch (or its newest commits when there's no base).
    let range = if base.is_empty() {
        bref.clone()
    } else {
        format!("{baseref}..{bref}")
    };
    let log = git_capture(
        &repo,
        &["log", "-n", "20", "--format=%h\x1f%s\x1f%an\x1f%cr", &range],
    )
    .unwrap_or_default();
    let commits = log
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| {
            let p: Vec<&str> = l.split('\x1f').collect();
            BranchCommit {
                hash: p.first().copied().unwrap_or("").to_string(),
                subject: p.get(1).copied().unwrap_or("").to_string(),
                author: p.get(2).copied().unwrap_or("").to_string(),
                rel_date: p.get(3).copied().unwrap_or("").to_string(),
            }
        })
        .collect();

    // Files changed vs the merge-base with the base branch.
    let changed_files = if base.is_empty() {
        vec![]
    } else {
        git_capture(
            &repo,
            &["diff", "--name-only", &format!("{baseref}...{bref}")],
        )
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(|s| s.to_string())
        .collect()
    };

    Ok(BranchDetail {
        name: branch,
        base,
        ahead,
        behind,
        commits,
        changed_files,
    })
}

fn git_capture(repo: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Real lineage: for each branch, parent = the other branch it most recently diverged
/// from (fewest commits on this branch since their merge-base), preferring the base
/// branch on ties. Capped for cost on big repos.
fn compute_parents(repo: &str, branches: &mut [GitBranchState]) {
    if branches.len() > 40 {
        return;
    }
    let names: Vec<String> = branches.iter().map(|b| b.name.clone()).collect();
    let base = names
        .iter()
        .find(|n| n.as_str() == "main")
        .or_else(|| names.iter().find(|n| n.as_str() == "master"))
        .cloned();
    for b in branches.iter_mut() {
        if Some(&b.name) == base.as_ref() {
            continue;
        }
        let mut best: Option<(String, u32)> = None;
        for cand in &names {
            if cand == &b.name {
                continue;
            }
            let Some(mb) = git_capture(repo, &["merge-base", &b.name, cand]) else {
                continue;
            };
            let count = git_capture(repo, &["rev-list", "--count", &format!("{mb}..{}", b.name)])
                .and_then(|s| s.parse::<u32>().ok())
                .unwrap_or(u32::MAX);
            // count == 0 means this branch's tip IS the merge-base → the candidate is a
            // descendant (child), not a parent. Skip it.
            if count == 0 {
                continue;
            }
            let cand_is_base = Some(cand) == base.as_ref();
            let better = match &best {
                None => true,
                Some((bn, bc)) => {
                    count < *bc || (count == *bc && cand_is_base && Some(bn) != base.as_ref())
                }
            };
            if better {
                best = Some((cand.clone(), count));
            }
        }
        b.parent = best.map(|(n, _)| n);
    }
}

/// Remove a git worktree (and its directory). Destructive — operator-confirmed in UI.
/// Runs from the main repo so it can remove a linked worktree by path.
#[tauri::command(async)]
pub fn remove_worktree(worktree: String) -> Result<String, String> {
    // The shared git dir lives in the main repo; derive the main worktree from it.
    let common = Command::new("git")
        .args([
            "-C",
            &worktree,
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ])
        .output()
        .map_err(|e| format!("git not found: {e}"))?;
    if !common.status.success() {
        return Err("not inside a git repository".into());
    }
    let common_dir = String::from_utf8_lossy(&common.stdout).trim().to_string();
    let main_repo = Path::new(&common_dir)
        .parent()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|| worktree.clone());
    let out = Command::new("git")
        .args(["-C", &main_repo, "worktree", "remove", "--force", &worktree])
        .output()
        .map_err(|e| format!("git worktree remove failed: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(format!("removed worktree {worktree}"))
}

// ── File tree helpers ────────────────────────────────────────────────────────

/// `git status --porcelain` for a workspace root. Returns `(relative_path, status_char)` pairs
/// where status_char is "M" (modified), "A" (added/staged), or "?" (untracked).
#[tauri::command(async)]
pub async fn git_status(root: String) -> Result<Vec<(String, String)>, String> {
    // async subprocess (tokio::process) so a slow `git status` on a large root does
    // NOT block a tokio worker thread. The sync std::process variant occupied a
    // worker for the whole subprocess; with the 5s poll across N roots that starved
    // the shared pool and made unrelated fast commands (list_dir/read_file) queue
    // for ~10s (L31). tokio::process yields the worker while git runs.
    let output = tokio::process::Command::new("git")
        .args(["-C", &root, "status", "--porcelain"])
        .output()
        .await
        .map_err(|e| format!("git not found: {e}"))?;
    if !output.status.success() {
        // Not a git repo or other error — return empty list silently.
        return Ok(vec![]);
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut result = Vec::new();
    for line in stdout.lines() {
        if line.len() < 3 {
            continue;
        }
        let x = line.chars().next().unwrap_or(' ');
        let y = line.chars().nth(1).unwrap_or(' ');
        let rel = line[3..]
            .trim_start_matches('"')
            .trim_end_matches('"')
            .to_string();
        let status = if x == '?' && y == '?' {
            "?"
        } else if x == 'A' || x == 'C' {
            "A"
        } else if x == 'M' || y == 'M' || x == 'R' {
            "M"
        } else if x == 'D' || y == 'D' {
            "D"
        } else {
            continue;
        };
        let abs = Path::new(&root).join(&rel).to_string_lossy().into_owned();
        result.push((abs, status.to_string()));
    }
    Ok(result)
}

/// Resolve a (possibly `~`- or cwd-relative) path and report what it is.
/// Used by the terminal path-link provider to linkify only real paths.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PathKind {
    /// Absolute, `~`/relative-expanded path.
    pub resolved: String,
    /// "file" | "dir" | "none"
    pub kind: String,
}

/// Expand `~`, join a relative path onto `cwd`, and classify the target.
#[tauri::command(async)]
pub fn resolve_path_kind(path: String, cwd: Option<String>) -> PathKind {
    let raw = path.trim();
    let expanded: String = if raw == "~" {
        std::env::var("HOME").unwrap_or_else(|_| raw.to_string())
    } else if let Some(rest) = raw.strip_prefix("~/") {
        std::env::var("HOME")
            .map(|h| format!("{h}/{rest}"))
            .unwrap_or_else(|_| raw.to_string())
    } else {
        raw.to_string()
    };

    let p = Path::new(&expanded);
    let resolved_pb = if p.is_absolute() {
        p.to_path_buf()
    } else if let Some(c) = cwd.as_deref().filter(|c| !c.is_empty()) {
        Path::new(c).join(&expanded)
    } else {
        p.to_path_buf()
    };

    let kind = if resolved_pb.is_dir() {
        "dir"
    } else if resolved_pb.is_file() {
        "file"
    } else {
        "none"
    };
    PathKind {
        resolved: resolved_pb.to_string_lossy().into_owned(),
        kind: kind.to_string(),
    }
}

/// Best-effort primary non-loopback IPv4 of this machine (for the bridge's
/// "listen on this LAN address" UI). Uses the connect-a-UDP-socket trick — no
/// packet is actually sent; the kernel just picks the source addr it would use.
///
/// The candidate is only returned if it is actually **bindable** (an assigned,
/// listenable interface address). If the trick yields nothing bindable — no
/// route, VPN quirk, stale addr — we fall back to `127.0.0.1` rather than
/// suggesting a phantom IP the user can't actually listen on.
#[tauri::command(async)]
pub fn local_ip() -> Result<String, String> {
    use std::net::{TcpListener, UdpSocket};
    const LOOPBACK: &str = "127.0.0.1";
    let candidate = (|| {
        let sock = UdpSocket::bind("0.0.0.0:0").ok()?;
        // 8.8.8.8 is only used to select the outbound interface; nothing is sent.
        sock.connect("8.8.8.8:80").ok()?;
        Some(sock.local_addr().ok()?.ip())
    })();
    match candidate {
        // Verify it's a real, bindable interface address before suggesting it.
        Some(ip) if TcpListener::bind((ip, 0)).is_ok() => Ok(ip.to_string()),
        _ => Ok(LOOPBACK.to_string()),
    }
}

/// Grant the webview's asset protocol (`convertFileSrc`/`asset://`) read access to ONE
/// file (PRD `file-viewer-dispatcher`) — the image/PDF viewer tabs call this before
/// rendering `<img>`/`<embed src=asset://...>`. File-scoped, not directory-scoped, so
/// opening one image never exposes its whole folder to the webview. No extra path
/// restriction beyond that: `read_file` already reads any local path unrestricted (this
/// is the equivalent operator-facing "show me this file" action, not an agent path).
#[tauri::command(async)]
pub fn allow_asset_path(path: String, app: tauri::AppHandle) -> Result<(), String> {
    use tauri::Manager;
    app.asset_protocol_scope()
        .allow_file(&path)
        .map_err(|e| format!("failed to allow asset path: {e}"))
}

/// What to tell the operator when macOS blocks a path.
///
/// macOS raises its privacy prompt the first time the app touches a protected
/// folder (Documents / Desktop / Downloads / iCloud / removable volumes). Once
/// that prompt is ANSWERED the decision is permanent — and if the answer was
/// "Don't Allow", the OS never prompts again: every read just returns EPERM
/// forever. There is no API to ask a second time. So the only honest thing to
/// show is where the switch actually lives.
fn access_denied_message(path: &str) -> String {
    format!(
        "macOS is blocking Muya from reading {path}. Grant access in \
         System Settings › Privacy & Security › Files and Folders (or turn on \
         Full Disk Access for Muya), then try again."
    )
}

/// Reported to the UI so a fresh install can explain itself instead of just
/// failing. `translocated` is the one that silently breaks everything.
#[derive(serde::Serialize)]
pub struct FileAccessStatus {
    pub translocated: bool,
    pub exe_path: String,
    pub folders: Vec<FolderAccess>,
}

#[derive(serde::Serialize)]
pub struct FolderAccess {
    pub name: String,
    pub path: String,
    pub granted: bool,
}

/// Is this executable running from an App Translocation mount?
///
/// macOS runs a QUARANTINED app (i.e. one that was downloaded, which is every
/// zip we ship) from a randomized read-only copy under
/// `/private/var/folders/.../AppTranslocation/<UUID>/d/Muya.app` whenever it is
/// launched from outside a trusted install location. The UUID is different on
/// every launch, so macOS sees a DIFFERENT APP each time: every privacy grant
/// the user gives is recorded against a path that will never exist again, and
/// the next launch asks for the same permission from scratch — forever. It also
/// makes the self-updater fail, because the mount is read-only.
///
/// Moving the app to /Applications (Finder's move strips the quarantine flag)
/// ends it permanently. Nothing the app can do at runtime fixes it from inside,
/// so all we can do is detect it and say so — which beats looking broken.
/// Reported by users on fresh installs, 2026-08-30; never reproducible on a
/// developer machine, where the app was long since moved and de-quarantined.
fn path_is_translocated(exe_path: &str) -> bool {
    exe_path.contains("/AppTranslocation/")
}

/// The `.app` bundle root for a given executable path, if it is inside one.
///
/// `<bundle>/Contents/MacOS/<exe>` — three levels up. Returns None for a bare
/// binary (`cargo run`, tests), which must never be touched.
fn bundle_root_from_exe(exe_path: &str) -> Option<String> {
    let p = Path::new(exe_path);
    let root = p.parent()?.parent()?.parent()?;
    root.extension()
        .filter(|e| *e == "app")
        .map(|_| root.to_string_lossy().into_owned())
}

/// Strip `com.apple.quarantine` from our own bundle, every launch.
///
/// Not a one-time chore: the updater REPLACES the bundle in place, and a
/// replaced bundle can come back carrying the quarantine flag. A quarantined app
/// living anywhere outside /Applications gets App Translocation on its NEXT
/// launch — so an update would silently reintroduce exactly the bug this release
/// fixes, and the user's file permission would reset all over again.
///
/// Safe by construction: we are already running, so macOS has already assessed
/// and admitted this exact bundle. Removing the flag from a binary the system
/// just executed grants nothing new. Skipped when translocated, because there
/// the path is the throwaway copy and the real bundle is out of reach — that
/// case is handled by telling the user to move the app.
///
/// Best-effort: a failure here is not worth blocking startup over.
pub fn strip_own_quarantine() {
    let Ok(exe) = std::env::current_exe() else { return };
    let exe = exe.to_string_lossy().into_owned();
    if path_is_translocated(&exe) {
        return;
    }
    let Some(bundle) = bundle_root_from_exe(&exe) else { return };
    let _ = Command::new("/usr/bin/xattr")
        .args(["-d", "-r", "com.apple.quarantine", &bundle])
        .output();
}

/// The protected folders a workspace realistically lives in.
fn protected_folders(home: &str) -> Vec<(String, String)> {
    ["Documents", "Desktop", "Downloads"]
        .iter()
        .map(|n| ((*n).to_string(), format!("{home}/{n}")))
        .collect()
}

/// Report whether Muya can actually read the user's folders.
///
/// `probe = true` deliberately lists each folder, which is what raises macOS's
/// permission prompt. That is the point: the prompt should appear when the user
/// pressed a button that explains why, not at random later. Already-granted
/// folders raise nothing, and an already-denied folder returns EPERM silently
/// (macOS never re-asks once answered), so probing is safe to repeat.
#[tauri::command(async)]
pub fn file_access_status(probe: bool) -> FileAccessStatus {
    let exe_path = std::env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    let home = std::env::var("HOME").unwrap_or_default();
    let folders = if home.is_empty() {
        Vec::new()
    } else {
        protected_folders(&home)
            .into_iter()
            .map(|(name, path)| {
                // `read_dir` is the operation that actually needs the grant.
                let granted = probe && std::fs::read_dir(&path).is_ok();
                FolderAccess {
                    name,
                    path,
                    granted,
                }
            })
            .collect()
    };
    FileAccessStatus {
        translocated: path_is_translocated(&exe_path),
        exe_path,
        folders,
    }
}

/// Open macOS's privacy settings so the operator can grant folder access.
///
/// This is the app's ONLY recourse after a denial — see `access_denied_message`.
/// The pane anchor has moved between macOS releases, so the Files-and-Folders
/// anchor is tried first and the Privacy & Security pane is the fallback.
///
/// Deliberately NOT `open -g`. The first version backgrounded System Settings to
/// avoid stealing focus — but the user pressed a button whose entire purpose is
/// "show me that window", and it opened behind Muya where they could not see it.
/// The button looked broken. Focus-stealing is wrong when the app decides to do
/// it; it is the correct and expected result of a click that asks for it.
#[tauri::command(async)]
pub fn open_privacy_settings() -> Result<(), String> {
    const PANES: [&str; 2] = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
        "x-apple.systempreferences:com.apple.preference.security?Privacy",
    ];
    let mut last_err = String::new();
    for pane in PANES {
        match Command::new("open").arg(pane).status() {
            Ok(st) if st.success() => return Ok(()),
            Ok(st) => last_err = format!("open exited with {st}"),
            Err(e) => last_err = format!("open failed: {e}"),
        }
    }
    Err(format!("could not open privacy settings: {last_err}"))
}

/// Open the given path in Finder (macOS: `open -R <path>`).
#[tauri::command(async)]
pub fn reveal_in_finder(path: String) -> Result<(), String> {
    Command::new("open")
        .args(["-R", &path])
        .spawn()
        .map_err(|e| format!("open -R failed: {e}"))?;
    Ok(())
}

/// Rename a file or directory to a new name within the same parent directory.
#[tauri::command(async)]
pub fn rename_entry(old_path: String, new_name: String) -> Result<(), String> {
    let old_path = crate::validate::valid_mutable_path(&old_path)?;
    // new_name is a single component joined onto the parent — block traversal so a
    // rename can't move the entry outside its directory (e.g. "../../evil").
    let new_name = crate::validate::valid_name(&new_name, "new_name")?;
    let p = Path::new(&old_path);
    let parent = p.parent().ok_or("no parent directory")?;
    let new_path = parent.join(&new_name);
    std::fs::rename(&old_path, &new_path).map_err(|e| format!("rename failed: {e}"))
}

/// Delete a file or directory (recursive for directories).
#[tauri::command(async)]
pub fn delete_entry(path: String) -> Result<(), String> {
    let path = crate::validate::valid_mutable_path(&path)?;
    let p = Path::new(&path);
    if p.is_dir() {
        std::fs::remove_dir_all(p).map_err(|e| format!("remove dir failed: {e}"))
    } else {
        std::fs::remove_file(p).map_err(|e| format!("remove file failed: {e}"))
    }
}

// ── Claude Resources Viewer ──────────────────────────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeSkill {
    pub name: String,
    pub path: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeAgent {
    pub name: String,
    pub path: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeHook {
    pub name: String,
    pub path: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeMcp {
    pub name: String,
    pub command: String,
    pub description: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeResources {
    pub skills: Vec<ClaudeSkill>,
    pub agents: Vec<ClaudeAgent>,
    pub hooks: Vec<ClaudeHook>,
    pub mcps: Vec<ClaudeMcp>,
}

/// Scan `~/.claude/{skills,agents,hooks}` and merge MCP JSON configs.
/// Returns a snapshot for the Resources Viewer tab.
#[tauri::command(async)]
pub fn list_claude_resources() -> Result<ClaudeResources, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    let claude = Path::new(&home).join(".claude");

    // --- Skills: immediate subdirectories of ~/.claude/skills/ ---
    let mut skills = Vec::new();
    let skills_dir = claude.join("skills");
    if let Ok(rd) = std::fs::read_dir(&skills_dir) {
        let mut entries: Vec<_> = rd.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let path = entry.path();
            if path.is_dir() {
                skills.push(ClaudeSkill {
                    name: entry.file_name().to_string_lossy().into_owned(),
                    path: path.to_string_lossy().into_owned(),
                });
            }
        }
    }

    // --- Agents: ~/.claude/agents/*.md ---
    let mut agents = Vec::new();
    let agents_dir = claude.join("agents");
    if let Ok(rd) = std::fs::read_dir(&agents_dir) {
        let mut entries: Vec<_> = rd
            .flatten()
            .filter(|e| e.path().extension().map(|x| x == "md").unwrap_or(false))
            .collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let path = entry.path();
            let name = path
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
            agents.push(ClaudeAgent {
                name,
                path: path.to_string_lossy().into_owned(),
            });
        }
    }

    // --- Hooks: ~/.claude/hooks/*.{sh,py,mjs} ---
    let mut hooks = Vec::new();
    let hooks_dir = claude.join("hooks");
    if let Ok(rd) = std::fs::read_dir(&hooks_dir) {
        let mut entries: Vec<_> = rd
            .flatten()
            .filter(|e| {
                let p = e.path();
                if !p.is_file() {
                    return false;
                }
                matches!(
                    p.extension().and_then(|x| x.to_str()),
                    Some("sh") | Some("py") | Some("mjs")
                )
            })
            .collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let path = entry.path();
            hooks.push(ClaudeHook {
                name: entry.file_name().to_string_lossy().into_owned(),
                path: path.to_string_lossy().into_owned(),
            });
        }
    }

    // --- MCPs: merge ~/.claude/.mcp.json + ~/.claude/claude-config/mcp.json ---
    let mcp_paths = [
        claude.join(".mcp.json"),
        claude.join("claude-config").join("mcp.json"),
    ];
    let mut mcps: Vec<ClaudeMcp> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for mcp_path in &mcp_paths {
        if let Ok(content) = std::fs::read_to_string(mcp_path) {
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                if let Some(servers) = val["mcpServers"].as_object() {
                    let mut sorted: Vec<_> = servers.iter().collect();
                    sorted.sort_by_key(|(k, _)| k.as_str());
                    for (name, cfg) in sorted {
                        if seen.contains(name) {
                            continue;
                        }
                        seen.insert(name.clone());
                        let command = cfg["command"]
                            .as_str()
                            .or_else(|| cfg["url"].as_str())
                            .unwrap_or("")
                            .to_string();
                        let description = cfg["description"].as_str().unwrap_or("").to_string();
                        mcps.push(ClaudeMcp {
                            name: name.clone(),
                            command,
                            description,
                        });
                    }
                }
            }
        }
    }

    Ok(ClaudeResources {
        skills,
        agents,
        hooks,
        mcps,
    })
}

// ── Marketplace ───────────────────────────────────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarketSkill {
    pub name: String,
    pub description: String,
    pub stars: String,
    pub author: String,
    pub github_url: String,
    pub featured: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarketMcp {
    pub name: String,
    pub description: String,
    pub command: String,
    pub args: Vec<String>,
    pub source: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarketResult {
    pub items: Vec<MarketMcp>,
    pub open_browser: bool,
}

/// Fetch skill listings from skillsmp.com.
/// Always prepends @st4unch featured skills at top, then adds query results (deduped).
#[tauri::command(async)]
pub async fn fetch_skill_marketplace(query: String) -> Result<Vec<MarketSkill>, String> {
    let client = reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36")
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;

    // 1. Always fetch @st4unch featured skills at top
    let featured_html = fetch_skillsmp_page(&client, "st4unch").await;
    let featured = parse_skillsmp_html(&featured_html, true);
    let featured_names: std::collections::HashSet<String> =
        featured.iter().map(|s| s.name.clone()).collect();

    // 2. Fetch query-specific skills (skip if identical to "st4unch")
    let mut skills = featured;
    if !query.is_empty() && query.to_lowercase() != "st4unch" {
        let query_html = fetch_skillsmp_page(&client, &query).await;
        for s in parse_skillsmp_html(&query_html, false) {
            if !featured_names.contains(&s.name) {
                skills.push(s);
            }
        }
    }

    Ok(skills)
}

async fn fetch_skillsmp_page(client: &reqwest::Client, q: &str) -> String {
    match client
        .get("https://skillsmp.com/search")
        .query(&[("q", q)])
        .send()
        .await
    {
        Ok(resp) => resp.text().await.unwrap_or_default(),
        Err(_) => String::new(),
    }
}

fn parse_skillsmp_html(html: &str, featured: bool) -> Vec<MarketSkill> {
    use scraper::{Html, Selector};
    let doc = Html::parse_document(html);
    let card_sel = Selector::parse("a[href*='/creators/']").unwrap();
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for card in doc.select(&card_sel) {
        let href = card.value().attr("href").unwrap_or("").to_string();
        if href.is_empty() || seen.contains(&href) {
            continue;
        }
        seen.insert(href.clone());
        let text: String = card
            .text()
            .collect::<Vec<_>>()
            .join(" ")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        if text.is_empty() {
            continue;
        }
        let parts: Vec<&str> = href.trim_matches('/').split('/').collect();
        let name = parts.last().copied().unwrap_or("unknown").to_string();
        let author = parts.get(1).copied().unwrap_or("").to_string();
        let github_url = if parts.len() >= 4 {
            format!("https://github.com/{}/{}", parts[2], parts[3])
        } else {
            String::new()
        };
        let stars = text
            .split_whitespace()
            .find(|t| {
                (t.ends_with('k') && t[..t.len() - 1].parse::<f64>().is_ok())
                    || t.parse::<u64>().is_ok()
            })
            .unwrap_or("—")
            .to_string();
        let description = text
            .trim_start_matches(name.as_str())
            .trim_start_matches(author.as_str())
            .trim_start_matches(stars.as_str())
            .trim()
            .chars()
            .take(120)
            .collect::<String>();
        out.push(MarketSkill {
            name,
            description,
            stars,
            author,
            github_url,
            featured,
        });
        if out.len() >= 50 {
            break;
        }
    }
    out
}

/// Fetch MCP listings from glama.ai public JSON API.
/// Returns items with name/description/source (glama page URL).
/// command/args are empty — user opens source link to get install instructions.
#[tauri::command(async)]
pub async fn fetch_mcp_marketplace(query: String) -> Result<MarketResult, String> {
    let client = reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36")
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;

    let mut req = client
        .get("https://glama.ai/api/mcp/v1/servers")
        .query(&[("first", "40")]);
    if !query.is_empty() {
        req = req.query(&[("search", &query)]);
    }

    if let Ok(resp) = req.send().await {
        if resp.status().is_success() {
            if let Ok(body) = resp.text().await {
                if let Ok(json) = serde_json::from_str::<serde_json::Value>(&body) {
                    let items = parse_glama_mcp_json(&json);
                    if !items.is_empty() {
                        return Ok(MarketResult {
                            items,
                            open_browser: false,
                        });
                    }
                }
            }
        }
    }

    Ok(MarketResult {
        items: Vec::new(),
        open_browser: true,
    })
}

fn parse_glama_mcp_json(json: &serde_json::Value) -> Vec<MarketMcp> {
    let mut items = Vec::new();
    if let Some(arr) = json["servers"].as_array() {
        for item in arr.iter().take(50) {
            let name = item["name"].as_str().unwrap_or("").to_string();
            if name.is_empty() {
                continue;
            }
            let description = item["description"].as_str().unwrap_or("").to_string();
            let source = item["url"]
                .as_str()
                .unwrap_or("https://glama.ai/mcp/servers")
                .to_string();
            items.push(MarketMcp {
                name,
                description,
                command: String::new(),
                args: Vec::new(),
                source,
            });
        }
    }
    items
}

/// Clone a skill from GitHub into ~/.claude/skills/<name>/.
#[tauri::command(async)]
pub fn install_skill(name: String, github_url: String) -> Result<(), String> {
    let name = crate::validate::valid_name(&name, "name")?;
    let github_url = crate::validate::valid_git_url(&github_url)?;
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    let dest = Path::new(&home).join(".claude").join("skills").join(&name);
    if dest.exists() {
        return Err(format!("~/.claude/skills/{name} already exists"));
    }
    // `--` ends option parsing so the URL/dest can never be read as a git flag.
    let out = Command::new("git")
        .args(["clone", "--depth=1", "--"])
        .arg(&github_url)
        .arg(dest.to_string_lossy().as_ref())
        .output()
        .map_err(|e| format!("git not found: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(())
}

/// Merge an MCP entry into the user's Claude config (`~/.claude.json`, user scope,
/// deduped by name). Claude Code reads user-scope MCP servers from `~/.claude.json`
/// — NOT `~/.claude/.mcp.json`, which it ignores — so entries must land here to be
/// visible to spawned `claude` sessions.
///
/// This file holds the user's ENTIRE Claude configuration (projects, auth, history),
/// so the merge is deliberately conservative: an existing-but-unparseable file is a
/// hard error (never overwrite it), every other key is preserved via a Value
/// round-trip, and the write is atomic (temp + rename) so a crash can't truncate it.
#[tauri::command(async)]
pub fn install_mcp(name: String, command: String, args: Vec<String>) -> Result<(), String> {
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    let cfg_path = Path::new(&home).join(".claude.json");
    install_mcp_at(&cfg_path, name, command, args)
}

/// Remove an MCP server entry by name from `~/.claude.json` (no-op if absent). Used to
/// migrate a renamed server (drop the stale key) without disturbing any other config.
pub fn remove_mcp(name: String) -> Result<(), String> {
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    let cfg_path = Path::new(&home).join(".claude.json");
    remove_mcp_at(&cfg_path, &name)
}

fn remove_mcp_at(cfg_path: &Path, name: &str) -> Result<(), String> {
    if !cfg_path.exists() {
        return Ok(());
    }
    let content = std::fs::read_to_string(cfg_path).map_err(|e| e.to_string())?;
    let mut root: serde_json::Value = serde_json::from_str(&content)
        .map_err(|e| format!("~/.claude.json is not valid JSON — refusing to modify it: {e}"))?;
    let removed = root
        .get_mut("mcpServers")
        .and_then(|s| s.as_object_mut())
        .map(|servers| servers.remove(name).is_some())
        .unwrap_or(false);
    if !removed {
        return Ok(()); // nothing to do — never rewrite the file needlessly
    }
    let out = serde_json::to_vec_pretty(&root).map_err(|e| e.to_string())?;
    crate::credstore::atomic_write(cfg_path, &out)
}

/// Path-injectable core of `install_mcp` so tests never touch the real
/// `~/.claude.json`. Production always goes through `install_mcp` (default path).
fn install_mcp_at(
    cfg_path: &Path,
    name: String,
    command: String,
    args: Vec<String>,
) -> Result<(), String> {
    let name = crate::validate::valid_name(&name, "name")?;
    // command is executed by Claude Code later — require a non-empty, non-NUL value.
    let command = crate::validate::clean_arg(&command, "command", true)?;

    let mut root: serde_json::Value = if cfg_path.exists() {
        let content = std::fs::read_to_string(cfg_path).map_err(|e| e.to_string())?;
        // Refuse to touch a config we can't parse — replacing it with a fresh object
        // would destroy the user's projects/auth/history.
        serde_json::from_str(&content)
            .map_err(|e| format!("~/.claude.json is not valid JSON — refusing to modify it: {e}"))?
    } else {
        serde_json::json!({})
    };

    let obj = root
        .as_object_mut()
        .ok_or("~/.claude.json is not a JSON object")?;
    // Create mcpServers only if absent; never disturb the other top-level keys.
    let servers = obj
        .entry("mcpServers")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .ok_or("~/.claude.json 'mcpServers' is not an object")?;

    let args_json: Vec<serde_json::Value> = args.iter().map(|a| serde_json::json!(a)).collect();
    servers.insert(
        name,
        serde_json::json!({ "command": command, "args": args_json }),
    );

    let out = serde_json::to_vec_pretty(&root).map_err(|e| e.to_string())?;
    // Atomic temp+rename (shared with credstore) — a mid-write crash can never leave
    // the user's Claude config truncated.
    crate::credstore::atomic_write(cfg_path, &out)
}

const MUYA_PLUGIN_INSTALL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

/// Pure decision: does a failed `claude plugin` invocation's combined output actually
/// mean "already added/installed" (idempotent success), given the process succeeded
/// or failed? Extracted so the idempotency rule is unit-testable without spawning a
/// real `claude` process.
fn is_idempotent_success(exit_success: bool, stdout: &str, stderr: &str) -> bool {
    if exit_success {
        return true;
    }
    format!("{stdout} {stderr}")
        .to_lowercase()
        .contains("already")
}

/// Run a single `claude plugin ...` subcommand and treat "already added/installed"
/// as success — the whole point of `install_muya_plugin` is idempotent end-state,
/// not "did this exact invocation do fresh work".
fn run_claude_plugin_cmd(args: &[&str]) -> Result<String, String> {
    // MUST use the resolver, not a bare "claude": a macOS GUI app launched from
    // Finder/Dock inherits a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) that does
    // NOT include ~/.local/bin or Homebrew, so `Command::new("claude")` fails with
    // "No such file or directory" for every operator whose claude lives there —
    // exactly what this button did on first release (v0.2.40).
    let bin = crate::agents::claude_bin();
    let out = Command::new(bin)
        .args(args)
        .output()
        .map_err(|e| format!("claude CLI not runnable at '{bin}': {e}"))?;
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
    if is_idempotent_success(out.status.success(), &stdout, &stderr) {
        return Ok(stdout);
    }
    Err(if stderr.is_empty() { stdout } else { stderr })
}

/// One-click install of Muya's own Claude Code plugin (`muya-mcp` — teaches Claude
/// how to use Muya's SSH/session MCP tools). Equivalent to the operator typing:
///   claude plugin marketplace add st4unch/muya
///   claude plugin install muya-mcp@muya
/// Both `claude` subprocess calls are blocking, so they run on the blocking pool
/// (never the tokio worker pool — see muya-agent skill §3 / lessons L16, L31) with a
/// wall-clock timeout so a hung/prompting `claude` process can't leave the Marketplace
/// panel's Install button spinning forever.
#[tauri::command(async)]
pub async fn install_muya_plugin() -> Result<String, String> {
    let work = tokio::task::spawn_blocking(|| -> Result<String, String> {
        run_claude_plugin_cmd(&["plugin", "marketplace", "add", "st4unch/muya"])?;
        run_claude_plugin_cmd(&["plugin", "install", "muya-mcp@muya"])?;
        Ok("muya-mcp plugin installed.".to_string())
    });

    match tokio::time::timeout(MUYA_PLUGIN_INSTALL_TIMEOUT, work).await {
        Ok(join_result) => join_result.map_err(|e| format!("install task panicked: {e}"))?,
        Err(_) => Err(format!(
            "timed out after {}s waiting for the claude CLI",
            MUYA_PLUGIN_INSTALL_TIMEOUT.as_secs()
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn translocation_is_detected_from_the_executable_path() {
        // The real shape macOS hands a downloaded app that was launched from
        // outside a trusted install location. The UUID changes every launch,
        // which is exactly why privacy grants never stick.
        assert!(path_is_translocated(
            "/private/var/folders/96/xk_1/T/AppTranslocation/9F0C1B2A-0000-4E11-9C3E-AAAABBBBCCCC/d/Muya.app/Contents/MacOS/muya"
        ));
        // Normal install locations must never be reported as translocated —
        // a false positive would nag every correctly-installed user forever.
        for ok in [
            "/Applications/Muya.app/Contents/MacOS/muya",
            "/Users/someone/Applications/Muya.app/Contents/MacOS/muya",
            "/Users/someone/Desktop/Muya.app/Contents/MacOS/muya",
            "/Users/someone/Documents/claude-control-plane/src-tauri/target/debug/muya",
        ] {
            assert!(!path_is_translocated(ok), "false positive on {ok}");
        }
        assert!(!path_is_translocated(""));
    }

    #[test]
    fn bundle_root_is_found_only_for_real_app_bundles() {
        assert_eq!(
            bundle_root_from_exe("/Applications/Muya.app/Contents/MacOS/muya").as_deref(),
            Some("/Applications/Muya.app")
        );
        // A bare binary (cargo run, test harness) has no bundle — we must never
        // run xattr against some unrelated parent directory.
        assert_eq!(bundle_root_from_exe("/Users/x/proj/target/debug/muya"), None);
        assert_eq!(bundle_root_from_exe("muya"), None);
        assert_eq!(bundle_root_from_exe(""), None);
    }

    #[test]
    fn protected_folders_are_the_three_tcc_gated_ones_under_home() {
        let f = protected_folders("/Users/someone");
        let names: Vec<&str> = f.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, ["Documents", "Desktop", "Downloads"]);
        assert_eq!(f[0].1, "/Users/someone/Documents");
    }

    use super::*;
    use crate::testutil::*;

    // ----- install_mcp: merges into ~/.claude.json safely -----

    #[test]
    fn install_mcp_merges_and_preserves_other_keys() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join(".claude.json");
        // A realistic config: other top-level keys + an existing MCP server.
        std::fs::write(
            &cfg,
            r#"{"numStartups":42,"mcpServers":{"blender":{"command":"uvx","args":["blender-mcp"]}}}"#,
        )
        .unwrap();

        install_mcp_at(
            &cfg,
            "muya-ssh".into(),
            "/path/to/muya-ssh-mcp".into(),
            vec![],
        )
        .unwrap();

        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&cfg).unwrap()).unwrap();
        // Our entry landed…
        assert_eq!(
            v["mcpServers"]["muya-ssh"]["command"],
            "/path/to/muya-ssh-mcp"
        );
        // …the pre-existing server is untouched…
        assert_eq!(v["mcpServers"]["blender"]["command"], "uvx");
        // …and unrelated top-level keys are preserved (not wiped).
        assert_eq!(v["numStartups"], 42);
    }

    #[test]
    fn install_mcp_creates_config_when_absent() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join(".claude.json");
        install_mcp_at(&cfg, "muya-ssh".into(), "/x/muya-ssh-mcp".into(), vec![]).unwrap();
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&cfg).unwrap()).unwrap();
        assert_eq!(v["mcpServers"]["muya-ssh"]["command"], "/x/muya-ssh-mcp");
    }

    // The critical safety property: an existing but unparseable config is NEVER
    // overwritten — refuse and leave the user's Claude config exactly as it was.
    #[test]
    fn install_mcp_refuses_to_clobber_unparseable_config() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join(".claude.json");
        let junk = "{ this is not valid json ";
        std::fs::write(&cfg, junk).unwrap();
        let err = install_mcp_at(&cfg, "muya-ssh".into(), "/x/muya-ssh-mcp".into(), vec![])
            .expect_err("must refuse an unparseable config");
        assert!(err.contains("refusing to modify"), "unexpected: {err}");
        // The original bytes survive untouched.
        assert_eq!(std::fs::read_to_string(&cfg).unwrap(), junk);
    }

    // ----- remove_mcp: migration drops the stale key, preserves everything else -----

    #[test]
    fn remove_mcp_drops_target_and_preserves_rest() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join(".claude.json");
        std::fs::write(
            &cfg,
            r#"{"numStartups":7,"mcpServers":{"muya-ssh":{"command":"/x/muya-ssh-mcp","args":[]},"blender":{"command":"uvx","args":["blender-mcp"]}}}"#,
        )
        .unwrap();
        remove_mcp_at(&cfg, "muya-ssh").unwrap();
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&cfg).unwrap()).unwrap();
        assert!(
            v["mcpServers"].get("muya-ssh").is_none(),
            "stale key removed"
        );
        assert_eq!(v["mcpServers"]["blender"]["command"], "uvx");
        assert_eq!(v["numStartups"], 7);
    }

    #[test]
    fn remove_mcp_noop_when_absent_or_no_config() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join(".claude.json");
        // No file at all → Ok, nothing created.
        remove_mcp_at(&cfg, "muya-ssh").unwrap();
        assert!(!cfg.exists());
        // File without the key → untouched.
        std::fs::write(&cfg, r#"{"mcpServers":{"blender":{"command":"uvx"}}}"#).unwrap();
        remove_mcp_at(&cfg, "muya-ssh").unwrap();
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&cfg).unwrap()).unwrap();
        assert_eq!(v["mcpServers"]["blender"]["command"], "uvx");
    }

    // ----- pure-function unit tests (no I/O) -----

    #[test]
    fn branch_kind_classifies() {
        assert_eq!(branch_kind("main", false), "PRD");
        assert_eq!(branch_kind("release/1.0", false), "PRD");
        assert_eq!(branch_kind("feature/x", false), "WIP");
        assert_eq!(branch_kind("fix/y", false), "WIP");
        assert_eq!(branch_kind("random", false), "OPEN");
        // main always PRD even if (oddly) checked out in a worktree.
        assert_eq!(branch_kind("main", true), "PRD");
        // No naming convention, but a worktree has it checked out → WIP.
        // This is the real fix: branches like "dev" or "backup/x" that don't
        // follow feature/fix/... prefixes still surface as WIP when a worktree
        // (an active agent's workspace) is on them.
        assert_eq!(branch_kind("dev", true), "WIP");
        assert_eq!(branch_kind("backup/pre-security-redact", true), "WIP");
        // Same names, no worktree → falls back to OPEN (no prefix match).
        assert_eq!(branch_kind("dev", false), "OPEN");
        assert_eq!(branch_kind("backup/pre-security-redact", false), "OPEN");
    }

    #[test]
    fn worktree_branches_lists_primary_and_linked() {
        let r = init_repo();
        run_git(&r.path, &["switch", "-c", "feature/wt-detect"]);
        put_file(&r.path, "f.txt", "x");
        run_git(&r.path, &["add", "."]);
        run_git(&r.path, &["commit", "-m", "wip"]);
        let set = worktree_branches(&r.path);
        assert!(
            set.contains("feature/wt-detect"),
            "expected primary worktree's checked-out branch in set, got {set:?}"
        );
    }

    #[test]
    fn track_to_status_maps() {
        assert_eq!(track_to_status(""), "synced");
        assert_eq!(track_to_status("[ahead 2]"), "ahead");
        assert_eq!(track_to_status("[behind 1]"), "synced");
        assert_eq!(track_to_status("[ahead 1, behind 3]"), "diverged");
    }

    // ----- hermetic git integration tests (temp repos) -----

    #[test]
    fn list_dir_sorts_dirs_first() {
        let r = init_repo();
        std::fs::create_dir(Path::new(&r.path).join("zdir")).unwrap();
        put_file(&r.path, "afile.txt", "x");
        let entries = list_dir(r.path.clone()).unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert!(names.contains(&"zdir") && names.contains(&"afile.txt"));
        let first_file = entries.iter().position(|e| !e.is_directory).unwrap();
        let dirs_before = entries[..first_file].iter().all(|e| e.is_directory);
        assert!(dirs_before, "dirs should precede files: {names:?}");
    }

    #[test]
    fn list_branches_and_parents() {
        let r = init_repo();
        // main → feature/a (1 commit) → feature/b (1 commit)
        run_git(&r.path, &["switch", "-c", "feature/a"]);
        commit_file(&r.path, "a.txt", "a", "a1");
        run_git(&r.path, &["switch", "-c", "feature/b"]);
        commit_file(&r.path, "b.txt", "b", "b1");
        run_git(&r.path, &["switch", "main"]);

        let bs = list_branches_sync(r.path.clone()).unwrap();
        let by = |n: &str| bs.iter().find(|b| b.name == n).unwrap();
        assert_eq!(bs.len(), 3);
        assert_eq!(by("feature/a").kind, "WIP");
        assert_eq!(by("main").parent, None);
        assert_eq!(by("feature/a").parent.as_deref(), Some("main"));
        assert_eq!(by("feature/b").parent.as_deref(), Some("feature/a"));
    }

    #[test]
    fn read_head_file_returns_committed_then_empty_for_untracked() {
        let r = init_repo();
        commit_file(&r.path, "f.txt", "committed\n", "c");
        put_file(&r.path, "f.txt", "working changes\n"); // dirty
        let head =
            read_head_file(Path::new(&r.path).join("f.txt").to_string_lossy().into()).unwrap();
        assert_eq!(head, "committed\n");
        // untracked file → empty HEAD
        put_file(&r.path, "new.txt", "x");
        let none =
            read_head_file(Path::new(&r.path).join("new.txt").to_string_lossy().into()).unwrap();
        assert_eq!(none, "");
    }

    #[test]
    fn create_and_remove_worktree() {
        let r = init_repo();
        let wt = create_worktree(r.path.clone(), "feature/wt".into()).unwrap();
        assert!(Path::new(&wt).exists(), "worktree dir exists");
        // listed by git
        let list = Command::new("git")
            .args(["-C", &r.path, "worktree", "list"])
            .output()
            .unwrap();
        assert!(String::from_utf8_lossy(&list.stdout).contains(&wt));
        remove_worktree(wt.clone()).unwrap();
        assert!(!Path::new(&wt).exists(), "worktree dir removed");
    }

    #[test]
    fn create_file_makes_empty_then_preserves_existing() {
        let r = init_repo();
        let f = Path::new(&r.path)
            .join("sub/new.txt")
            .to_string_lossy()
            .into_owned();
        create_file(f.clone()).unwrap();
        assert!(Path::new(&f).exists(), "new file created");
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "");
        // Re-creating over an existing file must NOT truncate it.
        std::fs::write(&f, "keep").unwrap();
        create_file(f.clone()).unwrap();
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "keep");
    }

    #[test]
    fn branch_detail_reports_commits_and_diff() {
        let r = init_repo();
        run_git(&r.path, &["switch", "-c", "feature/x"]);
        commit_file(&r.path, "x.txt", "x", "add x");
        run_git(&r.path, &["switch", "main"]);

        let d = branch_detail(r.path.clone(), "feature/x".into()).unwrap();
        assert_eq!(d.base, "main");
        assert_eq!(d.ahead, 1);
        assert_eq!(d.behind, 0);
        assert_eq!(d.commits.len(), 1);
        assert_eq!(d.commits[0].subject, "add x");
        assert!(d.changed_files.contains(&"x.txt".to_string()));
    }

    #[test]
    fn branch_detail_base_branch_has_nothing_ahead_and_errors_on_unknown() {
        let r = init_repo();
        commit_file(&r.path, "a.txt", "a", "c1");
        commit_file(&r.path, "b.txt", "b", "c2");
        // Inspecting main itself (no base above it) must not report its whole history
        // as "ahead".
        let d = branch_detail(r.path.clone(), "main".into()).unwrap();
        assert_eq!(d.base, "");
        assert_eq!(d.ahead, 0);
        assert_eq!(d.behind, 0);
        assert!(d.changed_files.is_empty());
        // Unknown branch → explicit error, not a silently empty card.
        assert!(branch_detail(r.path.clone(), "does-not-exist".into()).is_err());
    }
}

// ─── PRD document scanner ───────────────────────────────────────────────────

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PrdDoc {
    pub name: String,
    pub slug: String,
    pub prd_path: String,
    pub progress_path: Option<String>,
    pub status: String,
    pub owner: Option<String>,
    pub started: Option<String>,
    pub completed: Option<String>,
    pub total_phases: u32,
    pub done_phases: u32,
    pub phase_summary: Vec<String>,
}

fn parse_frontmatter_field(content: &str, key: &str) -> Option<String> {
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed == "---" && !content.starts_with(trimmed) {
            break;
        }
        if let Some(rest) = trimmed.strip_prefix(&format!("{key}:")) {
            let val = rest.trim().trim_matches('"').trim();
            if !val.is_empty() {
                return Some(val.to_string());
            }
        }
    }
    None
}

fn extract_status_from_prd(content: &str) -> String {
    for line in content.lines() {
        let lower = line.to_lowercase();
        if lower.contains("**status:**") || lower.contains("status:") {
            let cleaned = line
                .replace("**Status:**", "")
                .replace("**status:**", "")
                .replace("status:", "")
                .trim()
                .to_string();
            if !cleaned.is_empty() {
                return cleaned;
            }
        }
    }
    "unknown".to_string()
}

fn count_phases(content: &str) -> (u32, u32, Vec<String>) {
    let mut total = 0u32;
    let mut done = 0u32;
    let mut summaries = Vec::new();
    for line in content.lines() {
        let trimmed = line.trim();
        if (trimmed.starts_with("### Faz ") || trimmed.starts_with("### Phase "))
            && !trimmed.contains("Çıktı")
        {
            total += 1;
            let is_done =
                trimmed.contains("✅") || trimmed.contains("done") || trimmed.contains("PASS");
            if is_done {
                done += 1;
            }
            summaries.push(trimmed.trim_start_matches('#').trim().to_string());
        }
    }
    (total, done, summaries)
}

#[tauri::command(async)]
pub fn scan_prd_docs(dirs: Vec<String>) -> Vec<PrdDoc> {
    let mut results = Vec::new();
    for dir in &dirs {
        let docs_dir = Path::new(dir).join("docs");
        if !docs_dir.is_dir() {
            continue;
        }
        let entries = match std::fs::read_dir(&docs_dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        let mut prd_files: Vec<String> = Vec::new();
        let mut progress_files: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();

        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("prd-") && name.ends_with(".progress.md") {
                let slug = name
                    .strip_prefix("prd-")
                    .unwrap_or(&name)
                    .strip_suffix(".progress.md")
                    .unwrap_or(&name)
                    .to_string();
                progress_files.insert(slug, entry.path().to_string_lossy().to_string());
            } else if name.starts_with("prd-") && name.ends_with(".md") {
                prd_files.push(entry.path().to_string_lossy().to_string());
            }
        }

        for prd_path in prd_files {
            let file_name = Path::new(&prd_path)
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();
            let slug = file_name
                .strip_prefix("prd-")
                .unwrap_or(&file_name)
                .strip_suffix(".md")
                .unwrap_or(&file_name)
                .to_string();

            let prd_content = std::fs::read_to_string(&prd_path).unwrap_or_default();

            let title = prd_content
                .lines()
                .find(|l| l.starts_with("# "))
                .map(|l| l.trim_start_matches('#').trim().to_string())
                .unwrap_or_else(|| slug.replace('-', " "));

            let progress_path = progress_files.get(&slug).cloned();

            let (status, started, completed, total_phases, done_phases, phase_summary) =
                if let Some(pp) = &progress_path {
                    let prog_content = std::fs::read_to_string(pp).unwrap_or_default();
                    let st = parse_frontmatter_field(&prog_content, "status")
                        .unwrap_or_else(|| "draft".to_string());
                    let started = parse_frontmatter_field(&prog_content, "started");
                    let completed = parse_frontmatter_field(&prog_content, "completed");
                    let (total, done, sums) = count_phases(&prog_content);
                    (st, started, completed, total, done, sums)
                } else {
                    let st = extract_status_from_prd(&prd_content);
                    (st, None, None, 0, 0, Vec::new())
                };

            let owner = prd_content
                .lines()
                .find(|l| l.to_lowercase().contains("**owner:**"))
                .map(|l| {
                    l.replace("**Owner:**", "")
                        .replace("**owner:**", "")
                        .trim()
                        .to_string()
                });

            results.push(PrdDoc {
                name: title,
                slug,
                prd_path,
                progress_path,
                status,
                owner,
                started,
                completed,
                total_phases,
                done_phases,
                phase_summary,
            });
        }
    }
    // Dedup by slug: with multiple roots scanned (a repo + its worktrees share
    // committed docs), the SAME PRD can appear more than once. Keep the richest copy
    // — one WITH a progress file, else the most-advanced (more done phases).
    let mut by_slug: std::collections::HashMap<String, PrdDoc> = std::collections::HashMap::new();
    for doc in results {
        let replace = match by_slug.get(&doc.slug) {
            None => true,
            Some(cur) => {
                (doc.progress_path.is_some() && cur.progress_path.is_none())
                    || doc.done_phases > cur.done_phases
            }
        };
        if replace {
            by_slug.insert(doc.slug.clone(), doc);
        }
    }
    let mut results: Vec<PrdDoc> = by_slug.into_values().collect();
    results.sort_by(|a, b| a.name.cmp(&b.name));
    results
}

#[cfg(test)]
mod path_kind_tests {
    use super::*;

    #[test]
    fn resolve_path_kind_classifies() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        // absolute dir
        assert_eq!(
            resolve_path_kind(d.to_string_lossy().into(), None).kind,
            "dir"
        );
        // absolute file
        let f = d.join("a.txt");
        std::fs::write(&f, "x").unwrap();
        let r = resolve_path_kind(f.to_string_lossy().into(), None);
        assert_eq!(r.kind, "file");
        assert_eq!(r.resolved, f.to_string_lossy());
        // relative joined to cwd
        let rel = resolve_path_kind("a.txt".into(), Some(d.to_string_lossy().into()));
        assert_eq!(rel.kind, "file");
        assert_eq!(rel.resolved, f.to_string_lossy());
        // non-existent
        assert_eq!(
            resolve_path_kind("/no/such/path/xyz".into(), None).kind,
            "none"
        );
        // trailing token that isn't a path
        assert_eq!(resolve_path_kind("not-a-path".into(), None).kind, "none");
    }

    #[test]
    fn resolve_path_kind_expands_tilde() {
        // ~ expands to $HOME which exists as a dir.
        if std::env::var("HOME").is_ok() {
            assert_eq!(resolve_path_kind("~".into(), None).kind, "dir");
        }
    }

    // ----- install_muya_plugin: idempotency decision -----

    #[test]
    fn idempotent_success_when_exit_ok() {
        assert!(is_idempotent_success(true, "installed", ""));
    }

    #[test]
    fn idempotent_success_when_already_added() {
        assert!(is_idempotent_success(
            false,
            "",
            "Error: marketplace 'muya' already exists"
        ));
        assert!(is_idempotent_success(
            false,
            "plugin muya-mcp is already installed",
            ""
        ));
    }

    #[test]
    fn not_idempotent_success_on_a_real_failure() {
        assert!(!is_idempotent_success(
            false,
            "",
            "Error: repository not found"
        ));
        assert!(!is_idempotent_success(false, "", ""));
    }
}

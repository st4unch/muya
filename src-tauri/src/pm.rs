//! Project Manager: stateless, compute-on-demand git status + push/merge queue
//! checks. No background daemon, no machine-specific paths — the frontend passes the
//! paths to inspect; everything is derived live from `git` (found on PATH). Agnostic
//! by construction: base branch is detected per-repo, never assumed.

use std::path::Path;
use std::process::Command;

use serde::Serialize;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectStatus {
    pub path: String,
    pub name: String,
    pub is_git: bool,
    pub branch: String,
    pub base: String,
    pub ahead: u32,
    pub behind: u32,
    /// Uncommitted (working tree) changes count.
    pub dirty: u32,
    /// Files changed on this branch vs base.
    pub changed: u32,
    /// Last commit time, ms epoch (0 if unknown).
    pub last_activity: i64,
}

fn git(repo: &str, args: &[&str]) -> Option<String> {
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

/// Detect the repo's integration branch without assuming a name.
fn base_branch(repo: &str) -> String {
    if let Some(h) = git(repo, &["symbolic-ref", "refs/remotes/origin/HEAD"]) {
        if let Some(b) = h.rsplit('/').next() {
            if !b.is_empty() {
                return b.to_string();
            }
        }
    }
    for cand in ["main", "master"] {
        if git(repo, &["rev-parse", "--verify", "--quiet", cand]).is_some() {
            return cand.to_string();
        }
    }
    "main".to_string()
}

/// Like `git`, but does NOT trim — preserves leading spaces, which matter for
/// `status --porcelain` where column 0 is part of the status field.
fn git_raw(repo: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn name_of(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string())
}

fn status_for(path: &str) -> ProjectStatus {
    let mut s = ProjectStatus {
        name: name_of(path),
        path: path.to_string(),
        is_git: false,
        branch: String::new(),
        base: String::new(),
        ahead: 0,
        behind: 0,
        dirty: 0,
        changed: 0,
        last_activity: 0,
    };
    if git(path, &["rev-parse", "--is-inside-work-tree"]).as_deref() != Some("true") {
        return s;
    }
    s.is_git = true;
    s.branch = git(path, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_default();
    s.base = base_branch(path);
    s.dirty = git(path, &["status", "--porcelain"])
        .map(|o| o.lines().filter(|l| !l.is_empty()).count() as u32)
        .unwrap_or(0);
    if s.branch != s.base {
        // left-right count of base...HEAD → "<behind>\t<ahead>"
        if let Some(c) = git(
            path,
            &[
                "rev-list",
                "--left-right",
                "--count",
                &format!("{}...HEAD", s.base),
            ],
        ) {
            let mut it = c.split_whitespace();
            s.behind = it.next().and_then(|x| x.parse().ok()).unwrap_or(0);
            s.ahead = it.next().and_then(|x| x.parse().ok()).unwrap_or(0);
        }
        s.changed = git(
            path,
            &["diff", "--name-only", &format!("{}...HEAD", s.base)],
        )
        .map(|o| o.lines().filter(|l| !l.is_empty()).count() as u32)
        .unwrap_or(0);
    }
    s.last_activity = git(path, &["log", "-1", "--format=%ct"])
        .and_then(|t| t.parse::<i64>().ok())
        .map(|secs| secs * 1000)
        .unwrap_or(0);
    s
}

/// Live status for the given project/worktree paths (non-git paths reported as such).
#[tauri::command(async)]
pub fn pm_status(paths: Vec<String>) -> Vec<ProjectStatus> {
    paths.iter().map(|p| status_for(p)).collect()
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MergeCheck {
    pub clean: bool,
    pub detail: String,
}

/// Trial-merge a branch into its base WITHOUT touching the working tree (git
/// merge-tree). Reports whether it would merge cleanly.
#[tauri::command(async)]
pub fn pm_check_merge(repo: String, branch: String) -> Result<MergeCheck, String> {
    let base = base_branch(&repo);
    if branch == base {
        return Ok(MergeCheck {
            clean: true,
            detail: format!("already on base ({base})"),
        });
    }
    let out = Command::new("git")
        .args(["-C", &repo, "merge-tree", "--write-tree", &base, &branch])
        .output()
        .map_err(|e| format!("git merge-tree failed: {e}"))?;
    if out.status.success() {
        Ok(MergeCheck {
            clean: true,
            detail: format!("merges cleanly into {base}"),
        })
    } else {
        let txt = String::from_utf8_lossy(&out.stdout);
        let conflicts: Vec<&str> = txt
            .lines()
            .filter(|l| l.contains("CONFLICT") || l.contains("changed in both"))
            .take(5)
            .collect();
        Ok(MergeCheck {
            clean: false,
            detail: if conflicts.is_empty() {
                format!("conflicts merging into {base}")
            } else {
                conflicts.join("; ")
            },
        })
    }
}

/// Local merge: merge `branch` into the repo's base branch. Operator-confirmed in UI.
/// Switches to base first (fails safely if the tree is dirty).
#[tauri::command(async)]
pub fn pm_merge(repo: String, branch: String) -> Result<String, String> {
    let base = base_branch(&repo);
    let switch = Command::new("git")
        .args(["-C", &repo, "switch", &base])
        .output()
        .map_err(|e| format!("git switch failed: {e}"))?;
    if !switch.status.success() {
        return Err(format!(
            "could not switch to {base}: {}",
            String::from_utf8_lossy(&switch.stderr)
        ));
    }
    let merge = Command::new("git")
        .args(["-C", &repo, "merge", "--no-ff", &branch])
        .output()
        .map_err(|e| format!("git merge failed: {e}"))?;
    if !merge.status.success() {
        return Err(format!(
            "merge failed: {}",
            String::from_utf8_lossy(&merge.stderr)
        ));
    }
    Ok(format!("merged {branch} into {base}"))
}

/// Push a branch to its remote. Operator-confirmed in UI (Golden Rule §6).
#[tauri::command(async)]
pub fn pm_push(repo: String, branch: String) -> Result<String, String> {
    let out = Command::new("git")
        .args(["-C", &repo, "push", "origin", &branch])
        .output()
        .map_err(|e| format!("git push failed: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(format!("pushed {branch} to origin"))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Collision {
    /// Repo-relative file path edited in more than one worktree.
    pub file: String,
    /// Names of the worktrees with uncommitted changes to that file.
    pub worktrees: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CollisionReport {
    pub collisions: Vec<Collision>,
    /// Total uncommitted file changes across all tracked worktrees.
    pub edited_files: u32,
}

/// Real, hook-free collision detection: the same repo-relative file being edited
/// (uncommitted) in two or more worktrees of the same repo. Compares working-tree
/// changes via `git status --porcelain`.
#[tauri::command(async)]
pub fn pm_collisions(paths: Vec<String>) -> CollisionReport {
    use std::collections::HashMap;
    // repo common-dir -> (repo-relative file -> worktree names that changed it)
    let mut map: HashMap<String, HashMap<String, Vec<String>>> = HashMap::new();
    let mut edited = 0u32;
    // A worktree's identity is its ROOT, not the path the operator happened to add.
    // Adding both a repo and a folder inside it would otherwise look like two
    // worktrees reporting the same `git status`, flagging every dirty file as a
    // collision. Scan each distinct root once.
    let mut seen_roots: std::collections::HashSet<String> = std::collections::HashSet::new();
    for p in &paths {
        if git(p, &["rev-parse", "--is-inside-work-tree"]).as_deref() != Some("true") {
            continue;
        }
        let root = git(p, &["rev-parse", "--show-toplevel"]).unwrap_or_else(|| p.clone());
        if !seen_roots.insert(root.clone()) {
            continue; // same worktree already scanned via another entry
        }
        let common = git(
            p,
            &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        )
        .unwrap_or_else(|| p.clone());
        // Name from the worktree root so two entries into the same tree agree.
        let wt_name = name_of(&root);
        if let Some(porc) = git_raw(p, &["status", "--porcelain"]) {
            for line in porc.lines() {
                if line.len() < 3 {
                    continue;
                }
                let xy = &line[..2];
                // Skip untracked (??) and ignored (!!) entries — they are not real
                // conflicts; the same untracked file in two worktrees is not a collision.
                if xy == "??" || xy == "!!" {
                    continue;
                }
                // porcelain: 2 status chars + space + path
                let rest: String = line.chars().skip(3).collect();
                let file = rest.trim();
                if file.is_empty() {
                    continue;
                }
                // renames render as "old -> new"; take the new path
                let file = file.rsplit(" -> ").next().unwrap_or(file).to_string();
                edited += 1;
                map.entry(common.clone())
                    .or_default()
                    .entry(file)
                    .or_default()
                    .push(wt_name.clone());
            }
        }
    }
    let mut collisions = Vec::new();
    for (_repo, files) in map {
        for (file, mut wts) in files {
            wts.sort();
            wts.dedup();
            if wts.len() >= 2 {
                collisions.push(Collision {
                    file,
                    worktrees: wts,
                });
            }
        }
    }
    collisions.sort_by(|a, b| a.file.cmp(&b.file));
    CollisionReport {
        collisions,
        edited_files: edited,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    #[test]
    fn pm_status_ahead_and_dirty() {
        let r = init_repo();
        run_git(&r.path, &["switch", "-c", "feature/x"]);
        commit_file(&r.path, "x.txt", "x", "x1"); // 1 ahead of main
        put_file(&r.path, "x.txt", "dirty"); // uncommitted change
        let s = &pm_status(vec![r.path.clone()])[0];
        assert!(s.is_git);
        assert_eq!(s.branch, "feature/x");
        assert_eq!(s.base, "main");
        assert_eq!(s.ahead, 1);
        assert_eq!(s.behind, 0);
        assert_eq!(s.dirty, 1);
        assert_eq!(s.changed, 1);
    }

    #[test]
    fn pm_status_non_git() {
        let dir = tempfile::tempdir().unwrap();
        let s = &pm_status(vec![dir.path().to_string_lossy().into()])[0];
        assert!(!s.is_git);
    }

    #[test]
    fn pm_check_merge_clean_vs_conflict() {
        let r = init_repo();
        commit_file(&r.path, "shared.txt", "line1\nline2\n", "base");
        // clean branch: edits a different file
        run_git(&r.path, &["switch", "-c", "feature/clean"]);
        commit_file(&r.path, "other.txt", "new\n", "c");
        // conflicting branch: edits the same line as a later main change
        run_git(&r.path, &["switch", "main"]);
        run_git(&r.path, &["switch", "-c", "feature/conflict"]);
        commit_file(&r.path, "shared.txt", "lineX\nline2\n", "cf");
        run_git(&r.path, &["switch", "main"]);
        commit_file(&r.path, "shared.txt", "lineY\nline2\n", "main-change");

        let clean = pm_check_merge(r.path.clone(), "feature/clean".into()).unwrap();
        assert!(clean.clean, "clean branch should merge: {}", clean.detail);
        let conflict = pm_check_merge(r.path.clone(), "feature/conflict".into()).unwrap();
        assert!(!conflict.clean, "should conflict: {}", conflict.detail);
    }

    #[test]
    fn pm_collisions_ignores_repo_added_twice_as_subdir() {
        // REGRESSION: the operator adds a repo AND a folder inside it as separate
        // workspaces. Both resolve to the same worktree and report the same
        // `git status`, which used to mark every dirty file as a collision.
        let r = init_repo();
        commit_file(&r.path, "app.txt", "orig\n", "base");
        std::fs::create_dir_all(format!("{}/sub", r.path)).unwrap();
        commit_file(&r.path, "sub/inner.txt", "x\n", "sub");
        // one real edit in the single worktree
        put_file(&r.path, "app.txt", "changed\n");

        let report = pm_collisions(vec![r.path.clone(), format!("{}/sub", r.path)]);
        assert!(
            report.collisions.is_empty(),
            "same worktree added twice must not collide with itself: {:?}",
            report.collisions
        );
    }

    #[test]
    fn pm_collisions_same_file_two_worktrees() {
        let r = init_repo();
        commit_file(&r.path, "app.txt", "orig\n", "base");
        // two worktrees off the same repo
        let wt1 = crate::fs::create_worktree(r.path.clone(), "feature/a".into()).unwrap();
        let wt2 = crate::fs::create_worktree(r.path.clone(), "feature/b".into()).unwrap();
        // both edit the SAME repo-relative file → collision
        put_file(&wt1, "app.txt", "from a\n");
        put_file(&wt2, "app.txt", "from b\n");
        let report = pm_collisions(vec![wt1.clone(), wt2.clone()]);
        assert_eq!(report.collisions.len(), 1, "{:?}", report.collisions);
        assert_eq!(report.collisions[0].file, "app.txt");
        assert_eq!(report.collisions[0].worktrees.len(), 2);

        // editing DIFFERENT files → no collision
        put_file(&wt1, "only-a.txt", "x");
        let report2 = pm_collisions(vec![wt1.clone(), wt2.clone()]);
        // app.txt still collides, only-a.txt does not
        assert!(report2.collisions.iter().all(|c| c.file == "app.txt"));
    }

    #[test]
    #[ignore = "machine-specific: needs a real local repo"]
    fn pm_status_smoke() {
        let repo = "/Users/staunch/Documents/mcp-context-forge";
        if !Path::new(repo).exists() {
            return;
        }
        let s = &pm_status(vec![repo.to_string()])[0];
        assert!(s.is_git);
    }
}

//! Test-only helpers for building hermetic git repositories in a temp dir, so tests
//! are machine-independent (no hardcoded paths, no reliance on the host's repos).

use std::path::Path;
use std::process::Command;

use tempfile::TempDir;

pub struct TempRepo {
    /// Held to keep the temp dir alive for the test's duration (RAII), not read.
    #[allow(dead_code)]
    pub dir: TempDir,
    pub path: String,
}

/// Run a git command in `repo` and assert success.
pub fn run_git(repo: &str, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .expect("git runs");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// Write a file (relative to the repo) and stage+commit it.
pub fn commit_file(repo: &str, rel: &str, content: &str, msg: &str) {
    let full = Path::new(repo).join(rel);
    if let Some(parent) = full.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(full, content).unwrap();
    run_git(repo, &["add", "."]);
    run_git(repo, &["commit", "-m", msg]);
}

/// Just write a file without committing (dirty working tree).
pub fn put_file(repo: &str, rel: &str, content: &str) {
    std::fs::write(Path::new(repo).join(rel), content).unwrap();
}

/// A fresh repo on `main` with one initial commit. Deterministic default branch.
pub fn init_repo() -> TempRepo {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_string_lossy().into_owned();
    run_git(&path, &["init", "-b", "main"]);
    run_git(&path, &["config", "user.email", "t@example.com"]);
    run_git(&path, &["config", "user.name", "Test"]);
    commit_file(&path, "README.md", "# test\n", "init");
    TempRepo { dir, path }
}

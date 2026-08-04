//! Persisted workspace roots — the source of truth for `ssh_scp`'s local-path
//! guardrail (PRD `ssh-scp`, AC3; see `local_guard.rs`).
//!
//! GROUNDING NOTE (2026-08-04): before this feature, "workspace roots" existed
//! ONLY in the frontend's `localStorage` (`apex.workspaces`, `App.tsx`) — there
//! was no Rust-side/on-disk source `ssh_scp`'s Rust-only guardrail could read (the
//! mini-PRD assumed one existed and said to grep for it; it does not). This module
//! is the new, minimal bridge: the frontend mirrors its tracked workspace+worktree
//! paths here (see `App.tsx`'s `set_workspace_roots` call) via `save_workspace_roots`,
//! atomically, the same way `ssh.rs`/`credstore.rs` persist their own config. The
//! broker (`broker.rs::handle_scp`) reads it with `load_workspace_roots` — no
//! secret, no write path reachable by an agent.

use std::path::{Path, PathBuf};

fn roots_path() -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    Ok(Path::new(&home).join(".claude/muya-workspace-roots.json"))
}

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct RootsFile {
    #[serde(default)]
    roots: Vec<String>,
}

/// Load the persisted workspace roots. Absent/empty/malformed file ⇒ empty list
/// (fail-closed for the GUARDRAIL, not the loader: `local_guard` treats an empty
/// list as "refuse everything", not "allow everything").
pub(crate) fn load_workspace_roots() -> Result<Vec<String>, String> {
    load_workspace_roots_from(&roots_path()?)
}

pub(crate) fn load_workspace_roots_from(path: &Path) -> Result<Vec<String>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(format!("read workspace roots: {e}")),
    };
    if text.trim().is_empty() {
        return Ok(vec![]);
    }
    match serde_json::from_str::<RootsFile>(&text) {
        Ok(f) => Ok(f.roots),
        Err(_) => Ok(vec![]), // malformed ⇒ fail-closed empty (guardrail: refuse, not allow)
    }
}

pub(crate) fn save_workspace_roots(roots: &[String]) -> Result<(), String> {
    save_workspace_roots_to(&roots_path()?, roots)
}

fn save_workspace_roots_to(path: &Path, roots: &[String]) -> Result<(), String> {
    let f = RootsFile {
        roots: roots.to_vec(),
    };
    let bytes = serde_json::to_vec_pretty(&f).map_err(|e| e.to_string())?;
    crate::credstore::atomic_write(path, &bytes)
}

/// The frontend calls this whenever its tracked workspace/worktree paths change
/// (mirrors `App.tsx`'s `localStorage.setItem("apex.workspaces", …)` effect) so
/// the Rust-side broker always has an up-to-date list for the `ssh_scp` guardrail.
/// Carries no secret — just plain filesystem paths the operator already opened.
#[tauri::command]
pub fn set_workspace_roots(roots: Vec<String>) -> Result<(), String> {
    save_workspace_roots(&roots)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_file_loads_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("muya-workspace-roots.json");
        assert!(load_workspace_roots_from(&path).unwrap().is_empty());
    }

    #[test]
    fn round_trips_through_disk() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("muya-workspace-roots.json");
        save_workspace_roots_to(
            &path,
            &["/Users/x/proj-a".to_string(), "/Users/x/proj-b".to_string()],
        )
        .unwrap();
        let loaded = load_workspace_roots_from(&path).unwrap();
        assert_eq!(loaded, vec!["/Users/x/proj-a", "/Users/x/proj-b"]);
    }

    #[test]
    fn malformed_file_fails_closed_to_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("muya-workspace-roots.json");
        std::fs::write(&path, "{ not json").unwrap();
        assert!(load_workspace_roots_from(&path).unwrap().is_empty());
    }
}

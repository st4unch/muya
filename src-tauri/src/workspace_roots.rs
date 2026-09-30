//! Workspace roots — the source of truth for `ssh_scp`'s local-path guardrail (PRD
//! `ssh-scp`, AC3; see `local_guard.rs`).
//!
//! The frontend owns the list (its tracked workspace + worktree paths) and pushes it
//! here with `set_workspace_roots` whenever it changes. The broker that enforces the
//! guardrail (`broker.rs::handle_scp`) runs INSIDE the same Muya process, so the list
//! lives in this process's memory.
//!
//! It used to be a shared file (`~/.claude/muya-workspace-roots.json`). Every Muya
//! instance wrote it and every instance's broker read it, so launching a second Muya
//! (a dev or test build with no workspaces) replaced the first instance's list with
//! `[]` — and the running app's `ssh_scp` silently refused every local path.
//! Found 2026-09-30. The file is no longer written or read; an older running build
//! may still use it, which is exactly why this one leaves it alone.
//!
//! Fail-closed: until the frontend has pushed a list, the guardrail sees `[]`, and
//! `local_guard` treats an empty list as "refuse everything", not "allow everything".

use std::sync::RwLock;

static ROOTS: RwLock<Vec<String>> = RwLock::new(Vec::new());

/// The roots this process's frontend last pushed (empty until it has).
pub(crate) fn load_workspace_roots() -> Result<Vec<String>, String> {
    ROOTS
        .read()
        .map(|r| r.clone())
        .map_err(|_| "workspace roots lock poisoned".to_string())
}

/// The frontend calls this whenever its tracked workspace/worktree paths change.
/// Carries no secret — just plain filesystem paths the operator already opened.
#[tauri::command]
pub fn set_workspace_roots(roots: Vec<String>) -> Result<(), String> {
    let mut slot = ROOTS
        .write()
        .map_err(|_| "workspace roots lock poisoned".to_string())?;
    *slot = roots;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // One test owns the process-wide static, so the steps can't race each other.
    #[test]
    fn roots_live_in_this_process_and_ignore_the_legacy_shared_file() {
        set_workspace_roots(vec![]).unwrap();
        assert!(
            load_workspace_roots().unwrap().is_empty(),
            "fail-closed before a push"
        );

        set_workspace_roots(vec!["/Users/x/proj-a".into(), "/Users/x/proj-b".into()]).unwrap();
        assert_eq!(
            load_workspace_roots().unwrap(),
            vec!["/Users/x/proj-a", "/Users/x/proj-b"]
        );

        // What another instance (or an older build) writes to the old shared file must
        // not change this process's list.
        let home = tempfile::tempdir().unwrap();
        let legacy = home.path().join(".claude/muya-workspace-roots.json");
        std::fs::create_dir_all(legacy.parent().unwrap()).unwrap();
        std::fs::write(&legacy, r#"{"roots":[]}"#).unwrap();
        assert_eq!(load_workspace_roots().unwrap().len(), 2);

        set_workspace_roots(vec![]).unwrap();
    }
}

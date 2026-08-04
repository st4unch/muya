//! Local-filesystem guardrail for `ssh_scp` (PRD `ssh-scp`, AC3 — SECURITY CRITICAL).
//!
//! `ssh_scp` is the first agent-facing tool that reads/writes the LOCAL filesystem
//! (every prior broker op only ever touched a REMOTE host or the encrypted secret
//! store). Without a guardrail an agent could exfiltrate `~/.ssh/id_rsa` (upload)
//! or overwrite `/etc/hosts` (download) simply by naming the path.
//!
//! Operator decision (2026-08-04, `docs/prd-ssh-scp.progress.md` § Kararlar):
//! confine `localPath` to the configured **workspace roots** (the same folders the
//! operator already opened in Muya's file tree / New-agent worktrees), NOT a
//! dedicated `~/.claude/muya-scp/` sandbox. `workspace_roots.rs` persists that list
//! (see its header — no such server-side source existed before this feature).
//!
//! The check is fail-closed and canonicalization-based (resolves BOTH `..` and
//! symlinks), so all four AC3 cases are covered by the SAME code path:
//!   * `~/.ssh/id_rsa`, `/etc/passwd` — canonical path never `starts_with` a root.
//!   * `..` escape — `Path::canonicalize` collapses `..` before the prefix check.
//!   * a workspace-internal symlink pointing outside — `canonicalize` follows it;
//!     the RESOLVED target (not the symlink's own location) is what's checked.
//! On any rejection the caller (`broker.rs::handle_scp`) MUST return before ever
//! invoking `scp` or touching the path further (no partial reads/writes).

use std::path::{Path, PathBuf};

/// Resolve + guardrail-check a `localPath` from the agent. `for_download` is true
/// when this is a WRITE target that may not exist yet (the leaf file); the nearest
/// EXISTING ancestor is canonicalized (resolving any symlinks up to that point) and
/// the still-missing tail is rejoined literally — so a download can target a new
/// file without requiring it to pre-exist, while a symlink-escape on any EXISTING
/// ancestor is still caught. For an upload (`for_download == false`) the full path
/// is expected to already exist (the source file); a missing upload source is
/// reported as a plain "not found", not silently treated as a new-file case.
pub(crate) fn resolve_local_scp_path(
    candidate: &str,
    roots: &[String],
    for_download: bool,
) -> Result<PathBuf, String> {
    let trimmed = candidate.trim();
    if trimmed.is_empty() {
        return Err("localPath is required".to_string());
    }
    if trimmed.contains('\0') {
        return Err("localPath contains an invalid NUL byte".to_string());
    }
    let raw = Path::new(trimmed);
    if !raw.is_absolute() {
        return Err("localPath must be an absolute path".to_string());
    }

    if roots.is_empty() {
        return Err(
            "no workspace roots are configured in Muya — open a project/workspace folder \
             first (ssh_scp is confined to workspace roots)"
                .to_string(),
        );
    }
    let canon_roots: Vec<PathBuf> = roots
        .iter()
        .filter_map(|r| Path::new(r).canonicalize().ok())
        .collect();
    if canon_roots.is_empty() {
        return Err("no configured workspace root could be resolved on disk".to_string());
    }

    if !for_download && !raw.exists() {
        return Err(format!("localPath '{trimmed}' does not exist"));
    }

    let resolved = canonicalize_allowing_missing_leaf(raw)?;

    let inside = canon_roots.iter().any(|root| resolved.starts_with(root));
    if !inside {
        return Err(format!(
            "localPath '{trimmed}' is outside the configured workspace roots — refusing \
             (ssh_scp never reads/writes outside a workspace root)"
        ));
    }
    Ok(resolved)
}

/// Canonicalize `p`. If `p` (or a suffix of it) does not exist yet, walk up to the
/// nearest EXISTING ancestor, canonicalize THAT (resolving symlinks up to there),
/// then rejoin the missing tail components literally. Any `..`/`.` component in the
/// missing tail is rejected explicitly (defense in depth — `Path` parsing already
/// keeps them as literal components here since they were never resolved by the OS).
fn canonicalize_allowing_missing_leaf(p: &Path) -> Result<PathBuf, String> {
    if let Ok(c) = p.canonicalize() {
        return Ok(c);
    }
    // Walk up to the nearest EXISTING ancestor.
    let mut existing = p.to_path_buf();
    loop {
        if !existing.pop() {
            return Err("localPath has no resolvable ancestor directory".to_string());
        }
        if existing.exists() {
            break;
        }
    }
    // The still-missing tail, relative to that ancestor. Reject any `..`/`.` in it
    // explicitly (defense in depth — these components were never resolved by the
    // OS since the path doesn't exist yet).
    let tail = p
        .strip_prefix(&existing)
        .map_err(|_| "localPath resolution error".to_string())?;
    let mut missing_tail: Vec<std::ffi::OsString> = Vec::new();
    for comp in tail.components() {
        use std::path::Component;
        match comp {
            Component::Normal(s) => missing_tail.push(s.to_os_string()),
            Component::CurDir => {}
            Component::ParentDir => {
                return Err("localPath must not contain '..' path traversal".to_string())
            }
            _ => return Err("localPath has an invalid component".to_string()),
        }
    }
    // Canonicalize the existing ancestor (resolves any symlinks up to there), then
    // rejoin the missing tail literally — it can't itself contain a symlink since
    // it doesn't exist on disk yet.
    let mut canon = existing
        .canonicalize()
        .map_err(|e| format!("cannot resolve localPath: {e}"))?;
    for comp in missing_tail {
        canon.push(comp);
    }
    Ok(canon)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn roots_of(dirs: &[&Path]) -> Vec<String> {
        dirs.iter()
            .map(|d| d.to_string_lossy().into_owned())
            .collect()
    }

    // AC3 — an absolute path entirely outside every workspace root is rejected,
    // and nothing about the call touches the filesystem beyond read-only stat.
    #[test]
    fn ac3_outside_root_rejected() {
        let ws = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let f = outside.path().join("id_rsa");
        std::fs::write(&f, b"secret").unwrap();
        let roots = roots_of(&[ws.path()]);
        let err = resolve_local_scp_path(&f.to_string_lossy(), &roots, false).unwrap_err();
        assert!(err.contains("outside"), "got: {err}");
    }

    // AC3 — classic sensitive-file targets outside any workspace are rejected.
    #[test]
    fn ac3_sensitive_paths_rejected() {
        let ws = tempfile::tempdir().unwrap();
        let roots = roots_of(&[ws.path()]);
        for p in ["/etc/passwd", "/etc/hosts"] {
            let err = resolve_local_scp_path(p, &roots, false).unwrap_err();
            assert!(
                err.contains("outside") || err.contains("does not exist"),
                "{p} -> {err}"
            );
        }
    }

    // AC3 — `..` escape from inside a workspace root is rejected even though the
    // raw string starts with the root's own prefix (a naive string-prefix check
    // would be fooled; canonicalize-based prefix check is not).
    #[test]
    fn ac3_dotdot_escape_rejected() {
        let ws = tempfile::tempdir().unwrap();
        let sub = ws.path().join("sub");
        std::fs::create_dir(&sub).unwrap();
        let escape = sub.join("..").join("..").join("etc").join("passwd");
        let roots = roots_of(&[ws.path()]);
        let err = resolve_local_scp_path(&escape.to_string_lossy(), &roots, false).unwrap_err();
        assert!(
            err.contains("outside") || err.contains("does not exist"),
            "got: {err}"
        );
    }

    // AC3 — a symlink INSIDE the workspace root pointing OUTSIDE it is rejected:
    // canonicalize follows the symlink to its real (outside) target.
    #[test]
    fn ac3_symlink_escape_rejected() {
        let ws = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let outside_file = outside.path().join("secret.txt");
        std::fs::write(&outside_file, b"nope").unwrap();
        let link = ws.path().join("escape_link");
        symlink(&outside_file, &link).unwrap();
        let roots = roots_of(&[ws.path()]);
        let err = resolve_local_scp_path(&link.to_string_lossy(), &roots, false).unwrap_err();
        assert!(err.contains("outside"), "got: {err}");
    }

    // AC1/AC2 (happy path) — a real file strictly inside a workspace root resolves
    // and matches the canonical form of that same file.
    #[test]
    fn inside_workspace_root_resolves() {
        let ws = tempfile::tempdir().unwrap();
        let f = ws.path().join("payload.txt");
        std::fs::write(&f, b"hi").unwrap();
        let roots = roots_of(&[ws.path()]);
        let resolved = resolve_local_scp_path(&f.to_string_lossy(), &roots, false).unwrap();
        assert_eq!(resolved, f.canonicalize().unwrap());
    }

    // Download target: the leaf file does not exist yet, but its parent does and is
    // inside the workspace root — must resolve (not require pre-existence).
    #[test]
    fn download_target_not_yet_existing_resolves_via_parent() {
        let ws = tempfile::tempdir().unwrap();
        let target = ws.path().join("new_download.txt");
        assert!(!target.exists());
        let roots = roots_of(&[ws.path()]);
        let resolved = resolve_local_scp_path(&target.to_string_lossy(), &roots, true).unwrap();
        assert_eq!(
            resolved,
            ws.path().canonicalize().unwrap().join("new_download.txt")
        );
    }

    // Download target whose PARENT directory is a symlink escaping the workspace —
    // still caught (the parent is canonicalized before the tail is rejoined).
    #[test]
    fn download_target_parent_symlink_escape_rejected() {
        let ws = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let link_dir = ws.path().join("out_link");
        symlink(outside.path(), &link_dir).unwrap();
        let target = link_dir.join("new_file.txt");
        let roots = roots_of(&[ws.path()]);
        let err = resolve_local_scp_path(&target.to_string_lossy(), &roots, true).unwrap_err();
        assert!(err.contains("outside"), "got: {err}");
    }

    // An upload source that doesn't exist is a plain, distinct "not found" error —
    // never silently treated as a new-file (download-style) case.
    #[test]
    fn upload_missing_source_reports_not_found() {
        let ws = tempfile::tempdir().unwrap();
        let missing = ws.path().join("ghost.txt");
        let roots = roots_of(&[ws.path()]);
        let err = resolve_local_scp_path(&missing.to_string_lossy(), &roots, false).unwrap_err();
        assert!(err.contains("does not exist"), "got: {err}");
    }

    // Relative paths are rejected outright (Muya's cwd is not something the agent
    // should be able to rely on / manipulate).
    #[test]
    fn relative_path_rejected() {
        let ws = tempfile::tempdir().unwrap();
        let roots = roots_of(&[ws.path()]);
        let err = resolve_local_scp_path("relative/path.txt", &roots, false).unwrap_err();
        assert!(err.contains("absolute"), "got: {err}");
    }

    // Empty roots (no workspace opened yet) fail closed with a clear message.
    #[test]
    fn no_roots_configured_fails_closed() {
        let err = resolve_local_scp_path("/tmp/whatever.txt", &[], false).unwrap_err();
        assert!(err.contains("workspace roots"), "got: {err}");
    }

    // NUL byte and empty-string inputs are rejected before any filesystem call.
    #[test]
    fn nul_and_empty_rejected() {
        let ws = tempfile::tempdir().unwrap();
        let roots = roots_of(&[ws.path()]);
        assert!(resolve_local_scp_path("", &roots, false).is_err());
        assert!(resolve_local_scp_path("a\0b", &roots, false).is_err());
    }
}

//! Input validation for values that cross the webview → backend trust boundary
//! and are then handed to the filesystem or to `git`/process arguments.
//!
//! This app shells out via argument vectors (`Command::args`), so classic shell
//! command injection isn't possible. The residual risks these guards close are:
//!   - **argument injection**: a value beginning with `-` being read as a CLI flag
//!     (e.g. `git clone --upload-pack=…`).
//!   - **git remote-helper abuse**: `ext::`, `fd::`, `file://` URLs that make
//!     `git clone` run arbitrary commands.
//!   - **path abuse**: empty paths, embedded NUL bytes, or deleting a home/root.

use std::path::Path;

/// Reject empty strings, interior NUL bytes, and (optionally) leading-dash values
/// that a CLI could misread as a flag. Returns the trimmed value on success.
pub fn clean_arg(value: &str, field: &str, allow_leading_dash: bool) -> Result<String, String> {
    let v = value.trim();
    if v.is_empty() {
        return Err(format!("{field} is required"));
    }
    if v.contains('\0') {
        return Err(format!("{field} contains an invalid NUL byte"));
    }
    if !allow_leading_dash && v.starts_with('-') {
        return Err(format!("{field} may not start with '-'"));
    }
    Ok(v.to_string())
}

/// Validate a git branch name: no leading dash, no whitespace/control chars, no
/// `..` sequence (git refname rules a superset — this is a conservative subset).
pub fn valid_branch(branch: &str) -> Result<String, String> {
    let b = clean_arg(branch, "branch name", false)?;
    if b.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("branch name may not contain whitespace or control characters".into());
    }
    if b.contains("..") || b.contains('~') || b.contains('^') || b.contains(':') {
        return Err("branch name contains an illegal character".into());
    }
    Ok(b)
}

/// Validate a git clone URL: only `https://` or `git@…:` (scp-like SSH). Blocks
/// `ext::`, `fd::`, `file://`, and any leading-dash argument-injection value.
pub fn valid_git_url(url: &str) -> Result<String, String> {
    let u = clean_arg(url, "github_url", false)?;
    let is_https = u.starts_with("https://");
    let is_ssh = u.starts_with("git@") && u.contains(':');
    if !is_https && !is_ssh {
        return Err("github_url must be an https:// or git@ SSH URL".into());
    }
    // `ext::`/`fd::` remote helpers can execute arbitrary commands via git clone.
    if u.contains("::") {
        return Err("github_url uses a disallowed remote helper scheme".into());
    }
    Ok(u)
}

/// Validate a filesystem path destined for a mutating op (write/create/rename/delete).
/// Non-empty, no NUL, and never the user's HOME or the filesystem root.
pub fn valid_mutable_path(path: &str) -> Result<String, String> {
    let p = path.trim();
    if p.is_empty() {
        return Err("path is required".into());
    }
    if p.contains('\0') {
        return Err("path contains an invalid NUL byte".into());
    }
    let pb = Path::new(p);
    if pb == Path::new("/") {
        return Err("refusing to operate on the filesystem root".into());
    }
    if let Ok(home) = std::env::var("HOME") {
        if !home.is_empty() && pb == Path::new(&home) {
            return Err("refusing to operate on the home directory".into());
        }
    }
    Ok(p.to_string())
}

/// A single path component used as a name (skill/mcp name, rename target). Rejects
/// path separators and traversal so it can't escape its intended parent directory.
pub fn valid_name(name: &str, field: &str) -> Result<String, String> {
    let n = clean_arg(name, field, true)?;
    if n.contains('/') || n.contains('\\') || n == "." || n == ".." {
        return Err(format!(
            "{field} may not contain path separators or traversal"
        ));
    }
    if n.contains('\0') {
        return Err(format!("{field} contains an invalid NUL byte"));
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_arg_rejects_empty_and_dash() {
        assert!(clean_arg("", "x", false).is_err());
        assert!(clean_arg("   ", "x", false).is_err());
        assert!(clean_arg("--upload-pack=evil", "x", false).is_err());
        assert!(clean_arg("-o", "x", false).is_err());
        assert!(clean_arg("ok", "x", false).is_ok());
        assert!(clean_arg("-allowed", "x", true).is_ok());
        assert!(clean_arg("a\0b", "x", false).is_err());
    }

    #[test]
    fn valid_branch_rules() {
        assert!(valid_branch("feature/foo").is_ok());
        assert!(valid_branch("main").is_ok());
        assert!(valid_branch("-x").is_err());
        assert!(valid_branch("a..b").is_err());
        assert!(valid_branch("has space").is_err());
        assert!(valid_branch("has:colon").is_err());
        assert!(valid_branch("").is_err());
    }

    #[test]
    fn valid_git_url_rules() {
        assert!(valid_git_url("https://github.com/a/b").is_ok());
        assert!(valid_git_url("git@github.com:a/b.git").is_ok());
        assert!(valid_git_url("ext::sh -c 'touch /tmp/pwned'").is_err());
        assert!(valid_git_url("file:///etc/passwd").is_err());
        assert!(valid_git_url("--upload-pack=evil").is_err());
        assert!(valid_git_url("http://insecure").is_err());
    }

    #[test]
    fn valid_mutable_path_rules() {
        assert!(valid_mutable_path("/tmp/some/file.txt").is_ok());
        assert!(valid_mutable_path("").is_err());
        assert!(valid_mutable_path("/").is_err());
        assert!(valid_mutable_path("a\0b").is_err());
    }

    #[test]
    fn valid_name_rules() {
        assert!(valid_name("my-skill", "name").is_ok());
        assert!(valid_name("../escape", "name").is_err());
        assert!(valid_name("a/b", "name").is_err());
        assert!(valid_name("..", "name").is_err());
        assert!(valid_name("", "name").is_err());
    }
}

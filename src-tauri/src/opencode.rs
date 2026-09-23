//! opencode CLI integration — the second agent Muya can run alongside Claude Code.
//!
//! opencode (https://opencode.ai) is a terminal coding agent with the same shape as
//! Claude Code — a TUI in a PTY — but a different CLI surface. The differences that
//! actually drive this module:
//!
//! | | Claude Code | opencode |
//! |---|---|---|
//! | auto-approve | `--dangerously-skip-permissions` | `--auto` |
//! | list sessions | `claude agents --json` | `opencode session list --format json` |
//! | resume | `--resume <id>` | `--session <id>` |
//! | name a TUI session | `--name <name>` | **no equivalent** |
//! | MCP config | `~/.claude.json` → `mcpServers` | `~/.config/opencode/opencode.json` → `mcp` |
//!
//! The missing `--name` is the one that shapes the design: a Claude session can be
//! addressed later by the name it was launched with, an opencode session cannot. So
//! opencode sessions are addressed by their MUYA TAB name instead. That costs
//! nothing, because message delivery types into the PTY (`broker.rs` `deliver:"muya"`
//! → `muya://deliver-message`) rather than going through the CLI.

use std::process::Command;
use std::sync::OnceLock;

/// Auto-approve flag — opencode's analogue of `--dangerously-skip-permissions`.
/// "Auto-approve permissions that are not explicitly denied."
pub(crate) const AUTO_FLAG: &str = "--auto";

/// Resolve the `opencode` binary once per process, the same way `claude` is resolved
/// (`agents::claude_bin`): probe the CAPABILITY we need, never mere existence.
///
/// L48, learned the hard way on the Claude side: a stale binary earlier on PATH
/// exists, runs, and answers `--version` happily while rejecting the one flag the
/// feature depends on. Checking that the path resolves proves nothing.
pub(crate) fn opencode_bin() -> &'static str {
    static BIN: OnceLock<String> = OnceLock::new();
    BIN.get_or_init(resolve_opencode_bin).as_str()
}

fn resolve_opencode_bin() -> String {
    let mut candidates: Vec<String> = vec!["opencode".to_string()];
    if let Some(path) = crate::agents::bin_via_login_shell("opencode") {
        candidates.push(path);
    }
    if let Some(home) = std::env::var_os("HOME") {
        // The install script's default prefix, plus the usual node-manager layout.
        for rel in [".opencode/bin/opencode", ".local/bin/opencode"] {
            candidates.push(
                std::path::Path::new(&home)
                    .join(rel)
                    .to_string_lossy()
                    .into_owned(),
            );
        }
    }
    candidates.push("/opt/homebrew/bin/opencode".to_string());
    candidates.push("/usr/local/bin/opencode".to_string());

    for c in &candidates {
        if supports_session_list(c) {
            return c.clone();
        }
    }
    // Nothing usable. Name a real path if one at least exists, so the error the
    // caller shows points somewhere, else a bare name for a clean not-found.
    candidates
        .into_iter()
        .find(|c| c != "opencode" && std::path::Path::new(c).is_file())
        .unwrap_or_else(|| "opencode".to_string())
}

/// Can this binary answer `session list --format json` — the call the session list
/// is built on? An empty list (`[]`, exit 0) counts as yes: having no sessions yet
/// is not the same as being unable to report them.
fn supports_session_list(bin: &str) -> bool {
    let Ok(out) = Command::new(bin)
        .args(["session", "list", "--format", "json"])
        .output()
    else {
        return false;
    };
    out.status.success() && serde_json::from_slice::<serde_json::Value>(&out.stdout).is_ok()
}

/// The command that opens a fresh opencode TUI, auto-approving tool use — the
/// direct counterpart of `claude --dangerously-skip-permissions`.
///
/// No `--name`: opencode has no way to label a TUI session (its `--title` lives on
/// the non-interactive `run` subcommand). The caller names the Muya tab instead.
pub(crate) fn open_command() -> String {
    format!("opencode {AUTO_FLAG}")
}

/// The command that resumes an existing opencode session by id.
pub(crate) fn resume_command(session_id: &str) -> String {
    format!("opencode --session {session_id} {AUTO_FLAG}")
}

/// One opencode session as the frontend needs it. Deliberately narrow: only the
/// fields we can actually promise.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct OpencodeSession {
    pub id: String,
    pub title: String,
    /// Millisecond epoch as a string, or empty when the CLI reported none. Same
    /// convention as `AgentSession::created_at` so both sort with one comparator.
    pub created_at: String,
}

/// Parse `opencode session list --format json`.
///
/// DELIBERATELY PERMISSIVE, and that is not laziness. opencode's session JSON
/// schema is not published, and opencode is not installed on the machine this was
/// written on — so writing a strict `Deserialize` against guessed field names would
/// be inventing a contract and calling it verified. Instead: accept either a bare
/// array or an object wrapping one, try the plausible spellings for each field, and
/// skip any entry without an id rather than failing the whole list.
///
/// The cost of being wrong is therefore a missing row, never a broken session list —
/// which matters because this list is merged with the Claude one.
pub(crate) fn parse_sessions(json: &[u8]) -> Vec<OpencodeSession> {
    let Ok(root) = serde_json::from_slice::<serde_json::Value>(json) else {
        return Vec::new();
    };
    // Either `[...]` or `{"sessions": [...]}` — both shapes appear in the wild for
    // list commands, and guessing wrong should not cost the whole list.
    let items = root
        .as_array()
        .or_else(|| root.get("sessions").and_then(|s| s.as_array()))
        .or_else(|| root.get("data").and_then(|s| s.as_array()));
    let Some(items) = items else {
        return Vec::new();
    };

    items
        .iter()
        .filter_map(|item| {
            let id = first_string(item, &["id", "sessionID", "sessionId", "session_id"])?;
            if id.trim().is_empty() {
                return None;
            }
            let title = first_string(item, &["title", "name", "summary"]).unwrap_or_default();
            let created_at = first_epoch_ms(item, &["time", "updated", "created", "createdAt"]);
            Some(OpencodeSession {
                id,
                title,
                created_at,
            })
        })
        .collect()
}

/// First of `keys` present on `v` as a non-empty string.
fn first_string(v: &serde_json::Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|k| v.get(*k).and_then(|x| x.as_str()))
        .map(|s| s.to_string())
}

/// First of `keys` readable as a millisecond epoch, returned as a string to match
/// `AgentSession::created_at`. Accepts a number, a numeric string, or a nested
/// object carrying the timestamp under a conventional sub-key (opencode's own
/// docs show a `time` object in places) — anything else yields "".
fn first_epoch_ms(v: &serde_json::Value, keys: &[&str]) -> String {
    for k in keys {
        let Some(x) = v.get(*k) else { continue };
        if let Some(n) = x.as_i64() {
            return n.to_string();
        }
        if let Some(s) = x.as_str() {
            if s.chars().all(|c| c.is_ascii_digit()) && !s.is_empty() {
                return s.to_string();
            }
        }
        if let Some(obj) = x.as_object() {
            for sub in ["updated", "created", "start"] {
                if let Some(n) = obj.get(sub).and_then(|y| y.as_i64()) {
                    return n.to_string();
                }
            }
        }
    }
    String::new()
}

/// List opencode sessions, or an empty list if opencode is unavailable.
///
/// Never an `Err`: this is merged into the Claude session list, and a machine
/// without opencode installed is the normal case, not a failure worth showing the
/// user. A genuinely broken opencode is logged, not surfaced.
pub(crate) fn list_sessions() -> Vec<OpencodeSession> {
    let out = Command::new(opencode_bin())
        .args(["session", "list", "--format", "json"])
        .output();
    match out {
        Ok(o) if o.status.success() => parse_sessions(&o.stdout),
        Ok(o) => {
            crate::debuglog::log(&format!(
                "[opencode] session list exited with {}: {}",
                o.status,
                String::from_utf8_lossy(&o.stderr).trim()
            ));
            Vec::new()
        }
        Err(_) => Vec::new(), // not installed — the common case, not an error
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commands_use_opencode_flags_not_claude_ones() {
        // The auto-approve flag differs between the two CLIs; passing Claude's to
        // opencode would be rejected outright.
        assert_eq!(open_command(), "opencode --auto");
        assert!(!open_command().contains("dangerously"));
        // Resume is --session, not --resume.
        assert_eq!(
            resume_command("ses_abc"),
            "opencode --session ses_abc --auto"
        );
    }

    #[test]
    fn parses_a_plain_array_of_sessions() {
        let json = br#"[
            {"id":"ses_1","title":"refactor auth","time":{"updated":1750000000000}},
            {"id":"ses_2","title":"fix tests","time":{"updated":1740000000000}}
        ]"#;
        let s = parse_sessions(json);
        assert_eq!(s.len(), 2);
        assert_eq!(s[0].id, "ses_1");
        assert_eq!(s[0].title, "refactor auth");
        assert_eq!(s[0].created_at, "1750000000000");
    }

    #[test]
    fn tolerates_the_field_spellings_we_could_not_verify() {
        // The schema is unpublished and opencode was not installed when this was
        // written, so the parser accepts the plausible spellings rather than
        // pretending one guess is the contract.
        let json =
            br#"{"sessions":[{"sessionID":"ses_9","name":"wrapped","created":1700000000000}]}"#;
        let s = parse_sessions(json);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].id, "ses_9");
        assert_eq!(s[0].title, "wrapped");
        assert_eq!(s[0].created_at, "1700000000000");
    }

    #[test]
    fn a_bad_entry_costs_one_row_never_the_whole_list() {
        // This list is merged with the Claude one. An entry we cannot read must not
        // take the others — or worse, the Claude sessions — down with it.
        let json = br#"[{"nope":1},{"id":"","title":"empty id"},{"id":"ses_ok","title":"fine"}]"#;
        let s = parse_sessions(json);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].id, "ses_ok");
    }

    #[test]
    fn unusable_json_yields_an_empty_list_not_a_panic() {
        assert!(parse_sessions(b"not json at all").is_empty());
        assert!(parse_sessions(b"").is_empty());
        assert!(parse_sessions(b"{}").is_empty());
        // A title is optional — a session with only an id is still listable.
        let s = parse_sessions(br#"[{"id":"ses_x"}]"#);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].title, "");
        assert_eq!(s[0].created_at, "");
    }
}

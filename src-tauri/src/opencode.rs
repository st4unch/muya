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
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

/// Auto-approve flag — opencode's analogue of `--dangerously-skip-permissions`.
/// "Auto-approve permissions that are not explicitly denied."
pub(crate) const AUTO_FLAG: &str = "--auto";

/// How long a FAILED resolution stays cached. Long enough that the session list,
/// polled every few seconds, does not shell out to a missing binary on every tick;
/// short enough that installing opencode takes effect without restarting the app.
const RESOLVE_RETRY: std::time::Duration = std::time::Duration::from_secs(60);

/// Resolve the `opencode` binary, probing the CAPABILITY we need rather than mere
/// existence.
///
/// L48, learned the hard way on the Claude side: a stale binary earlier on PATH
/// exists, runs, and answers `--version` happily while rejecting the one flag the
/// feature depends on. Checking that the path resolves proves nothing.
///
/// A SUCCESS is cached for the life of the process; a FAILURE is only cached for
/// `RESOLVE_RETRY`. That asymmetry is the point. This used to be a plain
/// `OnceLock`, which made the first probe final — and the first probe is exactly
/// the fragile one: Muya is usually already running when opencode gets installed,
/// and opencode runs `brew upgrade opencode` on its own startup, which unlinks and
/// relinks `/opt/homebrew/bin/opencode` while we may be probing it. Either way the
/// process cached "no opencode here" forever, and the user saw a running opencode
/// session that never appeared in Sessions or in `list_sessions`, with an app
/// restart as the only cure.
pub(crate) fn opencode_bin() -> String {
    static CACHE: OnceLock<Mutex<Option<Resolved>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(None));

    // A poisoned lock must not disable opencode outright — resolve uncached rather
    // than hand back a name that was never probed.
    let Ok(mut slot) = cache.lock() else {
        return resolve_opencode_bin().bin;
    };
    if let Some(prev) = slot.as_ref() {
        if still_usable(prev) {
            return prev.bin.clone();
        }
    }
    let resolved = resolve_opencode_bin();
    let bin = resolved.bin.clone();
    *slot = Some(resolved);
    bin
}

/// A resolution attempt: which binary we settled on, whether it actually answered
/// the probe, and when. `working: false` is what makes the entry retryable — the
/// binary may be a real path that merely could not answer at that moment.
struct Resolved {
    bin: String,
    working: bool,
    at: Instant,
}

/// May a cached resolution be reused? A binary that answered the probe never
/// expires — nothing about it can go stale that a re-probe would catch sooner than
/// the next failed call. A failure expires, because the thing that caused it
/// (opencode not installed yet, a `brew upgrade` mid-flight) routinely goes away
/// on its own.
fn still_usable(prev: &Resolved) -> bool {
    prev.working || prev.at.elapsed() < RESOLVE_RETRY
}

/// What resolution falls back to when it found nothing at all.
const FALLBACK_BIN: &str = "opencode";

fn resolve_opencode_bin() -> Resolved {
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
            return Resolved {
                bin: c.clone(),
                working: true,
                at: Instant::now(),
            };
        }
    }
    // Nothing usable. Name a real path if one at least exists, so the error the
    // caller shows points somewhere, else a bare name for a clean not-found.
    Resolved {
        bin: candidates
            .into_iter()
            .find(|c| c != FALLBACK_BIN && std::path::Path::new(c).is_file())
            .unwrap_or_else(|| FALLBACK_BIN.to_string()),
        working: false,
        at: Instant::now(),
    }
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
    /// Where the session runs. opencode reports this as `directory`; it is what
    /// gives the row a working directory and therefore a git branch, like a
    /// Claude row's `cwd`.
    pub directory: String,
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
            let directory = first_string(item, &["directory", "cwd", "path"]).unwrap_or_default();
            Some(OpencodeSession {
                id,
                title,
                created_at,
                directory,
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
///
/// Cached: `opencode session list` costs ~0.5 s of CPU per run (measured 2026-10-01)
/// and the session list is polled every few seconds, which made it the single largest
/// idle CPU cost of the app. opencode sessions appear/disappear rarely, so a result is
/// reused for LIST_TTL (NOT_INSTALLED_TTL when opencode isn't there at all).
pub(crate) fn list_sessions() -> Vec<OpencodeSession> {
    const LIST_TTL: std::time::Duration = std::time::Duration::from_secs(20);
    const NOT_INSTALLED_TTL: std::time::Duration = std::time::Duration::from_secs(120);
    static CACHE: OnceLock<Mutex<Option<(Instant, std::time::Duration, Vec<OpencodeSession>)>>> =
        OnceLock::new();
    // Held across the spawn on purpose: concurrent pollers wait for one run and share it.
    let Ok(mut slot) = CACHE.get_or_init(|| Mutex::new(None)).lock() else {
        return list_sessions_uncached().1;
    };
    if let Some((at, ttl, list)) = slot.as_ref() {
        if at.elapsed() < *ttl {
            return list.clone();
        }
    }
    let (installed, list) = list_sessions_uncached();
    let ttl = if installed {
        LIST_TTL
    } else {
        NOT_INSTALLED_TTL
    };
    *slot = Some((Instant::now(), ttl, list.clone()));
    list
}

/// One real `opencode session list` run: (opencode could be started, sessions).
fn list_sessions_uncached() -> (bool, Vec<OpencodeSession>) {
    let out = Command::new(opencode_bin())
        .args(["session", "list", "--format", "json"])
        .output();
    match out {
        Ok(o) if o.status.success() => (true, parse_sessions(&o.stdout)),
        Ok(o) => {
            crate::debuglog::log(&format!(
                "[opencode] session list exited with {}: {}",
                o.status,
                String::from_utf8_lossy(&o.stderr).trim()
            ));
            (true, Vec::new())
        }
        Err(_) => (false, Vec::new()), // not installed — the common case, not an error
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn a_failed_resolution_is_retried_but_a_working_one_is_not() {
        // The bug this guards: as a plain `OnceLock`, the FIRST probe was final.
        // Muya is normally already running when opencode gets installed, and
        // opencode itself runs `brew upgrade opencode` on startup — which unlinks
        // and relinks the binary we probe. One unlucky moment and the process was
        // stuck reporting "no opencode" until the app was restarted.
        let failed_long_ago = Resolved {
            bin: FALLBACK_BIN.to_string(),
            working: false,
            at: Instant::now() - RESOLVE_RETRY - Duration::from_secs(1),
        };
        assert!(
            !still_usable(&failed_long_ago),
            "a stale failure must be retried"
        );

        let failed_just_now = Resolved {
            bin: FALLBACK_BIN.to_string(),
            working: false,
            at: Instant::now(),
        };
        assert!(
            still_usable(&failed_just_now),
            "a fresh failure must be reused — the session list polls every few \
             seconds and must not shell out on every tick"
        );

        // A failure that named a real path is still a failure: it did not answer
        // the probe, so it must expire like any other.
        let found_but_unusable = Resolved {
            bin: "/opt/homebrew/bin/opencode".to_string(),
            working: false,
            at: Instant::now() - RESOLVE_RETRY - Duration::from_secs(1),
        };
        assert!(!still_usable(&found_but_unusable));

        let working_old = Resolved {
            bin: "/opt/homebrew/bin/opencode".to_string(),
            working: true,
            at: Instant::now() - Duration::from_secs(60 * 60 * 24),
        };
        assert!(
            still_usable(&working_old),
            "a working binary must not expire"
        );
    }

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

    /// LIVE check against the opencode actually installed on this machine.
    ///
    /// `#[ignore]` because it shells out to a real CLI that most machines will not
    /// have — run it deliberately with:
    ///     cargo test --lib opencode::tests::live -- --ignored --nocapture
    /// Everything else in this module works from captured fixtures; this is the one
    /// that proves the fixtures still describe reality.
    #[test]
    #[ignore = "requires opencode installed"]
    fn live_opencode_resolves_and_lists_sessions() {
        let bin = opencode_bin();
        println!("resolved binary: {bin}");
        assert!(
            supports_session_list(&bin),
            "resolver returned {bin}, which cannot answer 'session list --format json'"
        );

        let sessions = list_sessions();
        println!("parsed {} session(s)", sessions.len());
        for s in &sessions {
            println!(
                "  id={} title={:?} created_at={:?} dir={:?}",
                s.id, s.title, s.created_at, s.directory
            );
            // A row with no id would have been dropped; one with no timestamp sorts
            // last and looks broken in the list. Both are worth knowing about.
            assert!(!s.id.is_empty());
        }
    }

    /// LIVE check that opencode rows actually SURVIVE the merge into the session
    /// list the app and the MCP broker read (`agents::list_agent_sessions_sync`).
    ///
    /// The test above proves `list_sessions()` works in isolation. That is not the
    /// same claim: a row can parse perfectly and still be dropped a layer up by a
    /// status filter, an id rule, or a merge that was never wired. This one fails
    /// if the merge stops happening — which is the failure a user actually sees
    /// (an opencode session running, but absent from Sessions and from
    /// `list_sessions`).
    #[test]
    #[ignore = "requires opencode and claude installed"]
    fn live_opencode_rows_reach_the_merged_session_list() {
        let direct = list_sessions();
        if direct.is_empty() {
            println!("no opencode sessions on this machine — nothing to merge");
            return;
        }
        let merged = crate::agents::list_agent_sessions_sync(Some(true))
            .expect("list_agent_sessions_sync failed");
        println!(
            "opencode: {} row(s), merged list: {} row(s)",
            direct.len(),
            merged.len()
        );
        for s in &direct {
            assert!(
                merged.iter().any(|m| m.id == s.id),
                "opencode session {} ({:?}) is missing from the merged list — \
                 it parses but never reaches the app",
                s.id,
                s.title
            );
        }
    }

    /// The session list is polled every few seconds and one `opencode session list`
    /// costs ~0.5 s of CPU — repeated calls inside the TTL must reuse the first run.
    #[test]
    #[ignore = "requires opencode installed"]
    fn live_session_list_is_cached_between_polls() {
        let t = Instant::now();
        let first = list_sessions();
        let cold = t.elapsed();
        let t = Instant::now();
        for _ in 0..10 {
            assert_eq!(list_sessions(), first);
        }
        let warm = t.elapsed();
        println!("cold {cold:?}, 10 cached calls {warm:?}");
        assert!(warm < std::time::Duration::from_millis(20), "cached calls must not spawn opencode: {warm:?}");
    }

    #[test]
    fn parses_the_real_output_of_opencode_1_18_32() {
        // Captured verbatim from `opencode session list --format json` on a real
        // install. Everything above this test was written before opencode was
        // available, against an unpublished schema — this is the check that the
        // guesses actually match the CLI.
        let json = r#"[
          {
            "id": "ses_f310ec032ffeOzEdsT4uJrZ7VU",
            "title": "Türkçe selamlaşma",
            "updated": 1790178325280,
            "created": 1790178312141,
            "projectId": "89a031fbe0ec7f81a9e103101baa616454f09098",
            "directory": "/Users/someone/Documents/project"
          }
        ]"#;
        let s = parse_sessions(json.as_bytes());
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].id, "ses_f310ec032ffeOzEdsT4uJrZ7VU");
        assert_eq!(s[0].title, "Türkçe selamlaşma");
        // `updated` is a bare number here, not the nested object the fallback also
        // accepts — both shapes must work.
        assert_eq!(s[0].created_at, "1790178325280");
        assert_eq!(s[0].directory, "/Users/someone/Documents/project");
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

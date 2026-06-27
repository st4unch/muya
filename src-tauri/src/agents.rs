//! Claude Code session reader. Shells out to `claude agents --json` (the stable,
//! machine-readable source per the PRD) and maps the result onto the frontend's
//! `AgentSession` contract. Fields not exposed by the CLI (token usage, quota,
//! active task/file) are left empty for now — they come from transcript parsing
//! in a later phase.

use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// Raw entry as emitted by `claude agents --json`. Only the fields we rely on are
/// declared; unknown/extra fields are ignored (schema is version-volatile).
#[derive(Debug, Deserialize)]
struct RawAgent {
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    pid: Option<i64>,
    /// Short background-session id (present only for `kind == "background"`); this is
    /// what `claude attach/stop/logs/respawn <id>` expect.
    id: Option<String>,
    /// Human label for background sessions.
    name: Option<String>,
    cwd: Option<String>,
    kind: Option<String>,
    #[serde(rename = "startedAt")]
    started_at: Option<i64>,
    /// interactive sessions: "idle" | "busy"; background: "working" | "blocked" | ...
    status: Option<String>,
    state: Option<String>,
    /// Present when this session was spawned by another Claude session (sub-agent).
    #[serde(rename = "parentSessionId", default)]
    parent_session_id: Option<String>,
}

/// Mirrors the frontend `AgentSession` TypeScript interface (camelCase via serde).
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSession {
    pub id: String,
    pub name: String,
    pub branch: String,
    pub worktree: String,
    /// One of: working | waiting-for-input | idle | stopped
    pub status: String,
    pub active_task: String,
    pub active_file: String,
    pub tokens_used: u64,
    pub models_used: String,
    pub quota_burn: f64,
    pub duration: String,
    pub created_at: String,
    /// True for background sessions, which `claude attach <id>` can connect to.
    pub attachable: bool,
    /// Id to pass to `claude attach` (short background id, else the full sessionId).
    pub attach_id: String,
    /// OS process id (for stopping interactive sessions that have no background id).
    pub pid: Option<i64>,
    /// Set when this session was spawned by another Claude agent (sub-agent tree).
    pub parent_id: Option<String>,
}

/// Resolve the `claude` binary: GUI apps on macOS inherit a minimal PATH, so a bare
/// `claude` may not be found. Try PATH first, then common install locations.
fn claude_bin() -> String {
    if Command::new("claude").arg("--version").output().is_ok() {
        return "claude".to_string();
    }
    if let Some(home) = std::env::var_os("HOME") {
        let candidate = std::path::Path::new(&home).join(".local/bin/claude");
        if candidate.exists() {
            return candidate.to_string_lossy().into_owned();
        }
    }
    for p in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
        if std::path::Path::new(p).exists() {
            return p.to_string();
        }
    }
    "claude".to_string()
}

/// Best-effort current branch for a working directory; "—" if not a git repo.
fn branch_for(cwd: &str) -> String {
    Command::new("git")
        .args(["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "—".to_string())
}

/// Map the CLI status onto the 4 frontend states.
fn map_status(raw: &RawAgent) -> String {
    let s = raw
        .state
        .as_deref()
        .or(raw.status.as_deref())
        .unwrap_or("")
        .to_lowercase();
    match s.as_str() {
        "busy" | "working" => "working",
        "blocked" | "waiting" => "waiting-for-input",
        "idle" | "done" => "idle",
        "stopped" | "failed" => "stopped",
        _ => "idle",
    }
    .to_string()
}

fn name_from_cwd(cwd: &str, fallback: &str) -> String {
    std::path::Path::new(cwd)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| fallback.to_string())
}

/// Human duration since `started_at` (ms epoch), e.g. "12m" / "1h 4m".
fn duration_since(started_at: Option<i64>) -> String {
    let Some(start_ms) = started_at else {
        return "—".to_string();
    };
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(start_ms);
    let secs = ((now_ms - start_ms).max(0)) / 1000;
    let (h, m) = (secs / 3600, (secs % 3600) / 60);
    if h > 0 {
        format!("{h}h {m}m")
    } else if m > 0 {
        format!("{m}m")
    } else {
        format!("{secs}s")
    }
}

fn map_agent(raw: RawAgent) -> AgentSession {
    let id = raw.session_id.clone().unwrap_or_default();
    let cwd = raw.cwd.clone().unwrap_or_default();
    let short = id.split('-').next().unwrap_or(&id).to_string();
    // Background sessions are the ones `claude attach <id>` accepts. They carry a
    // short `id` (and a `state`); interactive sessions don't.
    let attachable = raw.kind.as_deref() == Some("background") || raw.id.is_some();
    let attach_id = raw.id.clone().unwrap_or_else(|| id.clone());
    // Prefer the session's own name; fall back to the directory, then the short id.
    let name = raw
        .name
        .clone()
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| name_from_cwd(&cwd, &short));
    AgentSession {
        name,
        branch: if cwd.is_empty() {
            "—".to_string()
        } else {
            branch_for(&cwd)
        },
        status: map_status(&raw),
        duration: duration_since(raw.started_at),
        created_at: raw.started_at.map(|t| t.to_string()).unwrap_or_default(),
        worktree: cwd,
        id,
        active_task: String::new(),
        active_file: String::new(),
        tokens_used: 0,
        models_used: raw.kind.unwrap_or_default(),
        quota_burn: 0.0,
        attachable,
        attach_id,
        pid: raw.pid,
        parent_id: raw.parent_session_id,
    }
}

/// Append a short discriminator to names that collide, so every parallel session is
/// visually distinguishable (the whole point of the control plane).
fn disambiguate_names(sessions: &mut [AgentSession]) {
    let mut counts: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for s in sessions.iter() {
        *counts.entry(s.name.clone()).or_default() += 1;
    }
    for s in sessions.iter_mut() {
        if counts.get(&s.name).copied().unwrap_or(0) > 1 {
            let hint = if !s.attach_id.is_empty() && s.attach_id != s.id {
                s.attach_id.clone()
            } else {
                s.id.split('-').next().unwrap_or(&s.id).to_string()
            };
            s.name = format!("{} ({})", s.name, hint);
        }
    }
}

/// Tauri command: live Claude Code sessions from `claude agents --json`.
/// `--all` includes completed sessions too.
#[tauri::command(async)]
pub fn list_agent_sessions(include_all: Option<bool>) -> Result<Vec<AgentSession>, String> {
    let mut cmd = Command::new(claude_bin());
    cmd.args(["agents", "--json"]);
    if include_all.unwrap_or(false) {
        cmd.arg("--all");
    }
    let output = cmd
        .output()
        .map_err(|e| format!("failed to run `claude agents --json`: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "`claude agents --json` exited with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let raw: Vec<RawAgent> = serde_json::from_slice(&output.stdout)
        .map_err(|e| format!("failed to parse claude agents JSON: {e}"))?;
    let mut sessions: Vec<AgentSession> = raw.into_iter().map(map_agent).collect();
    disambiguate_names(&mut sessions);
    Ok(sessions)
}

/// Stop any session: background → `claude stop <id>`; interactive (no background id)
/// → terminate the OS process by pid.
#[tauri::command(async)]
pub fn kill_session(id: Option<String>, pid: Option<i64>) -> Result<String, String> {
    if let Some(id) = id.filter(|s| !s.is_empty()) {
        return stop_agent(id);
    }
    let pid = pid.ok_or("no background id and no pid to kill")?;
    let output = Command::new("kill")
        .arg(pid.to_string())
        .output()
        .map_err(|e| format!("failed to run kill: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "kill {pid} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(format!("sent SIGTERM to pid {pid}"))
}

/// Stop a background session: `claude stop <id>`.
#[tauri::command(async)]
pub fn stop_agent(id: String) -> Result<String, String> {
    let output = Command::new(claude_bin())
        .args(["stop", &id])
        .output()
        .map_err(|e| format!("failed to run `claude stop`: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "`claude stop {id}` failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(id: &str, name: &str) -> AgentSession {
        AgentSession {
            id: id.into(),
            name: name.into(),
            branch: "—".into(),
            worktree: String::new(),
            status: "idle".into(),
            active_task: String::new(),
            active_file: String::new(),
            tokens_used: 0,
            models_used: String::new(),
            quota_burn: 0.0,
            duration: String::new(),
            created_at: String::new(),
            attachable: false,
            attach_id: String::new(),
            pid: None,
            parent_id: None,
        }
    }

    #[test]
    fn map_status_maps_states() {
        let mut r = RawAgent {
            session_id: None,
            pid: None,
            id: None,
            name: None,
            cwd: None,
            kind: None,
            started_at: None,
            status: Some("busy".into()),
            state: None,
            parent_session_id: None,
        };
        assert_eq!(map_status(&r), "working");
        r.state = Some("blocked".into());
        assert_eq!(map_status(&r), "waiting-for-input"); // state wins over status
        r.state = Some("done".into());
        assert_eq!(map_status(&r), "idle");
    }

    #[test]
    fn disambiguate_appends_id_only_on_collision() {
        let mut s = vec![
            session("aaaa-1", "proj"),
            session("bbbb-2", "proj"),
            session("cccc-3", "unique"),
        ];
        disambiguate_names(&mut s);
        assert_eq!(s[0].name, "proj (aaaa)");
        assert_eq!(s[1].name, "proj (bbbb)");
        assert_eq!(s[2].name, "unique"); // no collision → untouched
    }

    /// Live smoke test against the local `claude` install — prints mapped sessions.
    #[test]
    #[ignore = "machine-specific: needs live claude CLI"]
    fn live_sessions_smoke() {
        match list_agent_sessions(Some(false)) {
            Ok(sessions) => {
                println!("mapped {} session(s):", sessions.len());
                for s in &sessions {
                    println!(
                        "  id={} name={} branch={} status={} worktree={} dur={}",
                        &s.id[..s.id.len().min(8)],
                        s.name,
                        s.branch,
                        s.status,
                        s.worktree,
                        s.duration
                    );
                }
            }
            Err(e) => println!("list_agent_sessions errored (claude may be unavailable): {e}"),
        }
    }
}

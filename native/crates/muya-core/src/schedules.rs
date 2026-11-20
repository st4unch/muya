// Created by Claude — Classification: INTERNAL
// (Tauri-free core, moved from src-tauri for the native rewrite, PRD AC22; the app keeps thin
// command shims. Items are `pub` so the app's tests and muyad can reach them.)
//
// Schedules (docs/prd-schedules.md): Claude prompts that run headless (`claude -p`) in a
// chosen folder on a timer, with the user's own settings, MCP servers and skills.
//
// - Jobs live in ~/.claude/muya-schedules.json (atomic tmp+rename write); every run is
//   one JSON line in ~/.claude/muya-schedule-runs/<job-id>.jsonl (last 100 kept).
// - The timer runs inside Muya: runs missed while Muya was closed are skipped, not
//   back-filled. A lock file keeps a second Muya from firing the same jobs twice.
// - A run goes through the user's environment as their login shell sets it up
//   (captured once — a GUI app inherits a bare PATH that MCP servers' npx/uvx miss).
//   The prompt is an argv element after `--`: never shell text, never a flag.
// - At most MAX_PARALLEL runs at once; the rest wait their turn. A timeout stops the
//   whole process group (Claude and the MCP servers it started).

use chrono::{DateTime, Datelike, Duration as ChronoDuration, Local, NaiveTime, TimeZone};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::future::Future;
use std::pin::Pin;

pub const MAX_RUNS_KEPT: usize = 100;
pub const MAX_OUTPUT: usize = 64 * 1024;
pub const MAX_PROMPT: usize = 20_000;
pub const MIN_INTERVAL_MIN: u32 = 5;
pub const MAX_PARALLEL: usize = 3;
pub const TICK_SECS: u64 = 15;

// ── Model ─────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Schedule {
    /// Every `minutes` minutes (≥ MIN_INTERVAL_MIN).
    Interval { minutes: u32 },
    /// Every day at local "HH:MM", and at each of `extra_times`.
    Daily {
        time: String,
        /// More times the same day (docs/prd-schedule-multi-times.md). Omitted when
        /// empty so a single-time job is stored exactly as before.
        #[serde(default, rename = "extraTimes", skip_serializing_if = "Vec::is_empty")]
        extra_times: Vec<String>,
    },
    /// On the given weekdays (0 = Monday … 6 = Sunday) at local "HH:MM", and at each
    /// of `extra_times`.
    Weekly {
        days: Vec<u8>,
        time: String,
        #[serde(default, rename = "extraTimes", skip_serializing_if = "Vec::is_empty")]
        extra_times: Vec<String>,
    },
}

/// Most runs one daily/weekly schedule may have in a day; more is an interval job.
pub const MAX_TIMES_PER_DAY: usize = 6;

/// `time` plus `extra`, parsed and de-duplicated; None if any is invalid or there are
/// more than MAX_TIMES_PER_DAY.
pub fn day_times(time: &str, extra: &[String]) -> Option<Vec<NaiveTime>> {
    let mut v = Vec::with_capacity(1 + extra.len());
    for s in std::iter::once(time).chain(extra.iter().map(String::as_str)) {
        let t = parse_hhmm(s)?;
        if !v.contains(&t) {
            v.push(t);
        }
    }
    (v.len() <= MAX_TIMES_PER_DAY).then_some(v)
}

/// A running terminal session a job types its prompt into instead of starting `claude -p`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TargetSession {
    pub id: u64,
    pub name: String,
    pub cwd: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub name: String,
    pub prompt: String,
    pub folder: String,
    pub schedule: Schedule,
    pub enabled: bool,
    pub timeout_min: u32,
    /// Run with `--dangerously-skip-permissions` (nothing can answer a permission
    /// prompt headless). Off: `--permission-mode acceptEdits`.
    pub bypass: bool,
    /// Created/last edited by an agent (muya-mcp). Provenance only: an agent may set `bypass`
    /// either way, like the operator.
    #[serde(default)]
    pub agent: bool,
    /// `--model` for the run: an alias (opus, sonnet, haiku) or a full model id. Empty = claude's default.
    #[serde(default)]
    pub model: String,
    /// `--effort` for the run: low, medium, high, xhigh or max. Empty = claude's default.
    #[serde(default)]
    pub effort: String,
    /// Load Claude in Chrome (`--chrome`). Interactive sessions get it from the
    /// user's setting; `claude -p` only with the flag. Missing in jobs saved by
    /// 4.1.0 → on, so they see the same tools as the user's own sessions.
    #[serde(default = "yes")]
    pub chrome: bool,
    /// Set: the prompt is typed into this existing session (docs/prd-native-session-schedule.md).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<TargetSession>,
    pub created: i64,
    pub updated: i64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Store {
    pub version: u32,
    pub jobs: Vec<Job>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RunStatus {
    Success,
    Failed,
    Timeout,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Run {
    pub job_id: String,
    pub started: i64,
    pub ended: i64,
    pub status: RunStatus,
    pub exit_code: Option<i32>,
    pub cost_usd: Option<f64>,
    /// "schedule" or "manual".
    pub trigger: String,
    pub output: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JobView {
    #[serde(flatten)]
    pub job: Job,
    pub next_run: Option<i64>,
    pub running: bool,
    pub queued: bool,
    pub runs: usize,
    pub ok: usize,
    pub failed: usize,
    pub last: Option<RunSummary>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunSummary {
    pub started: i64,
    pub ended: i64,
    pub status: RunStatus,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobInput {
    pub id: Option<String>,
    pub name: String,
    pub prompt: String,
    pub folder: String,
    pub schedule: Schedule,
    pub enabled: bool,
    pub timeout_min: u32,
    pub bypass: bool,
    #[serde(default)]
    pub agent: bool,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub effort: String,
    #[serde(default = "yes")]
    pub chrome: bool,
    #[serde(default)]
    pub target: Option<TargetSession>,
}

pub const EFFORTS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

/// `model` is empty or an alias / model id (letters, digits, `.-_:/[]`, not starting with `-`);
/// `effort` is empty or one of [`EFFORTS`].
pub fn validate_model_effort(model: &str, effort: &str) -> Result<(), String> {
    let m = model.trim();
    if !m.is_empty()
        && (m.len() > 100
            || m.starts_with('-')
            || !m.chars().all(|c| c.is_ascii_alphanumeric() || ".-_:/[]".contains(c)))
    {
        return Err("Model must be an alias (opus, sonnet, haiku) or a model id.".into());
    }
    let e = effort.trim();
    if !e.is_empty() && !EFFORTS.contains(&e) {
        return Err("Effort must be low, medium, high, xhigh or max.".into());
    }
    Ok(())
}

pub fn yes() -> bool {
    true
}

// ── Pure helpers (tested) ─────────────────────────────────────────────────────────

pub fn parse_hhmm(s: &str) -> Option<NaiveTime> {
    NaiveTime::parse_from_str(s.trim(), "%H:%M").ok()
}

/// A local wall-clock time on `date`. In a DST gap (the time doesn't exist) the next
/// hour is used; in an overlap the earlier instant, so the job fires once.
pub fn local_at(date: chrono::NaiveDate, t: NaiveTime) -> Option<DateTime<Local>> {
    let ndt = date.and_time(t);
    Local.from_local_datetime(&ndt).earliest().or_else(|| {
        Local
            .from_local_datetime(&(ndt + ChronoDuration::hours(1)))
            .earliest()
    })
}

/// The first run strictly after `after`, or None for an invalid schedule.
pub fn next_after(s: &Schedule, after: DateTime<Local>) -> Option<DateTime<Local>> {
    match s {
        Schedule::Interval { minutes } => {
            if *minutes < MIN_INTERVAL_MIN {
                return None;
            }
            Some(after + ChronoDuration::minutes(i64::from(*minutes)))
        }
        Schedule::Daily { time, extra_times } => {
            let times = day_times(time, extra_times)?;
            (0..=2).find_map(|d| {
                let date = after.date_naive() + ChronoDuration::days(d);
                times
                    .iter()
                    .filter_map(|t| local_at(date, *t).filter(|x| *x > after))
                    .min()
            })
        }
        Schedule::Weekly {
            days,
            time,
            extra_times,
        } => {
            let times = day_times(time, extra_times)?;
            if days.is_empty() || days.iter().any(|d| *d > 6) {
                return None;
            }
            (0..=8).find_map(|d| {
                let date = after.date_naive() + ChronoDuration::days(d);
                let wd = date.weekday().num_days_from_monday() as u8;
                if !days.contains(&wd) {
                    return None;
                }
                times
                    .iter()
                    .filter_map(|t| local_at(date, *t).filter(|x| *x > after))
                    .min()
            })
        }
    }
}

pub fn validate(input: &JobInput) -> Result<String, String> {
    if input.name.trim().is_empty() {
        return Err("Give the schedule a name.".into());
    }
    if input.prompt.trim().is_empty() {
        return Err("The prompt is empty.".into());
    }
    if input.prompt.len() > MAX_PROMPT {
        return Err(format!(
            "The prompt is longer than {MAX_PROMPT} characters."
        ));
    }
    validate_model_effort(&input.model, &input.effort)?;
    if !(1..=24 * 60).contains(&input.timeout_min) {
        return Err("Timeout must be between 1 minute and 24 hours.".into());
    }
    if next_after(&input.schedule, Local::now()).is_none() {
        return Err(match input.schedule {
            Schedule::Interval { .. } => format!("Run at most every {MIN_INTERVAL_MIN} minutes."),
            Schedule::Weekly { ref days, .. } if days.is_empty() => "Pick at least one day.".into(),
            Schedule::Daily { ref time, ref extra_times }
            | Schedule::Weekly { ref time, ref extra_times, .. }
                if extra_times.len() + 1 > MAX_TIMES_PER_DAY
                    && extra_times.iter().chain([time]).all(|t| parse_hhmm(t).is_some()) =>
            {
                format!("At most {MAX_TIMES_PER_DAY} times a day.")
            }
            _ => "Use times like 09:30.".into(),
        });
    }
    if let Some(t) = &input.target {
        if t.name.trim().is_empty() {
            return Err("The target session has no name.".into());
        }
        // A targeted job runs nothing in a folder; keep the session's own folder for display.
        let f = input.folder.trim();
        return Ok(if f.is_empty() { t.cwd.clone() } else { f.to_string() });
    }
    let p = Path::new(input.folder.trim());
    if !p.is_absolute() {
        return Err("Choose a folder.".into());
    }
    let canon = fs::canonicalize(p).map_err(|_| "That folder doesn't exist.".to_string())?;
    if !canon.is_dir() {
        return Err("That path is not a folder.".into());
    }
    Ok(canon.to_string_lossy().into_owned())
}

/// The argv after the claude binary. The prompt goes last, after `--`.
pub fn claude_args(prompt: &str, bypass: bool, chrome: bool, model: &str, effort: &str) -> Vec<String> {
    let mut a: Vec<String> = vec!["-p".into(), "--output-format".into(), "json".into()];
    if chrome {
        a.push("--chrome".into());
    }
    if !model.trim().is_empty() {
        a.extend(["--model".into(), model.trim().into()]);
    }
    if !effort.trim().is_empty() {
        a.extend(["--effort".into(), effort.trim().into()]);
    }
    if bypass {
        a.push("--dangerously-skip-permissions".into());
    } else {
        a.extend(["--permission-mode".into(), "acceptEdits".into()]);
    }
    a.push("--".into());
    a.push(prompt.into());
    a
}

/// Status, cost and readable text of a finished `claude -p --output-format json`.
pub fn classify(
    exit_code: Option<i32>,
    stdout: &str,
    stderr: &str,
) -> (RunStatus, Option<f64>, String) {
    let parsed: Option<serde_json::Value> = serde_json::from_str(stdout.trim()).ok();
    let is_error = parsed
        .as_ref()
        .and_then(|v| v.get("is_error"))
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let cost = parsed
        .as_ref()
        .and_then(|v| v.get("total_cost_usd"))
        .and_then(|v| v.as_f64());
    let mut text = parsed
        .as_ref()
        .and_then(|v| v.get("result"))
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| stdout.trim().to_string());
    let ok = exit_code == Some(0) && parsed.is_some() && !is_error;
    if !ok && !stderr.trim().is_empty() {
        if !text.is_empty() {
            text.push_str("\n\n");
        }
        text.push_str(stderr.trim());
    }
    (
        if ok {
            RunStatus::Success
        } else {
            RunStatus::Failed
        },
        cost,
        truncate(text),
    )
}

pub fn truncate(mut s: String) -> String {
    if s.len() > MAX_OUTPUT {
        let mut cut = MAX_OUTPUT;
        while !s.is_char_boundary(cut) {
            cut -= 1;
        }
        s.truncate(cut);
        s.push_str("\n… (output truncated)");
    }
    s
}

// ── Storage ───────────────────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct Paths {
    pub jobs: PathBuf,
    pub runs: PathBuf,
    pub lock: PathBuf,
    pub status: PathBuf,
    pub heartbeat: PathBuf,
    pub requests: PathBuf,
    pub marker: PathBuf,
}

impl Paths {
    pub fn under(claude_dir: &Path) -> Self {
        Paths {
            jobs: claude_dir.join("muya-schedules.json"),
            runs: claude_dir.join("muya-schedule-runs"),
            lock: claude_dir.join("muya-schedules.lock"),
            status: claude_dir.join("muya-schedules.status.json"),
            heartbeat: claude_dir.join("muya-scheduler.heartbeat.json"),
            requests: claude_dir.join("muya-schedule-requests"),
            marker: claude_dir.join("muya-schedules.fired.json"),
        }
    }
    pub fn runs_file(&self, id: &str) -> PathBuf {
        self.runs.join(format!("{id}.jsonl"))
    }
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("tmp");
    {
        let mut f = private_file(&tmp)?;
        f.write_all(bytes).map_err(|e| e.to_string())?;
        f.sync_all().ok();
    }
    fs::rename(&tmp, path).map_err(|e| e.to_string())
}

pub fn private_file(path: &Path) -> Result<fs::File, String> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| e.to_string())
}

pub fn load_jobs(p: &Paths) -> Vec<Job> {
    fs::read(&p.jobs)
        .ok()
        .and_then(|b| serde_json::from_slice::<Store>(&b).ok())
        .map(|s| s.jobs)
        .unwrap_or_default()
}

pub fn save_jobs(p: &Paths, jobs: &[Job]) -> Result<(), String> {
    let store = Store {
        version: 1,
        jobs: jobs.to_vec(),
    };
    atomic_write(
        &p.jobs,
        &serde_json::to_vec_pretty(&store).map_err(|e| e.to_string())?,
    )
}

pub fn ensure_runs_dir(p: &Paths) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    fs::create_dir_all(&p.runs).map_err(|e| e.to_string())?;
    fs::set_permissions(&p.runs, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())
}

/// Runs of one job, oldest first.
pub fn read_runs(p: &Paths, id: &str) -> Vec<Run> {
    fs::read_to_string(p.runs_file(id))
        .map(|s| {
            s.lines()
                .filter_map(|l| serde_json::from_str(l).ok())
                .collect()
        })
        .unwrap_or_default()
}

pub fn append_run(p: &Paths, run: &Run) -> Result<(), String> {
    ensure_runs_dir(p)?;
    let mut runs = read_runs(p, &run.job_id);
    runs.push(run.clone());
    let start = runs.len().saturating_sub(MAX_RUNS_KEPT);
    let mut out = String::new();
    for r in &runs[start..] {
        out.push_str(&serde_json::to_string(r).map_err(|e| e.to_string())?);
        out.push('\n');
    }
    atomic_write(&p.runs_file(&run.job_id), out.as_bytes())
}

// ── Runner ────────────────────────────────────────────────────────────────────────

/// The user's environment as their login shell builds it, captured once. Interactive
/// rc files (.zshrc) are where nvm and friends usually set PATH, so `-i` is tried
/// first with a time limit; without a TTY it can stall or fail, then `-l` alone.
pub fn login_env() -> &'static HashMap<String, String> {
    static ENV: OnceLock<HashMap<String, String>> = OnceLock::new();
    ENV.get_or_init(|| {
        let shell = std::env::var("SHELL")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| "/bin/zsh".into());
        for flags in [["-l", "-i"].as_slice(), ["-l"].as_slice()] {
            if let Some(env) = capture_env(&shell, flags) {
                return env;
            }
        }
        std::env::vars().collect()
    })
}

pub fn capture_env(shell: &str, flags: &[&str]) -> Option<HashMap<String, String>> {
    use std::process::{Command, Stdio};
    const MARK: &str = "__MUYA_ENV__";
    let mut cmd = Command::new(shell);
    cmd.args(flags)
        .arg("-c")
        .arg(format!("printf '%s\\0' {MARK}; env -0"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut child = cmd.spawn().ok()?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(8);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(50))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let out = child.wait_with_output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    // Anything an rc file printed comes before the marker.
    let body = text.split_once(&format!("{MARK}\0"))?.1;
    let env: HashMap<String, String> = body
        .split('\0')
        .filter_map(|kv| kv.split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    env.contains_key("PATH").then_some(env)
}

pub struct Spawned {
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
}

/// Read a pipe to the end, keeping at most `cap` bytes (it keeps draining, so the
/// child never blocks on a full pipe).
pub async fn drain<R: tokio::io::AsyncRead + Unpin>(mut r: R, cap: usize) -> String {
    use tokio::io::AsyncReadExt;
    let mut kept = Vec::new();
    let mut buf = [0u8; 8192];
    loop {
        match r.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let room = cap.saturating_sub(kept.len());
                kept.extend_from_slice(&buf[..n.min(room)]);
            }
        }
    }
    String::from_utf8_lossy(&kept).into_owned()
}

pub async fn spawn_run(
    bin: &str,
    args: &[String],
    cwd: &str,
    env: &HashMap<String, String>,
    timeout: std::time::Duration,
) -> Result<Spawned, String> {
    use std::process::Stdio;
    let mut cmd = tokio::process::Command::new(bin);
    cmd.args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(env)
        .env("NO_COLOR", "1")
        .env("MUYA_SCHEDULE", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true);
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Could not start {bin}: {e}"))?;
    let pid = child.id();
    let out = tokio::spawn(drain(
        child.stdout.take().ok_or("no stdout")?,
        MAX_OUTPUT * 4,
    ));
    let err = tokio::spawn(drain(child.stderr.take().ok_or("no stderr")?, 16 * 1024));
    let (exit_code, timed_out) = match tokio::time::timeout(timeout, child.wait()).await {
        Ok(Ok(st)) => (st.code(), false),
        Ok(Err(e)) => return Err(e.to_string()),
        Err(_) => {
            if let Some(pid) = pid {
                kill_group(pid as i32, libc::SIGTERM);
                if tokio::time::timeout(std::time::Duration::from_secs(5), child.wait())
                    .await
                    .is_err()
                {
                    kill_group(pid as i32, libc::SIGKILL);
                    let _ = child.wait().await;
                }
            }
            (None, true)
        }
    };
    if let Some(pid) = pid {
        // MCP servers Claude started can outlive it; the group goes with the run.
        kill_group(pid as i32, libc::SIGTERM);
    }
    Ok(Spawned {
        exit_code,
        stdout: out.await.unwrap_or_default(),
        stderr: err.await.unwrap_or_default(),
        timed_out,
    })
}

pub fn kill_group(pgid: i32, sig: i32) {
    if pgid > 1 {
        // SAFETY: plain kill(2) on our own child's process group.
        unsafe {
            libc::kill(-pgid, sig);
        }
    }
}

/// `spawn_run` for the daemon: the child is started by `spawn::spawn_cloexec` (only fds 0-2).
pub async fn spawn_run_cloexec(
    bin: &str,
    args: &[String],
    cwd: &str,
    env: &HashMap<String, String>,
    timeout: std::time::Duration,
) -> Result<Spawned, String> {
    use crate::spawn::{pipe_cloexec, spawn_cloexec, wait_timeout, Stdio};
    use std::os::fd::{FromRawFd, OwnedFd};
    use tokio::net::unix::pipe::Receiver;
    // posix_spawnp searches the daemon's PATH; the run gets the login environment's.
    let bin_path = if bin.contains('/') {
        bin.to_string()
    } else {
        env.get("PATH")
            .into_iter()
            .flat_map(|p| p.split(':'))
            .map(|d| Path::new(d).join(bin))
            .find(|c| c.is_file())
            .map(|c| c.to_string_lossy().into_owned())
            .unwrap_or_else(|| bin.to_string())
    };
    let mut argv = vec![bin_path];
    argv.extend(args.iter().cloned());
    let mut envv: Vec<(String, String)> = env
        .iter()
        .filter(|(k, _)| *k != "NO_COLOR" && *k != "MUYA_SCHEDULE")
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    envv.push(("NO_COLOR".into(), "1".into()));
    envv.push(("MUYA_SCHEDULE".into(), "1".into()));
    let (out_r, out_w) = pipe_cloexec().map_err(|e| e.to_string())?;
    let (err_r, err_w) = pipe_cloexec().map_err(|e| e.to_string())?;
    let started = spawn_cloexec(
        &argv,
        Some(cwd),
        &envv,
        [Stdio::Null, Stdio::Fd(out_w), Stdio::Fd(err_w)],
        true,
    );
    // SAFETY: we own all four descriptors; the child has its own copies.
    unsafe {
        libc::close(out_w);
        libc::close(err_w);
    }
    let pid = match started {
        Ok(p) => p,
        Err(e) => {
            unsafe {
                libc::close(out_r);
                libc::close(err_r);
            }
            return Err(format!("Could not start {bin}: {e}"));
        }
    };
    // SAFETY: out_r/err_r are valid pipe read ends owned by nobody else.
    let rx = |fd| Receiver::from_owned_fd(unsafe { OwnedFd::from_raw_fd(fd) }).map_err(|e| e.to_string());
    let out = tokio::spawn(drain(rx(out_r)?, MAX_OUTPUT * 4));
    let err = tokio::spawn(drain(rx(err_r)?, 16 * 1024));
    let wait = |d: Option<std::time::Duration>| async move {
        tokio::task::spawn_blocking(move || wait_timeout(pid, d)).await.ok().flatten()
    };
    let (exit_code, timed_out) = match wait(Some(timeout)).await {
        Some(code) => (code, false),
        None => {
            kill_group(pid, libc::SIGTERM);
            if wait(Some(std::time::Duration::from_secs(5))).await.is_none() {
                kill_group(pid, libc::SIGKILL);
                let _ = wait(None).await;
            }
            (None, true)
        }
    };
    // MCP servers Claude started can outlive it; the group goes with the run.
    kill_group(pid, libc::SIGTERM);
    Ok(Spawned {
        exit_code,
        stdout: out.await.unwrap_or_default(),
        stderr: err.await.unwrap_or_default(),
        timed_out,
    })
}

// ── State + timer ─────────────────────────────────────────────────────────────────
//
// One process at a time fires the timers: whoever holds the lock file. That is the
// Muya window, or the background service (`muya --scheduler`, docs/
// prd-schedules-background.md) when the user turned it on. The window hands the
// lock over while the service's heartbeat is fresh and takes it back once it stops.
// Every process re-reads the jobs file when it changes, the active one writes a
// status file the others show, and "Run now" from a passive one leaves a request
// file the active one picks up on its next tick.

/// The Muya window, or the headless background service.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Role {
    App,
    Service,
    /// muyad started with `--scheduler` (native rewrite, PRD AC22/D8): the single owner of the
    /// timers. Yields to a live background service, spawns runs with `spawn_cloexec`, and keeps
    /// a last-fire marker so a restart never fires a slot twice.
    Daemon,
    /// Reads and edits the store, never fires: `run_now` leaves a request for the owner. Used by
    /// a muyad that serves the broker but does not own the timers (`--broker` without `--scheduler`).
    Client,
}

/// A service heartbeat older than this means the service is gone.
pub const HEARTBEAT_FRESH_MS: i64 = 45_000;
/// A status file older than this is ignored (its writer stopped).
pub const STATUS_FRESH_MS: i64 = 60_000;
/// A slot missed by a crashed daemon is still fired once on restart when it is this recent.
pub const CATCHUP_MS: i64 = 120_000;

/// What the active process is doing, for the others to show.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub pid: u32,
    /// Which ScheduleState wrote it (a pid alone can't tell two in one process apart).
    #[serde(default)]
    pub token: String,
    pub ts: i64,
    pub running: Vec<String>,
    pub queued: Vec<String>,
    pub due: HashMap<String, i64>,
}

/// Written by the background service on every tick, active or not.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Heartbeat {
    pub pid: u32,
    pub version: String,
    pub ts: i64,
}

/// The daemon's persisted fire state: the slot each job is waiting for and when it last fired.
#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Marker {
    pub jobs: HashMap<String, MarkerJob>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkerJob {
    pub last_fire: i64,
    pub next_due: i64,
    /// `Job::updated` the slot was computed for; an edited job's old slot is void.
    pub updated: i64,
}

#[derive(Serialize, Deserialize)]
pub struct Request {
    pub id: String,
}

pub struct Inner {
    pub paths: Paths,
    pub role: Role,
    /// Tells this state's status file from another's.
    pub token: String,
    pub jobs: Vec<Job>,
    /// The jobs file's mtime as last read or written here.
    pub jobs_seen: Option<std::time::SystemTime>,
    pub due: HashMap<String, i64>,
    pub running: HashSet<String>,
    pub queued: HashSet<String>,
    /// This process holds the lock and fires timers.
    pub active: bool,
    pub lock: Option<LockGuard>,
    /// Daemon role: when each job last fired (persisted in the marker file).
    pub last_fire: HashMap<String, i64>,
}

/// Starts a future on the host's async runtime (the app passes tauri's).
pub type Spawner = Box<dyn Fn(Pin<Box<dyn Future<Output = ()> + Send>>) + Send + Sync>;
pub type Sink = Box<dyn Fn() + Send + Sync>;
/// Types `text` into a running session and submits it; Err = why it could not (session gone, ...).
pub type SessionSender = Box<dyn Fn(&TargetSession, &str) -> Result<(), String> + Send + Sync>;

#[derive(Clone)]
pub struct ScheduleState {
    pub inner: Arc<Mutex<Inner>>,
    slots: Arc<tokio::sync::Semaphore>,
    /// Told whenever something the page shows changed (the window emits an event).
    sink: Arc<OnceLock<Sink>>,
    spawner: Arc<OnceLock<Spawner>>,
    /// How a targeted job reaches its session; only muyad has one.
    sender: Arc<OnceLock<SessionSender>>,
}

pub fn claude_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|h| h.is_absolute())
        .unwrap_or_else(std::env::temp_dir)
        .join(".claude")
}

impl Default for ScheduleState {
    fn default() -> Self {
        Self::at(&claude_dir())
    }
}

pub fn mtime(path: &Path) -> Option<std::time::SystemTime> {
    fs::metadata(path).and_then(|m| m.modified()).ok()
}

pub fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
}

pub fn write_json<T: Serialize>(path: &Path, v: &T) {
    if let Ok(b) = serde_json::to_vec(v) {
        if let Err(e) = atomic_write(path, &b) {
            log::warn!("schedules: could not write {}: {e}", path.display());
        }
    }
}

/// The background service's heartbeat, when it is fresh.
pub fn service_heartbeat() -> Option<Heartbeat> {
    heartbeat_at(&Paths::under(&claude_dir()), now_ms())
}

pub fn heartbeat_at(p: &Paths, now: i64) -> Option<Heartbeat> {
    read_json::<Heartbeat>(&p.heartbeat).filter(|h| now - h.ts < HEARTBEAT_FRESH_MS)
}

/// Forget the service's heartbeat (it was just turned off), so the window takes the
/// timers back on its next tick instead of after HEARTBEAT_FRESH_MS.
pub fn clear_service_heartbeat() {
    let _ = fs::remove_file(Paths::under(&claude_dir()).heartbeat);
}

pub fn other_status(p: &Paths, token: &str, now: i64) -> Option<Status> {
    read_json::<Status>(&p.status).filter(|s| s.token != token && now - s.ts < STATUS_FRESH_MS)
}

/// Ids with a "Run now" request waiting for the active process.
pub fn pending_requests(p: &Paths) -> HashSet<String> {
    fs::read_dir(&p.requests)
        .map(|d| {
            d.flatten()
                .filter_map(|e| {
                    let name = e.file_name().to_string_lossy().into_owned();
                    name.strip_suffix(".json")
                        .and_then(|n| n.split('-').next().map(String::from))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Read and remove every waiting request.
pub fn take_requests(p: &Paths) -> Vec<String> {
    let mut ids = Vec::new();
    let Ok(dir) = fs::read_dir(&p.requests) else {
        return ids;
    };
    for e in dir.flatten() {
        let path = e.path();
        if path.extension().is_none_or(|x| x != "json") {
            continue;
        }
        let req = read_json::<Request>(&path);
        let _ = fs::remove_file(&path);
        if let Some(r) = req {
            if !ids.contains(&r.id) {
                ids.push(r.id);
            }
        }
    }
    ids
}

/// The schedule lock. Cross-process exclusion is a POSIX record lock (`fcntl F_SETLK`), which —
/// unlike `flock` — belongs to the process, not to the open file description: a child that is
/// forked or posix_spawned while the lock is held (any thread, any test) does not inherit it, so
/// releasing the lock really releases it. Record locks do not exclude two holders inside one
/// process, so a process-wide registry does that part.
#[derive(Debug)]
pub struct LockGuard {
    file: Option<fs::File>,
    key: PathBuf,
}

fn held_locks() -> &'static Mutex<HashSet<PathBuf>> {
    static HELD: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();
    HELD.get_or_init(Default::default)
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        drop(self.file.take()); // closing releases the record lock
        if let Ok(mut h) = held_locks().lock() {
            h.remove(&self.key);
        }
    }
}

/// False only when the kernel says there is no such process (EPERM still means alive).
fn pid_alive(pid: u32) -> bool {
    let r = unsafe { libc::kill(pid as libc::pid_t, 0) };
    r == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

pub fn try_lock_file(path: &Path) -> Option<LockGuard> {
    use std::os::fd::AsRawFd;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).ok()?;
    }
    let abs = path.parent()?.canonicalize().ok()?.join(path.file_name()?);
    // Claim the path in-process first: opening and closing the file again from this process
    // would drop the record lock a live holder owns.
    if !held_locks().lock().ok()?.insert(abs.clone()) {
        return None;
    }
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path)
        .ok();
    let locked = file.filter(|f| {
        let mut fl: libc::flock = unsafe { std::mem::zeroed() };
        fl.l_type = libc::F_WRLCK as _;
        fl.l_whence = libc::SEEK_SET as _;
        unsafe { libc::fcntl(f.as_raw_fd(), libc::F_SETLK, &fl) == 0 }
    });
    match locked {
        Some(file) => Some(LockGuard { file: Some(file), key: abs }),
        None => {
            held_locks().lock().ok()?.remove(&abs);
            None
        }
    }
}

impl Inner {
    /// Pick up a jobs file another process wrote. Due times of unchanged jobs stay.
    fn refresh(&mut self) -> bool {
        let seen = mtime(&self.paths.jobs);
        if seen == self.jobs_seen {
            return false;
        }
        let old: HashMap<String, Schedule> = self
            .jobs
            .iter()
            .map(|j| (j.id.clone(), j.schedule.clone()))
            .collect();
        self.jobs = load_jobs(&self.paths);
        self.jobs_seen = seen;
        let now = Local::now();
        let mut due = HashMap::new();
        for j in &self.jobs {
            let kept = (old.get(&j.id) == Some(&j.schedule))
                .then(|| self.due.get(&j.id).copied())
                .flatten();
            if let Some(t) =
                kept.or_else(|| next_after(&j.schedule, now).map(|t| t.timestamp_millis()))
            {
                due.insert(j.id.clone(), t);
            }
        }
        self.due = due;
        true
    }

    fn persist(&mut self) -> Result<(), String> {
        save_jobs(&self.paths, &self.jobs)?;
        self.jobs_seen = mtime(&self.paths.jobs);
        Ok(())
    }

    /// Take or hand over the lock. Returns true when `active` changed.
    fn coordinate(&mut self, now: i64) -> bool {
        // The background service wins over the window and over muyad (the migration rule: while
        // a registered `muya --scheduler` agent is alive, nothing else fires).
        // A heartbeat whose process is gone (kill -9 leaves the file behind, fresh for a while)
        // is no service: a restarted muyad must not yield to its dead predecessor.
        let yield_to_service = self.role != Role::Service
            && heartbeat_at(&self.paths, now).is_some_and(|h| {
                pid_alive(h.pid) && (self.role != Role::Daemon || h.pid != std::process::id())
            });
        if self.active && yield_to_service {
            self.lock = None;
            self.active = false;
            log::info!("schedules: the background service runs the timers now");
            return true;
        }
        if !self.active && !yield_to_service && self.role != Role::Client {
            if let Some(f) = try_lock_file(&self.paths.lock) {
                self.lock = Some(f);
                self.active = true;
                // Fresh from now: slots missed while another process ran (or none
                // did) are skipped, as at startup.
                self.jobs_seen = None;
                self.refresh();
                let now = Local::now();
                self.due = self
                    .jobs
                    .iter()
                    .filter_map(|j| {
                        next_after(&j.schedule, now).map(|t| (j.id.clone(), t.timestamp_millis()))
                    })
                    .collect();
                if self.role == Role::Daemon {
                    self.catch_up(now_ms());
                }
                return true;
            }
        }
        false
    }

    /// Restores the daemon's slots from the marker after a (re)start: the job must be unchanged
    /// and its slot unfired; a missed slot is fired once if it is at most CATCHUP_MS old.
    pub fn catch_up(&mut self, now: i64) {
        let Some(m) = read_json::<Marker>(&self.paths.marker) else {
            return;
        };
        for j in self.jobs.iter().filter(|j| j.enabled) {
            if let Some(mj) = m.jobs.get(&j.id) {
                self.last_fire.insert(j.id.clone(), mj.last_fire);
                // The slot the job was waiting for survives a restart (a future one is simply
                // kept, so frequent restarts never postpone an interval job); a missed one is
                // fired once when recent, else skipped like the window does.
                if mj.updated == j.updated && now - mj.next_due <= CATCHUP_MS && mj.last_fire < mj.next_due {
                    self.due.insert(j.id.clone(), mj.next_due);
                }
            }
        }
    }

    pub fn write_marker(&self) {
        let jobs = self
            .jobs
            .iter()
            .filter_map(|j| {
                let next_due = *self.due.get(&j.id)?;
                Some((
                    j.id.clone(),
                    MarkerJob {
                        last_fire: self.last_fire.get(&j.id).copied().unwrap_or(0),
                        next_due,
                        updated: j.updated,
                    },
                ))
            })
            .collect();
        write_json(&self.paths.marker, &Marker { jobs });
    }

    pub fn write_status(&self) {
        if !self.active {
            return;
        }
        if self.role == Role::Daemon {
            self.write_marker();
        }
        let mut running: Vec<String> = self.running.iter().cloned().collect();
        let mut queued: Vec<String> = self.queued.iter().cloned().collect();
        running.sort();
        queued.sort();
        write_json(
            &self.paths.status,
            &Status {
                pid: std::process::id(),
                token: self.token.clone(),
                ts: now_ms(),
                running,
                queued,
                due: self.due.clone(),
            },
        );
    }

    /// Running or waiting here or, for a passive process, in the active one.
    fn busy(&self, id: &str) -> bool {
        if self.running.contains(id) || self.queued.contains(id) {
            return true;
        }
        if self.active {
            return false;
        }
        other_status(&self.paths, &self.token, now_ms())
            .is_some_and(|s| s.running.iter().chain(&s.queued).any(|x| x == id))
            || pending_requests(&self.paths).contains(id)
    }
}

impl ScheduleState {
    pub fn at(claude_dir: &Path) -> Self {
        Self::at_role(claude_dir, Role::App)
    }

    /// The state the background service runs with.
    pub fn service() -> Self {
        Self::at_role(&claude_dir(), Role::Service)
    }

    pub fn at_role(claude_dir: &Path, role: Role) -> Self {
        let paths = Paths::under(claude_dir);
        let mut inner = Inner {
            jobs: Vec::new(),
            jobs_seen: None,
            due: HashMap::new(),
            running: HashSet::new(),
            queued: HashSet::new(),
            active: false,
            lock: None,
            last_fire: HashMap::new(),
            paths,
            role,
            token: format!("{}-{:x}{:04x}", std::process::id(), now_ms(), rand_u16()),
        };
        inner.refresh();
        inner.coordinate(now_ms());
        ScheduleState {
            inner: Arc::new(Mutex::new(inner)),
            slots: Arc::new(tokio::sync::Semaphore::new(MAX_PARALLEL)),
            sink: Arc::new(OnceLock::new()),
            spawner: Arc::new(OnceLock::new()),
            sender: Arc::new(OnceLock::new()),
        }
    }

    /// How targeted jobs type into their session (muyad installs it).
    pub fn set_session_sender(&self, f: impl Fn(&TargetSession, &str) -> Result<(), String> + Send + Sync + 'static) {
        let _ = self.sender.set(Box::new(f));
    }

    /// How futures reach the host's runtime. Without one, `tokio::spawn` (needs a runtime context).
    pub fn set_spawner(&self, f: impl Fn(Pin<Box<dyn Future<Output = ()> + Send>>) + Send + Sync + 'static) {
        let _ = self.spawner.set(Box::new(f));
    }

    fn spawn(&self, fut: impl Future<Output = ()> + Send + 'static) {
        match self.spawner.get() {
            Some(f) => f(Box::pin(fut)),
            None => {
                tokio::spawn(fut);
            }
        }
    }

    /// The timers of muyad (`--scheduler`) under `$HOME/.claude`.
    pub fn daemon() -> Self {
        Self::at_role(&claude_dir(), Role::Daemon)
    }

    /// A store handle that never takes the timers (see [`Role::Client`]).
    pub fn client() -> Self {
        Self::at_role(&claude_dir(), Role::Client)
    }

    pub fn client_at(claude_dir: &Path) -> Self {
        Self::at_role(claude_dir, Role::Client)
    }

    pub fn daemon_at(claude_dir: &Path) -> Self {
        Self::at_role(claude_dir, Role::Daemon)
    }

    /// This process holds the schedule lock and fires the timers.
    pub fn is_active(&self) -> bool {
        self.inner.lock().map(|g| g.active).unwrap_or(false)
    }

    pub fn set_sink(&self, f: impl Fn() + Send + Sync + 'static) {
        let _ = self.sink.set(Box::new(f));
    }

    /// Something the page shows changed: refresh the status file, tell the sink.
    pub fn changed(&self) {
        if let Ok(g) = self.inner.lock() {
            g.write_status();
        }
        if let Some(f) = self.sink.get() {
            f();
        }
    }

    /// Run `id` now: here when this process fires the timers, else through a
    /// request file the active process picks up on its next tick.
    pub fn run_now(&self, id: &str) -> Result<(), String> {
        {
            let mut g = self.inner.lock().map_err(|_| "busy")?;
            g.refresh();
            if !g.jobs.iter().any(|j| j.id == id) {
                return Err("Schedule not found.".into());
            }
            if !g.active {
                if g.busy(id) {
                    return Err("This schedule is already running.".into());
                }
                let dir = &g.paths.requests;
                fs::create_dir_all(dir).map_err(|e| e.to_string())?;
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
                }
                let file = dir.join(format!("{id}-{:x}{:04x}.json", now_ms(), rand_u16()));
                let bytes = serde_json::to_vec(&Request { id: id.to_string() })
                    .map_err(|e| e.to_string())?;
                atomic_write(&file, &bytes)?;
                drop(g);
                self.changed();
                return Ok(());
            }
        }
        self.launch(id, "manual")
    }

    /// Start one run of `id` unless it is already running or waiting. Returns at
    /// once; the run waits for a free slot.
    pub fn launch(&self, id: &str, trigger: &str) -> Result<(), String> {
        let job = {
            let mut g = self.inner.lock().map_err(|_| "busy")?;
            if g.running.contains(id) || g.queued.contains(id) {
                return Err("This schedule is already running.".into());
            }
            let job = g
                .jobs
                .iter()
                .find(|j| j.id == id)
                .cloned()
                .ok_or("Schedule not found.")?;
            g.queued.insert(id.to_string());
            job
        };
        self.changed();
        let (state, trigger) = (self.clone(), trigger.to_string());
        self.spawn(async move {
            let _permit = state.slots.clone().acquire_owned().await;
            if let Ok(mut g) = state.inner.lock() {
                g.queued.remove(&job.id);
                g.running.insert(job.id.clone());
            }
            state.changed();
            let started = now_ms();
            if let Some(target) = job.target.clone() {
                let sent = match state.sender.get() {
                    Some(send) => send(&target, &job.prompt),
                    None => Err("This app cannot type into sessions; the Muya daemon runs session schedules.".into()),
                };
                let (status, output) = match sent {
                    Ok(()) => (RunStatus::Success, format!("Sent to “{}”.", target.name)),
                    Err(e) => (RunStatus::Failed, e),
                };
                let run = Run {
                    job_id: job.id.clone(),
                    started,
                    ended: now_ms(),
                    status,
                    exit_code: None,
                    cost_usd: None,
                    trigger,
                    output,
                };
                let paths = state.inner.lock().map(|g| g.paths.clone()).ok();
                if let Some(p) = paths {
                    if let Err(e) = append_run(&p, &run) {
                        log::warn!("schedules: could not save run of {}: {e}", job.id);
                    }
                }
                if let Ok(mut g) = state.inner.lock() {
                    g.running.remove(&job.id);
                }
                state.changed();
                return;
            }
            let env = tokio::task::spawn_blocking(login_env)
                .await
                .map(|e| e.clone())
                .unwrap_or_default();
            let bin = crate::agents::claude_bin().to_string();
            let args = claude_args(&job.prompt, job.bypass, job.chrome, &job.model, &job.effort);
            let timeout = std::time::Duration::from_secs(u64::from(job.timeout_min) * 60);
            let cloexec = state.inner.lock().map(|g| g.role == Role::Daemon).unwrap_or(false);
            let ran = if cloexec {
                spawn_run_cloexec(&bin, &args, &job.folder, &env, timeout).await
            } else {
                spawn_run(&bin, &args, &job.folder, &env, timeout).await
            };
            let (status, exit_code, cost, output) =
                match ran {
                    Ok(s) if s.timed_out => {
                        let (_, cost, text) = classify(s.exit_code, &s.stdout, &s.stderr);
                        (
                            RunStatus::Timeout,
                            None,
                            cost,
                            format!("Stopped after {} min.\n\n{text}", job.timeout_min)
                                .trim()
                                .to_string(),
                        )
                    }
                    Ok(s) => {
                        let (st, cost, text) = classify(s.exit_code, &s.stdout, &s.stderr);
                        (st, s.exit_code, cost, text)
                    }
                    Err(e) => (RunStatus::Failed, None, None, e),
                };
            let run = Run {
                job_id: job.id.clone(),
                started,
                ended: now_ms(),
                status,
                exit_code,
                cost_usd: cost,
                trigger,
                output,
            };
            let paths = state.inner.lock().map(|g| g.paths.clone()).ok();
            if let Some(p) = paths {
                if let Err(e) = append_run(&p, &run) {
                    log::warn!("schedules: could not save run of {}: {e}", job.id);
                }
            }
            if let Ok(mut g) = state.inner.lock() {
                g.running.remove(&job.id);
            }
            state.changed();
        });
        Ok(())
    }

    /// One timer tick: heartbeat, lock hand-over, reload, then what to start now as
    /// (id, trigger). The bool says the page should refresh.
    pub fn tick(&self, now: DateTime<Local>) -> (Vec<(String, &'static str)>, bool) {
        let Ok(mut g) = self.inner.lock() else {
            return (Vec::new(), false);
        };
        let now_ms = now.timestamp_millis();
        // muyad --scheduler (Daemon) is the service now: same heartbeat, so the window shows
        // "service" and stays passive.
        if matches!(g.role, Role::Service | Role::Daemon) {
            write_json(
                &g.paths.heartbeat,
                &Heartbeat {
                    pid: std::process::id(),
                    version: env!("CARGO_PKG_VERSION").to_string(),
                    ts: now_ms,
                },
            );
        }
        let flipped = g.coordinate(now_ms);
        let reloaded = g.refresh();
        if !g.active {
            // Passive: the active process's status changes without telling us.
            return (Vec::new(), true);
        }
        let mut fire: Vec<(String, &'static str)> = take_requests(&g.paths)
            .into_iter()
            .map(|id| (id, "manual"))
            .collect();
        let due_now: Vec<(String, Schedule)> = g
            .jobs
            .iter()
            .filter(|j| j.enabled && g.due.get(&j.id).is_some_and(|d| *d <= now_ms))
            .map(|j| (j.id.clone(), j.schedule.clone()))
            .collect();
        for (id, s) in due_now {
            // From now, not from the missed time: a Mac that slept through several
            // slots runs once, not once per slot.
            match next_after(&s, now) {
                Some(t) => g.due.insert(id.clone(), t.timestamp_millis()),
                None => g.due.remove(&id),
            };
            if !fire.iter().any(|(x, _)| *x == id) {
                g.last_fire.insert(id.clone(), now_ms);
                fire.push((id, "schedule"));
            }
        }
        g.write_status();
        (fire, flipped || reloaded)
    }

    pub fn idle(&self) -> bool {
        self.inner
            .lock()
            .map(|g| g.running.is_empty() && g.queued.is_empty())
            .unwrap_or(false)
    }
}

/// The timer loop, for the window and the background service alike.
pub async fn run_timer(state: ScheduleState) {
    // The service runs from the app bundle: after an update replaced it, exit once
    // idle so launchd starts the new version (KeepAlive restarts a failed exit).
    let exe_id = |p: &Path| {
        use std::os::unix::fs::MetadataExt;
        fs::metadata(p).ok().map(|m| (m.dev(), m.ino()))
    };
    let exe = std::env::current_exe().ok();
    let exe_at_start = exe.as_deref().and_then(exe_id);
    let service = state
        .inner
        .lock()
        .map(|g| g.role == Role::Service)
        .unwrap_or(false);
    // MUYA_SCHEDULE_TICK_MS: faster ticks for tests (never below 100 ms).
    let tick_ms = std::env::var("MUYA_SCHEDULE_TICK_MS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .map(|v| v.max(100))
        .unwrap_or(TICK_SECS * 1000);
    let mut tick = tokio::time::interval(std::time::Duration::from_millis(tick_ms));
    loop {
        tick.tick().await;
        let (fire, refresh) = state.tick(Local::now());
        for (id, trigger) in fire {
            if let Err(e) = state.launch(&id, trigger) {
                log::info!("schedules: {id} not started: {e}");
            }
        }
        if refresh {
            if let Some(f) = state.sink.get() {
                f();
            }
        }
        if service
            && exe_at_start.is_some()
            && exe.as_deref().and_then(exe_id) != exe_at_start
            && state.idle()
        {
            log::info!("schedules: Muya was updated; restarting the background service");
            std::process::exit(75);
        }
    }
}

pub fn now_ms() -> i64 {
    Local::now().timestamp_millis()
}

pub fn view(inner: &Inner) -> Vec<JobView> {
    let now = now_ms();
    let other = (!inner.active)
        .then(|| other_status(&inner.paths, &inner.token, now))
        .flatten();
    let pending = if inner.active {
        HashSet::new()
    } else {
        pending_requests(&inner.paths)
    };
    let in_other = |list: fn(&Status) -> &Vec<String>, id: &str| {
        other
            .as_ref()
            .is_some_and(|s| list(s).iter().any(|x| x == id))
    };
    inner
        .jobs
        .iter()
        .map(|j| {
            let runs = read_runs(&inner.paths, &j.id);
            let ok = runs
                .iter()
                .filter(|r| r.status == RunStatus::Success)
                .count();
            let next_run = if !j.enabled {
                None
            } else if inner.active {
                inner.due.get(&j.id).copied()
            } else {
                other.as_ref().and_then(|s| s.due.get(&j.id).copied())
            };
            JobView {
                job: j.clone(),
                next_run,
                running: inner.running.contains(&j.id) || in_other(|s| &s.running, &j.id),
                queued: inner.queued.contains(&j.id)
                    || in_other(|s| &s.queued, &j.id)
                    || pending.contains(&j.id),
                runs: runs.len(),
                ok,
                failed: runs.len() - ok,
                last: runs.last().map(|r| RunSummary {
                    started: r.started,
                    ended: r.ended,
                    status: r.status.clone(),
                }),
            }
        })
        .collect()
}
// ── Commands ──────────────────────────────────────────────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListResult {
    pub jobs: Vec<JobView>,
    /// False when another process holds the schedule lock (its timer runs the jobs).
    pub active: bool,
    /// Who runs the timers: "here", "service" (the background service) or "other"
    /// (another Muya window). "none" briefly while the lock changes hands.
    pub runner: &'static str,
}

pub fn runner(inner: &Inner) -> &'static str {
    let now = now_ms();
    if inner.active {
        "here"
    } else if heartbeat_at(&inner.paths, now).is_some_and(|h| pid_alive(h.pid)) {
        // A dead process's leftover heartbeat is no service (same rule as `coordinate`).
        "service"
    } else if other_status(&inner.paths, &inner.token, now).is_some() {
        "other"
    } else {
        "none"
    }
}

pub fn upsert(inner: &mut Inner, input: JobInput) -> Result<Job, String> {
    let folder = validate(&input)?;
    inner.refresh();
    let now = now_ms();
    let job = match input.id.as_deref().filter(|s| !s.is_empty()) {
        Some(id) => {
            let j = inner
                .jobs
                .iter_mut()
                .find(|j| j.id == id)
                .ok_or("Schedule not found.")?;
            j.name = input.name.trim().into();
            j.prompt = input.prompt;
            j.folder = folder;
            j.schedule = input.schedule;
            j.enabled = input.enabled;
            j.timeout_min = input.timeout_min;
            j.bypass = input.bypass;
            j.agent = input.agent;
            j.model = input.model.trim().into();
            j.effort = input.effort.trim().into();
            j.chrome = input.chrome;
            j.target = input.target;
            j.updated = now;
            j.clone()
        }
        None => {
            let id = format!("s{:x}{:04x}", now, rand_u16());
            let j = Job {
                id,
                name: input.name.trim().into(),
                prompt: input.prompt,
                folder,
                schedule: input.schedule,
                enabled: input.enabled,
                timeout_min: input.timeout_min,
                bypass: input.bypass,
                agent: input.agent,
                model: input.model.trim().into(),
                effort: input.effort.trim().into(),
                chrome: input.chrome,
                target: input.target,
                created: now,
                updated: now,
            };
            inner.jobs.push(j.clone());
            j
        }
    };
    inner.persist()?;
    match next_after(&job.schedule, Local::now()) {
        Some(t) => inner.due.insert(job.id.clone(), t.timestamp_millis()),
        None => inner.due.remove(&job.id),
    };
    Ok(job)
}

pub fn rand_u16() -> u16 {
    use std::sync::atomic::{AtomicU16, Ordering};
    static SEQ: AtomicU16 = AtomicU16::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    (nanos as u16) ^ SEQ.fetch_add(1, Ordering::Relaxed).wrapping_mul(40503)
}

pub fn set_enabled(inner: &mut Inner, id: &str, enabled: bool) -> Result<(), String> {
    inner.refresh();
    let j = inner
        .jobs
        .iter_mut()
        .find(|j| j.id == id)
        .ok_or("Schedule not found.")?;
    j.enabled = enabled;
    j.updated = now_ms();
    let s = j.schedule.clone();
    inner.persist()?;
    if let Some(t) = next_after(&s, Local::now()) {
        inner.due.insert(id.to_string(), t.timestamp_millis());
    }
    Ok(())
}

pub fn delete(inner: &mut Inner, id: &str) -> Result<(), String> {
    inner.refresh();
    if inner.busy(id) {
        return Err("Wait for the running schedule to finish.".into());
    }
    let before = inner.jobs.len();
    inner.jobs.retain(|j| j.id != id);
    if inner.jobs.len() == before {
        return Err("Schedule not found.".into());
    }
    inner.persist()?;
    inner.due.remove(id);
    let _ = fs::remove_file(inner.paths.runs_file(id));
    Ok(())
}

// ── Agent API (muya-mcp tools via broker.rs) ──────────────────────────────────────
//
// The same operations the page offers, for a Claude session: list, create, update
// (only the fields given), enable/disable, delete, run now, history. A schedule is
// addressed by its id or its exact name (case-insensitive).

/// Output of each run in an agent's history listing is capped: a run keeps up to
/// 64 KB, and ten of those would flood the agent's context.
pub const AGENT_OUTPUT_CAP: usize = 8_000;

pub fn resolve(inner: &Inner, key: &str) -> Result<String, String> {
    let key = key.trim();
    if let Some(j) = inner.jobs.iter().find(|j| j.id == key) {
        return Ok(j.id.clone());
    }
    let named: Vec<&Job> = inner
        .jobs
        .iter()
        .filter(|j| j.name.eq_ignore_ascii_case(key))
        .collect();
    match named.as_slice() {
        [one] => Ok(one.id.clone()),
        [] => Err(format!(
            "No schedule with id or name '{key}'. Use schedules_list to see them."
        )),
        many => Err(format!(
            "{} schedules are named '{key}'; use the id instead: {}",
            many.len(),
            many.iter()
                .map(|j| j.id.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
}

/// A JobInput from the agent's fields, on top of `base` (the job being updated) or
/// the page's defaults for a new one.
pub fn input_from(base: Option<&Job>, patch: &serde_json::Value) -> Result<JobInput, String> {
    input_from_agent(base, patch, false)
}

/// Same, for a schedule written by an AGENT: it may set `bypass` true or false, like the operator;
/// the job is only marked `agent` (provenance).
pub fn input_from_agent(base: Option<&Job>, patch: &serde_json::Value, agent: bool) -> Result<JobInput, String> {
    let mut v = match base {
        Some(j) => serde_json::json!({
            "id": j.id, "name": j.name, "prompt": j.prompt, "folder": j.folder, "schedule": j.schedule,
            "enabled": j.enabled, "timeoutMin": j.timeout_min, "bypass": j.bypass, "chrome": j.chrome,
            "target": j.target, "agent": j.agent, "model": j.model, "effort": j.effort,
        }),
        None => serde_json::json!({ "enabled": true, "timeoutMin": 30, "bypass": false, "chrome": true }),
    };
    let obj = patch
        .as_object()
        .ok_or("Expected an object of schedule fields.")?;
    for k in [
        "name",
        "prompt",
        "folder",
        "schedule",
        "enabled",
        "timeoutMin",
        "bypass",
        "chrome",
        "target",
        "model",
        "effort",
    ] {
        if let Some(x) = obj.get(k).filter(|x| !x.is_null()) {
            v[k] = x.clone();
        }
    }
    for k in ["name", "prompt", "folder", "schedule"] {
        if v.get(k).is_none_or(|x| x.is_null()) {
            return Err(format!("Missing '{k}'."));
        }
    }
    if agent {
        v["agent"] = serde_json::Value::Bool(true);
    }
    serde_json::from_value(v).map_err(|e| format!("Bad schedule fields: {e}"))
}

pub fn agent_run(r: &Run) -> serde_json::Value {
    let mut out = r.output.clone();
    if out.len() > AGENT_OUTPUT_CAP {
        let mut cut = AGENT_OUTPUT_CAP;
        while !out.is_char_boundary(cut) {
            cut -= 1;
        }
        out.truncate(cut);
        out.push_str("\n… (truncated; the full output is in Muya's Schedules page)");
    }
    serde_json::json!({
        "started": r.started, "ended": r.ended, "durationMs": r.ended - r.started, "status": r.status,
        "exitCode": r.exit_code, "costUsd": r.cost_usd, "trigger": r.trigger, "output": out,
    })
}

// ── Operations (the app's commands and the agent API both call these) ────────────────

impl ScheduleState {
    /// The jobs with their live state, for the page or an agent.
    pub fn list(&self) -> Result<ListResult, String> {
        let mut g = self.inner.lock().map_err(|_| "busy".to_string())?;
        g.refresh();
        Ok(ListResult {
            jobs: view(&g),
            active: g.active,
            runner: runner(&g),
        })
    }

    pub fn save(&self, job: JobInput) -> Result<Job, String> {
        let out = {
            let mut g = self.inner.lock().map_err(|_| "busy".to_string())?;
            upsert(&mut g, job)
        };
        self.changed();
        out
    }

    pub fn set_job_enabled(&self, id: &str, enabled: bool) -> Result<(), String> {
        {
            let mut g = self.inner.lock().map_err(|_| "busy".to_string())?;
            set_enabled(&mut g, id, enabled)?;
        }
        self.changed();
        Ok(())
    }

    pub fn delete_job(&self, id: &str) -> Result<(), String> {
        {
            let mut g = self.inner.lock().map_err(|_| "busy".to_string())?;
            delete(&mut g, id)?;
        }
        self.changed();
        Ok(())
    }

    /// Runs of one job, newest first.
    pub fn runs(&self, id: &str) -> Result<Vec<Run>, String> {
        let p = self.inner.lock().map_err(|_| "busy".to_string())?.paths.clone();
        let mut runs = read_runs(&p, id);
        runs.reverse();
        Ok(runs)
    }

    /// One agent operation (muya-mcp tools). `key` names the schedule (id or name), `fields`
    /// carries the create/update fields, `enabled` the toggle and `limit` the history length.
    pub fn agent_op(
        &self,
        op: &str,
        key: Option<&str>,
        fields: Option<&serde_json::Value>,
        enabled: Option<bool>,
        limit: Option<usize>,
    ) -> Result<serde_json::Value, String> {
        let state = self;
        let need_key = || {
            key.filter(|k| !k.trim().is_empty())
                .ok_or_else(|| "Missing 'schedule' (its id or name).".to_string())
        };
        match op {
            "schedules_list" => {
                let mut g = state.inner.lock().map_err(|_| "busy")?;
                g.refresh();
                Ok(serde_json::json!({ "jobs": view(&g), "timersActive": g.active, "runner": runner(&g) }))
            }
            "schedule_create" => {
                let input = input_from_agent(None, fields.ok_or("Missing schedule fields.")?, true)?;
                let mut g = state.inner.lock().map_err(|_| "busy")?;
                let job = upsert(&mut g, input)?;
                drop(g);
                state.changed();
                serde_json::to_value(job).map_err(|e| e.to_string())
            }
            "schedule_update" => {
                let mut g = state.inner.lock().map_err(|_| "busy")?;
                let id = resolve(&g, need_key()?)?;
                let base = g.jobs.iter().find(|j| j.id == id).cloned();
                let input = input_from_agent(base.as_ref(), fields.ok_or("Nothing to update.")?, true)?;
                let job = upsert(&mut g, input)?;
                drop(g);
                state.changed();
                serde_json::to_value(job).map_err(|e| e.to_string())
            }
            "schedule_set_enabled" => {
                let on = enabled.ok_or("Missing 'enabled' (true or false).")?;
                let mut g = state.inner.lock().map_err(|_| "busy")?;
                let id = resolve(&g, need_key()?)?;
                set_enabled(&mut g, &id, on)?;
                drop(g);
                state.changed();
                Ok(serde_json::json!({ "id": id, "enabled": on }))
            }
            "schedule_delete" => {
                let mut g = state.inner.lock().map_err(|_| "busy")?;
                let id = resolve(&g, need_key()?)?;
                delete(&mut g, &id)?;
                drop(g);
                state.changed();
                Ok(serde_json::json!({ "deleted": id }))
            }
            "schedule_run_now" => {
                let mut g = state.inner.lock().map_err(|_| "busy")?;
                g.refresh();
                let id = resolve(&g, need_key()?)?;
                drop(g);
                state.run_now(&id)?;
                Ok(
                    serde_json::json!({ "started": id, "note": "The run continues in the background; read its result with schedule_history." }),
                )
            }
            "schedule_history" => {
                let mut g = state.inner.lock().map_err(|_| "busy")?;
                g.refresh();
                let id = resolve(&g, need_key()?)?;
                let running = g.busy(&id);
                let paths = g.paths.clone();
                drop(g);
                let mut runs = read_runs(&paths, &id);
                runs.reverse();
                let n = limit.unwrap_or(5).clamp(1, MAX_RUNS_KEPT);
                Ok(serde_json::json!({
                    "id": id,
                    "running": running,
                    "totalRuns": runs.len(),
                    "runs": runs.iter().take(n).map(agent_run).collect::<Vec<_>>(),
                }))
            }
            other => Err(format!("unknown schedule op '{other}'")),
        }
    }
}

// ── Migration: the `muya --scheduler` SMAppService agent → muyad (PRD AC22, D8) ───────

/// The bundled agent's launchd label (src-tauri/launchd/com.staunch.muya.scheduler.plist).
pub const SCHEDULER_AGENT_LABEL: &str = "com.staunch.muya.scheduler";
/// The plist name `SMAppService.agent` registers it under.
pub const SCHEDULER_AGENT_PLIST: &str = "com.staunch.muya.scheduler.plist";

/// What to do about the old background agent before muyad owns the timers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentMigration {
    /// No agent is registered or running: muyad may own the timers.
    Clear,
    /// The agent is registered. The caller (the app, which can talk to SMAppService) unregisters
    /// `plist`; until then `still_firing` says whether its heartbeat is fresh, in which case muyad
    /// does not fire (coordinate() yields to the heartbeat, and the shared lock refuses a second
    /// owner either way).
    Unregister { plist: &'static str, still_firing: bool },
}

/// Pure decision. `launchctl_print_ok` is whether `launchctl print gui/<uid>/<label>` (see
/// [`launchctl_print_argv`]) succeeded — the agent is registered with launchd — and `heartbeat`
/// is [`service_heartbeat`]-style fresh state. Nothing here touches the system.
pub fn plan_agent_migration(launchctl_print_ok: bool, heartbeat: Option<&Heartbeat>) -> AgentMigration {
    if launchctl_print_ok || heartbeat.is_some() {
        AgentMigration::Unregister { plist: SCHEDULER_AGENT_PLIST, still_firing: heartbeat.is_some() }
    } else {
        AgentMigration::Clear
    }
}

/// The read-only command that tells whether launchd knows the agent.
pub fn launchctl_print_argv(uid: u32) -> Vec<String> {
    vec!["launchctl".into(), "print".into(), format!("gui/{uid}/{SCHEDULER_AGENT_LABEL}")]
}

#[cfg(test)]
mod daemon_tests {
    use super::*;

    #[test]
    fn agent_schedules_may_set_bypass_either_way() {
        let patch = serde_json::json!({"name":"n","prompt":"p","folder":"/","schedule":{"kind":"interval","minutes":10},"bypass":true});
        let on = input_from_agent(None, &patch, true).unwrap();
        assert!(on.bypass && on.agent);
        let mut off = patch.clone();
        off["bypass"] = serde_json::json!(false);
        assert!(!input_from_agent(None, &off, true).unwrap().bypass);
        // editing the prompt keeps the bypass the job has
        let job = Job { id: "i".into(), name: "n".into(), prompt: "p".into(), folder: "/".into(), schedule: on.schedule.clone(), enabled: true, timeout_min: 30, bypass: true, agent: false, model: String::new(), effort: String::new(), chrome: true, target: None, created: 0, updated: 0 };
        assert!(input_from_agent(Some(&job), &serde_json::json!({"prompt": "other"}), true).unwrap().bypass);
        assert!(claude_args("x", true, false, "", "").contains(&"--dangerously-skip-permissions".to_string()));
        let a = claude_args("x", false, false, "", "");
        assert!(a.windows(2).any(|w| w[0] == "--permission-mode" && w[1] == "acceptEdits"));
        assert!(!a.iter().any(|x| x == "auto"));
    }

    #[test]
    fn model_and_effort_reach_the_command_line_and_are_validated() {
        let a = claude_args("hello", true, false, "opus", "xhigh");
        assert!(a.windows(2).any(|w| w[0] == "--model" && w[1] == "opus"));
        assert!(a.windows(2).any(|w| w[0] == "--effort" && w[1] == "xhigh"));
        assert_eq!(a.last().map(String::as_str), Some("hello"));
        let none = claude_args("hello", true, false, "", "");
        assert!(!none.iter().any(|x| x == "--model" || x == "--effort"));
        assert!(validate_model_effort("claude-opus-4-1[1m]", "max").is_ok());
        assert!(validate_model_effort("", "").is_ok());
        assert!(validate_model_effort("--evil", "").is_err());
        assert!(validate_model_effort("a b", "").is_err());
        assert!(validate_model_effort("opus", "extreme").is_err());
        let patch = serde_json::json!({"name":"n","prompt":"p","folder":"/","schedule":{"kind":"interval","minutes":10},"model":"sonnet","effort":"low"});
        let inp = input_from_agent(None, &patch, true).unwrap();
        assert_eq!((inp.model.as_str(), inp.effort.as_str()), ("sonnet", "low"));
        // an old stored job without the fields loads with empty model/effort
        let old = r#"{"id":"a","name":"n","prompt":"p","folder":"/","schedule":{"kind":"interval","minutes":10},"enabled":true,"timeoutMin":5,"bypass":true,"created":1,"updated":1}"#;
        let j: Job = serde_json::from_str(old).unwrap();
        assert!(j.model.is_empty() && j.effort.is_empty());
    }

    fn job(st: &ScheduleState, folder: &Path, schedule: Schedule) -> Job {
        st.save(JobInput {
            id: None,
            name: "t".into(),
            prompt: "p".into(),
            folder: folder.to_str().unwrap().into(),
            schedule,
            enabled: true,
            timeout_min: 1,
            bypass: true,
            agent: false,
            model: String::new(),
            effort: String::new(),
            chrome: false,
            target: None,
        })
        .unwrap()
    }

    /// Regression for the src-tauri flake: a child spawned by another thread while the lock was
    /// held used to inherit the flock, so a released lock looked taken.
    #[test]
    fn a_released_lock_is_free_even_while_other_threads_spawn_children() {
        use std::os::unix::process::CommandExt;
        use std::sync::atomic::{AtomicBool, Ordering};
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("l.lock");
        let stop = Arc::new(AtomicBool::new(false));
        let spawners: Vec<_> = (0..4)
            .map(|_| {
                let stop = stop.clone();
                std::thread::spawn(move || {
                    while !stop.load(Ordering::Relaxed) {
                        let _ = std::process::Command::new("/usr/bin/true")
                            .stdout(std::process::Stdio::piped())
                            .process_group(0)
                            .status();
                    }
                })
            })
            .collect();
        for _ in 0..300 {
            let a = try_lock_file(&path).expect("free lock");
            assert!(try_lock_file(&path).is_none(), "held lock refuses a second taker");
            drop(a);
        }
        stop.store(true, Ordering::Relaxed);
        for h in spawners {
            h.join().unwrap();
        }
    }

    #[test]
    fn a_heartbeat_left_by_a_dead_process_is_not_a_service() {
        let home = tempfile::tempdir().unwrap();
        let p = Paths::under(home.path());
        let mut gone = std::process::Command::new("/usr/bin/true").spawn().unwrap();
        let pid = gone.id();
        gone.wait().unwrap();
        write_json(&p.heartbeat, &Heartbeat { pid, version: "x".into(), ts: now_ms() });
        let d = ScheduleState::at_role(home.path(), Role::Daemon);
        assert!(d.is_active(), "a restarted muyad does not yield to its dead predecessor");
    }

    #[test]
    fn runner_ignores_a_heartbeat_of_a_dead_pid() {
        let home = tempfile::tempdir().unwrap();
        let p = Paths::under(home.path());
        let mut gone = std::process::Command::new("/usr/bin/true").spawn().unwrap();
        let pid = gone.id();
        gone.wait().unwrap();
        write_json(&p.heartbeat, &Heartbeat { pid, version: "x".into(), ts: now_ms() });
        let c = ScheduleState::at_role(home.path(), Role::Client);
        assert_eq!(c.list().unwrap().runner, "none", "dead pid: not a service");
        write_json(&p.heartbeat, &Heartbeat { pid: std::process::id(), version: "x".into(), ts: now_ms() });
        assert_eq!(c.list().unwrap().runner, "service", "live pid: service");
    }

    #[test]
    fn a_second_daemon_refuses_while_the_first_holds_the_lock() {
        let home = tempfile::tempdir().unwrap();
        let first = ScheduleState::daemon_at(home.path());
        assert!(first.is_active());
        let second = ScheduleState::daemon_at(home.path());
        assert!(!second.is_active(), "same lock file: only one owner");
        second.tick(Local::now());
        assert!(!second.is_active());
        drop(first);
        second.tick(Local::now());
        assert!(second.is_active(), "failover once the owner is gone");
    }

    #[test]
    fn the_tauri_lock_holder_and_the_daemon_never_both_own() {
        let home = tempfile::tempdir().unwrap();
        let app = ScheduleState::at(home.path());
        assert!(app.is_active());
        assert!(!ScheduleState::daemon_at(home.path()).is_active());
    }

    #[test]
    fn the_daemon_yields_to_a_live_background_agent() {
        let home = tempfile::tempdir().unwrap();
        let p = Paths::under(home.path());
        write_json(&p.heartbeat, &Heartbeat { pid: 1, version: "x".into(), ts: now_ms() });
        let d = ScheduleState::daemon_at(home.path());
        assert!(!d.is_active(), "agent heartbeat is fresh");
        write_json(&p.heartbeat, &Heartbeat { pid: 1, version: "x".into(), ts: now_ms() - HEARTBEAT_FRESH_MS - 1 });
        d.tick(Local::now());
        assert!(d.is_active(), "a stale heartbeat does not count");
    }

    #[test]
    fn marker_catches_up_a_recent_unfired_slot_once_and_never_a_fired_one() {
        let home = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let first = ScheduleState::daemon_at(home.path());
        let j = job(&first, work.path(), Schedule::Interval { minutes: 30 });
        let p = Paths::under(home.path());
        drop(first);
        let now = now_ms();
        let jobs = load_jobs(&p);
        let mk = |last_fire: i64, next_due: i64| {
            write_json(
                &p.marker,
                &Marker {
                    jobs: HashMap::from([(j.id.clone(), MarkerJob { last_fire, next_due, updated: jobs[0].updated })]),
                },
            );
        };
        // Killed 10 s after the slot, before it fired: fire it once.
        mk(0, now - 10_000);
        let d = ScheduleState::daemon_at(home.path());
        let (fire, _) = d.tick(Local::now());
        assert_eq!(fire.len(), 1, "the missed recent slot fires once");
        let (fire, _) = d.tick(Local::now());
        assert!(fire.is_empty(), "…and only once");
        drop(d);
        // Already fired: no second fire after a restart.
        mk(now - 10_000, now - 10_000);
        let d = ScheduleState::daemon_at(home.path());
        assert!(d.tick(Local::now()).0.is_empty());
        drop(d);
        // A future slot is kept as is (interval jobs are not postponed by a restart).
        mk(0, now + 60_000);
        let d = ScheduleState::daemon_at(home.path());
        assert_eq!(d.inner.lock().unwrap().due[&j.id], now + 60_000);
        drop(d);
        // Too old: skipped like the window does.
        mk(0, now - CATCHUP_MS - 5_000);
        let d = ScheduleState::daemon_at(home.path());
        assert!(d.tick(Local::now()).0.is_empty());
    }

    #[test]
    fn the_marker_records_the_fire_before_it_is_launched() {
        let home = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let d = ScheduleState::daemon_at(home.path());
        let j = job(&d, work.path(), Schedule::Interval { minutes: 30 });
        d.inner.lock().unwrap().due.insert(j.id.clone(), now_ms() - 1);
        let (fire, _) = d.tick(Local::now());
        assert_eq!(fire.len(), 1);
        let m: Marker = read_json(&Paths::under(home.path()).marker).unwrap();
        assert!(m.jobs[&j.id].last_fire > 0 && m.jobs[&j.id].next_due > now_ms(), "persisted by tick, before launch");
    }

    #[test]
    fn migration_plan_unregisters_a_registered_or_live_agent() {
        let hb = Heartbeat { pid: 7, version: "x".into(), ts: 1 };
        assert_eq!(plan_agent_migration(false, None), AgentMigration::Clear);
        assert_eq!(
            plan_agent_migration(true, None),
            AgentMigration::Unregister { plist: SCHEDULER_AGENT_PLIST, still_firing: false }
        );
        assert_eq!(
            plan_agent_migration(true, Some(&hb)),
            AgentMigration::Unregister { plist: SCHEDULER_AGENT_PLIST, still_firing: true }
        );
        assert_eq!(launchctl_print_argv(501), ["launchctl", "print", "gui/501/com.staunch.muya.scheduler"]);
    }

    fn targeted(st: &ScheduleState, id: u64) -> Job {
        st.save(JobInput {
            id: None,
            name: "echo".into(),
            prompt: "echo SCHED".into(),
            folder: String::new(),
            schedule: Schedule::Interval { minutes: 30 },
            enabled: true,
            timeout_min: 30,
            bypass: false,
            agent: false,
            model: String::new(),
            effort: String::new(),
            chrome: false,
            target: Some(TargetSession { id, name: "shell".into(), cwd: "/work".into() }),
        })
        .unwrap()
    }

    fn wait_run(st: &ScheduleState, job: &str) -> Run {
        for _ in 0..200 {
            if let Some(r) = st.runs(job).unwrap().into_iter().next() {
                return r;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        panic!("no run recorded");
    }

    #[test]
    fn the_target_session_round_trips_through_the_store() {
        let home = tempfile::tempdir().unwrap();
        let st = ScheduleState::daemon_at(home.path());
        let j = targeted(&st, 7);
        assert_eq!(j.target, Some(TargetSession { id: 7, name: "shell".into(), cwd: "/work".into() }));
        assert_eq!(j.folder, "/work", "a targeted job keeps the session folder without needing it on disk");
        let again = ScheduleState::daemon_at(home.path());
        assert_eq!(again.list().unwrap().jobs[0].job.target, j.target);
        // A job saved before the field existed loads with no target.
        let old = r#"{"id":"a","name":"n","prompt":"p","folder":"/","schedule":{"kind":"interval","minutes":10},"enabled":true,"timeoutMin":5,"bypass":true,"created":1,"updated":1}"#;
        assert!(serde_json::from_str::<Job>(old).unwrap().target.is_none());
        assert!(!serde_json::to_string(&serde_json::from_str::<Job>(old).unwrap()).unwrap().contains("target"));
    }

    #[test]
    fn firing_a_targeted_job_types_into_its_session_and_records_ok() {
        let home = tempfile::tempdir().unwrap();
        let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().unwrap();
        let st = ScheduleState::daemon_at(home.path());
        let h = rt.handle().clone();
        st.set_spawner(move |f| {
            h.spawn(f);
        });
        let got: Arc<Mutex<Vec<(u64, String)>>> = Arc::default();
        let g2 = got.clone();
        st.set_session_sender(move |t, text| {
            g2.lock().unwrap().push((t.id, text.to_string()));
            Ok(())
        });
        let j = targeted(&st, 7);
        st.run_now(&j.id).unwrap();
        let run = wait_run(&st, &j.id);
        assert_eq!(run.status, RunStatus::Success);
        assert_eq!(got.lock().unwrap().as_slice(), [(7, "echo SCHED".to_string())]);
    }

    #[test]
    fn a_gone_target_records_a_failed_run_with_the_reason_and_starts_nothing() {
        let home = tempfile::tempdir().unwrap();
        let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().unwrap();
        let st = ScheduleState::daemon_at(home.path());
        let h = rt.handle().clone();
        st.set_spawner(move |f| {
            h.spawn(f);
        });
        st.set_session_sender(|t, _| Err(format!("The session “{}” is no longer running.", t.name)));
        let j = targeted(&st, 9);
        st.run_now(&j.id).unwrap();
        let run = wait_run(&st, &j.id);
        assert_eq!(run.status, RunStatus::Failed);
        assert_eq!(run.output, "The session “shell” is no longer running.");
        assert_eq!(run.exit_code, None);
    }
}

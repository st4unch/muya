// Created by Claude — Classification: INTERNAL
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
use tauri::{AppHandle, Emitter, Manager, State};

const MAX_RUNS_KEPT: usize = 100;
const MAX_OUTPUT: usize = 64 * 1024;
const MAX_PROMPT: usize = 20_000;
const MIN_INTERVAL_MIN: u32 = 5;
const MAX_PARALLEL: usize = 3;
const TICK_SECS: u64 = 15;
const CHANGED_EVENT: &str = "schedules-changed";

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
fn day_times(time: &str, extra: &[String]) -> Option<Vec<NaiveTime>> {
    let mut v = Vec::with_capacity(1 + extra.len());
    for s in std::iter::once(time).chain(extra.iter().map(String::as_str)) {
        let t = parse_hhmm(s)?;
        if !v.contains(&t) {
            v.push(t);
        }
    }
    (v.len() <= MAX_TIMES_PER_DAY).then_some(v)
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
    /// Load Claude in Chrome (`--chrome`). Interactive sessions get it from the
    /// user's setting; `claude -p` only with the flag. Missing in jobs saved by
    /// 4.1.0 → on, so they see the same tools as the user's own sessions.
    #[serde(default = "yes")]
    pub chrome: bool,
    pub created: i64,
    pub updated: i64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Store {
    version: u32,
    jobs: Vec<Job>,
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
    #[serde(default = "yes")]
    pub chrome: bool,
}

fn yes() -> bool {
    true
}

// ── Pure helpers (tested) ─────────────────────────────────────────────────────────

fn parse_hhmm(s: &str) -> Option<NaiveTime> {
    NaiveTime::parse_from_str(s.trim(), "%H:%M").ok()
}

/// A local wall-clock time on `date`. In a DST gap (the time doesn't exist) the next
/// hour is used; in an overlap the earlier instant, so the job fires once.
fn local_at(date: chrono::NaiveDate, t: NaiveTime) -> Option<DateTime<Local>> {
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

fn validate(input: &JobInput) -> Result<String, String> {
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
pub fn claude_args(prompt: &str, bypass: bool, chrome: bool) -> Vec<String> {
    let mut a: Vec<String> = vec!["-p".into(), "--output-format".into(), "json".into()];
    if chrome {
        a.push("--chrome".into());
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

fn truncate(mut s: String) -> String {
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
struct Paths {
    jobs: PathBuf,
    runs: PathBuf,
    lock: PathBuf,
    status: PathBuf,
    heartbeat: PathBuf,
    requests: PathBuf,
}

impl Paths {
    fn under(claude_dir: &Path) -> Self {
        Paths {
            jobs: claude_dir.join("muya-schedules.json"),
            runs: claude_dir.join("muya-schedule-runs"),
            lock: claude_dir.join("muya-schedules.lock"),
            status: claude_dir.join("muya-schedules.status.json"),
            heartbeat: claude_dir.join("muya-scheduler.heartbeat.json"),
            requests: claude_dir.join("muya-schedule-requests"),
        }
    }
    fn runs_file(&self, id: &str) -> PathBuf {
        self.runs.join(format!("{id}.jsonl"))
    }
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
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

fn private_file(path: &Path) -> Result<fs::File, String> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| e.to_string())
}

fn load_jobs(p: &Paths) -> Vec<Job> {
    fs::read(&p.jobs)
        .ok()
        .and_then(|b| serde_json::from_slice::<Store>(&b).ok())
        .map(|s| s.jobs)
        .unwrap_or_default()
}

fn save_jobs(p: &Paths, jobs: &[Job]) -> Result<(), String> {
    let store = Store {
        version: 1,
        jobs: jobs.to_vec(),
    };
    atomic_write(
        &p.jobs,
        &serde_json::to_vec_pretty(&store).map_err(|e| e.to_string())?,
    )
}

fn ensure_runs_dir(p: &Paths) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    fs::create_dir_all(&p.runs).map_err(|e| e.to_string())?;
    fs::set_permissions(&p.runs, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())
}

/// Runs of one job, oldest first.
fn read_runs(p: &Paths, id: &str) -> Vec<Run> {
    fs::read_to_string(p.runs_file(id))
        .map(|s| {
            s.lines()
                .filter_map(|l| serde_json::from_str(l).ok())
                .collect()
        })
        .unwrap_or_default()
}

fn append_run(p: &Paths, run: &Run) -> Result<(), String> {
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
fn login_env() -> &'static HashMap<String, String> {
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

fn capture_env(shell: &str, flags: &[&str]) -> Option<HashMap<String, String>> {
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

struct Spawned {
    exit_code: Option<i32>,
    stdout: String,
    stderr: String,
    timed_out: bool,
}

/// Read a pipe to the end, keeping at most `cap` bytes (it keeps draining, so the
/// child never blocks on a full pipe).
async fn drain<R: tokio::io::AsyncRead + Unpin>(mut r: R, cap: usize) -> String {
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

async fn spawn_run(
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

fn kill_group(pgid: i32, sig: i32) {
    if pgid > 1 {
        // SAFETY: plain kill(2) on our own child's process group.
        unsafe {
            libc::kill(-pgid, sig);
        }
    }
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
}

/// A service heartbeat older than this means the service is gone.
const HEARTBEAT_FRESH_MS: i64 = 45_000;
/// A status file older than this is ignored (its writer stopped).
const STATUS_FRESH_MS: i64 = 60_000;

/// What the active process is doing, for the others to show.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Status {
    pid: u32,
    /// Which ScheduleState wrote it (a pid alone can't tell two in one process apart).
    #[serde(default)]
    token: String,
    ts: i64,
    running: Vec<String>,
    queued: Vec<String>,
    due: HashMap<String, i64>,
}

/// Written by the background service on every tick, active or not.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Heartbeat {
    pub pid: u32,
    pub version: String,
    pub ts: i64,
}

#[derive(Serialize, Deserialize)]
struct Request {
    id: String,
}

struct Inner {
    paths: Paths,
    role: Role,
    /// Tells this state's status file from another's.
    token: String,
    jobs: Vec<Job>,
    /// The jobs file's mtime as last read or written here.
    jobs_seen: Option<std::time::SystemTime>,
    due: HashMap<String, i64>,
    running: HashSet<String>,
    queued: HashSet<String>,
    /// This process holds the lock and fires timers.
    active: bool,
    lock: Option<fs::File>,
}

type Sink = Box<dyn Fn() + Send + Sync>;

#[derive(Clone)]
pub struct ScheduleState {
    inner: Arc<Mutex<Inner>>,
    slots: Arc<tokio::sync::Semaphore>,
    /// Told whenever something the page shows changed (the window emits an event).
    sink: Arc<OnceLock<Sink>>,
}

fn claude_dir() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join(".claude")
}

impl Default for ScheduleState {
    fn default() -> Self {
        Self::at(&claude_dir())
    }
}

fn mtime(path: &Path) -> Option<std::time::SystemTime> {
    fs::metadata(path).and_then(|m| m.modified()).ok()
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
}

fn write_json<T: Serialize>(path: &Path, v: &T) {
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

fn heartbeat_at(p: &Paths, now: i64) -> Option<Heartbeat> {
    read_json::<Heartbeat>(&p.heartbeat).filter(|h| now - h.ts < HEARTBEAT_FRESH_MS)
}

/// Forget the service's heartbeat (it was just turned off), so the window takes the
/// timers back on its next tick instead of after HEARTBEAT_FRESH_MS.
pub fn clear_service_heartbeat() {
    let _ = fs::remove_file(Paths::under(&claude_dir()).heartbeat);
}

fn other_status(p: &Paths, token: &str, now: i64) -> Option<Status> {
    read_json::<Status>(&p.status).filter(|s| s.token != token && now - s.ts < STATUS_FRESH_MS)
}

/// Ids with a "Run now" request waiting for the active process.
fn pending_requests(p: &Paths) -> HashSet<String> {
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
fn take_requests(p: &Paths) -> Vec<String> {
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

fn try_lock_file(path: &Path) -> Option<fs::File> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).ok()?;
    }
    fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path)
        .ok()
        .filter(|f| f.try_lock().is_ok())
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
        let yield_to_service = self.role == Role::App && heartbeat_at(&self.paths, now).is_some();
        if self.active && yield_to_service {
            self.lock = None;
            self.active = false;
            log::info!("schedules: the background service runs the timers now");
            return true;
        }
        if !self.active && !yield_to_service {
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
                return true;
            }
        }
        false
    }

    fn write_status(&self) {
        if !self.active {
            return;
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
    fn at(claude_dir: &Path) -> Self {
        Self::at_role(claude_dir, Role::App)
    }

    /// The state the background service runs with.
    pub fn service() -> Self {
        Self::at_role(&claude_dir(), Role::Service)
    }

    fn at_role(claude_dir: &Path, role: Role) -> Self {
        let paths = Paths::under(claude_dir);
        let mut inner = Inner {
            jobs: Vec::new(),
            jobs_seen: None,
            due: HashMap::new(),
            running: HashSet::new(),
            queued: HashSet::new(),
            active: false,
            lock: None,
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
        }
    }

    pub fn set_sink(&self, f: impl Fn() + Send + Sync + 'static) {
        let _ = self.sink.set(Box::new(f));
    }

    /// Something the page shows changed: refresh the status file, tell the sink.
    fn changed(&self) {
        if let Ok(g) = self.inner.lock() {
            g.write_status();
        }
        if let Some(f) = self.sink.get() {
            f();
        }
    }

    /// Run `id` now: here when this process fires the timers, else through a
    /// request file the active process picks up on its next tick.
    fn run_now(&self, id: &str) -> Result<(), String> {
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
    fn launch(&self, id: &str, trigger: &str) -> Result<(), String> {
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
        tauri::async_runtime::spawn(async move {
            let _permit = state.slots.clone().acquire_owned().await;
            if let Ok(mut g) = state.inner.lock() {
                g.queued.remove(&job.id);
                g.running.insert(job.id.clone());
            }
            state.changed();
            let started = now_ms();
            let env = tauri::async_runtime::spawn_blocking(login_env)
                .await
                .map(|e| e.clone())
                .unwrap_or_default();
            let bin = crate::agents::claude_bin().to_string();
            let args = claude_args(&job.prompt, job.bypass, job.chrome);
            let timeout = std::time::Duration::from_secs(u64::from(job.timeout_min) * 60);
            let (status, exit_code, cost, output) =
                match spawn_run(&bin, &args, &job.folder, &env, timeout).await {
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
    fn tick(&self, now: DateTime<Local>) -> (Vec<(String, &'static str)>, bool) {
        let Ok(mut g) = self.inner.lock() else {
            return (Vec::new(), false);
        };
        let now_ms = now.timestamp_millis();
        if g.role == Role::Service {
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
                fire.push((id, "schedule"));
            }
        }
        g.write_status();
        (fire, flipped || reloaded)
    }

    fn idle(&self) -> bool {
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
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(TICK_SECS));
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

/// The window's timer. Started once from setup.
pub fn start(app: &AppHandle) {
    let state = app.state::<ScheduleState>().inner().clone();
    let h = app.clone();
    state.set_sink(move || {
        let _ = h.emit(CHANGED_EVENT, ());
    });
    tauri::async_runtime::spawn(run_timer(state));
}

fn now_ms() -> i64 {
    Local::now().timestamp_millis()
}

fn view(inner: &Inner) -> Vec<JobView> {
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
    jobs: Vec<JobView>,
    /// False when another process holds the schedule lock (its timer runs the jobs).
    active: bool,
    /// Who runs the timers: "here", "service" (the background service) or "other"
    /// (another Muya window). "none" briefly while the lock changes hands.
    runner: &'static str,
}

fn runner(inner: &Inner) -> &'static str {
    let now = now_ms();
    if inner.active {
        "here"
    } else if heartbeat_at(&inner.paths, now).is_some() {
        "service"
    } else if other_status(&inner.paths, &inner.token, now).is_some() {
        "other"
    } else {
        "none"
    }
}

#[tauri::command]
pub async fn schedules_list(state: State<'_, ScheduleState>) -> Result<ListResult, String> {
    let inner = state.inner.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut g = inner.lock().map_err(|_| "busy".to_string())?;
        g.refresh();
        Ok(ListResult {
            jobs: view(&g),
            active: g.active,
            runner: runner(&g),
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

fn upsert(inner: &mut Inner, input: JobInput) -> Result<Job, String> {
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
            j.chrome = input.chrome;
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
                chrome: input.chrome,
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

fn rand_u16() -> u16 {
    use std::sync::atomic::{AtomicU16, Ordering};
    static SEQ: AtomicU16 = AtomicU16::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    (nanos as u16) ^ SEQ.fetch_add(1, Ordering::Relaxed).wrapping_mul(40503)
}

#[tauri::command]
pub async fn schedule_save(
    state: State<'_, ScheduleState>,
    job: JobInput,
) -> Result<Job, String> {
    let inner = state.inner.clone();
    let out = tauri::async_runtime::spawn_blocking(move || {
        let mut g = inner.lock().map_err(|_| "busy".to_string())?;
        upsert(&mut g, job)
    })
    .await
    .map_err(|e| e.to_string())?;
    state.changed();
    out
}

fn set_enabled(inner: &mut Inner, id: &str, enabled: bool) -> Result<(), String> {
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

#[tauri::command]
pub async fn schedule_set_enabled(
    state: State<'_, ScheduleState>,
    id: String,
    enabled: bool,
) -> Result<(), String> {
    let inner = state.inner.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut g = inner.lock().map_err(|_| "busy".to_string())?;
        set_enabled(&mut g, &id, enabled)
    })
    .await
    .map_err(|e| e.to_string())??;
    state.changed();
    Ok(())
}

fn delete(inner: &mut Inner, id: &str) -> Result<(), String> {
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

#[tauri::command]
pub async fn schedule_delete(
    state: State<'_, ScheduleState>,
    id: String,
) -> Result<(), String> {
    let inner = state.inner.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut g = inner.lock().map_err(|_| "busy".to_string())?;
        delete(&mut g, &id)
    })
    .await
    .map_err(|e| e.to_string())??;
    state.changed();
    Ok(())
}

#[tauri::command]
pub fn schedule_run_now(state: State<'_, ScheduleState>, id: String) -> Result<(), String> {
    state.run_now(&id)
}

/// Runs of one job, newest first.
#[tauri::command]
pub async fn schedule_runs(
    state: State<'_, ScheduleState>,
    id: String,
) -> Result<Vec<Run>, String> {
    let inner = state.inner.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let p = inner.lock().map_err(|_| "busy".to_string())?.paths.clone();
        let mut runs = read_runs(&p, &id);
        runs.reverse();
        Ok(runs)
    })
    .await
    .map_err(|e| e.to_string())?
}

// ── Agent API (muya-mcp tools via broker.rs) ──────────────────────────────────────
//
// The same operations the page offers, for a Claude session: list, create, update
// (only the fields given), enable/disable, delete, run now, history. A schedule is
// addressed by its id or its exact name (case-insensitive).

/// Output of each run in an agent's history listing is capped: a run keeps up to
/// 64 KB, and ten of those would flood the agent's context.
const AGENT_OUTPUT_CAP: usize = 8_000;

fn resolve(inner: &Inner, key: &str) -> Result<String, String> {
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
fn input_from(base: Option<&Job>, patch: &serde_json::Value) -> Result<JobInput, String> {
    let mut v = match base {
        Some(j) => serde_json::json!({
            "id": j.id, "name": j.name, "prompt": j.prompt, "folder": j.folder, "schedule": j.schedule,
            "enabled": j.enabled, "timeoutMin": j.timeout_min, "bypass": j.bypass, "chrome": j.chrome,
        }),
        None => serde_json::json!({ "enabled": true, "timeoutMin": 30, "bypass": true, "chrome": true }),
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
    serde_json::from_value(v).map_err(|e| format!("Bad schedule fields: {e}"))
}

fn agent_run(r: &Run) -> serde_json::Value {
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

/// One agent operation. `key` names the schedule (id or name), `fields` carries the
/// create/update fields, `enabled` the toggle and `limit` the history length.
pub fn agent_op(
    app: &AppHandle,
    op: &str,
    key: Option<&str>,
    fields: Option<&serde_json::Value>,
    enabled: Option<bool>,
    limit: Option<usize>,
) -> Result<serde_json::Value, String> {
    let state = app.state::<ScheduleState>().inner().clone();
    let need_key = || {
        key.filter(|k| !k.trim().is_empty())
            .ok_or_else(|| "Missing 'schedule' (its id or name).".to_string())
    };
    let changed = |_: &AppHandle| state.changed();
    match op {
        "schedules_list" => {
            let mut g = state.inner.lock().map_err(|_| "busy")?;
            g.refresh();
            Ok(serde_json::json!({ "jobs": view(&g), "timersActive": g.active, "runner": runner(&g) }))
        }
        "schedule_create" => {
            let input = input_from(None, fields.ok_or("Missing schedule fields.")?)?;
            let mut g = state.inner.lock().map_err(|_| "busy")?;
            let job = upsert(&mut g, input)?;
            drop(g);
            changed(app);
            Ok(serde_json::to_value(job).map_err(|e| e.to_string())?)
        }
        "schedule_update" => {
            let mut g = state.inner.lock().map_err(|_| "busy")?;
            let id = resolve(&g, need_key()?)?;
            let base = g.jobs.iter().find(|j| j.id == id).cloned();
            let input = input_from(base.as_ref(), fields.ok_or("Nothing to update.")?)?;
            let job = upsert(&mut g, input)?;
            drop(g);
            changed(app);
            Ok(serde_json::to_value(job).map_err(|e| e.to_string())?)
        }
        "schedule_set_enabled" => {
            let on = enabled.ok_or("Missing 'enabled' (true or false).")?;
            let mut g = state.inner.lock().map_err(|_| "busy")?;
            let id = resolve(&g, need_key()?)?;
            set_enabled(&mut g, &id, on)?;
            drop(g);
            changed(app);
            Ok(serde_json::json!({ "id": id, "enabled": on }))
        }
        "schedule_delete" => {
            let mut g = state.inner.lock().map_err(|_| "busy")?;
            let id = resolve(&g, need_key()?)?;
            delete(&mut g, &id)?;
            drop(g);
            changed(app);
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

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    #[test]
    fn agent_fields_merge_onto_the_job_and_names_resolve() {
        let home = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let st = ScheduleState::at(home.path());
        let mut g = st.inner.lock().unwrap();
        let folder = work.path().to_str().unwrap();
        let fields = serde_json::json!({ "name": "Audit", "prompt": "audit", "folder": folder, "schedule": { "kind": "interval", "minutes": 30 } });
        let j = upsert(&mut g, input_from(None, &fields).unwrap()).unwrap();
        assert!(
            j.enabled && j.bypass && j.timeout_min == 30,
            "page defaults for a new job"
        );
        assert_eq!(
            resolve(&g, "audit").unwrap(),
            j.id,
            "names match case-insensitively"
        );
        assert_eq!(resolve(&g, &j.id).unwrap(), j.id);
        assert!(resolve(&g, "nope").is_err());

        let patched = input_from(
            Some(&j),
            &serde_json::json!({ "timeoutMin": 5, "bypass": false }),
        )
        .unwrap();
        assert_eq!(
            (patched.name.as_str(), patched.timeout_min, patched.bypass),
            ("Audit", 5, false)
        );
        assert_eq!(
            patched.schedule,
            Schedule::Interval { minutes: 30 },
            "fields not given are kept"
        );
        assert!(input_from(None, &serde_json::json!({ "name": "x" }))
            .unwrap_err()
            .contains("prompt"));

        upsert(&mut g, input_from(None, &fields).unwrap()).unwrap();
        assert!(
            resolve(&g, "Audit").unwrap_err().contains("use the id"),
            "duplicate names must be addressed by id"
        );

        let long = Run {
            job_id: j.id.clone(),
            started: 1,
            ended: 2,
            status: RunStatus::Success,
            exit_code: Some(0),
            cost_usd: None,
            trigger: "manual".into(),
            output: "é".repeat(AGENT_OUTPUT_CAP),
        };
        assert!(agent_run(&long)["output"]
            .as_str()
            .unwrap()
            .ends_with("Schedules page)"));
    }

    fn at(y: i32, m: u32, d: u32, h: u32, min: u32) -> DateTime<Local> {
        Local
            .from_local_datetime(
                &NaiveDate::from_ymd_opt(y, m, d)
                    .unwrap()
                    .and_hms_opt(h, min, 0)
                    .unwrap(),
            )
            .earliest()
            .unwrap()
    }

    #[test]
    fn interval_adds_minutes_and_rejects_short_ones() {
        let t = at(2026, 1, 5, 10, 0);
        assert_eq!(
            next_after(&Schedule::Interval { minutes: 30 }, t),
            Some(at(2026, 1, 5, 10, 30))
        );
        assert_eq!(next_after(&Schedule::Interval { minutes: 4 }, t), None);
    }

    #[test]
    fn daily_is_today_if_still_ahead_else_tomorrow() {
        let s = Schedule::Daily {
            time: "09:30".into(),
                extra_times: vec![],
        };
        assert_eq!(
            next_after(&s, at(2026, 1, 5, 8, 0)),
            Some(at(2026, 1, 5, 9, 30))
        );
        assert_eq!(
            next_after(&s, at(2026, 1, 5, 9, 30)),
            Some(at(2026, 1, 6, 9, 30))
        );
        assert_eq!(
            next_after(&s, at(2026, 12, 31, 23, 0)),
            Some(at(2027, 1, 1, 9, 30))
        );
        assert_eq!(
            next_after(
                &Schedule::Daily {
                    time: "25:00".into(),
                extra_times: vec![],
                },
                at(2026, 1, 5, 8, 0)
            ),
            None
        );
    }

    #[test]
    fn several_times_a_day_pick_the_earliest_ahead() {
        let s = Schedule::Daily {
            time: "09:00".into(),
            extra_times: vec!["19:00".into(), "13:30".into(), "09:00".into()],
        };
        assert_eq!(next_after(&s, at(2026, 1, 5, 8, 0)), Some(at(2026, 1, 5, 9, 0)));
        assert_eq!(next_after(&s, at(2026, 1, 5, 9, 0)), Some(at(2026, 1, 5, 13, 30)));
        assert_eq!(next_after(&s, at(2026, 1, 5, 14, 0)), Some(at(2026, 1, 5, 19, 0)));
        assert_eq!(next_after(&s, at(2026, 1, 5, 19, 0)), Some(at(2026, 1, 6, 9, 0)));
        // weekly: Mon + Wed, 08:00 and 20:00 (2026-01-05 is a Monday)
        let w = Schedule::Weekly {
            days: vec![0, 2],
            time: "20:00".into(),
            extra_times: vec!["08:00".into()],
        };
        assert_eq!(next_after(&w, at(2026, 1, 5, 9, 0)), Some(at(2026, 1, 5, 20, 0)));
        assert_eq!(next_after(&w, at(2026, 1, 5, 21, 0)), Some(at(2026, 1, 7, 8, 0)));
        // a bad extra time or too many times → invalid
        let bad = Schedule::Daily { time: "09:00".into(), extra_times: vec!["7pm".into()] };
        assert_eq!(next_after(&bad, at(2026, 1, 5, 8, 0)), None);
        let many = Schedule::Daily {
            time: "01:00".into(),
            extra_times: (2..=7).map(|h| format!("{h:02}:00")).collect(),
        };
        assert_eq!(next_after(&many, at(2026, 1, 5, 0, 0)), None);
    }

    #[test]
    fn validate_explains_bad_or_too_many_times() {
        let input = |extra: serde_json::Value| {
            input_from(None, &serde_json::json!({ "name": "a", "prompt": "b", "folder": "/tmp",
                "schedule": { "kind": "daily", "time": "09:00", "extraTimes": extra } }))
            .unwrap()
        };
        assert!(validate(&input(serde_json::json!(["19:00"]))).is_ok());
        assert_eq!(validate(&input(serde_json::json!(["7pm"]))).unwrap_err(), "Use times like 09:30.");
        let six: Vec<String> = (10..16).map(|h| format!("{h}:00")).collect();
        assert_eq!(validate(&input(serde_json::json!(six))).unwrap_err(), "At most 6 times a day.");
    }

    #[test]
    fn extra_times_are_optional_and_omitted_when_empty() {
        let old: Schedule = serde_json::from_str(r#"{"kind":"daily","time":"09:00"}"#).unwrap();
        assert_eq!(old, Schedule::Daily { time: "09:00".into(), extra_times: vec![] });
        assert_eq!(serde_json::to_string(&old).unwrap(), r#"{"kind":"daily","time":"09:00"}"#);
        let two: Schedule =
            serde_json::from_str(r#"{"kind":"weekly","days":[1],"time":"09:00","extraTimes":["19:00"]}"#).unwrap();
        assert!(serde_json::to_string(&two).unwrap().contains(r#""extraTimes":["19:00"]"#));
    }

    #[test]
    fn weekly_finds_the_next_chosen_weekday() {
        // 2026-01-05 is a Monday.
        let s = Schedule::Weekly {
            days: vec![2, 4],
            time: "18:00".into(),
                extra_times: vec![],
        }; // Wed, Fri
        assert_eq!(
            next_after(&s, at(2026, 1, 5, 12, 0)),
            Some(at(2026, 1, 7, 18, 0))
        );
        assert_eq!(
            next_after(&s, at(2026, 1, 9, 18, 0)),
            Some(at(2026, 1, 14, 18, 0))
        );
        let mon = Schedule::Weekly {
            days: vec![0],
            time: "08:00".into(),
                extra_times: vec![],
        };
        assert_eq!(
            next_after(&mon, at(2026, 1, 5, 9, 0)),
            Some(at(2026, 1, 12, 8, 0))
        );
        assert_eq!(
            next_after(
                &Schedule::Weekly {
                    days: vec![],
                    time: "08:00".into(),
                extra_times: vec![],
                },
                at(2026, 1, 5, 9, 0)
            ),
            None
        );
        assert_eq!(
            next_after(
                &Schedule::Weekly {
                    days: vec![7],
                    time: "08:00".into(),
                extra_times: vec![],
                },
                at(2026, 1, 5, 9, 0)
            ),
            None
        );
    }

    #[test]
    fn prompt_is_one_argv_element_after_double_dash() {
        let a = claude_args("-rf; rm -rf ~ && echo $(whoami)", true, false);
        assert_eq!(a[a.len() - 2], "--");
        assert_eq!(a.last().unwrap(), "-rf; rm -rf ~ && echo $(whoami)");
        assert!(a.contains(&"--dangerously-skip-permissions".to_string()));
        let safe = claude_args("x", false, false);
        assert!(safe
            .windows(2)
            .any(|w| w[0] == "--permission-mode" && w[1] == "acceptEdits"));
        assert!(!safe.contains(&"--dangerously-skip-permissions".to_string()));
        assert!(!safe.contains(&"--chrome".to_string()));
        let c = claude_args("x", true, true);
        assert!(c.contains(&"--chrome".to_string()));
        assert_eq!(c[c.len() - 2], "--", "the prompt still comes last");
    }

    #[test]
    fn chrome_defaults_on_for_new_and_older_jobs() {
        let old = r#"{"id":"s1","name":"n","prompt":"p","folder":"/tmp","schedule":{"kind":"daily","time":"09:00"},"enabled":true,"timeoutMin":30,"bypass":true,"created":1,"updated":1}"#;
        assert!(serde_json::from_str::<Job>(old).unwrap().chrome, "a 4.1.0 job gets the browser");
        let off = input_from(None, &serde_json::json!({ "name": "a", "prompt": "b", "folder": "/tmp", "schedule": { "kind": "daily", "time": "09:00" }, "chrome": false })).unwrap();
        assert!(!off.chrome);
        let new = input_from(None, &serde_json::json!({ "name": "a", "prompt": "b", "folder": "/tmp", "schedule": { "kind": "daily", "time": "09:00" } })).unwrap();
        assert!(new.chrome);
    }

    #[test]
    fn classify_reads_claude_json() {
        let ok = r#"{"type":"result","is_error":false,"result":"done","total_cost_usd":0.12}"#;
        let (st, cost, text) = classify(Some(0), ok, "");
        assert_eq!(
            (st, cost, text.as_str()),
            (RunStatus::Success, Some(0.12), "done")
        );
        let bad = r#"{"type":"result","is_error":true,"result":"limit"}"#;
        assert_eq!(classify(Some(0), bad, "").0, RunStatus::Failed);
        let (st, _, text) = classify(Some(1), "", "boom");
        assert_eq!(st, RunStatus::Failed);
        assert_eq!(text, "boom");
        assert_eq!(classify(Some(0), "not json", "").0, RunStatus::Failed);
        let big = "x".repeat(MAX_OUTPUT + 10);
        assert!(classify(Some(1), &big, "")
            .2
            .ends_with("(output truncated)"));
    }

    fn input(folder: &str) -> JobInput {
        JobInput {
            id: None,
            name: "Daily report".into(),
            prompt: "summarize".into(),
            folder: folder.into(),
            schedule: Schedule::Daily {
                time: "09:00".into(),
                extra_times: vec![],
            },
            enabled: true,
            timeout_min: 30,
            bypass: true,
            chrome: true,
        }
    }

    #[test]
    fn validate_rejects_bad_input() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().to_str().unwrap();
        assert!(validate(&input(d)).is_ok());
        assert!(validate(&input("relative/dir")).is_err());
        assert!(validate(&input("/definitely/not/here")).is_err());
        assert!(validate(&JobInput {
            prompt: "  ".into(),
            ..input(d)
        })
        .is_err());
        assert!(validate(&JobInput {
            name: "".into(),
            ..input(d)
        })
        .is_err());
        assert!(validate(&JobInput {
            timeout_min: 0,
            ..input(d)
        })
        .is_err());
        assert!(validate(&JobInput {
            schedule: Schedule::Interval { minutes: 1 },
            ..input(d)
        })
        .is_err());
    }

    #[test]
    fn jobs_persist_edit_toggle_and_delete_with_history() {
        let home = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let st = ScheduleState::at(home.path());
        let mut g = st.inner.lock().unwrap();
        assert!(g.active);
        let j = upsert(&mut g, input(work.path().to_str().unwrap())).unwrap();
        assert!(g.due.contains_key(&j.id));
        let edited = upsert(
            &mut g,
            JobInput {
                id: Some(j.id.clone()),
                name: "Renamed".into(),
                ..input(work.path().to_str().unwrap())
            },
        )
        .unwrap();
        assert_eq!(edited.created, j.created);
        set_enabled(&mut g, &j.id, false).unwrap();
        let paths = g.paths.clone();
        drop(g);

        // Reloaded from disk.
        let jobs = load_jobs(&paths);
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].name, "Renamed");
        assert!(!jobs[0].enabled);

        for i in 0..(MAX_RUNS_KEPT + 5) {
            let status = if i % 2 == 0 {
                RunStatus::Success
            } else {
                RunStatus::Failed
            };
            append_run(
                &paths,
                &Run {
                    job_id: j.id.clone(),
                    started: i as i64,
                    ended: i as i64 + 1,
                    status,
                    exit_code: Some(0),
                    cost_usd: None,
                    trigger: "manual".into(),
                    output: "o".into(),
                },
            )
            .unwrap();
        }
        let runs = read_runs(&paths, &j.id);
        assert_eq!(runs.len(), MAX_RUNS_KEPT);
        assert_eq!(runs[0].started, 5, "oldest runs are dropped");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(paths.runs_file(&j.id))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(&paths.runs).unwrap().permissions().mode() & 0o777,
            0o700
        );

        let st2 = ScheduleState::at(home.path());
        assert!(
            !st2.inner.lock().unwrap().active,
            "a second instance does not fire timers"
        );
        let v = view(&st.inner.lock().unwrap());
        assert_eq!((v[0].runs, v[0].ok, v[0].failed), (100, 50, 50));
        assert_eq!(v[0].next_run, None, "disabled job has no next run");

        delete(&mut st.inner.lock().unwrap(), &j.id).unwrap();
        assert!(load_jobs(&paths).is_empty());
        assert!(!paths.runs_file(&j.id).exists());
    }

    fn job_in(st: &ScheduleState, folder: &Path) -> Job {
        upsert(&mut st.inner.lock().unwrap(), input(folder.to_str().unwrap())).unwrap()
    }

    #[test]
    fn a_waiting_process_takes_the_lock_once_it_is_free() {
        let home = tempfile::tempdir().unwrap();
        let first = ScheduleState::at(home.path());
        let second = ScheduleState::at(home.path());
        assert!(first.inner.lock().unwrap().active);
        second.tick(Local::now());
        assert!(!second.inner.lock().unwrap().active, "lock still held");
        drop(first);
        let (_, refresh) = second.tick(Local::now());
        assert!(second.inner.lock().unwrap().active && refresh, "taken on the next tick");
    }

    #[test]
    fn the_window_hands_the_timers_to_the_service_and_takes_them_back() {
        let home = tempfile::tempdir().unwrap();
        let app = ScheduleState::at(home.path());
        assert!(app.inner.lock().unwrap().active);
        let service = ScheduleState::at_role(home.path(), Role::Service);
        assert!(!service.inner.lock().unwrap().active, "the window got there first");

        service.tick(Local::now()); // writes the heartbeat
        let paths = Paths::under(home.path());
        assert!(heartbeat_at(&paths, now_ms()).is_some());
        app.tick(Local::now());
        assert!(!app.inner.lock().unwrap().active, "the window yields to a live service");
        service.tick(Local::now());
        assert!(service.inner.lock().unwrap().active, "the service takes the free lock");

        let _ = fs::remove_file(&paths.heartbeat);
        app.tick(Local::now());
        assert!(!app.inner.lock().unwrap().active, "the service still holds the lock");
        drop(service);
        app.tick(Local::now());
        assert!(app.inner.lock().unwrap().active, "service gone: the window runs the timers again");

        // A stale heartbeat does not count.
        write_json(
            &paths.heartbeat,
            &Heartbeat { pid: 1, version: "x".into(), ts: now_ms() - HEARTBEAT_FRESH_MS - 1 },
        );
        app.tick(Local::now());
        assert!(app.inner.lock().unwrap().active);
    }

    #[test]
    fn the_active_process_picks_up_jobs_written_by_another() {
        let home = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let active = ScheduleState::at(home.path());
        let passive = ScheduleState::at(home.path());
        let j = job_in(&passive, work.path());
        let (_, refresh) = active.tick(Local::now());
        assert!(refresh);
        {
            let g = active.inner.lock().unwrap();
            assert!(g.jobs.iter().any(|x| x.id == j.id));
            assert!(g.due.contains_key(&j.id), "a new job gets its next run");
        }
        // And an edit made on the active side is not lost by the passive one's next write.
        set_enabled(&mut active.inner.lock().unwrap(), &j.id, false).unwrap();
        let other = job_in(&passive, work.path());
        let jobs = load_jobs(&Paths::under(home.path()));
        assert_eq!(jobs.len(), 2);
        assert!(!jobs.iter().find(|x| x.id == j.id).unwrap().enabled);
        assert!(jobs.iter().any(|x| x.id == other.id));
    }

    #[test]
    fn run_now_from_a_passive_process_goes_through_a_request_file() {
        let home = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let active = ScheduleState::at(home.path());
        let passive = ScheduleState::at(home.path());
        let j = job_in(&passive, work.path());
        active.tick(Local::now());

        passive.run_now(&j.id).unwrap();
        let paths = Paths::under(home.path());
        assert!(pending_requests(&paths).contains(&j.id));
        assert!(view(&passive.inner.lock().unwrap())[0].queued, "shown as waiting");
        assert!(passive.run_now(&j.id).unwrap_err().contains("already"), "no double request");
        assert!(passive.run_now("nope").is_err());

        let (fire, _) = active.tick(Local::now());
        assert_eq!(fire, vec![(j.id.clone(), "manual")]);
        assert!(pending_requests(&paths).is_empty(), "the request is consumed");

        // The passive side shows the active one's state from its status file.
        active.inner.lock().unwrap().running.insert(j.id.clone());
        active.changed();
        let v = view(&passive.inner.lock().unwrap());
        assert!(v[0].running);
        assert_eq!(v[0].next_run, active.inner.lock().unwrap().due.get(&j.id).copied());
        assert!(delete(&mut passive.inner.lock().unwrap(), &j.id).is_err(), "busy elsewhere");
        assert_eq!(runner(&passive.inner.lock().unwrap()), "other");
    }

    #[tokio::test]
    async fn spawn_passes_argv_and_cwd_and_times_out_the_group() {
        let work = tempfile::tempdir().unwrap();
        let canon = fs::canonicalize(work.path()).unwrap();
        let env: HashMap<String, String> =
            [("PATH".to_string(), "/usr/bin:/bin".to_string())].into();
        // A stand-in for claude: prints its cwd and last argv element.
        let script = work.path().join("fake-claude");
        fs::write(
            &script,
            "#!/bin/sh\npwd\nfor a; do last=$a; done\nprintf '%s' \"$last\"\n",
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let args = claude_args("hi; touch PWNED", true, false);
        let s = spawn_run(
            script.to_str().unwrap(),
            &args,
            canon.to_str().unwrap(),
            &env,
            std::time::Duration::from_secs(10),
        )
        .await
        .unwrap();
        assert_eq!(s.exit_code, Some(0));
        assert!(s.stdout.starts_with(canon.to_str().unwrap()));
        assert!(s.stdout.ends_with("hi; touch PWNED"));
        assert!(
            !canon.join("PWNED").exists(),
            "the prompt never reaches a shell"
        );

        // Timeout stops the child AND what it started.
        let marker = canon.join("grandchild-alive");
        let slow = work.path().join("slow");
        fs::write(
            &slow,
            format!(
                "#!/bin/sh\n(sleep 3; touch '{}') &\nsleep 30\n",
                marker.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&slow, fs::Permissions::from_mode(0o755)).unwrap();
        let t0 = std::time::Instant::now();
        let s = spawn_run(
            slow.to_str().unwrap(),
            &[],
            canon.to_str().unwrap(),
            &env,
            std::time::Duration::from_secs(1),
        )
        .await
        .unwrap();
        assert!(s.timed_out);
        assert!(t0.elapsed() < std::time::Duration::from_secs(8));
        tokio::time::sleep(std::time::Duration::from_secs(4)).await;
        assert!(
            !marker.exists(),
            "the background grandchild was stopped with the group"
        );
    }
}

#[cfg(test)]
mod live {
    use super::*;

    /// Real headless run with the operator's own environment. Costs a few cents:
    /// `cargo test --lib schedules::live -- --ignored --nocapture`
    #[tokio::test]
    #[ignore = "runs the real claude CLI"]
    async fn real_claude_headless_run_sees_mcp_tools() {
        let work = tempfile::tempdir().unwrap();
        let env = tauri::async_runtime::spawn_blocking(login_env)
            .await
            .unwrap()
            .clone();
        let bin = crate::agents::claude_bin().to_string();
        let args = claude_args("List the names of the MCP servers whose tools you can call, comma separated, nothing else.", true, true);
        let s = spawn_run(
            &bin,
            &args,
            work.path().to_str().unwrap(),
            &env,
            std::time::Duration::from_secs(300),
        )
        .await
        .unwrap();
        let (st, cost, text) = classify(s.exit_code, &s.stdout, &s.stderr);
        println!("bin={bin}\nstatus={st:?} cost={cost:?}\noutput={text}");
        assert_eq!(st, RunStatus::Success);
    }
}

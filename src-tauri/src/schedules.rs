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
    /// Every day at local "HH:MM".
    Daily { time: String },
    /// On the given weekdays (0 = Monday … 6 = Sunday) at local "HH:MM".
    Weekly { days: Vec<u8>, time: String },
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
        Schedule::Daily { time } => {
            let t = parse_hhmm(time)?;
            (0..=2).find_map(|d| {
                local_at(after.date_naive() + ChronoDuration::days(d), t).filter(|x| *x > after)
            })
        }
        Schedule::Weekly { days, time } => {
            let t = parse_hhmm(time)?;
            if days.is_empty() || days.iter().any(|d| *d > 6) {
                return None;
            }
            (0..=8).find_map(|d| {
                let date = after.date_naive() + ChronoDuration::days(d);
                let wd = date.weekday().num_days_from_monday() as u8;
                if !days.contains(&wd) {
                    return None;
                }
                local_at(date, t).filter(|x| *x > after)
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
            _ => "Use a time like 09:30.".into(),
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
pub fn claude_args(prompt: &str, bypass: bool) -> Vec<String> {
    let mut a: Vec<String> = vec!["-p".into(), "--output-format".into(), "json".into()];
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
}

impl Paths {
    fn under(claude_dir: &Path) -> Self {
        Paths {
            jobs: claude_dir.join("muya-schedules.json"),
            runs: claude_dir.join("muya-schedule-runs"),
            lock: claude_dir.join("muya-schedules.lock"),
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

struct Inner {
    paths: Paths,
    jobs: Vec<Job>,
    due: HashMap<String, i64>,
    running: HashSet<String>,
    queued: HashSet<String>,
    /// This instance holds the lock and fires timers.
    active: bool,
}

pub struct ScheduleState {
    inner: Arc<Mutex<Inner>>,
    slots: Arc<tokio::sync::Semaphore>,
    _lock: Mutex<Option<fs::File>>,
}

impl Default for ScheduleState {
    fn default() -> Self {
        let claude_dir = dirs_next::home_dir()
            .unwrap_or_else(std::env::temp_dir)
            .join(".claude");
        Self::at(&claude_dir)
    }
}

impl ScheduleState {
    fn at(claude_dir: &Path) -> Self {
        let paths = Paths::under(claude_dir);
        let jobs = load_jobs(&paths);
        let lock = fs::create_dir_all(claude_dir)
            .ok()
            .and_then(|_| {
                fs::OpenOptions::new()
                    .create(true)
                    .truncate(false)
                    .write(true)
                    .open(&paths.lock)
                    .ok()
            })
            .filter(|f| f.try_lock().is_ok());
        let now = Local::now();
        let due = jobs
            .iter()
            .filter_map(|j| {
                next_after(&j.schedule, now).map(|t| (j.id.clone(), t.timestamp_millis()))
            })
            .collect();
        ScheduleState {
            inner: Arc::new(Mutex::new(Inner {
                paths,
                jobs,
                due,
                running: HashSet::new(),
                queued: HashSet::new(),
                active: lock.is_some(),
            })),
            slots: Arc::new(tokio::sync::Semaphore::new(MAX_PARALLEL)),
            _lock: Mutex::new(lock),
        }
    }
}

fn now_ms() -> i64 {
    Local::now().timestamp_millis()
}

fn view(inner: &Inner) -> Vec<JobView> {
    inner
        .jobs
        .iter()
        .map(|j| {
            let runs = read_runs(&inner.paths, &j.id);
            let ok = runs
                .iter()
                .filter(|r| r.status == RunStatus::Success)
                .count();
            JobView {
                job: j.clone(),
                next_run: if j.enabled && inner.active {
                    inner.due.get(&j.id).copied()
                } else {
                    None
                },
                running: inner.running.contains(&j.id),
                queued: inner.queued.contains(&j.id),
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

/// Start one run of `id` unless it is already running or waiting. Returns at once;
/// the run waits for a free slot.
fn launch(
    app: &AppHandle,
    inner: &Arc<Mutex<Inner>>,
    slots: &Arc<tokio::sync::Semaphore>,
    id: &str,
    trigger: &str,
) -> Result<(), String> {
    let job = {
        let mut g = inner.lock().map_err(|_| "busy")?;
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
    let _ = app.emit(CHANGED_EVENT, ());
    let (app, inner, slots, trigger) = (
        app.clone(),
        inner.clone(),
        slots.clone(),
        trigger.to_string(),
    );
    tauri::async_runtime::spawn(async move {
        let _permit = slots.acquire_owned().await;
        if let Ok(mut g) = inner.lock() {
            g.queued.remove(&job.id);
            g.running.insert(job.id.clone());
        }
        let _ = app.emit(CHANGED_EVENT, ());
        let started = now_ms();
        let env = tauri::async_runtime::spawn_blocking(login_env)
            .await
            .map(|e| e.clone())
            .unwrap_or_default();
        let bin = crate::agents::claude_bin().to_string();
        let args = claude_args(&job.prompt, job.bypass);
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
        let paths = inner.lock().map(|g| g.paths.clone()).ok();
        if let Some(p) = paths {
            if let Err(e) = append_run(&p, &run) {
                log::warn!("schedules: could not save run of {}: {e}", job.id);
            }
        }
        if let Ok(mut g) = inner.lock() {
            g.running.remove(&job.id);
        }
        let _ = app.emit(CHANGED_EVENT, ());
    });
    Ok(())
}

/// The timer. Started once from setup.
pub fn start(app: &AppHandle) {
    let state = app.state::<ScheduleState>();
    let (inner, slots) = (state.inner.clone(), state.slots.clone());
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_secs(TICK_SECS));
        loop {
            tick.tick().await;
            let now = Local::now();
            let fire: Vec<String> = {
                let Ok(mut g) = inner.lock() else { continue };
                if !g.active {
                    continue;
                }
                let due_now: Vec<(String, Schedule)> = g
                    .jobs
                    .iter()
                    .filter(|j| {
                        j.enabled
                            && g.due
                                .get(&j.id)
                                .is_some_and(|d| *d <= now.timestamp_millis())
                    })
                    .map(|j| (j.id.clone(), j.schedule.clone()))
                    .collect();
                for (id, s) in &due_now {
                    // From now, not from the missed time: a Mac that slept through
                    // several slots runs once, not once per slot.
                    match next_after(s, now) {
                        Some(t) => g.due.insert(id.clone(), t.timestamp_millis()),
                        None => g.due.remove(id),
                    };
                }
                due_now.into_iter().map(|(id, _)| id).collect()
            };
            for id in fire {
                let _ = launch(&app, &inner, &slots, &id, "schedule");
            }
        }
    });
}

// ── Commands ──────────────────────────────────────────────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListResult {
    jobs: Vec<JobView>,
    /// False when another Muya holds the schedule lock (its timer runs the jobs).
    active: bool,
}

#[tauri::command]
pub async fn schedules_list(state: State<'_, ScheduleState>) -> Result<ListResult, String> {
    let inner = state.inner.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let g = inner.lock().map_err(|_| "busy".to_string())?;
        Ok(ListResult {
            jobs: view(&g),
            active: g.active,
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

fn upsert(inner: &mut Inner, input: JobInput) -> Result<Job, String> {
    let folder = validate(&input)?;
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
                created: now,
                updated: now,
            };
            inner.jobs.push(j.clone());
            j
        }
    };
    save_jobs(&inner.paths, &inner.jobs)?;
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
    app: AppHandle,
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
    let _ = app.emit(CHANGED_EVENT, ());
    out
}

fn set_enabled(inner: &mut Inner, id: &str, enabled: bool) -> Result<(), String> {
    let j = inner
        .jobs
        .iter_mut()
        .find(|j| j.id == id)
        .ok_or("Schedule not found.")?;
    j.enabled = enabled;
    j.updated = now_ms();
    let s = j.schedule.clone();
    save_jobs(&inner.paths, &inner.jobs)?;
    if let Some(t) = next_after(&s, Local::now()) {
        inner.due.insert(id.to_string(), t.timestamp_millis());
    }
    Ok(())
}

#[tauri::command]
pub async fn schedule_set_enabled(
    app: AppHandle,
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
    let _ = app.emit(CHANGED_EVENT, ());
    Ok(())
}

fn delete(inner: &mut Inner, id: &str) -> Result<(), String> {
    if inner.running.contains(id) || inner.queued.contains(id) {
        return Err("Wait for the running schedule to finish.".into());
    }
    let before = inner.jobs.len();
    inner.jobs.retain(|j| j.id != id);
    if inner.jobs.len() == before {
        return Err("Schedule not found.".into());
    }
    save_jobs(&inner.paths, &inner.jobs)?;
    inner.due.remove(id);
    let _ = fs::remove_file(inner.paths.runs_file(id));
    Ok(())
}

#[tauri::command]
pub async fn schedule_delete(
    app: AppHandle,
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
    let _ = app.emit(CHANGED_EVENT, ());
    Ok(())
}

#[tauri::command]
pub fn schedule_run_now(
    app: AppHandle,
    state: State<'_, ScheduleState>,
    id: String,
) -> Result<(), String> {
    launch(&app, &state.inner, &state.slots, &id, "manual")
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
            "enabled": j.enabled, "timeoutMin": j.timeout_min, "bypass": j.bypass,
        }),
        None => serde_json::json!({ "enabled": true, "timeoutMin": 30, "bypass": true }),
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
    let state = app.state::<ScheduleState>();
    let need_key = || {
        key.filter(|k| !k.trim().is_empty())
            .ok_or_else(|| "Missing 'schedule' (its id or name).".to_string())
    };
    let changed = |app: &AppHandle| {
        let _ = app.emit(CHANGED_EVENT, ());
    };
    match op {
        "schedules_list" => {
            let g = state.inner.lock().map_err(|_| "busy")?;
            Ok(serde_json::json!({ "jobs": view(&g), "timersActive": g.active }))
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
            let g = state.inner.lock().map_err(|_| "busy")?;
            let id = resolve(&g, need_key()?)?;
            drop(g);
            launch(app, &state.inner, &state.slots, &id, "manual")?;
            Ok(
                serde_json::json!({ "started": id, "note": "The run continues in the background; read its result with schedule_history." }),
            )
        }
        "schedule_history" => {
            let g = state.inner.lock().map_err(|_| "busy")?;
            let id = resolve(&g, need_key()?)?;
            let running = g.running.contains(&id) || g.queued.contains(&id);
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
                    time: "25:00".into()
                },
                at(2026, 1, 5, 8, 0)
            ),
            None
        );
    }

    #[test]
    fn weekly_finds_the_next_chosen_weekday() {
        // 2026-01-05 is a Monday.
        let s = Schedule::Weekly {
            days: vec![2, 4],
            time: "18:00".into(),
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
        };
        assert_eq!(
            next_after(&mon, at(2026, 1, 5, 9, 0)),
            Some(at(2026, 1, 12, 8, 0))
        );
        assert_eq!(
            next_after(
                &Schedule::Weekly {
                    days: vec![],
                    time: "08:00".into()
                },
                at(2026, 1, 5, 9, 0)
            ),
            None
        );
        assert_eq!(
            next_after(
                &Schedule::Weekly {
                    days: vec![7],
                    time: "08:00".into()
                },
                at(2026, 1, 5, 9, 0)
            ),
            None
        );
    }

    #[test]
    fn prompt_is_one_argv_element_after_double_dash() {
        let a = claude_args("-rf; rm -rf ~ && echo $(whoami)", true);
        assert_eq!(a[a.len() - 2], "--");
        assert_eq!(a.last().unwrap(), "-rf; rm -rf ~ && echo $(whoami)");
        assert!(a.contains(&"--dangerously-skip-permissions".to_string()));
        let safe = claude_args("x", false);
        assert!(safe
            .windows(2)
            .any(|w| w[0] == "--permission-mode" && w[1] == "acceptEdits"));
        assert!(!safe.contains(&"--dangerously-skip-permissions".to_string()));
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
            },
            enabled: true,
            timeout_min: 30,
            bypass: true,
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
        let args = claude_args("hi; touch PWNED", true);
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
        let args = claude_args("List the names of the MCP servers whose tools you can call, comma separated, nothing else.", true);
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

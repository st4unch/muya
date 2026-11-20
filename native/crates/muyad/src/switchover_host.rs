//! Muya's own updates and "Return to Muya Classic" (docs/prd-muya-v5-replace.md).
//!
//! All the trust logic (feed + minisign, codesign / Team ID / spctl, the pinned classic build, the swap with its
//! rollback) lives in the shared `muya-switchover` crate. This module only wires it to muyad: where the files are, which
//! app is replaced by which, and the events the app draws. Jobs run on their own thread and report through the
//! `muya://switchover` event; nothing here ever installs without a call from the app (the background poll only says
//! "an update is available").
//!
//! Three jobs, by the kind of app that asks:
//! - **update** (release app, `com.staunch.muya`): the signed `.app.tar.gz` from `latest.json` replaces the app in place;
//!   muyad exits and launchd starts the one inside the new bundle.
//! - **move** (legacy `.native` beta / bridge app): the same download lands as `Muya.app` in the same folder under the
//!   release id; the old app goes to the Trash after the new one proved itself and the old launchd jobs are booted out.
//! - **return** (release app): the build pinned at compile time (classic 4.1.22) replaces Muya in place.

use crate::Muyad;
use muya_switchover::manifest;
use muya_switchover::swap::{self, Plan, Platform, Step, SwapError, SwitchState};
use muya_switchover::sysplatform::SysPlatform;
use muya_switchover::v5::{self, Kind};
use muya_switchover::verify::VerifyError;
use muya_switchover::{feed, healthy_marker_path, launchd, state_path, TEAM_ID};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, Weak};
use std::time::Duration;

/// The Tauri updater public key from `src-tauri/tauri.conf.json` (plugins.updater.pubkey). It signs the `.app.tar.gz`
/// that `latest.json` points at, for classic's updater and for this one. A public key: safe to embed.
pub const UPDATER_PUBKEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IEVBN0U3REU0REI4NUFGRkEKUldUNnI0WGI1SDErNmpZQllSV09GWXY3QkZ1MEdvNHF6WE1nVElvNTU1TXBpK210c2lNQUNvYnAK";
const LATEST_URL: &str = "https://github.com/st4unch/muya/releases/latest/download/latest.json";
/// After a successful in-place update: how long the old daemon lingers so the app can draw "done" and the old app can
/// step aside (the Settings section quits 1.5 s after it).
const RESTART_AFTER_UPDATE: Duration = Duration::from_secs(3);
/// Handover: how long the detached script waits before it boots the old jobs out (the final event must reach the app).
const HANDOVER_DELAY_SECS: u32 = 2;

// Test-only overrides (cargo feature `e2e`, never in release builds): a local feed, its test key and the download
// prefix (muya-switchover reads MUYA_SWITCHOVER_E2E_URL_PREFIX itself, and the ids / pin / labels in its `v5` and
// `launchd` modules).
#[cfg(feature = "e2e")]
fn e2e_env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}
fn latest_url() -> String {
    #[cfg(feature = "e2e")]
    if let Some(u) = e2e_env("MUYA_SWITCHOVER_E2E_LATEST_URL") {
        return u;
    }
    LATEST_URL.to_string()
}
fn updater_pubkey() -> String {
    #[cfg(feature = "e2e")]
    if let Some(k) = e2e_env("MUYA_SWITCHOVER_E2E_PUBKEY") {
        return k;
    }
    UPDATER_PUBKEY.to_string()
}

/// What happens to this daemon once a job ended.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Post {
    /// In-place update: exit; launchd's KeepAlive starts the daemon inside the new bundle.
    RestartDaemon,
    /// The job replaced the bundle at another path or with another app: boot the old jobs out (detached), then exit.
    /// Without this launchd would keep (and re-start) a job whose binary is in the Trash, or no longer exists.
    HandOver,
    Nothing,
}

/// Pure decision. `moved` = the new app is a different bundle (the legacy move); `kind` is the event kind.
pub fn post_action(kind: &str, moved: bool, installed_and_healthy: bool) -> Post {
    if !installed_and_healthy {
        return Post::Nothing;
    }
    match (kind, moved) {
        ("update", false) => Post::RestartDaemon,
        ("update", true) | ("switch_back", _) => Post::HandOver,
        _ => Post::Nothing,
    }
}

const HEALTHY_TIMEOUT: Duration = Duration::from_secs(30);
const POLL_EVERY: Duration = Duration::from_secs(6 * 3600);
const POLL_FIRST: Duration = Duration::from_secs(20);

/// Progress / result of a running job: `{kind, phase, downloaded?, total?, message?, version?}`.
pub const EVENT: &str = "muya://switchover";
/// A newer release exists (the poll or a manual check found it): `{version}`.
pub const AVAILABLE_EVENT: &str = "muya://update-available";

/// One job at a time (a return and an update must never overlap).
static BUSY: AtomicBool = AtomicBool::new(false);
/// The newest release the poll saw, so an app that connects later can ask.
static PENDING: Mutex<Option<Value>> = Mutex::new(None);

// ---------- network ----------

pub trait Fetch: Send + Sync {
    fn get(&self, url: &str) -> Result<Vec<u8>, String>;
}

/// https-only curl, small bodies only (the feed).
pub struct CurlFetch;
impl Fetch for CurlFetch {
    fn get(&self, url: &str) -> Result<Vec<u8>, String> {
        if !manifest::url_allowed(url) {
            return Err(format!("refusing to fetch {url}"));
        }
        // `url_allowed` only lets a non-https URL through for the e2e build's local server.
        let proto: &[&str] = if url.starts_with("https://") {
            &["--proto", "=https", "--proto-redir", "=https"]
        } else {
            &[]
        };
        let out = std::process::Command::new("curl")
            .args(["-fsSL"])
            .args(proto)
            .args([
                "--connect-timeout",
                "15",
                "--max-time",
                "60",
                "--max-filesize",
                "2000000",
                url,
            ])
            .output()
            .map_err(|e| format!("curl: {e}"))?;
        if out.status.success() {
            Ok(out.stdout)
        } else {
            Err(format!(
                "network error: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ))
        }
    }
}

// ---------- the release feed ----------

#[derive(Debug, Clone, PartialEq)]
pub struct UpdateCheck {
    pub available: bool,
    pub release: feed::Release,
}

pub fn check_update(f: &dyn Fetch, installed: &str) -> Result<UpdateCheck, String> {
    let release = feed::parse_latest(&f.get(&latest_url())?)?;
    Ok(UpdateCheck {
        available: feed::is_available(installed, &release),
        release,
    })
}

// ---------- where things are ----------

fn home() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set".to_string())
}
/// Shared with classic: `switch.json` and the healthy marker live here.
fn support_dir(home: &Path) -> PathBuf {
    home.join("Library/Application Support/com.staunch.muya")
}
fn stage_dir(home: &Path, ver: &str) -> PathBuf {
    home.join("Library/Caches/com.staunch.muya/switchover")
        .join(ver)
}

/// `…/Foo.app` from a path inside it.
pub fn bundle_of(p: &Path) -> Option<PathBuf> {
    muya_switchover::target::bundle_of(p)
}

fn plist_string(bundle: &Path, key: &str) -> Option<String> {
    let out = std::process::Command::new("/usr/bin/plutil")
        .args(["-extract", key, "raw", "-o", "-"])
        .arg(bundle.join("Contents/Info.plist"))
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
}

/// The running Muya bundle. The app that asked (`appPath`, its own `Bundle.main.bundlePath`) is the truth: this
/// daemon may have been started from another copy (a renamed or replaced app, a stale LaunchAgent), so when the app
/// names its bundle and it is not a real one the call fails instead of quietly using the daemon's own bundle.
/// Only the poller, which has no asking app, uses the bundle around this binary.
fn current_bundle(app_path: Option<&str>) -> Result<PathBuf, String> {
    match app_path {
        Some(p) => {
            let b = bundle_of(Path::new(p))
                .filter(|b| b.join("Contents/Info.plist").is_file())
                .ok_or_else(|| format!("{p} is not a Muya app bundle"))?;
            Ok(std::fs::canonicalize(&b).unwrap_or(b))
        }
        None => std::env::current_exe()
            .ok()
            .and_then(|e| bundle_of(&e))
            .ok_or_else(|| "could not find the running Muya app".to_string()),
    }
}

/// The bundle an install may replace: symlinks resolved, not a translocated copy, same file name kept.
fn install_target(bundle: &Path) -> Result<PathBuf, String> {
    muya_switchover::target::resolve_bundle(bundle)
}

/// What kind of Muya is this bundle? Only the release app and the legacy `.native` app may update or return; a
/// development build must never swap itself away.
fn bundle_kind(bundle: &Path) -> Kind {
    plist_string(bundle, "CFBundleIdentifier")
        .map(|id| v5::kind_of(&id, &v5::ids()))
        .unwrap_or(Kind::Other)
}

fn require_release(bundle: &Path) -> Result<Kind, String> {
    match bundle_kind(bundle) {
        Kind::Other => Err("This is a development build; updating and returning to classic only work in the released Muya.".into()),
        k => Ok(k),
    }
}

// ---------- the Platform wrapper ----------

/// How a job differs from the plain swap.
#[derive(Debug, Default, Clone)]
struct Mode {
    /// Tauri's minisign signature of the `.app.tar.gz`: the "checksum" of the download is this signature check.
    signature: Option<String>,
    /// An app that replaces ITSELF in place has no old app to trash afterwards.
    no_source: Option<PathBuf>,
    /// An app that already sits in the Trash and verified: nothing to download.
    restore: Option<PathBuf>,
}

struct Wrapped<P: Platform> {
    inner: P,
    mode: Mode,
    expected: String,
    emit: Box<dyn Fn(Value) + Send>,
    kind: &'static str,
    version: String,
}

impl<P: Platform> Platform for Wrapped<P> {
    fn download(
        &mut self,
        url: &str,
        dest: &Path,
        progress: &mut dyn FnMut(u64, Option<u64>),
    ) -> Result<(), String> {
        if self.mode.restore.is_some() {
            return Ok(());
        }
        self.inner.download(url, dest, progress)
    }
    fn sha256(&mut self, path: &Path) -> Result<String, String> {
        if self.mode.restore.is_some() {
            return Ok(self.expected.clone());
        }
        match &self.mode.signature {
            Some(signature) => {
                let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
                manifest::verify_signature(&bytes, signature, &updater_pubkey())
                    .map_err(|e| format!("the download failed its signature check ({e})"))?;
                Ok(self.expected.clone())
            }
            None => self.inner.sha256(path),
        }
    }
    fn unpack(&mut self, zip: &Path, dir: &Path) -> Result<PathBuf, String> {
        match &self.mode.restore {
            Some(app) => Ok(app.clone()),
            None => self.inner.unpack(zip, dir),
        }
    }
    fn verify_app(&mut self, app: &Path, id: &str, team: &str) -> Result<(), VerifyError> {
        self.inner.verify_app(app, id, team)
    }
    fn drop_quarantine(&mut self, app: &Path) -> Result<(), String> {
        self.inner.drop_quarantine(app)
    }
    fn exists(&mut self, path: &Path) -> bool {
        self.inner.exists(path)
    }
    fn trash(&mut self, path: &Path) -> Result<Option<PathBuf>, String> {
        if self.mode.no_source.as_deref() == Some(path) {
            return Ok(None);
        }
        self.inner.trash(path)
    }
    fn restore(&mut self, from: &Path, to: &Path) -> Result<(), String> {
        self.inner.restore(from, to)
    }
    fn install(&mut self, staged: &Path, dest: &Path) -> Result<(), String> {
        self.inner.install(staged, dest)
    }
    fn launch(&mut self, app: &Path, args: &[String]) -> Result<(), String> {
        self.inner.launch(app, args)
    }
    fn wait_healthy(&mut self, timeout: Duration) -> bool {
        self.inner.wait_healthy(timeout)
    }
    fn terminate(&mut self, app: &Path) {
        // Self-update: the old and the new instance share one path, and this very daemon runs inside it.
        if self.mode.no_source.is_none() {
            self.inner.terminate(app);
        }
    }
    fn terminate_launched(&mut self, app: &Path) {
        if self.mode.no_source.is_none() {
            self.inner.terminate_launched(app);
        }
    }
    fn check_target(&mut self, target: &Path) -> Result<(), String> {
        self.inner.check_target(target)
    }
    fn save_state(&mut self, st: &SwitchState) {
        self.inner.save_state(st);
        let phase = match st.step {
            Step::Downloading => "downloading",
            Step::Verifying => "verifying",
            Step::Installing => "installing",
            Step::Launching => "launching",
            Step::NativeHealthy => "healthy",
            Step::Done | Step::RolledBack => return, // reported once, with the result
        };
        (self.emit)(json!({ "kind": self.kind, "phase": phase, "version": self.version }));
    }
}

fn sys_platform(home: &Path) -> SysPlatform {
    let support = support_dir(home);
    SysPlatform {
        state_file: state_path(&support),
        healthy_marker: healthy_marker_path(&support),
        trash_fn: Some(Box::new(|p: &Path| muya_core::trash::trash_item(p))),
    }
}

struct Job {
    kind: &'static str,
    plan: Plan,
    mode: Mode,
    home: PathBuf,
    /// The new app is another bundle than the running one (the legacy move).
    moved: bool,
}

fn run_job(job: Job, muyad: Weak<Muyad>) {
    let kind = job.kind;
    let moved = job.moved;
    let version = job.plan.version.clone();
    let emit = |m: &Weak<Muyad>, v: Value| {
        if let Some(m) = m.upgrade() {
            let _ = m.emit_event(EVENT, &v);
        }
    };
    let phase_target = muyad.clone();
    let mut w = Wrapped {
        inner: sys_platform(&job.home),
        mode: job.mode,
        expected: job.plan.sha256.clone(),
        emit: Box::new(move |v| emit_to(&phase_target, v)),
        kind,
        version: version.clone(),
    };
    let progress_target = muyad.clone();
    let progress_version = version.clone();
    let mut progress = move |d: u64, t: Option<u64>| {
        emit_to(
            &progress_target,
            json!({ "kind": kind, "phase": "downloading", "downloaded": d, "total": t, "version": progress_version }),
        );
    };
    let result = swap::run_swap(&mut w, &job.plan, &mut progress);
    // The download and the unpacked copy are ours alone (Caches/…/switchover/<version>); never leave them behind.
    let _ = std::fs::remove_dir_all(&job.plan.stage_dir);
    BUSY.store(false, Ordering::SeqCst);
    let installed = match result {
        Ok(_) => {
            emit(
                &muyad,
                json!({ "kind": kind, "phase": "done", "version": version }),
            );
            true
        }
        // Installed and healthy; only the old app is still in place.
        Err(e @ SwapError::TrashSource(_)) => {
            emit(
                &muyad,
                json!({ "kind": kind, "phase": "done", "version": version, "message": e.to_string() }),
            );
            true
        }
        Err(e) => {
            emit(
                &muyad,
                json!({ "kind": kind, "phase": "error", "version": version, "message": e.to_string() }),
            );
            false
        }
    };
    match post_action(kind, moved, installed) {
        Post::RestartDaemon => {
            // This daemon still runs the OLD bundle's binary. Exit cleanly (final event already sent); launchd's KeepAlive
            // starts the one inside the new bundle, the app reconnects on its own and ptyd keeps the sessions (re-adopted).
            std::thread::sleep(RESTART_AFTER_UPDATE);
            eprintln!("muyad: update installed; exiting so launchd starts the new build");
            std::process::exit(0);
        }
        Post::HandOver => {
            // The new app is another bundle: the jobs launchd holds belong to the old one. Boot them out from a detached
            // script (it outlives this daemon, which is one of the jobs); the new app registers its own once they are gone.
            match launchd::handover_script(
                launchd::current_uid(),
                &launchd::service_labels(),
                HANDOVER_DELAY_SECS,
            ) {
                Ok(script) => {
                    let _ = launchd::spawn_detached(&script);
                    std::thread::sleep(Duration::from_secs(u64::from(HANDOVER_DELAY_SECS) + 2));
                    eprintln!("muyad: handed over to the new app; exiting");
                    std::process::exit(0);
                }
                Err(e) => eprintln!("muyad: no hand-over: {e}"),
            }
        }
        Post::Nothing => {}
    }
}

fn emit_to(m: &Weak<Muyad>, v: Value) {
    if let Some(m) = m.upgrade() {
        let _ = m.emit_event(EVENT, &v);
    }
}

fn start_job(job: Job, muyad: Weak<Muyad>) -> Result<Value, String> {
    if BUSY.swap(true, Ordering::SeqCst) {
        return Err("a return or an update is already running".into());
    }
    let kind = job.kind;
    std::thread::Builder::new()
        .name("switchover".into())
        .spawn(move || run_job(job, muyad))
        .map_err(|e| {
            BUSY.store(false, Ordering::SeqCst);
            e.to_string()
        })?;
    Ok(json!({ "started": true, "kind": kind }))
}

// ---------- plans (pure) ----------

fn read_state(support: &Path) -> Option<SwitchState> {
    serde_json::from_slice(&std::fs::read(state_path(support)).ok()?).ok()
}

/// The update plan for the running `bundle` of `kind`. A release app is replaced where it is; a legacy app moves to
/// `Muya.app` in its folder. `genuine(path)` says whether what already sits at the move target is a verified Muya.
fn update_plan(
    bundle: &Path,
    kind: Kind,
    release: &feed::Release,
    home: &Path,
    genuine: impl Fn(&Path) -> bool,
) -> Result<(Plan, Mode, bool), String> {
    let ids = v5::ids();
    let target = v5::update_target(bundle, kind).ok_or("this build cannot update itself")?;
    let moved = target != bundle;
    if moved {
        v5::check_move_target(&target, bundle, target.exists(), genuine(&target))?;
    }
    let stage = stage_dir(home, &release.version);
    let no_source = stage.join("no-source.app");
    let plan = Plan {
        version: release.version.clone(),
        url: release.url.clone(),
        sha256: release.signature.clone(),
        stage_dir: stage,
        target_app: target,
        source_app: if moved {
            bundle.to_path_buf()
        } else {
            no_source.clone()
        },
        expected_id: v5::expected_new_id(&ids),
        expected_team: TEAM_ID.into(),
        launch_args: vec!["--switched-from=update".into()],
        healthy_timeout: HEALTHY_TIMEOUT,
    };
    let mode = Mode {
        signature: Some(release.signature.clone()),
        no_source: (!moved).then_some(no_source),
        restore: None,
    };
    Ok((plan, mode, moved))
}

/// Where classic goes back to, for a LEGACY app: the place it was switched away from, else next to the running app.
pub fn classic_target(prev: Option<&SwitchState>, native: &Path) -> PathBuf {
    prev.filter(|s| s.trashed_source.is_some())
        .map(|s| PathBuf::from(&s.from_path))
        .filter(|p| {
            p.extension().is_some_and(|e| e == "app") && p.parent().is_some_and(Path::is_dir)
        })
        .unwrap_or_else(|| {
            native
                .parent()
                .filter(|d| d.is_dir() && !d.starts_with("/private/var"))
                .map(|d| d.join(v5::RELEASE_APP_FILE))
                .unwrap_or_else(|| PathBuf::from("/Applications/Muya.app"))
        })
}

/// The "Return to Muya Classic" plan: the pinned build, in place for a release app. A legacy app may reuse a verified
/// classic that is still in the Trash from its own switch; everything else downloads the pin.
fn return_plan(
    bundle: &Path,
    kind: Kind,
    prev: Option<&SwitchState>,
    home: &Path,
    restorable: impl Fn(&Path) -> bool,
) -> Result<(Plan, Mode), String> {
    let ids = v5::ids();
    let pin = v5::classic_return();
    let target = match kind {
        Kind::Release => v5::return_target(bundle),
        _ => classic_target(prev, bundle),
    };
    let base = |ver: &str, url: &str, sha: &str| Plan {
        version: ver.to_string(),
        url: url.to_string(),
        sha256: sha.to_string(),
        stage_dir: stage_dir(home, ver),
        target_app: target.clone(),
        source_app: bundle.to_path_buf(),
        expected_id: ids.release.clone(),
        expected_team: TEAM_ID.into(),
        launch_args: vec!["--switched-from=native".into()],
        healthy_timeout: HEALTHY_TIMEOUT,
    };
    if kind == Kind::Legacy {
        if let Some(trashed) = prev
            .and_then(|s| s.trashed_source.as_deref())
            .map(PathBuf::from)
        {
            if restorable(&trashed) {
                return Ok((
                    base("restored", "", ""),
                    Mode {
                        restore: Some(trashed),
                        ..Mode::default()
                    },
                ));
            }
        }
    }
    Ok((base(&pin.version, &pin.url, &pin.sha256), Mode::default()))
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct AppParams {
    #[serde(default)]
    app_path: Option<String>,
    /// The app's own command line (`--switched-from=…`).
    #[serde(default)]
    args: Vec<String>,
}

fn params(raw: &str) -> Result<AppParams, String> {
    serde_json::from_str(if raw.trim().is_empty() { "{}" } else { raw })
        .map_err(|e| format!("bad parameters: {e}"))
}

/// `None` = not ours. The `beta_update_*` and `switch_back_*` names are the ones earlier builds used; kept so an app and
/// a daemon of different builds still understand each other.
pub fn call(method: &str, raw: &str, muyad: &Weak<Muyad>) -> Option<Result<Value, String>> {
    let r = match method {
        "return_classic_preflight" | "switch_back_preflight" => Ok(preflight(muyad)),
        "return_classic_start" | "switch_back_start" => {
            params(raw).and_then(|p| return_start(&p, muyad))
        }
        "update_status" | "beta_update_status" => params(raw).and_then(|p| status(&p)),
        "update_check" | "beta_update_check" => {
            params(raw).and_then(|p| update_check_rpc(&p, muyad))
        }
        "update_install" | "beta_update_install" => {
            params(raw).and_then(|p| update_install(&p, muyad))
        }
        "switchover_ack_launch" => params(raw).and_then(|p| ack_launch(&p.args)),
        "touchid_notice" => {
            Ok(json!({ "needed": muya_core::credstore::touchid_reenable_needed() }))
        }
        _ => return None,
    };
    Some(r)
}

fn preflight(muyad: &Weak<Muyad>) -> Value {
    let Some(m) = muyad.upgrade() else {
        return json!({ "live": 0, "agents": 0 });
    };
    let live: Vec<_> = m
        .live_sessions()
        .into_iter()
        .filter(|s| s.exited.is_none())
        .collect();
    json!({ "live": live.len(), "agents": live.iter().filter(|s| s.claude_session_id.is_some()).count() })
}

fn status(p: &AppParams) -> Result<Value, String> {
    let bundle = current_bundle(p.app_path.as_deref())?;
    let kind = bundle_kind(&bundle);
    Ok(json!({
        "installed": plist_string(&bundle, "CFBundleShortVersionString").unwrap_or_default(),
        "canSwitch": kind != Kind::Other,
        "kind": match kind { Kind::Release => "release", Kind::Legacy => "legacy", Kind::Other => "dev" },
        "returnVersion": v5::classic_return().version,
        "pending": PENDING.lock().ok().and_then(|g| g.clone()),
    }))
}

fn return_start(p: &AppParams, muyad: &Weak<Muyad>) -> Result<Value, String> {
    let bundle = current_bundle(p.app_path.as_deref())?;
    let kind = require_release(&bundle)?;
    let bundle = install_target(&bundle)?;
    let home = home()?;
    let prev = read_state(&support_dir(&home));
    let ids = v5::ids();
    let (plan, mode) = return_plan(&bundle, kind, prev.as_ref(), &home, |app| {
        // Capability, not presence: it must verify as classic from our Team before it is reused.
        app.exists()
            && muya_switchover::verify::verify_app(
                &muya_switchover::verify::SystemRunner,
                app,
                &ids.release,
                TEAM_ID,
            )
            .is_ok()
    })?;
    start_job(
        Job {
            kind: "switch_back",
            plan,
            mode,
            home,
            moved: false,
        },
        muyad.clone(),
    )
}

fn update_check_rpc(p: &AppParams, muyad: &Weak<Muyad>) -> Result<Value, String> {
    let bundle = current_bundle(p.app_path.as_deref())?;
    let installed = plist_string(&bundle, "CFBundleShortVersionString").unwrap_or_default();
    match check_update(&CurlFetch, &installed) {
        Ok(c) => {
            let v = json!({ "installed": installed, "available": c.available, "version": c.release.version });
            remember(&c, muyad);
            Ok(v)
        }
        // No feed published yet: not an error for the user.
        Err(e) if e.contains("404") => {
            Ok(json!({ "installed": installed, "available": false, "none": true }))
        }
        Err(e) => Err(e),
    }
}

fn remember(c: &UpdateCheck, muyad: &Weak<Muyad>) {
    let v = c.available.then(|| json!({ "version": c.release.version }));
    let changed = PENDING
        .lock()
        .map(|mut g| {
            let ch = *g != v;
            *g = v.clone();
            ch
        })
        .unwrap_or(false);
    if let (true, Some(v), Some(m)) = (changed, v, muyad.upgrade()) {
        let _ = m.emit_event(AVAILABLE_EVENT, &v);
    }
}

fn update_install(p: &AppParams, muyad: &Weak<Muyad>) -> Result<Value, String> {
    let bundle = current_bundle(p.app_path.as_deref())?;
    let kind = require_release(&bundle)?;
    let bundle = install_target(&bundle)?;
    let installed = plist_string(&bundle, "CFBundleShortVersionString").unwrap_or_default();
    // Re-fetch and re-verify: never trust an earlier answer.
    let c = check_update(&CurlFetch, &installed)?;
    if !c.available {
        return Err("Muya is already up to date.".into());
    }
    let home = home()?;
    let ids = v5::ids();
    let (plan, mode, moved) = update_plan(&bundle, kind, &c.release, &home, |app| {
        muya_switchover::verify::verify_app(
            &muya_switchover::verify::SystemRunner,
            app,
            &ids.release,
            TEAM_ID,
        )
        .is_ok()
    })?;
    start_job(
        Job {
            kind: "update",
            plan,
            mode,
            home,
            moved,
        },
        muyad.clone(),
    )
}

fn ack_launch(args: &[String]) -> Result<Value, String> {
    let from = args
        .iter()
        .find_map(|a| a.strip_prefix("--switched-from="))
        .map(str::to_string);
    let support = support_dir(&home()?);
    let launching = read_state(&support).is_some_and(|s| s.step == Step::Launching);
    let mut wrote = false;
    if from.is_some() || launching {
        let marker = healthy_marker_path(&support);
        if let Some(d) = marker.parent() {
            std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
        }
        let at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        std::fs::write(
            &marker,
            json!({ "app": "native", "pid": std::process::id(), "at": at }).to_string(),
        )
        .map_err(|e| e.to_string())?;
        wrote = true;
    }
    Ok(
        json!({ "switchedFrom": from, "healthyWritten": wrote, "touchIdNeeded": from.is_some() && muya_core::credstore::touchid_reenable_needed() }),
    )
}

// ---------- one-shot return (the launcher, macOS older than the app supports) ----------

/// `muyad --return-classic <app bundle>`: the same pinned, verified, in-place swap as "Return to Muya Classic", run to the end
/// on this thread without a daemon or an app. The launcher (native/launcher) calls it when Muya 5 cannot run on this macOS.
/// Progress goes to stderr, one JSON line each. Never reads the feed; never reuses a trashed app.
pub fn return_classic_cli(app: &str) -> Result<String, String> {
    let bundle = current_bundle(Some(app))?;
    let kind = require_release(&bundle)?;
    let bundle = install_target(&bundle)?;
    let home = home()?;
    let prev = read_state(&support_dir(&home));
    let (plan, mode) = return_plan(&bundle, kind, prev.as_ref(), &home, |_| false)?;
    let mut w = Wrapped { inner: sys_platform(&home), mode, expected: plan.sha256.clone(), emit: Box::new(|v| eprintln!("{v}")), kind: "switch_back", version: plan.version.clone() };
    let r = swap::run_swap(&mut w, &plan, &mut |_, _| {});
    let _ = std::fs::remove_dir_all(&plan.stage_dir);
    match r {
        Ok(_) | Err(SwapError::TrashSource(_)) => Ok(plan.version),
        Err(e) => Err(e.to_string()),
    }
}

// ---------- background poll ----------

/// At launch (after a short delay) and every 6 h: look for a newer release and only say so. Never installs.
pub fn spawn_poller(muyad: Weak<Muyad>) {
    let Ok(bundle) = current_bundle(None) else {
        return;
    };
    if require_release(&bundle).is_err() {
        return;
    }
    let _ = std::thread::Builder::new()
        .name("update-poll".into())
        .spawn(move || {
            std::thread::sleep(POLL_FIRST);
            loop {
                let installed =
                    plist_string(&bundle, "CFBundleShortVersionString").unwrap_or_default();
                if let Ok(c) = check_update(&CurlFetch, &installed) {
                    remember(&c, &muyad);
                }
                std::thread::sleep(POLL_EVERY);
            }
        });
}
#[cfg(test)]
mod tests {
    use super::*;
    use muya_switchover::{CLASSIC_BUNDLE_ID, NATIVE_BUNDLE_ID};
    use std::collections::BTreeMap;

    // A feed signed with a throwaway key (never the real one), generated once for these tests.
    const TEST_PUB: &str = "untrusted comment: minisign public key: C548A05F2CF8E139\nRWQ54fgsX6BIxWPsMYpl28lE/8laBgsY9iBGE6fxpZ/v/k5Xsxp+4LDA\n";
    const FEED: &str = r#"{"version":"5.0.0","notes":"n","platforms":{"darwin-aarch64":{"signature":"c2ln","url":"https://github.com/st4unch/muya/releases/download/v5.0.0/Muya-5.0.0-arm64.app.tar.gz"}}}"#;

    struct Feed(BTreeMap<String, Result<Vec<u8>, String>>);
    impl Fetch for Feed {
        fn get(&self, url: &str) -> Result<Vec<u8>, String> {
            self.0
                .get(url)
                .cloned()
                .unwrap_or_else(|| Err(format!("no fake for {url}")))
        }
    }
    fn feed(json: &str) -> Feed {
        Feed(BTreeMap::from([(
            LATEST_URL.to_string(),
            Ok(json.as_bytes().to_vec()),
        )]))
    }

    #[test]
    fn a_newer_release_is_available_older_or_equal_is_not() {
        let f = feed(FEED);
        let c = check_update(&f, "4.1.22").unwrap();
        assert!(c.available);
        assert_eq!(c.release.version, "5.0.0");
        assert!(
            check_update(&f, "4.1.27").unwrap().available,
            "the bridge moves to 5.0.0"
        );
        assert!(!check_update(&f, "5.0.0").unwrap().available, "equal");
        assert!(
            !check_update(&f, "5.1.0").unwrap().available,
            "never an older release"
        );
    }

    #[test]
    fn network_errors_pass_through_and_a_bad_feed_is_refused() {
        let f = Feed(BTreeMap::from([(
            LATEST_URL.to_string(),
            Err("network error: 404".to_string()),
        )]));
        assert!(check_update(&f, "4.1.22").unwrap_err().contains("404"));
        assert!(check_update(&feed("not json"), "4.1.22").is_err());
    }

    #[test]
    fn a_tarball_signed_with_another_key_is_refused_by_the_real_updater_key() {
        // TEST_PUB signs the test vector in muya-switchover's manifest tests; the real key must not accept a throwaway signature.
        let sig = "untrusted comment: test\nRUQ54fgsX6BIxW4DpbNRDjgAyu9E+6sHf2vxDbImmrHquoXzIj2bIuGiBf2GCBDOMz6S7rlWcxNhTLH/agcZeYVuhZeRTeZ8yAU=\ntrusted comment: test\niW2ePPQSNg8RbwKGPHYM77e/e0PtrmLSZKlB3nCV1ZpdQJFGjYbA9HGUhjM78gWGdDliSkKEBMT61DIKtdT6Cg==\n";
        assert!(manifest::verify_signature(b"anything", sig, UPDATER_PUBKEY).is_err());
        assert!(
            manifest::verify_signature(b"anything", sig, TEST_PUB).is_err(),
            "and a different payload fails even with the matching key"
        );
    }

    #[test]
    fn what_happens_to_the_daemon_after_each_job() {
        assert_eq!(
            post_action("update", false, true),
            Post::RestartDaemon,
            "in place: launchd restarts the daemon from the new bundle"
        );
        assert_eq!(
            post_action("update", true, true),
            Post::HandOver,
            "legacy move: the old jobs are booted out"
        );
        assert_eq!(
            post_action("switch_back", false, true),
            Post::HandOver,
            "return: the v5 services must not linger"
        );
        assert_eq!(
            post_action("update", false, false),
            Post::Nothing,
            "a failed job keeps the daemon"
        );
        assert_eq!(post_action("switch_back", false, false), Post::Nothing);
        assert_eq!(post_action("update", true, false), Post::Nothing);
    }

    #[test]
    fn classic_latest_feed_shape_is_the_one_the_crate_parses() {
        let ok = br#"{"version":"4.1.20","platforms":{"darwin-aarch64":{"signature":"c2ln","url":"https://github.com/st4unch/muya/releases/download/v4.1.20/Muya-4.1.20-arm64.app.tar.gz"}}}"#;
        assert_eq!(feed::parse_latest(ok).unwrap().version, "4.1.20");
    }

    fn rel() -> feed::Release {
        feed::parse_latest(FEED.as_bytes()).unwrap()
    }

    #[test]
    fn a_release_app_updates_in_place_and_never_trashes_a_second_app() {
        let home = tempfile::tempdir().unwrap();
        let app = Path::new("/Applications/Muya Yeni.app");
        let (plan, mode, moved) = update_plan(app, Kind::Release, &rel(), home.path(), |_| {
            panic!("no move, no probe")
        })
        .unwrap();
        assert!(!moved);
        assert_eq!(plan.target_app, app, "same folder, same file name");
        assert_eq!(
            plan.expected_id, CLASSIC_BUNDLE_ID,
            "the new app is the release id"
        );
        assert_eq!(plan.expected_team, TEAM_ID);
        assert_eq!(plan.launch_args, ["--switched-from=update"]);
        assert_eq!(
            plan.sha256, "c2ln",
            "the checksum slot carries the signature the wrapper verifies"
        );
        assert!(mode.no_source.is_some() && mode.signature.is_some() && mode.restore.is_none());
        assert_eq!(plan.source_app, mode.no_source.unwrap());
    }

    #[test]
    fn a_legacy_app_moves_to_muya_app_next_to_it() {
        let home = tempfile::tempdir().unwrap();
        let desk = tempfile::tempdir().unwrap();
        let old = desk.path().join("Muya Native.app");
        std::fs::create_dir_all(old.join("Contents")).unwrap();
        let (plan, mode, moved) =
            update_plan(&old, Kind::Legacy, &rel(), home.path(), |_| false).unwrap();
        assert!(moved);
        assert_eq!(plan.target_app, desk.path().join("Muya.app"));
        assert_eq!(
            plan.source_app, old,
            "the old app is trashed AFTER the new one is healthy"
        );
        assert_eq!(plan.expected_id, "com.staunch.muya");
        assert!(mode.no_source.is_none(), "there IS an old app to trash");
        // Something foreign already at the target is refused before anything is touched.
        std::fs::create_dir_all(desk.path().join("Muya.app")).unwrap();
        let e = update_plan(&old, Kind::Legacy, &rel(), home.path(), |_| false).unwrap_err();
        assert!(e.contains("not a Muya app"), "{e}");
        // ...but a genuine classic Muya.app is replaced (it goes to the Trash like any replaced app).
        assert!(update_plan(&old, Kind::Legacy, &rel(), home.path(), |_| true).is_ok());
        assert!(
            update_plan(
                Path::new("/x/Muya.app"),
                Kind::Other,
                &rel(),
                home.path(),
                |_| true
            )
            .is_err(),
            "a dev build cannot update"
        );
    }

    fn pin_plan(
        kind: Kind,
        bundle: &Path,
        prev: Option<&SwitchState>,
        restorable: bool,
    ) -> (Plan, Mode) {
        let home = tempfile::tempdir().unwrap();
        return_plan(bundle, kind, prev, home.path(), |_| restorable).unwrap()
    }

    #[test]
    fn return_to_classic_installs_the_pinned_build_in_place() {
        let bundle = Path::new("/Applications/Muya.app");
        let (plan, mode) = pin_plan(Kind::Release, bundle, None, false);
        assert_eq!(
            plan.target_app, bundle,
            "same path, same name: macOS permissions stay"
        );
        assert_eq!(plan.source_app, bundle);
        assert_eq!(plan.version, "4.1.22");
        assert_eq!(
            plan.url,
            "https://github.com/st4unch/muya/releases/download/v4.1.22/Muya-4.1.22-arm64.zip"
        );
        assert_eq!(
            plan.sha256, "11f582eb66e5daf6e27364168e39e3fa0091ef7326d4163403258342529ee11f",
            "the pin, not a feed value"
        );
        assert_eq!(
            (plan.expected_id.as_str(), plan.expected_team.as_str()),
            (CLASSIC_BUNDLE_ID, TEAM_ID)
        );
        assert_eq!(
            plan.launch_args,
            ["--switched-from=native"],
            "classic 4.1.22 answers this handshake"
        );
        assert!(
            mode.signature.is_none() && mode.no_source.is_none() && mode.restore.is_none(),
            "plain download + sha256 pin + codesign/notarization"
        );
    }

    #[test]
    fn a_release_app_never_reuses_a_trashed_app_and_never_reads_the_feed() {
        let prev = SwitchState {
            step: Step::Done,
            from_path: "/Applications/Muya.app".into(),
            to_path: "x".into(),
            trashed_previous_target: None,
            trashed_source: Some("/trash/Muya.app".into()),
            version: "4".into(),
        };
        let (plan, mode) = pin_plan(
            Kind::Release,
            Path::new("/Applications/Muya.app"),
            Some(&prev),
            true,
        );
        assert!(
            mode.restore.is_none(),
            "always the pinned, verified download"
        );
        assert_eq!(plan.version, "4.1.22");
    }

    #[test]
    fn a_legacy_app_still_prefers_a_verified_trashed_classic() {
        let apps = tempfile::tempdir().unwrap();
        let prev = SwitchState {
            step: Step::Done,
            from_path: apps.path().join("Muya.app").to_string_lossy().into(),
            to_path: "/x/Muya Native.app".into(),
            trashed_previous_target: None,
            trashed_source: Some("/trash/Muya.app".into()),
            version: "0.1.0".into(),
        };
        let native = Path::new("/Applications/Muya Native.app");
        let (plan, mode) = pin_plan(Kind::Legacy, native, Some(&prev), true);
        assert!(mode.restore.is_some());
        assert_eq!(plan.target_app, apps.path().join("Muya.app"));
        let (plan, mode) = pin_plan(Kind::Legacy, native, Some(&prev), false);
        assert!(mode.restore.is_none());
        assert_eq!(plan.version, "4.1.22");
        let (plan, _) = pin_plan(Kind::Legacy, native, None, false);
        assert_eq!(plan.target_app, PathBuf::from("/Applications/Muya.app"));
        let (plan, _) = pin_plan(
            Kind::Legacy,
            &apps.path().join("Muya Native.app"),
            None,
            false,
        );
        assert_eq!(plan.target_app, apps.path().join("Muya.app"));
    }

    /// Records calls instead of touching the system.
    #[derive(Default)]
    struct Rec {
        log: Vec<String>,
    }
    impl Platform for Rec {
        fn download(
            &mut self,
            _: &str,
            _: &Path,
            _: &mut dyn FnMut(u64, Option<u64>),
        ) -> Result<(), String> {
            self.log.push("download".into());
            Ok(())
        }
        fn sha256(&mut self, _: &Path) -> Result<String, String> {
            self.log.push("sha".into());
            Ok("EXP".into())
        }
        fn unpack(&mut self, _: &Path, d: &Path) -> Result<PathBuf, String> {
            self.log.push("unpack".into());
            Ok(d.join("a.app"))
        }
        fn verify_app(&mut self, _: &Path, _: &str, _: &str) -> Result<(), VerifyError> {
            Ok(())
        }
        fn drop_quarantine(&mut self, _: &Path) -> Result<(), String> {
            Ok(())
        }
        fn exists(&mut self, _: &Path) -> bool {
            true
        }
        fn trash(&mut self, p: &Path) -> Result<Option<PathBuf>, String> {
            self.log.push(format!("trash {}", p.display()));
            Ok(Some("/t".into()))
        }
        fn restore(&mut self, _: &Path, _: &Path) -> Result<(), String> {
            Ok(())
        }
        fn install(&mut self, _: &Path, _: &Path) -> Result<(), String> {
            self.log.push("install".into());
            Ok(())
        }
        fn launch(&mut self, _: &Path, _: &[String]) -> Result<(), String> {
            Ok(())
        }
        fn wait_healthy(&mut self, _: Duration) -> bool {
            true
        }
        fn terminate(&mut self, _: &Path) {
            self.log.push("terminate".into());
        }
        fn save_state(&mut self, _: &SwitchState) {}
    }
    fn wrapped(mode: Mode) -> Wrapped<Rec> {
        Wrapped {
            inner: Rec::default(),
            mode,
            expected: "EXP".into(),
            emit: Box::new(|_| {}),
            kind: "t",
            version: "1".into(),
        }
    }
    fn plan(target: &str, source: &str) -> Plan {
        Plan {
            version: "1".into(),
            url: String::new(),
            sha256: "EXP".into(),
            stage_dir: "/stage".into(),
            target_app: target.into(),
            source_app: source.into(),
            expected_id: CLASSIC_BUNDLE_ID.into(),
            expected_team: TEAM_ID.into(),
            launch_args: vec![],
            healthy_timeout: Duration::from_secs(1),
        }
    }

    #[test]
    fn restore_downloads_nothing_and_installs_the_trashed_app() {
        let mut w = wrapped(Mode {
            restore: Some("/trash/Muya.app".into()),
            ..Mode::default()
        });
        let out = swap::run_swap(
            &mut w,
            &plan("/Applications/Muya.app", "/Applications/Muya Native.app"),
            &mut |_, _| {},
        )
        .unwrap();
        assert!(
            !w.inner.log.contains(&"download".to_string())
                && !w.inner.log.contains(&"unpack".to_string())
        );
        assert_eq!(
            w.inner.log.last().unwrap(),
            "trash /Applications/Muya Native.app"
        );
        assert_eq!(out.trashed_source, Some(PathBuf::from("/t")));
    }

    #[test]
    fn a_pinned_download_is_checked_against_the_pin_not_a_signature() {
        // Mode::default() has no signature: the wrapper asks the real platform for the file's sha256 and the swap compares it
        // with the plan's (the pin). A mismatch must stop before anything is installed.
        let dir = tempfile::tempdir().unwrap();
        let mut w = wrapped(Mode::default());
        let mut p = plan("/Applications/Muya.app", "/Applications/Muya.app");
        p.stage_dir = dir.path().into();
        p.sha256 = "0".repeat(64);
        let e = swap::run_swap(&mut w, &p, &mut |_, _| {}).unwrap_err();
        // Rec::sha256 answers "EXP", which is not the pin.
        assert!(e.to_string().contains("damaged"), "{e}");
        assert!(
            !w.inner.log.contains(&"install".to_string())
                && !w.inner.log.iter().any(|l| l.starts_with("trash"))
        );
    }

    #[test]
    fn tarball_with_a_bad_signature_never_installs() {
        let dir = tempfile::tempdir().unwrap();
        let mut w = wrapped(Mode {
            signature: Some("c2ln".into()),
            ..Mode::default()
        });
        let mut p = plan("/Applications/Muya.app", "/Applications/Muya Native.app");
        p.stage_dir = dir.path().into();
        std::fs::write(dir.path().join("download.zip"), b"not an archive").unwrap();
        let e = swap::run_swap(&mut w, &p, &mut |_, _| {}).unwrap_err();
        assert!(e.to_string().contains("signature"), "{e}");
        assert!(!w.inner.log.contains(&"install".to_string()));
        assert!(
            !w.inner.log.iter().any(|l| l.starts_with("trash")),
            "nothing may be trashed: {:?}",
            w.inner.log
        );
    }

    #[test]
    fn self_update_has_no_old_app_to_trash_and_never_kills_itself() {
        let mut w = wrapped(Mode {
            signature: Some("c2ln".into()),
            no_source: Some("/stage/no-source.app".into()),
            restore: None,
        });
        w.mode.signature = None; // the signature path is covered above; Rec answers sha "EXP"
        swap::run_swap(
            &mut w,
            &plan("/Applications/Muya.app", "/stage/no-source.app"),
            &mut |_, _| {},
        )
        .unwrap();
        // The running bundle (the target) is trashed once to make room; the no-op source is not touched.
        assert_eq!(
            w.inner
                .log
                .iter()
                .filter(|l| l.starts_with("trash"))
                .collect::<Vec<_>>(),
            ["trash /Applications/Muya.app"]
        );
        w.terminate(Path::new("/Applications/Muya.app"));
        assert!(!w.inner.log.contains(&"terminate".to_string()));
    }

    #[test]
    fn a_move_trashes_the_old_app_after_the_new_one_is_healthy_and_may_terminate_the_new_one_on_rollback(
    ) {
        let mut w = wrapped(Mode::default());
        w.mode = Mode {
            signature: None,
            no_source: None,
            restore: None,
        };
        let mut p = plan("/Applications/Muya.app", "/Applications/Muya Native.app");
        p.sha256 = "EXP".into();
        swap::run_swap(&mut w, &p, &mut |_, _| {}).unwrap();
        // Order: the (existing) target goes first, the legacy source last, after launch + handshake.
        let trashes: Vec<_> = w
            .inner
            .log
            .iter()
            .filter(|l| l.starts_with("trash"))
            .cloned()
            .collect();
        assert_eq!(
            trashes,
            [
                "trash /Applications/Muya.app",
                "trash /Applications/Muya Native.app"
            ]
        );
        let install = w.inner.log.iter().position(|l| l == "install").unwrap();
        let last_trash = w
            .inner
            .log
            .iter()
            .rposition(|l| l.starts_with("trash"))
            .unwrap();
        assert!(last_trash > install);
    }

    #[test]
    fn ack_writes_the_healthy_marker_only_after_a_switch() {
        let home = tempfile::tempdir().unwrap();
        // Single test touching HOME in this crate's unit tests.
        unsafe { std::env::set_var("HOME", home.path()) };
        let marker = healthy_marker_path(&support_dir(home.path()));
        let v = ack_launch(&[]).unwrap();
        assert_eq!(v["healthyWritten"], false);
        assert!(!marker.exists());
        let v = ack_launch(&["--switched-from=classic".into()]).unwrap();
        assert_eq!(
            (v["switchedFrom"].as_str(), v["healthyWritten"].as_bool()),
            (Some("classic"), Some(true))
        );
        assert!(marker.is_file());
        // A crash left switch.json at "launching": the next start answers the handshake too.
        std::fs::remove_file(&marker).unwrap();
        let st = SwitchState {
            step: Step::Launching,
            from_path: "a".into(),
            to_path: "b".into(),
            trashed_previous_target: None,
            trashed_source: None,
            version: "1".into(),
        };
        std::fs::write(
            state_path(&support_dir(home.path())),
            serde_json::to_vec(&st).unwrap(),
        )
        .unwrap();
        assert_eq!(ack_launch(&[]).unwrap()["healthyWritten"], true);
        assert!(marker.is_file());
    }

    fn write_plist(app: &Path, id: &str) {
        std::fs::create_dir_all(app.join("Contents")).unwrap();
        std::fs::write(
            app.join("Contents/Info.plist"),
            format!(r#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>{id}</string><key>CFBundleShortVersionString</key><string>0.3.1</string></dict></plist>"#),
        )
        .unwrap();
    }

    #[test]
    fn bundle_helpers_and_kinds() {
        assert_eq!(
            bundle_of(Path::new("/A/Muya Native.app/Contents/MacOS/muyad")),
            Some(PathBuf::from("/A/Muya Native.app"))
        );
        assert_eq!(bundle_of(Path::new("/tmp/target/debug/muyad")), None);
        let d = tempfile::tempdir().unwrap();
        let app = d.path().join("X.app");
        write_plist(&app, "com.staunch.muya.dev");
        assert_eq!(
            plist_string(&app, "CFBundleShortVersionString").as_deref(),
            Some("0.3.1")
        );
        assert!(
            require_release(&app)
                .unwrap_err()
                .contains("development build"),
            "a dev build must refuse to swap itself"
        );
        let rel = d.path().join("Muya.app");
        write_plist(&rel, CLASSIC_BUNDLE_ID);
        assert_eq!(require_release(&rel), Ok(Kind::Release));
        let leg = d.path().join("Muya Native.app");
        write_plist(&leg, NATIVE_BUNDLE_ID);
        assert_eq!(require_release(&leg), Ok(Kind::Legacy));
        assert!(install_target(Path::new(
            "/private/var/folders/x/AppTranslocation/y/d/Muya.app"
        ))
        .is_err());
    }

    fn fake_app(dir: &Path, name: &str) -> PathBuf {
        let app = dir.join(name);
        std::fs::create_dir_all(app.join("Contents")).unwrap();
        std::fs::write(app.join("Contents/Info.plist"), "<plist/>").unwrap();
        app
    }

    #[test]
    fn the_asking_app_decides_the_target_never_this_daemons_own_bundle() {
        let d = tempfile::tempdir().unwrap();
        let desktop = d.path().join("Desktop");
        std::fs::create_dir(&desktop).unwrap();
        let app = fake_app(&desktop, "Muya Yeni.app");
        let got = install_target(&current_bundle(Some(app.to_str().unwrap())).unwrap()).unwrap();
        assert_eq!(got, std::fs::canonicalize(&app).unwrap());
        assert_eq!(got.file_name().unwrap(), "Muya Yeni.app");
        // A path that is not a bundle on disk is an error, not a silent switch to some other copy.
        let e = current_bundle(Some(desktop.join("Missing.app").to_str().unwrap())).unwrap_err();
        assert!(e.contains("not a Muya app bundle"), "{e}");
    }
}

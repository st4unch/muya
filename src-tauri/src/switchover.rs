//! "Try the Muya Native beta" — Tauri side. All decisions, verification and the
//! swap order live in the shared `muya-switchover` crate; this file only wires
//! them to Tauri commands/events and the filesystem locations classic uses.
//! See docs/prd-native-beta-offer.md.

use muya_switchover::manifest::{parse_signed, Manifest};
use muya_switchover::offer::{self, Answer, Offer, OfferInput, OfferState, Trigger};
use muya_switchover::swap::{run_swap, Plan};
use muya_switchover::sysplatform::SysPlatform;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tauri::{AppHandle, Emitter};

const MANIFEST_URL: &str =
    "https://github.com/st4unch/muya/releases/download/native-beta/native-beta.json";
const SIG_URL: &str =
    "https://github.com/st4unch/muya/releases/download/native-beta/native-beta.json.minisig";
const NATIVE_APP_NAME: &str = "Muya Native.app";

fn home() -> Result<PathBuf, String> {
    std::env::var("HOME")
        .map(PathBuf::from)
        .map_err(|_| "HOME is not set".to_string())
}
fn support_dir() -> Result<PathBuf, String> {
    Ok(home()?.join("Library/Application Support/com.staunch.muya"))
}
fn offer_state_path() -> Result<PathBuf, String> {
    Ok(support_dir()?.join("native-offer.json"))
}

/// Where Native lives. `/Applications` unless the e2e build redirects it.
fn apps_dir() -> PathBuf {
    #[cfg(feature = "e2e")]
    if let Ok(d) = std::env::var("MUYA_SWITCHOVER_E2E_APPS_DIR") {
        return PathBuf::from(d);
    }
    PathBuf::from("/Applications")
}

fn manifest_urls() -> (String, String) {
    #[cfg(feature = "e2e")]
    if let Ok(u) = std::env::var("MUYA_SWITCHOVER_E2E_MANIFEST_URL") {
        return (u.clone(), format!("{u}.minisig"));
    }
    (MANIFEST_URL.into(), SIG_URL.into())
}

fn pubkey(app: &AppHandle) -> String {
    #[cfg(feature = "e2e")]
    if let Ok(k) = std::env::var("MUYA_SWITCHOVER_E2E_PUBKEY") {
        return k;
    }
    app.config()
        .plugins
        .0
        .get("updater")
        .and_then(|u| u.get("pubkey"))
        .and_then(|k| k.as_str())
        .unwrap_or_default()
        .to_string()
}

fn read_state() -> OfferState {
    offer_state_path()
        .ok()
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}
fn write_state(s: &OfferState) -> Result<(), String> {
    let p = offer_state_path()?;
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    std::fs::write(p, serde_json::to_vec_pretty(s).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// `CFBundleShortVersionString` of an installed app, if present.
fn installed_version(app: &Path) -> Option<String> {
    let plist = app.join("Contents/Info.plist");
    let out = std::process::Command::new("/usr/libexec/PlistBuddy")
        .args([
            "-c",
            "Print :CFBundleShortVersionString",
            &plist.to_string_lossy(),
        ])
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

async fn fetch(url: &str) -> Result<Vec<u8>, String> {
    let c = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .https_only(!cfg!(feature = "e2e"))
        .build()
        .map_err(|e| e.to_string())?;
    let r = c.get(url).send().await.map_err(|e| e.to_string())?;
    if !r.status().is_success() {
        return Err(format!("HTTP {}", r.status()));
    }
    Ok(r.bytes().await.map_err(|e| e.to_string())?.to_vec())
}

async fn load_manifest(app: &AppHandle) -> Result<Manifest, String> {
    let (mu, su) = manifest_urls();
    let json = fetch(&mu).await?;
    let sig = String::from_utf8_lossy(&fetch(&su).await?).into_owned();
    parse_signed(&json, &sig, &pubkey(app)).map_err(|e| e.to_string())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckResult {
    /// "show" | "hidden" | "installed"
    pub status: String,
    pub version: Option<String>,
    pub notes: Option<String>,
    pub reason: Option<String>,
}

fn to_check(o: Offer, m: Option<&Manifest>) -> CheckResult {
    match o {
        Offer::Show { version } => CheckResult {
            status: "show".into(),
            version: Some(version),
            notes: m.map(|m| m.notes.clone()),
            reason: None,
        },
        Offer::AlreadyInstalled => CheckResult {
            status: "installed".into(),
            version: m.map(|m| m.version.clone()),
            notes: None,
            reason: None,
        },
        Offer::Hidden(r) => CheckResult {
            status: "hidden".into(),
            version: None,
            notes: None,
            reason: Some(format!("{r:?}")),
        },
    }
}

/// `trigger`: "afterUpdate" | "settings". Network trouble → hidden, never an error toast.
#[tauri::command]
pub async fn switchover_check(app: AppHandle, trigger: String) -> Result<CheckResult, String> {
    let trig = if trigger == "settings" {
        Trigger::Settings
    } else {
        Trigger::AfterUpdate
    };
    let manifest = load_manifest(&app).await;
    if trig == Trigger::Settings {
        if let Err(e) = &manifest {
            return Err(format!("Could not check for the Native beta: {e}"));
        }
    }
    let manifest = manifest.ok();
    let state = read_state();
    let installed = installed_version(&apps_dir().join(NATIVE_APP_NAME));
    let classic = env!("CARGO_PKG_VERSION");
    let input = OfferInput {
        manifest: manifest.as_ref(),
        classic_version: classic,
        installed_native: installed.as_deref(),
        state: &state,
        now_unix: now_unix(),
        trigger: trig,
    };
    Ok(to_check(offer::decide(&input), manifest.as_ref()))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Preflight {
    /// Terminals that die when Muya quits.
    pub pty_live: usize,
    /// Claude agent sessions currently running (can be resumed in Native).
    pub agent_running: usize,
    pub translocated: bool,
}

#[tauri::command(async)]
pub fn switchover_preflight(pty: tauri::State<'_, crate::pty::PtyManager>) -> Preflight {
    let agent_running = crate::agents::list_agent_sessions_sync(Some(true))
        .map(|v| v.iter().filter(|s| s.status != "stopped").count())
        .unwrap_or(0);
    let exe = std::env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    Preflight {
        pty_live: pty.live_count(),
        agent_running,
        translocated: crate::app_location::path_is_translocated(&exe),
    }
}

/// Records the answer ("tryIt" | "notNow" | "dontAsk"). `version` is the offered one.
#[tauri::command]
pub fn switchover_answer(version: String, answer: String) -> Result<(), String> {
    let a = match answer.as_str() {
        "tryIt" => Answer::TryIt,
        "notNow" => Answer::NotNow,
        "dontAsk" => Answer::DontAskAgain,
        other => return Err(format!("unknown answer {other}")),
    };
    write_state(&offer::after_answer(read_state(), &version, a, now_unix()))
}

/// Called once at startup: when Native launched us with `--switched-from=native`
/// (switch back to classic), write the healthy marker it is waiting for.
pub fn ack_switched_launch() {
    if !std::env::args().any(|a| a == "--switched-from=native") {
        return;
    }
    if let Ok(support) = support_dir() {
        let m = muya_switchover::healthy_marker_path(&support);
        if let Some(d) = m.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let _ = std::fs::write(&m, format!("{{\"app\":\"{}\",\"version\":\"{}\"}}", muya_switchover::CLASSIC_BUNDLE_ID, env!("CARGO_PKG_VERSION")));
    }
}

/// e2e builds only (`--features e2e`): with `MUYA_SWITCHOVER_E2E_AUTOSTART=1` run the
/// exact path a click on "Try it" runs (check → answer tryIt → start), because the
/// automated run cannot click in a locked session. Never compiled into releases.
#[cfg(feature = "e2e")]
pub fn e2e_autostart(app: AppHandle) {
    if std::env::var("MUYA_SWITCHOVER_E2E_AUTOSTART").as_deref() != Ok("1") {
        return;
    }
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(5)).await;
        let log = |m: String| {
            if let Ok(h) = home() {
                use std::io::Write;
                if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(h.join("e2e-switchover.log")) {
                    let _ = writeln!(f, "{m}");
                }
            }
        };
        {
            use tauri::Listener;
            let l2 = home().ok();
            app.listen("switchover://error", move |ev| {
                if let Some(h) = &l2 {
                    use std::io::Write;
                    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(h.join("e2e-switchover.log")) {
                        let _ = writeln!(f, "error event: {}", ev.payload());
                    }
                }
            });
        }
        match switchover_check(app.clone(), "afterUpdate".into()).await {
            Ok(r) if r.status == "show" => {
                log(format!("offer shown for {:?}", r.version));
                let _ = switchover_answer(r.version.clone().unwrap_or_default(), "tryIt".into());
                match switchover_start(app.clone()).await {
                    Ok(()) => log("switch started".into()),
                    Err(e) => log(format!("start failed: {e}")),
                }
            }
            Ok(r) => log(format!("no offer: {} {:?}", r.status, r.reason)),
            Err(e) => log(format!("check failed: {e}")),
        }
    });
}

/// The running `.app` bundle (walk up from the executable).
fn current_bundle() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    exe.ancestors()
        .find(|p| p.extension().is_some_and(|e| e == "app"))
        .map(Path::to_path_buf)
        .ok_or_else(|| "Muya is not running from an app bundle".to_string())
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Progress {
    phase: &'static str,
    done: u64,
    total: Option<u64>,
}

/// Download, verify, install Native, then move classic to the Trash and quit.
/// Runs on its own thread; progress/outcome come back as events:
/// `switchover://progress`, `switchover://error` (string), and the app exits on success.
#[tauri::command]
pub async fn switchover_start(app: AppHandle) -> Result<(), String> {
    let manifest = load_manifest(&app).await?;
    let source = current_bundle()?;
    let exe = std::env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    if crate::app_location::path_is_translocated(&exe) {
        return Err("Move Muya to your Applications folder first, then try again.".into());
    }
    let support = support_dir()?;
    let stage = home()?
        .join("Library/Caches/com.staunch.muya/switchover")
        .join(&manifest.version);
    let plan = Plan {
        version: manifest.version.clone(),
        url: manifest.url.clone(),
        sha256: manifest.sha256.clone(),
        stage_dir: stage.clone(),
        target_app: apps_dir().join(NATIVE_APP_NAME),
        source_app: source,
        expected_id: muya_switchover::NATIVE_BUNDLE_ID.into(),
        expected_team: muya_switchover::TEAM_ID.into(),
        launch_args: vec!["--switched-from=classic".into()],
        healthy_timeout: Duration::from_secs(30),
    };
    let handle = app.clone();
    std::thread::spawn(move || {
        let mut plat = SysPlatform {
            state_file: muya_switchover::state_path(&support),
            healthy_marker: muya_switchover::healthy_marker_path(&support),
            trash_fn: Some(Box::new(|p: &Path| {
                crate::history::to_trash_at(p)
            })),
        };
        let h2 = handle.clone();
        let mut progress = move |done: u64, total: Option<u64>| {
            let _ = h2.emit(
                "switchover://progress",
                Progress {
                    phase: "downloading",
                    done,
                    total,
                },
            );
        };
        let _ = handle.emit(
            "switchover://progress",
            Progress {
                phase: "starting",
                done: 0,
                total: None,
            },
        );
        match run_swap(&mut plat, &plan, &mut progress) {
            Ok(_) => {
                let _ = std::fs::remove_dir_all(&stage);
                handle.exit(0);
            }
            Err(e) => {
                let _ = std::fs::remove_dir_all(&stage);
                let _ = handle.emit("switchover://error", e.to_string());
            }
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_map_and_persist_round_trip() {
        let d = tempfile::tempdir().unwrap();
        std::env::set_var("HOME", d.path());
        assert!(switchover_answer("0.1.0".into(), "bogus".into()).is_err());
        switchover_answer("0.1.0".into(), "dontAsk".into()).unwrap();
        let s = read_state();
        assert!(s.dismissed_forever);
        assert_eq!(s.last_offered_version.as_deref(), Some("0.1.0"));
    }

    #[test]
    fn check_result_mapping() {
        let r = to_check(Offer::Hidden(offer::HideReason::ClassicTooOld), None);
        assert_eq!(r.status, "hidden");
        let r = to_check(Offer::AlreadyInstalled, None);
        assert_eq!(r.status, "installed");
    }
}

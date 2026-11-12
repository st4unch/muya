//! The swap state machine. Every platform action is behind [`Platform`] so the
//! ordering and the rollback rules are unit-tested without touching a disk.
//!
//! Order: download → sha256 → unpack → verify → (drop quarantine) → move any
//! existing target to Trash → install → launch → wait healthy → trash the old
//! app. A failure before the healthy handshake rolls back; the old app is
//! never touched until the new one proved itself.

use crate::verify::{check_sha, VerifyError};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Step {
    Downloading,
    Verifying,
    Installing,
    Launching,
    NativeHealthy,
    Done,
    RolledBack,
}

/// Persisted as `switch.json` so a crash mid-way can be resumed or rolled back.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SwitchState {
    pub step: Step,
    pub from_path: String,
    pub to_path: String,
    #[serde(default)]
    pub trashed_previous_target: Option<String>,
    #[serde(default)]
    pub trashed_source: Option<String>,
    #[serde(default)]
    pub version: String,
}

#[derive(Debug, Clone)]
pub struct Plan {
    pub version: String,
    pub url: String,
    pub sha256: String,
    pub stage_dir: PathBuf,
    /// Where the new app goes, e.g. `/Applications/Muya Native.app`.
    pub target_app: PathBuf,
    /// The app being replaced (the one running this code).
    pub source_app: PathBuf,
    pub expected_id: String,
    pub expected_team: String,
    pub launch_args: Vec<String>,
    pub healthy_timeout: Duration,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SwapError {
    Download(String),
    Verify(VerifyError),
    Unpack(String),
    Install(String),
    Launch(String),
    NotHealthy,
    /// The new app is fine but the old one could not be moved to the Trash.
    TrashSource(String),
}

impl std::fmt::Display for SwapError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Download(e) => write!(f, "download failed: {e}"),
            Self::Verify(e) => write!(f, "{e}"),
            Self::Unpack(e) => write!(f, "could not unpack the download: {e}"),
            Self::Install(e) => write!(f, "could not install: {e}"),
            Self::Launch(e) => write!(f, "could not start the new app: {e}"),
            Self::NotHealthy => write!(f, "the new app did not start properly"),
            Self::TrashSource(e) => write!(f, "installed, but could not move the old app to the Trash: {e}"),
        }
    }
}

pub trait Platform {
    fn download(&mut self, url: &str, dest: &Path, progress: &mut dyn FnMut(u64, Option<u64>)) -> Result<(), String>;
    fn sha256(&mut self, path: &Path) -> Result<String, String>;
    fn unpack(&mut self, zip: &Path, dir: &Path) -> Result<PathBuf, String>;
    fn verify_app(&mut self, app: &Path, id: &str, team: &str) -> Result<(), VerifyError>;
    fn drop_quarantine(&mut self, app: &Path) -> Result<(), String>;
    fn exists(&mut self, path: &Path) -> bool;
    /// Move to the Trash; returns where it landed.
    fn trash(&mut self, path: &Path) -> Result<Option<PathBuf>, String>;
    fn restore(&mut self, from: &Path, to: &Path) -> Result<(), String>;
    fn install(&mut self, staged: &Path, dest: &Path) -> Result<(), String>;
    fn launch(&mut self, app: &Path, args: &[String]) -> Result<(), String>;
    fn wait_healthy(&mut self, timeout: Duration) -> bool;
    /// Stop the app we just launched (used on rollback).
    fn terminate(&mut self, app: &Path);
    fn save_state(&mut self, st: &SwitchState);
}

#[derive(Debug, Clone, PartialEq)]
pub struct Outcome {
    pub trashed_source: Option<PathBuf>,
}

/// `progress(downloaded, total)` runs on the caller's (non-UI) thread.
pub fn run_swap(p: &mut dyn Platform, plan: &Plan, progress: &mut dyn FnMut(u64, Option<u64>)) -> Result<Outcome, SwapError> {
    let mut st = SwitchState {
        step: Step::Downloading,
        from_path: plan.source_app.to_string_lossy().into(),
        to_path: plan.target_app.to_string_lossy().into(),
        trashed_previous_target: None,
        trashed_source: None,
        version: plan.version.clone(),
    };
    p.save_state(&st);

    let zip = plan.stage_dir.join("download.zip");
    p.download(&plan.url, &zip, progress).map_err(SwapError::Download)?;

    st.step = Step::Verifying;
    p.save_state(&st);
    let actual = p.sha256(&zip).map_err(SwapError::Download)?;
    check_sha(&actual, &plan.sha256).map_err(SwapError::Verify)?;
    let staged = p.unpack(&zip, &plan.stage_dir.join("unpacked")).map_err(SwapError::Unpack)?;
    p.verify_app(&staged, &plan.expected_id, &plan.expected_team).map_err(SwapError::Verify)?;
    p.drop_quarantine(&staged).map_err(SwapError::Install)?;

    st.step = Step::Installing;
    p.save_state(&st);
    if p.exists(&plan.target_app) {
        let t = p.trash(&plan.target_app).map_err(SwapError::Install)?;
        st.trashed_previous_target = t.map(|t| t.to_string_lossy().into());
        p.save_state(&st);
    }
    let rollback = |p: &mut dyn Platform, st: &mut SwitchState, installed: bool| {
        if installed {
            p.terminate(&plan.target_app);
            let _ = p.trash(&plan.target_app);
        }
        if let Some(prev) = st.trashed_previous_target.clone() {
            let _ = p.restore(Path::new(&prev), &plan.target_app);
        }
        st.step = Step::RolledBack;
        p.save_state(st);
    };
    if let Err(e) = p.install(&staged, &plan.target_app) {
        rollback(p, &mut st, false);
        return Err(SwapError::Install(e));
    }

    st.step = Step::Launching;
    p.save_state(&st);
    if let Err(e) = p.launch(&plan.target_app, &plan.launch_args) {
        rollback(p, &mut st, true);
        return Err(SwapError::Launch(e));
    }
    if !p.wait_healthy(plan.healthy_timeout) {
        rollback(p, &mut st, true);
        return Err(SwapError::NotHealthy);
    }
    st.step = Step::NativeHealthy;
    p.save_state(&st);

    // Only now does the old app go to the Trash.
    match p.trash(&plan.source_app) {
        Ok(t) => {
            st.trashed_source = t.as_ref().map(|t| t.to_string_lossy().into());
            st.step = Step::Done;
            p.save_state(&st);
            Ok(Outcome { trashed_source: t })
        }
        Err(e) => Err(SwapError::TrashSource(e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Fake {
        log: Vec<String>,
        fail: Option<&'static str>,
        sha: String,
        target_exists: bool,
        healthy: bool,
        states: Vec<Step>,
    }
    impl Fake {
        fn f(&self, s: &str) -> Result<(), String> {
            if self.fail == Some(s) { Err(format!("{s} boom")) } else { Ok(()) }
        }
    }
    impl Platform for Fake {
        fn download(&mut self, _u: &str, _d: &Path, pr: &mut dyn FnMut(u64, Option<u64>)) -> Result<(), String> {
            self.log.push("download".into());
            pr(10, Some(10));
            self.f("download")
        }
        fn sha256(&mut self, _p: &Path) -> Result<String, String> {
            self.log.push("sha".into());
            Ok(self.sha.clone())
        }
        fn unpack(&mut self, _z: &Path, d: &Path) -> Result<PathBuf, String> {
            self.log.push("unpack".into());
            self.f("unpack")?;
            Ok(d.join("Muya Native.app"))
        }
        fn verify_app(&mut self, _a: &Path, _i: &str, _t: &str) -> Result<(), VerifyError> {
            self.log.push("verify".into());
            if self.fail == Some("verify") { Err(VerifyError::AdHoc) } else { Ok(()) }
        }
        fn drop_quarantine(&mut self, _a: &Path) -> Result<(), String> {
            self.log.push("quarantine".into());
            Ok(())
        }
        fn exists(&mut self, _p: &Path) -> bool {
            self.target_exists
        }
        fn trash(&mut self, p: &Path) -> Result<Option<PathBuf>, String> {
            self.log.push(format!("trash {}", p.file_name().unwrap().to_string_lossy()));
            if self.fail == Some("trash_source") && p.ends_with("Classic.app") { return Err("trash boom".into()); }
            Ok(Some(PathBuf::from("/Trash").join(p.file_name().unwrap())))
        }
        fn restore(&mut self, _f: &Path, _t: &Path) -> Result<(), String> {
            self.log.push("restore".into());
            Ok(())
        }
        fn install(&mut self, _s: &Path, _d: &Path) -> Result<(), String> {
            self.log.push("install".into());
            self.f("install")
        }
        fn launch(&mut self, _a: &Path, _g: &[String]) -> Result<(), String> {
            self.log.push("launch".into());
            self.f("launch")
        }
        fn wait_healthy(&mut self, _t: Duration) -> bool {
            self.log.push("wait".into());
            self.healthy
        }
        fn terminate(&mut self, _a: &Path) {
            self.log.push("terminate".into());
        }
        fn save_state(&mut self, st: &SwitchState) {
            self.states.push(st.step.clone());
        }
    }

    fn plan() -> Plan {
        Plan {
            version: "0.1.0".into(),
            url: "https://github.com/x".into(),
            sha256: "abc".into(),
            stage_dir: "/stage".into(),
            target_app: "/Applications/Muya Native.app".into(),
            source_app: "/Applications/Classic.app".into(),
            expected_id: "com.staunch.muya.native".into(),
            expected_team: "7PG95YYJ64".into(),
            launch_args: vec!["--switched-from=classic".into()],
            healthy_timeout: Duration::from_secs(1),
        }
    }
    fn fake() -> Fake {
        Fake { sha: "abc".into(), healthy: true, ..Default::default() }
    }
    fn touched_source(f: &Fake) -> bool {
        f.log.iter().any(|l| l == "trash Classic.app")
    }

    #[test]
    fn happy_path_order_and_source_trashed_last() {
        let mut f = fake();
        let out = run_swap(&mut f, &plan(), &mut |_, _| {}).unwrap();
        assert_eq!(f.log, ["download", "sha", "unpack", "verify", "quarantine", "install", "launch", "wait", "trash Classic.app"]);
        assert_eq!(out.trashed_source, Some(PathBuf::from("/Trash/Classic.app")));
        assert_eq!(f.states.last(), Some(&Step::Done));
    }
    #[test]
    fn bad_sha_stops_before_unpack() {
        let mut f = fake();
        f.sha = "zzz".into();
        let e = run_swap(&mut f, &plan(), &mut |_, _| {}).unwrap_err();
        assert!(matches!(e, SwapError::Verify(VerifyError::ShaMismatch { .. })));
        assert_eq!(f.log, ["download", "sha"]);
        assert!(!touched_source(&f));
    }
    #[test]
    fn failed_verify_installs_nothing() {
        let mut f = fake();
        f.fail = Some("verify");
        let e = run_swap(&mut f, &plan(), &mut |_, _| {}).unwrap_err();
        assert_eq!(e, SwapError::Verify(VerifyError::AdHoc));
        assert!(!f.log.contains(&"install".to_string()));
        assert!(!touched_source(&f));
    }
    #[test]
    fn download_failure_touches_nothing() {
        let mut f = fake();
        f.fail = Some("download");
        assert!(matches!(run_swap(&mut f, &plan(), &mut |_, _| {}), Err(SwapError::Download(_))));
        assert_eq!(f.log, ["download"]);
    }
    #[test]
    fn unhealthy_rolls_back_and_keeps_source() {
        let mut f = fake();
        f.healthy = false;
        f.target_exists = true;
        let e = run_swap(&mut f, &plan(), &mut |_, _| {}).unwrap_err();
        assert_eq!(e, SwapError::NotHealthy);
        assert!(!touched_source(&f));
        let tail: Vec<_> = f.log.iter().rev().take(3).rev().cloned().collect();
        assert_eq!(tail, ["terminate", "trash Muya Native.app", "restore"]);
        assert_eq!(f.states.last(), Some(&Step::RolledBack));
    }
    #[test]
    fn launch_failure_rolls_back() {
        let mut f = fake();
        f.fail = Some("launch");
        assert!(matches!(run_swap(&mut f, &plan(), &mut |_, _| {}), Err(SwapError::Launch(_))));
        assert!(!touched_source(&f));
        assert_eq!(f.states.last(), Some(&Step::RolledBack));
    }
    #[test]
    fn install_failure_restores_previous_target() {
        let mut f = fake();
        f.fail = Some("install");
        f.target_exists = true;
        assert!(matches!(run_swap(&mut f, &plan(), &mut |_, _| {}), Err(SwapError::Install(_))));
        assert!(f.log.contains(&"restore".to_string()));
        assert!(!f.log.contains(&"launch".to_string()));
    }
    #[test]
    fn trash_source_failure_is_reported_not_silent() {
        let mut f = fake();
        f.fail = Some("trash_source");
        assert!(matches!(run_swap(&mut f, &plan(), &mut |_, _| {}), Err(SwapError::TrashSource(_))));
    }
}

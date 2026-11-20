//! The launchd jobs that belong to a Muya bundle, and how a swap cleans them up.
//!
//! A swap replaces a bundle, but launchd keeps the jobs it loaded from the old one. A job whose `BundleProgram` no longer
//! exists fails and is retried for ever; a job that runs a binary from the Trash is an orphan. Both are avoided by booting
//! the old jobs out at the right moment. The commands are built here (pure, tested); running them is the caller's choice.

use std::process::Command;

/// The two background services of the Native app (their labels carry no `.native`: the new bundle reuses them).
pub const SERVICE_LABELS: [&str; 2] = ["com.staunch.muya.muyad", "com.staunch.muya.ptyd"];
/// Classic's scheduler agent (`muya --scheduler`). Muya 5 does not ship it; a job left over from classic is booted out.
pub const CLASSIC_SCHEDULER_LABEL: &str = "com.staunch.muya.scheduler";

/// Labels in this build: the production list, or (feature `e2e`) `MUYA_SWITCHOVER_E2E_LABELS` (comma separated),
/// so a test never touches the real jobs.
pub fn service_labels() -> Vec<String> {
    #[cfg(feature = "e2e")]
    if let Ok(v) = std::env::var("MUYA_SWITCHOVER_E2E_LABELS") {
        let l: Vec<String> = v
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(String::from)
            .collect();
        if !l.is_empty() {
            return l;
        }
    }
    SERVICE_LABELS.iter().map(|s| s.to_string()).collect()
}

/// A launchd label is dotted ASCII; refuse anything that could carry shell syntax.
pub fn label_is_safe(l: &str) -> bool {
    !l.is_empty()
        && l.len() <= 120
        && l.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
}

pub fn bootout_argv(uid: u32, label: &str) -> Vec<String> {
    vec![
        "launchctl".into(),
        "bootout".into(),
        format!("gui/{uid}/{label}"),
    ]
}

pub fn print_argv(uid: u32, label: &str) -> Vec<String> {
    vec![
        "launchctl".into(),
        "print".into(),
        format!("gui/{uid}/{label}"),
    ]
}

/// A `sh` script that waits `delay_secs`, then boots every label out (failures ignored: an unknown job is already gone).
pub fn handover_script(uid: u32, labels: &[String], delay_secs: u32) -> Result<String, String> {
    if let Some(bad) = labels.iter().find(|l| !label_is_safe(l)) {
        return Err(format!("refusing launchd label '{bad}'"));
    }
    let mut s = format!("sleep {delay_secs}\n");
    for l in labels {
        s.push_str(&format!(
            "/bin/launchctl bootout gui/{uid}/{l} >/dev/null 2>&1\n"
        ));
    }
    Ok(s)
}

/// Runs `script` in its own session, so booting out the job that runs the caller does not take the script with it.
pub fn spawn_detached(script: &str) -> std::io::Result<()> {
    use std::os::unix::process::CommandExt;
    let mut c = Command::new("/bin/sh");
    c.arg("-c")
        .arg(script)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    // SAFETY: setsid() is async-signal-safe and touches no memory.
    unsafe {
        c.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    c.spawn().map(|_| ())
}

/// Does launchd list the job (`launchctl print` succeeds)? `None` when launchctl cannot be run.
pub fn job_loaded(uid: u32, label: &str) -> Option<bool> {
    if !label_is_safe(label) {
        return None;
    }
    let a = print_argv(uid, label);
    let out = Command::new(&a[0]).args(&a[1..]).output().ok()?;
    Some(out.status.success())
}

/// Boots one job out now (blocking). Returns whether launchctl reported success.
pub fn bootout_now(uid: u32, label: &str) -> bool {
    if !label_is_safe(label) {
        return false;
    }
    let a = bootout_argv(uid, label);
    Command::new(&a[0])
        .args(&a[1..])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

pub fn current_uid() -> u32 {
    unsafe { libc::getuid() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn argv_names_the_gui_domain_and_the_label() {
        assert_eq!(
            bootout_argv(501, "com.staunch.muya.muyad"),
            ["launchctl", "bootout", "gui/501/com.staunch.muya.muyad"]
        );
        assert_eq!(
            print_argv(501, "x.y"),
            ["launchctl", "print", "gui/501/x.y"]
        );
    }

    #[test]
    fn the_production_labels_are_the_two_services_and_never_the_scheduler() {
        assert_eq!(
            service_labels(),
            ["com.staunch.muya.muyad", "com.staunch.muya.ptyd"]
        );
        assert!(!service_labels()
            .iter()
            .any(|l| l == CLASSIC_SCHEDULER_LABEL));
    }

    #[test]
    fn the_handover_script_waits_then_boots_each_label_out() {
        let s = handover_script(501, &service_labels(), 2).unwrap();
        assert!(s.starts_with("sleep 2\n"));
        assert!(
            s.contains("launchctl bootout gui/501/com.staunch.muya.ptyd")
                && s.contains("launchctl bootout gui/501/com.staunch.muya.muyad")
        );
    }

    #[test]
    fn a_label_with_shell_syntax_is_refused() {
        assert!(handover_script(501, &["a; rm -rf ~".to_string()], 1).is_err());
        assert!(handover_script(501, &["a b".to_string()], 1).is_err());
        assert!(
            !label_is_safe("")
                && !label_is_safe("$(x)")
                && label_is_safe("com.staunch.muya.e2e.muyad")
        );
        assert_eq!(job_loaded(501, "a;b"), None);
        assert!(!bootout_now(501, "a;b"));
    }

    #[test]
    fn a_detached_script_survives_and_runs() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("done");
        spawn_detached(&format!("sleep 0.2; touch '{}'", f.display())).unwrap();
        for _ in 0..30 {
            if f.exists() {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        panic!("detached script did not run");
    }

    #[test]
    fn an_unknown_job_is_reported_as_not_loaded() {
        assert_eq!(
            job_loaded(current_uid(), "com.staunch.muya.e2e.surely-not-loaded"),
            Some(false)
        );
    }
}

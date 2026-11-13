//! The real [`Platform`]: curl, ditto, xattr, open. Shared by classic and Native.
//! Trashing is injectable so each app can use its own recoverable-Trash call;
//! the default moves the bundle into `~/.Trash` (never deletes).

use crate::swap::{Platform, SwitchState};
use crate::verify::{sha256_file, SystemRunner, VerifyError};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

pub type TrashFn = Box<dyn Fn(&Path) -> Result<Option<PathBuf>, String> + Send>;

pub struct SysPlatform {
    /// Where `switch.json` lives.
    pub state_file: PathBuf,
    /// The new app writes this when it is up; we delete it before launching.
    pub healthy_marker: PathBuf,
    pub trash_fn: Option<TrashFn>,
}

/// Fallback Trash: move into `~/.Trash` with a collision-free name.
pub fn move_to_home_trash(p: &Path) -> Result<Option<PathBuf>, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME is not set".to_string())?;
    let trash = PathBuf::from(home).join(".Trash");
    std::fs::create_dir_all(&trash).map_err(|e| e.to_string())?;
    let name = p.file_name().ok_or("no file name")?.to_string_lossy().into_owned();
    let mut dest = trash.join(&name);
    let mut n = 1;
    while dest.exists() {
        let stem = name.trim_end_matches(".app");
        dest = trash.join(format!("{stem} {n}.app"));
        n += 1;
    }
    std::fs::rename(p, &dest).map_err(|e| {
        let raw = format!("could not move {} to the Trash: {e}", p.display());
        crate::target::explain_denied(p, &raw, crate::target::Op::ChangeApp)
    })?;
    Ok(Some(dest))
}

/// gzip magic bytes: the download is a tarball, not a zip.
fn is_gzip(p: &Path) -> bool {
    use std::io::Read;
    let mut b = [0u8; 2];
    std::fs::File::open(p).and_then(|mut f| f.read_exact(&mut b)).is_ok() && b == [0x1f, 0x8b]
}

fn run(prog: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(prog).args(args).output().map_err(|e| format!("{prog}: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!("{prog} failed: {}", String::from_utf8_lossy(&out.stderr).trim()))
    }
}

impl Platform for SysPlatform {
    fn download(&mut self, url: &str, dest: &Path, progress: &mut dyn FnMut(u64, Option<u64>)) -> Result<(), String> {
        if let Some(d) = dest.parent() {
            std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
        }
        let _ = std::fs::remove_file(dest);
        // https only, redirects only to https (GitHub -> objects.githubusercontent.com).
        let mut args: Vec<String> = vec!["-fsSL".into(), "--connect-timeout".into(), "15".into(), "--max-time".into(), "900".into(), "-o".into(), dest.to_string_lossy().into(), url.into()];
        if url.starts_with("https://") {
            let mut p = vec!["--proto".to_string(), "=https".into(), "--proto-redir".into(), "=https".into()];
            p.append(&mut args);
            args = p;
        }
        let mut child = Command::new("curl").args(&args).stderr(std::process::Stdio::piped()).spawn().map_err(|e| format!("curl: {e}"))?;
        loop {
            match child.try_wait().map_err(|e| e.to_string())? {
                Some(status) => {
                    if !status.success() {
                        let _ = std::fs::remove_file(dest);
                        let mut err = String::new();
                        if let Some(mut s) = child.stderr.take() {
                            use std::io::Read;
                            let _ = s.read_to_string(&mut err);
                        }
                        return Err(format!("network error: {}", err.trim()));
                    }
                    let n = std::fs::metadata(dest).map(|m| m.len()).unwrap_or(0);
                    progress(n, Some(n));
                    return Ok(());
                }
                None => {
                    let n = std::fs::metadata(dest).map(|m| m.len()).unwrap_or(0);
                    progress(n, None);
                    std::thread::sleep(Duration::from_millis(200));
                }
            }
        }
    }
    fn sha256(&mut self, path: &Path) -> Result<String, String> {
        sha256_file(path).map_err(|e| e.to_string())
    }
    fn unpack(&mut self, zip: &Path, dir: &Path) -> Result<PathBuf, String> {
        let _ = std::fs::remove_dir_all(dir);
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        if is_gzip(zip) {
            // Classic's Tauri updater archive (.app.tar.gz).
            run("tar", &["-xzf", &zip.to_string_lossy(), "-C", &dir.to_string_lossy()])?;
        } else {
            run("ditto", &["-x", "-k", &zip.to_string_lossy(), &dir.to_string_lossy()])?;
        }
        for e in std::fs::read_dir(dir).map_err(|e| e.to_string())? {
            let p = e.map_err(|e| e.to_string())?.path();
            if p.extension().is_some_and(|x| x == "app") {
                return Ok(p);
            }
        }
        Err("the download contains no app".into())
    }
    fn verify_app(&mut self, app: &Path, id: &str, team: &str) -> Result<(), VerifyError> {
        crate::verify::verify_app(&SystemRunner, app, id, team)
    }
    fn drop_quarantine(&mut self, app: &Path) -> Result<(), String> {
        // Missing attribute is not an error.
        let _ = Command::new("xattr").args(["-dr", "com.apple.quarantine", &app.to_string_lossy()]).output();
        Ok(())
    }
    fn exists(&mut self, path: &Path) -> bool {
        path.exists()
    }
    fn trash(&mut self, path: &Path) -> Result<Option<PathBuf>, String> {
        let r = match &self.trash_fn {
            Some(f) => f(path),
            None => move_to_home_trash(path),
        };
        r.map_err(|e| crate::target::explain_denied(path, &e, crate::target::Op::ChangeApp))
    }
    fn restore(&mut self, from: &Path, to: &Path) -> Result<(), String> {
        std::fs::rename(from, to).map_err(|e| e.to_string())
    }
    fn install(&mut self, staged: &Path, dest: &Path) -> Result<(), String> {
        if std::fs::rename(staged, dest).is_ok() {
            return Ok(());
        }
        // Different volume: copy with ditto (keeps the signature), then clean up.
        if let Err(e) = run("ditto", &[&staged.to_string_lossy(), &dest.to_string_lossy()]) {
            // A failed copy must not leave a half-written bundle at the target: the caller puts the old app back there.
            let _ = std::fs::remove_dir_all(dest);
            return Err(crate::target::explain_denied(dest, &e, crate::target::Op::ChangeApp));
        }
        let _ = std::fs::remove_dir_all(staged);
        Ok(())
    }
    fn check_target(&mut self, target: &Path) -> Result<(), String> {
        crate::target::check_folder_writable(target)
    }
    fn launch(&mut self, app: &Path, args: &[String]) -> Result<(), String> {
        let _ = std::fs::remove_file(&self.healthy_marker);
        let mut c = Command::new("open");
        c.arg("-n");
        // Test runs only (MUYA_SWITCHOVER_PASS_ENV set): `open` starts the app from launchd, which would otherwise hand
        // it the REAL home. Pass the synthetic user's environment through explicitly.
        if std::env::var_os("MUYA_SWITCHOVER_PASS_ENV").is_some() {
            for k in ["HOME", "PATH"] {
                if let Ok(v) = std::env::var(k) {
                    c.arg("--env").arg(format!("{k}={v}"));
                }
            }
        }
        c.arg(app);
        if !args.is_empty() {
            c.arg("--args").args(args);
        }
        let out = c.output().map_err(|e| format!("open: {e}"))?;
        if out.status.success() { Ok(()) } else { Err(String::from_utf8_lossy(&out.stderr).trim().to_string()) }
    }
    fn wait_healthy(&mut self, timeout: Duration) -> bool {
        let t0 = Instant::now();
        while t0.elapsed() < timeout {
            if self.healthy_marker.exists() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        false
    }
    fn terminate(&mut self, app: &Path) {
        let pat = format!("{}/Contents/MacOS/", app.display());
        let _ = Command::new("pkill").args(["-f", &pat]).output();
    }
    fn terminate_launched(&mut self, app: &Path) {
        // Only the new bundle's main executable (its CFBundleExecutable), not a prefix match: the old app that used to
        // live under this very path keeps running with a command line that starts with the same directory.
        let Ok(exe) = run("/usr/libexec/PlistBuddy", &["-c", "Print :CFBundleExecutable", &app.join("Contents/Info.plist").to_string_lossy()]) else { return };
        let pat = format!("{}/Contents/MacOS/{}( |$)", app.display(), exe.trim());
        let _ = Command::new("pkill").args(["-f", &pat]).output();
    }
    fn save_state(&mut self, st: &SwitchState) {
        if let Some(d) = self.state_file.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        if let Ok(j) = serde_json::to_vec_pretty(st) {
            let tmp = self.state_file.with_extension("json.tmp");
            if std::fs::write(&tmp, j).is_ok() {
                let _ = std::fs::rename(&tmp, &self.state_file);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_trash_moves_never_deletes_and_avoids_collisions() {
        let home = tempfile::tempdir().unwrap();
        // HOME is process-global; this is the only test touching it.
        std::env::set_var("HOME", home.path());
        let src = tempfile::tempdir().unwrap();
        let mut landed = vec![];
        for _ in 0..2 {
            let app = src.path().join("Muya.app");
            std::fs::create_dir_all(app.join("Contents")).unwrap();
            std::fs::write(app.join("Contents/x"), b"1").unwrap();
            landed.push(move_to_home_trash(&app).unwrap().unwrap());
            assert!(!app.exists());
        }
        assert_ne!(landed[0], landed[1]);
        assert!(landed[0].join("Contents/x").exists() && landed[1].join("Contents/x").exists());
    }

    #[test]
    fn unpack_accepts_tar_gz_and_zip() {
        let d = tempfile::tempdir().unwrap();
        let app = d.path().join("src/Muya.app/Contents");
        std::fs::create_dir_all(&app).unwrap();
        std::fs::write(app.join("x"), b"1").unwrap();
        let mut p = SysPlatform { state_file: d.path().join("s.json"), healthy_marker: d.path().join("h"), trash_fn: None };
        let tgz = d.path().join("a.tar.gz");
        assert!(Command::new("tar").args(["-czf"]).arg(&tgz).args(["-C"]).arg(d.path().join("src")).arg("Muya.app").status().unwrap().success());
        assert!(is_gzip(&tgz));
        let out = p.unpack(&tgz, &d.path().join("o1")).unwrap();
        assert!(out.join("Contents/x").exists());
        let zip = d.path().join("a.zip");
        assert!(Command::new("ditto").args(["-c", "-k", "--keepParent"]).arg(d.path().join("src/Muya.app")).arg(&zip).status().unwrap().success());
        assert!(!is_gzip(&zip));
        assert!(p.unpack(&zip, &d.path().join("o2")).unwrap().join("Contents/x").exists());
    }

    #[test]
    fn download_failure_is_an_error_and_leaves_no_file() {
        let d = tempfile::tempdir().unwrap();
        let mut p = SysPlatform { state_file: d.path().join("s.json"), healthy_marker: d.path().join("h"), trash_fn: None };
        let dest = d.path().join("a.zip");
        let r = p.download("http://127.0.0.1:1/none.zip", &dest, &mut |_, _| {});
        assert!(r.is_err());
        assert!(!dest.exists());
    }

    #[test]
    fn healthy_marker_wait() {
        let d = tempfile::tempdir().unwrap();
        let mut p = SysPlatform { state_file: d.path().join("s.json"), healthy_marker: d.path().join("h"), trash_fn: None };
        assert!(!p.wait_healthy(Duration::from_millis(300)));
        std::fs::write(d.path().join("h"), b"{}").unwrap();
        assert!(p.wait_healthy(Duration::from_millis(300)));
    }

    /// The real platform on a real folder: an install that fails after the old app went to the Trash puts the old
    /// app straight back, byte for byte, and leaves no half-written bundle at the target.
    #[test]
    fn failed_install_restores_the_old_app_in_its_own_folder_under_its_own_name() {
        use crate::swap::{run_swap, Plan, SwapError};
        use crate::verify::VerifyError;
        struct Scripted(SysPlatform);
        impl Platform for Scripted {
            fn download(&mut self, _u: &str, _d: &Path, _p: &mut dyn FnMut(u64, Option<u64>)) -> Result<(), String> { Ok(()) }
            fn sha256(&mut self, _p: &Path) -> Result<String, String> { Ok("abc".into()) }
            // A staged app that does not exist: rename and ditto both fail, like a copy that dies half way.
            fn unpack(&mut self, _z: &Path, d: &Path) -> Result<PathBuf, String> { Ok(d.join("gone/Muya Native.app")) }
            fn verify_app(&mut self, _a: &Path, _i: &str, _t: &str) -> Result<(), VerifyError> { Ok(()) }
            fn drop_quarantine(&mut self, _a: &Path) -> Result<(), String> { Ok(()) }
            fn exists(&mut self, p: &Path) -> bool { self.0.exists(p) }
            fn trash(&mut self, p: &Path) -> Result<Option<PathBuf>, String> { self.0.trash(p) }
            fn restore(&mut self, f: &Path, t: &Path) -> Result<(), String> { self.0.restore(f, t) }
            fn install(&mut self, s: &Path, d: &Path) -> Result<(), String> { self.0.install(s, d) }
            fn launch(&mut self, _a: &Path, _g: &[String]) -> Result<(), String> { panic!("must not launch") }
            fn wait_healthy(&mut self, _t: Duration) -> bool { false }
            fn terminate(&mut self, _a: &Path) {}
            fn save_state(&mut self, st: &crate::swap::SwitchState) { self.0.save_state(st) }
            fn check_target(&mut self, t: &Path) -> Result<(), String> { self.0.check_target(t) }
        }
        let d = tempfile::tempdir().unwrap();
        let home = d.path().join("home");
        std::fs::create_dir_all(home.join(".Trash")).unwrap();
        let desktop = d.path().join("Desktop");
        let app = desktop.join("Muya Native Yeni.app");
        std::fs::create_dir_all(app.join("Contents")).unwrap();
        std::fs::write(app.join("Contents/marker"), b"old build").unwrap();
        let tmp = d.path().to_path_buf();
        let trash_dir = home.join(".Trash");
        let mut p = Scripted(SysPlatform {
            state_file: d.path().join("s.json"),
            healthy_marker: d.path().join("h"),
            trash_fn: Some(Box::new(move |p: &Path| {
                let dest = trash_dir.join(p.file_name().unwrap());
                std::fs::rename(p, &dest).map_err(|e| e.to_string())?;
                let _ = &tmp;
                Ok(Some(dest))
            })),
        });
        let plan = Plan {
            version: "9.9.9".into(),
            url: "https://github.com/x".into(),
            sha256: "abc".into(),
            stage_dir: d.path().join("stage"),
            target_app: app.clone(),
            source_app: app.clone(),
            expected_id: "x".into(),
            expected_team: "x".into(),
            launch_args: vec![],
            healthy_timeout: Duration::from_millis(10),
        };
        let e = run_swap(&mut p, &plan, &mut |_, _| {}).unwrap_err();
        assert!(matches!(e, SwapError::Install(_)), "{e:?}");
        assert_eq!(std::fs::read(app.join("Contents/marker")).unwrap(), b"old build", "the old app is back, same place, same name");
        let names: Vec<_> = std::fs::read_dir(&desktop).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        assert_eq!(names, ["Muya Native Yeni.app"], "no partial copy or probe file left in the folder");
        assert_eq!(std::fs::read_dir(home.join(".Trash")).unwrap().count(), 0, "nothing is left in the Trash");
    }
}

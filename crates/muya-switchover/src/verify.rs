//! Verifying a downloaded zip and an unpacked app BEFORE anything is touched.

use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::Path;

#[derive(Debug, Clone, PartialEq)]
pub enum VerifyError {
    Io(String),
    ShaMismatch { expected: String, actual: String },
    CodesignFailed(String),
    WrongIdentifier { expected: String, actual: String },
    WrongTeam { expected: String, actual: Option<String> },
    AdHoc,
    GatekeeperRejected(String),
    NotNotarized(String),
}

impl std::fmt::Display for VerifyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "could not read the download: {e}"),
            Self::ShaMismatch { .. } => write!(f, "the download is damaged (checksum mismatch)"),
            Self::CodesignFailed(e) => write!(f, "the app's signature is invalid: {e}"),
            Self::WrongIdentifier { expected, actual } => write!(f, "wrong app identity (expected {expected}, got {actual})"),
            Self::WrongTeam { .. } => write!(f, "the app is not signed by the Muya developer"),
            Self::AdHoc => write!(f, "the app is not properly signed (ad-hoc)"),
            Self::GatekeeperRejected(e) => write!(f, "macOS would not accept the app: {e}"),
            Self::NotNotarized(e) => write!(f, "the app is not notarized: {e}"),
        }
    }
}

pub fn sha256_file(path: &Path) -> Result<String, VerifyError> {
    let mut f = std::fs::File::open(path).map_err(|e| VerifyError::Io(e.to_string()))?;
    let mut h = Sha256::new();
    let mut buf = [0u8; 1 << 16];
    loop {
        let n = f.read(&mut buf).map_err(|e| VerifyError::Io(e.to_string()))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

pub fn check_sha(actual: &str, expected: &str) -> Result<(), VerifyError> {
    if actual.eq_ignore_ascii_case(expected) {
        Ok(())
    } else {
        Err(VerifyError::ShaMismatch { expected: expected.into(), actual: actual.into() })
    }
}

/// Runs an external tool. Real impl shells out; tests feed canned output.
pub trait CmdRunner {
    /// Returns (exit code, stdout+stderr).
    fn run(&self, prog: &str, args: &[&str]) -> Result<(i32, String), String>;
}

pub struct SystemRunner;
impl CmdRunner for SystemRunner {
    fn run(&self, prog: &str, args: &[&str]) -> Result<(i32, String), String> {
        let out = std::process::Command::new(prog).args(args).output().map_err(|e| format!("{prog}: {e}"))?;
        let mut s = String::from_utf8_lossy(&out.stdout).into_owned();
        s.push_str(&String::from_utf8_lossy(&out.stderr));
        Ok((out.status.code().unwrap_or(-1), s))
    }
}

/// Pull `Identifier=`, `TeamIdentifier=` and `Signature=adhoc` out of `codesign -dvv`.
pub fn parse_codesign(out: &str) -> (Option<String>, Option<String>, bool) {
    let mut id = None;
    let mut team = None;
    let mut adhoc = false;
    for line in out.lines() {
        if let Some(v) = line.strip_prefix("Identifier=") {
            id = Some(v.trim().to_string());
        } else if let Some(v) = line.strip_prefix("TeamIdentifier=") {
            let v = v.trim();
            if v != "not set" {
                team = Some(v.to_string());
            }
        } else if line.trim() == "Signature=adhoc" {
            adhoc = true;
        }
    }
    (id, team, adhoc)
}

/// Full app check. `expected_id` is a compiled-in constant, `expected_team` too.
pub fn verify_app(
    run: &dyn CmdRunner,
    app: &Path,
    expected_id: &str,
    expected_team: &str,
) -> Result<(), VerifyError> {
    let p = app.to_string_lossy();
    // 1. Seal intact, nested code too.
    let (code, out) = run.run("codesign", &["--verify", "--deep", "--strict", &p]).map_err(VerifyError::CodesignFailed)?;
    if code != 0 {
        return Err(VerifyError::CodesignFailed(out.trim().to_string()));
    }
    // 2. Who signed it.
    let (_, out) = run.run("codesign", &["-dvv", &p]).map_err(VerifyError::CodesignFailed)?;
    let (id, team, adhoc) = parse_codesign(&out);
    if adhoc {
        return Err(VerifyError::AdHoc);
    }
    let id = id.unwrap_or_default();
    if id != expected_id {
        return Err(VerifyError::WrongIdentifier { expected: expected_id.into(), actual: id });
    }
    if team.as_deref() != Some(expected_team) {
        return Err(VerifyError::WrongTeam { expected: expected_team.into(), actual: team });
    }
    // 3. Gatekeeper + notarization.
    let (code, out) = run.run("spctl", &["-a", "-t", "exec", "-vv", &p]).map_err(VerifyError::GatekeeperRejected)?;
    if code != 0 || !out.contains("accepted") {
        return Err(VerifyError::GatekeeperRejected(out.trim().to_string()));
    }
    if !out.contains("Notarized Developer ID") {
        return Err(VerifyError::NotNotarized(out.trim().to_string()));
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod fake {
    use super::*;
    use std::cell::RefCell;
    pub struct Canned(pub RefCell<Vec<(i32, String)>>);
    impl CmdRunner for Canned {
        fn run(&self, _p: &str, _a: &[&str]) -> Result<(i32, String), String> {
            let mut v = self.0.borrow_mut();
            Ok(v.remove(0))
        }
    }
    pub fn canned(items: &[(i32, &str)]) -> Canned {
        Canned(RefCell::new(items.iter().map(|(c, s)| (*c, s.to_string())).collect()))
    }
}

#[cfg(test)]
mod tests {
    use super::fake::canned;
    use super::*;

    const GOOD_DV: &str = "Identifier=com.staunch.muya.native\nTeamIdentifier=7PG95YYJ64\nSignature size=9000\n";
    const GOOD_SPCTL: &str = "/x/Muya Native.app: accepted\nsource=Notarized Developer ID\n";

    #[test]
    fn good_app_passes() {
        let r = canned(&[(0, ""), (0, GOOD_DV), (0, GOOD_SPCTL)]);
        assert_eq!(verify_app(&r, Path::new("/x"), "com.staunch.muya.native", "7PG95YYJ64"), Ok(()));
    }
    #[test]
    fn broken_seal_fails() {
        let r = canned(&[(1, "a sealed resource is missing or invalid")]);
        assert!(matches!(verify_app(&r, Path::new("/x"), "com.staunch.muya.native", "7PG95YYJ64"), Err(VerifyError::CodesignFailed(_))));
    }
    #[test]
    fn adhoc_fails() {
        let r = canned(&[(0, ""), (0, "Identifier=com.staunch.muya.native\nSignature=adhoc\nTeamIdentifier=not set\n")]);
        assert_eq!(verify_app(&r, Path::new("/x"), "com.staunch.muya.native", "7PG95YYJ64"), Err(VerifyError::AdHoc));
    }
    #[test]
    fn wrong_team_fails() {
        let r = canned(&[(0, ""), (0, "Identifier=com.staunch.muya.native\nTeamIdentifier=EVIL000000\n")]);
        assert!(matches!(verify_app(&r, Path::new("/x"), "com.staunch.muya.native", "7PG95YYJ64"), Err(VerifyError::WrongTeam { .. })));
    }
    #[test]
    fn wrong_identifier_fails() {
        let r = canned(&[(0, ""), (0, "Identifier=com.evil.app\nTeamIdentifier=7PG95YYJ64\n")]);
        assert!(matches!(verify_app(&r, Path::new("/x"), "com.staunch.muya.native", "7PG95YYJ64"), Err(VerifyError::WrongIdentifier { .. })));
    }
    #[test]
    fn spctl_rejected_fails() {
        let r = canned(&[(0, ""), (0, GOOD_DV), (3, "rejected\nsource=no usable signature")]);
        assert!(matches!(verify_app(&r, Path::new("/x"), "com.staunch.muya.native", "7PG95YYJ64"), Err(VerifyError::GatekeeperRejected(_))));
    }
    #[test]
    fn not_notarized_fails() {
        let r = canned(&[(0, ""), (0, GOOD_DV), (0, "accepted\nsource=Developer ID")]);
        assert!(matches!(verify_app(&r, Path::new("/x"), "com.staunch.muya.native", "7PG95YYJ64"), Err(VerifyError::NotNotarized(_))));
    }
    #[test]
    fn sha_check() {
        assert!(check_sha("ABC", "abc").is_ok());
        assert!(matches!(check_sha("a", "b"), Err(VerifyError::ShaMismatch { .. })));
    }
    #[test]
    fn sha_file() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("f");
        std::fs::write(&p, b"hello").unwrap();
        assert_eq!(sha256_file(&p).unwrap(), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    }
}

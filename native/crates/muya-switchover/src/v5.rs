//! Muya 5: the app that replaces classic in place keeps classic's identity (docs/prd-muya-v5-replace.md).
//!
//! Three questions are answered here, all pure and unit-tested:
//! - which kind of Muya is this bundle (the release app, a legacy `.native` beta/bridge app, or something else),
//! - where does an update of it go (the same bundle; a legacy app moves to `Muya.app` in the same folder),
//! - what is the pinned classic build "Return to Muya Classic" installs.

use crate::manifest::{is_sha256_hex, url_allowed};
use std::path::{Path, PathBuf};

/// The release app's bundle id: the one classic has always had (its designated requirement is built from it).
pub const RELEASE_ID: &str = crate::CLASSIC_BUNDLE_ID;
/// The beta / bridge app's id. Already-published beta apps only accept this id from their own updater.
pub const LEGACY_ID: &str = crate::NATIVE_BUNDLE_ID;
/// File name a legacy app takes when it moves to Muya 5.
pub const RELEASE_APP_FILE: &str = "Muya.app";

/// The ids this process treats as "release" and "legacy". Production: the constants. An e2e build (cargo feature `e2e`,
/// never shipped) can name throwaway ids through the environment so a test never uses the real one.
#[derive(Debug, Clone, PartialEq)]
pub struct Ids {
    pub release: String,
    pub legacy: String,
}

impl Ids {
    pub fn production() -> Self {
        Ids {
            release: RELEASE_ID.into(),
            legacy: LEGACY_ID.into(),
        }
    }
}

/// Production ids, or (feature `e2e`) the test ids from `MUYA_SWITCHOVER_E2E_RELEASE_ID` / `..._LEGACY_ID`.
pub fn ids() -> Ids {
    #[cfg(feature = "e2e")]
    if let (Ok(r), Ok(l)) = (
        std::env::var("MUYA_SWITCHOVER_E2E_RELEASE_ID"),
        std::env::var("MUYA_SWITCHOVER_E2E_LEGACY_ID"),
    ) {
        if !r.is_empty() && !l.is_empty() {
            return Ids {
                release: r,
                legacy: l,
            };
        }
    }
    Ids::production()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// `com.staunch.muya`: the Muya 5 app (and classic).
    Release,
    /// `com.staunch.muya.native`: the beta / bridge app.
    Legacy,
    /// A development build or anything else: it must never swap itself.
    Other,
}

pub fn kind_of(bundle_id: &str, ids: &Ids) -> Kind {
    if bundle_id == ids.release {
        Kind::Release
    } else if bundle_id == ids.legacy {
        Kind::Legacy
    } else {
        Kind::Other
    }
}

/// Where an update of `running` is installed. A release app is replaced where it is (same folder, same file name,
/// whatever the user renamed it to). A legacy app moves to `Muya.app` next to it. `None` for an app that may not update.
pub fn update_target(running: &Path, kind: Kind) -> Option<PathBuf> {
    match kind {
        Kind::Release => Some(running.to_path_buf()),
        Kind::Legacy => running.parent().map(|d| d.join(RELEASE_APP_FILE)),
        Kind::Other => None,
    }
}

/// The identity the update's new app must carry: always the release id (a legacy app is leaving its id behind).
pub fn expected_new_id(ids: &Ids) -> String {
    ids.release.clone()
}

/// A legacy app moves to `Muya.app`. When something already sits there it may only be replaced if it is a genuine Muya
/// (classic or an earlier 5.x, verified by the caller); anything else is refused and left alone.
pub fn check_move_target(
    target: &Path,
    running: &Path,
    exists: bool,
    genuine_muya: bool,
) -> Result<(), String> {
    if !exists || target == running {
        return Ok(());
    }
    if genuine_muya {
        return Ok(());
    }
    Err(format!(
        "{} already exists and is not a Muya app, so Muya Native cannot move there. Rename or remove it, then try again. Nothing was changed.",
        target.display()
    ))
}

/// A build that is pinned at compile time: URL (a fixed release asset, never `latest`) and its sha256.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pinned {
    pub version: &'static str,
    pub url: &'static str,
    pub sha256: &'static str,
}

/// "Return to Muya Classic": classic 4.1.22, the notarized zip of the GitHub release v4.1.22.
/// The sha256 is of that exact file (shasum -a 256 Muya-4.1.22-arm64.zip); the app inside is ALSO checked for the Team ID
/// and notarization after unpacking, so the pin is one of three independent checks.
pub const CLASSIC_RETURN: Pinned = Pinned {
    version: "4.1.22",
    url: "https://github.com/st4unch/muya/releases/download/v4.1.22/Muya-4.1.22-arm64.zip",
    sha256: "11f582eb66e5daf6e27364168e39e3fa0091ef7326d4163403258342529ee11f",
};

impl Pinned {
    /// Structural sanity: an allowed host, a fixed tag in the path, a valid sha256 and version.
    pub fn validate(&self) -> Result<(), String> {
        if !url_allowed(self.url) {
            return Err(format!("pinned url {} is not an allowed host", self.url));
        }
        if !self.url.contains(&format!("/v{}/", self.version)) {
            return Err("pinned url must name its own release tag, never `latest`".into());
        }
        if !is_sha256_hex(self.sha256) {
            return Err("pinned sha256 is not 64 hex digits".into());
        }
        if crate::version::compare(self.version, "0.0.0").is_none() {
            return Err("pinned version is not a version".into());
        }
        Ok(())
    }
}

/// The pin in force: [`CLASSIC_RETURN`], or (feature `e2e`) a local copy named by the environment
/// (`MUYA_SWITCHOVER_E2E_RETURN_URL` + `..._RETURN_SHA` [+ `..._RETURN_VERSION`]). Owned strings, because a test pin is not static.
#[derive(Debug, Clone, PartialEq)]
pub struct PinnedOwned {
    pub version: String,
    pub url: String,
    pub sha256: String,
}

pub fn classic_return() -> PinnedOwned {
    #[cfg(feature = "e2e")]
    if let (Ok(u), Ok(s)) = (
        std::env::var("MUYA_SWITCHOVER_E2E_RETURN_URL"),
        std::env::var("MUYA_SWITCHOVER_E2E_RETURN_SHA"),
    ) {
        if !u.is_empty() && !s.is_empty() {
            let v = std::env::var("MUYA_SWITCHOVER_E2E_RETURN_VERSION")
                .unwrap_or_else(|_| CLASSIC_RETURN.version.into());
            return PinnedOwned {
                version: v,
                url: u,
                sha256: s,
            };
        }
    }
    PinnedOwned {
        version: CLASSIC_RETURN.version.into(),
        url: CLASSIC_RETURN.url.into(),
        sha256: CLASSIC_RETURN.sha256.into(),
    }
}

/// Where "Return to Muya Classic" puts classic: in place, exactly where the running Muya 5 is (same folder, same file name).
pub fn return_target(running: &Path) -> PathBuf {
    running.to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_release_id_is_classics_id_and_the_legacy_id_differs() {
        assert_eq!(RELEASE_ID, "com.staunch.muya");
        assert_eq!(LEGACY_ID, "com.staunch.muya.native");
        let i = Ids::production();
        assert_eq!(kind_of("com.staunch.muya", &i), Kind::Release);
        assert_eq!(kind_of("com.staunch.muya.native", &i), Kind::Legacy);
        assert_eq!(
            kind_of("com.staunch.muya.dev", &i),
            Kind::Other,
            "a dev build never swaps itself"
        );
        assert_eq!(
            kind_of("com.staunch.muya.e2e", &i),
            Kind::Other,
            "the e2e id is not the real one"
        );
        assert_eq!(kind_of("", &i), Kind::Other);
    }

    #[test]
    fn a_release_app_updates_in_place_whatever_it_is_called() {
        for p in [
            "/Applications/Muya.app",
            "/Users/u/Desktop/Muya Yeni.app",
            "/Volumes/X/Apps/Muya 2.app",
        ] {
            assert_eq!(
                update_target(Path::new(p), Kind::Release),
                Some(PathBuf::from(p))
            );
        }
    }

    #[test]
    fn a_legacy_app_moves_to_muya_app_in_its_own_folder() {
        assert_eq!(
            update_target(Path::new("/Applications/Muya Native.app"), Kind::Legacy),
            Some(PathBuf::from("/Applications/Muya.app"))
        );
        assert_eq!(
            update_target(
                Path::new("/Users/u/Desktop/Muya Native Yeni.app"),
                Kind::Legacy
            ),
            Some(PathBuf::from("/Users/u/Desktop/Muya.app"))
        );
        assert_eq!(update_target(Path::new("/x/Muya.app"), Kind::Other), None);
    }

    #[test]
    fn the_new_app_always_carries_the_release_id() {
        assert_eq!(expected_new_id(&Ids::production()), "com.staunch.muya");
    }

    #[test]
    fn moving_onto_an_existing_muya_app_only_when_it_is_genuine() {
        let t = Path::new("/Applications/Muya.app");
        let run = Path::new("/Applications/Muya Native.app");
        assert!(check_move_target(t, run, false, false).is_ok(), "free");
        assert!(
            check_move_target(t, run, true, true).is_ok(),
            "classic or an old 5.x: replaced (it goes to the Trash)"
        );
        let e = check_move_target(t, run, true, false).unwrap_err();
        assert!(
            e.contains("not a Muya app") && e.contains("Nothing was changed"),
            "{e}"
        );
        assert!(check_move_target(run, run, true, false).is_ok(), "in place");
    }

    #[test]
    fn the_classic_pin_is_valid_fixed_and_allowed() {
        CLASSIC_RETURN.validate().unwrap();
        assert!(CLASSIC_RETURN.url.ends_with("Muya-4.1.22-arm64.zip"));
        let bad = Pinned {
            url: "https://github.com/st4unch/muya/releases/latest/download/x.zip",
            ..CLASSIC_RETURN
        };
        assert!(bad.validate().unwrap_err().contains("latest"));
        let evil = Pinned {
            url: "https://evil.example/v4.1.22/x.zip",
            ..CLASSIC_RETURN
        };
        assert!(evil.validate().is_err());
        let short = Pinned {
            sha256: "abc",
            ..CLASSIC_RETURN
        };
        assert!(short.validate().is_err());
        let p = classic_return();
        assert_eq!(
            (p.version.as_str(), p.sha256.as_str()),
            ("4.1.22", CLASSIC_RETURN.sha256)
        );
    }

    #[test]
    fn return_goes_exactly_where_v5_runs() {
        assert_eq!(
            return_target(Path::new("/Users/u/Desktop/Muya Yeni.app")),
            PathBuf::from("/Users/u/Desktop/Muya Yeni.app")
        );
    }
}

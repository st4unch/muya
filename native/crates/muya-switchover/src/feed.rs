//! The update feed: the Tauri updater's `latest.json` (`releases/latest/download/latest.json`).
//!
//! Classic 4.1.22 reads this file with its normal updater; Muya 5 reads the same file itself. The file is unsigned, the
//! minisign signature inside it covers the `.app.tar.gz` it points at, so only shape and host are checked here and the
//! archive signature is verified after the download (see `manifest::verify_signature`).

use crate::manifest::url_allowed;
use crate::version;
use serde::Deserialize;

#[derive(Debug, Clone, PartialEq)]
pub struct Release {
    pub version: String,
    pub url: String,
    /// Tauri's base64 minisign signature of the `.app.tar.gz`.
    pub signature: String,
}

#[derive(Deserialize)]
struct Latest {
    version: String,
    platforms: std::collections::BTreeMap<String, Platform>,
}
#[derive(Deserialize)]
struct Platform {
    signature: String,
    url: String,
}

pub fn parse_latest(json: &[u8]) -> Result<Release, String> {
    let l: Latest =
        serde_json::from_slice(json).map_err(|e| format!("the release feed is unreadable: {e}"))?;
    if version::compare(&l.version, "0.0.0").is_none() {
        return Err(format!(
            "the release feed has a bad version '{}'",
            l.version
        ));
    }
    let p = l
        .platforms
        .get("darwin-aarch64")
        .or_else(|| l.platforms.get("darwin-aarch64-app"))
        .ok_or("the release has no Apple-silicon build")?;
    if !url_allowed(&p.url) {
        return Err(format!(
            "the release points at an unexpected host: {}",
            p.url
        ));
    }
    if p.signature.trim().is_empty() {
        return Err("the release has no signature".into());
    }
    Ok(Release {
        version: l.version,
        url: p.url.clone(),
        signature: p.signature.clone(),
    })
}

/// Is the feed's release newer than what is installed? An unparsable installed version counts as "unknown": no update.
pub fn is_available(installed: &str, r: &Release) -> bool {
    version::compare(&r.version, installed).is_some_and(|o| o == std::cmp::Ordering::Greater)
}

#[cfg(test)]
mod tests {
    use super::*;

    const OK: &[u8] = br#"{"version":"5.0.0","notes":"n","platforms":{"darwin-aarch64":{"signature":"c2ln","url":"https://github.com/st4unch/muya/releases/download/v5.0.0/Muya-5.0.0-arm64.app.tar.gz"}}}"#;

    #[test]
    fn parses_the_shape_publish_release_writes() {
        let r = parse_latest(OK).unwrap();
        assert_eq!(
            (r.version.as_str(), r.signature.as_str()),
            ("5.0.0", "c2ln")
        );
        assert!(r.url.ends_with("Muya-5.0.0-arm64.app.tar.gz"));
    }

    #[test]
    fn foreign_hosts_missing_builds_and_junk_are_refused() {
        let evil = String::from_utf8_lossy(OK).replace("github.com/st4unch", "evil.example/x");
        assert!(parse_latest(evil.as_bytes())
            .unwrap_err()
            .contains("unexpected host"));
        assert!(parse_latest(br#"{"version":"5.0.0","platforms":{}}"#).is_err());
        assert!(parse_latest(br#"{"version":"x","platforms":{}}"#).is_err());
        assert!(parse_latest(b"not json").is_err());
        let nosig = String::from_utf8_lossy(OK).replace("c2ln", "");
        assert!(parse_latest(nosig.as_bytes())
            .unwrap_err()
            .contains("no signature"));
    }

    #[test]
    fn only_a_strictly_newer_release_is_an_update() {
        let r = parse_latest(OK).unwrap();
        assert!(is_available("4.1.27", &r), "the bridge moves to 5.0.0");
        assert!(is_available("4.1.22", &r));
        assert!(!is_available("5.0.0", &r));
        assert!(!is_available("5.0.1", &r), "never an older release");
        assert!(!is_available("garbage", &r));
    }
}

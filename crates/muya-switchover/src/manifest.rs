//! `native-beta.json`: parsing, signature check, structural validation.

use base64::Engine;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub schema: u32,
    pub channel: String,
    pub version: String,
    #[serde(default)]
    pub build: Option<String>,
    #[serde(default)]
    pub pub_date: Option<String>,
    pub url: String,
    #[serde(default)]
    pub size: Option<u64>,
    pub sha256: String,
    pub min_classic_version: String,
    #[serde(default)]
    pub min_macos: Option<String>,
    #[serde(default)]
    pub notes: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ManifestError {
    BadSignature(String),
    BadJson(String),
    Schema(u32),
    Channel(String),
    BadUrl(String),
    BadSha(String),
    BadVersion(String),
}

impl std::fmt::Display for ManifestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

/// Hosts a download may come from. GitHub release assets redirect to the second one.
const ALLOWED_HOSTS: &[&str] = &["github.com", "objects.githubusercontent.com"];

pub fn url_allowed(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else { return false };
    let host_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..host_end];
    // No userinfo, no port: `https://github.com@evil/..` must not pass.
    if authority.contains('@') || authority.contains(':') {
        return false;
    }
    ALLOWED_HOSTS.contains(&authority.to_ascii_lowercase().as_str())
}

pub fn is_sha256_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Verify a minisign signature. `pubkey` is the Tauri-style value: base64 of the
/// minisign public-key file. `sig` is the signature file text (or the Tauri base64 of it).
pub fn verify_signature(data: &[u8], sig: &str, pubkey: &str) -> Result<(), ManifestError> {
    let bad = |e: String| ManifestError::BadSignature(e);
    let b64 = base64::engine::general_purpose::STANDARD;
    let pk_text = b64
        .decode(pubkey.trim())
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
        .unwrap_or_else(|| pubkey.to_string());
    let pk = minisign_verify::PublicKey::decode(&pk_text).map_err(|e| bad(e.to_string()))?;
    let sig_text = if sig.trim_start().starts_with("untrusted comment") {
        sig.to_string()
    } else {
        b64.decode(sig.trim())
            .ok()
            .and_then(|b| String::from_utf8(b).ok())
            .ok_or_else(|| bad("signature is neither minisign text nor base64".into()))?
    };
    let sig = minisign_verify::Signature::decode(&sig_text).map_err(|e| bad(e.to_string()))?;
    pk.verify(data, &sig, false).map_err(|e| bad(e.to_string()))
}

/// Signature first, then structure. Nothing from an unsigned manifest is trusted.
pub fn parse_signed(json: &[u8], sig: &str, pubkey: &str) -> Result<Manifest, ManifestError> {
    verify_signature(json, sig, pubkey)?;
    parse_unsigned(json)
}

/// Structural validation only (used after the signature has passed, and in tests).
pub fn parse_unsigned(json: &[u8]) -> Result<Manifest, ManifestError> {
    let m: Manifest = serde_json::from_slice(json).map_err(|e| ManifestError::BadJson(e.to_string()))?;
    if m.schema != 1 {
        return Err(ManifestError::Schema(m.schema));
    }
    if m.channel != "beta" {
        return Err(ManifestError::Channel(m.channel));
    }
    if !url_allowed(&m.url) {
        return Err(ManifestError::BadUrl(m.url));
    }
    if !is_sha256_hex(&m.sha256) {
        return Err(ManifestError::BadSha(m.sha256));
    }
    for v in [&m.version, &m.min_classic_version] {
        if crate::version::compare(v, "0.0.0").is_none() {
            return Err(ManifestError::BadVersion(v.clone()));
        }
    }
    Ok(m)
}

#[cfg(test)]
pub(crate) fn sample_json(version: &str) -> String {
    format!(
        r#"{{"schema":1,"channel":"beta","version":"{version}","url":"https://github.com/st4unch/muya/releases/download/native-v{version}/Muya-Native-{version}.zip","sha256":"{}","minClassicVersion":"4.1.21","notes":"hi"}}"#,
        "a".repeat(64)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with(f: impl Fn(&mut serde_json::Value)) -> Vec<u8> {
        let mut v: serde_json::Value = serde_json::from_str(&sample_json("0.1.0")).unwrap();
        f(&mut v);
        serde_json::to_vec(&v).unwrap()
    }

    #[test]
    fn accepts_good() {
        let m = parse_unsigned(sample_json("0.1.0").as_bytes()).unwrap();
        assert_eq!(m.version, "0.1.0");
    }
    #[test]
    fn rejects_schema() {
        assert_eq!(parse_unsigned(&with(|v| v["schema"] = 2.into())), Err(ManifestError::Schema(2)));
    }
    #[test]
    fn rejects_channel() {
        assert!(matches!(parse_unsigned(&with(|v| v["channel"] = "stable".into())), Err(ManifestError::Channel(_))));
    }
    #[test]
    fn rejects_urls() {
        for u in [
            "http://github.com/x.zip",
            "https://evil.example/x.zip",
            "https://github.com@evil.example/x.zip",
            "https://github.com:444/x.zip",
            "https://github.com.evil.example/x.zip",
            "file:///tmp/x.zip",
        ] {
            let r = parse_unsigned(&with(|v| v["url"] = u.into()));
            assert!(matches!(r, Err(ManifestError::BadUrl(_))), "{u}");
        }
        assert!(url_allowed("https://objects.githubusercontent.com/a/b"));
    }
    #[test]
    fn rejects_sha_and_missing() {
        assert!(matches!(parse_unsigned(&with(|v| v["sha256"] = "abc".into())), Err(ManifestError::BadSha(_))));
        assert!(matches!(parse_unsigned(&with(|v| { v.as_object_mut().unwrap().remove("url"); })), Err(ManifestError::BadJson(_))));
        assert!(matches!(parse_unsigned(&with(|v| v["version"] = "x".into())), Err(ManifestError::BadVersion(_))));
    }
    #[test]
    fn bad_signature_rejected() {
        let r = parse_signed(sample_json("0.1.0").as_bytes(), "not a sig", "not a key");
        assert!(matches!(r, Err(ManifestError::BadSignature(_))));
    }
}

//! CyberArk PVWA v10 REST client — logon, account listing and just-in-time
//! password retrieval for SSH connections (PRD `ssh-cyberark`, Faz 3).
//!
//! Security invariant (PRD §9, mirrors `credstore.rs`): NO secret ever crosses
//! the Rust→JS boundary. The session token and any retrieved account password
//! live only inside Rust — the token is cached in `CyberarkState`, passwords are
//! returned as `Zeroizing<String>` to the connect/PTY-injection path. The Tauri
//! commands hand the frontend only metadata and success/failure strings. Error
//! strings may carry an HTTP status + a short response-body snippet, but never
//! the credential we sent.
//!
//! Design note — username: CyberArk PVWA Logon requires a `username` alongside
//! the password. `crate::ssh::CyberarkConfig` (imported, never redefined) carries
//! no username field, and the "prompt" credential source is session-only, so the
//! logon commands accept an explicit `username` parameter next to the `master`
//! password. Both are used once and dropped; only the resulting token is cached.

use crate::ssh::CyberarkConfig;
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::time::Duration;
use tauri::State;
use zeroize::Zeroizing;

const REASON: &str = "Muya SSH connection";
const TIMEOUT_DEFAULT: Duration = Duration::from_secs(20);
// RADIUS push logon can block server-side until the user approves the push on
// their device, so it gets a longer request timeout (best-effort).
const TIMEOUT_RADIUS: Duration = Duration::from_secs(60);

// ---------------------------------------------------------------------------
// State + types
// ---------------------------------------------------------------------------

/// Cached PVWA session. The token is a bearer-style credential (used verbatim as
/// the `Authorization` header) and is zeroized on drop.
struct Session {
    token: Zeroizing<String>,
    base_url: String,
    tls_verify: bool,
    ca_cert_path: Option<String>,
}

/// Tauri-managed CyberArk session cache. `None` = not logged on.
#[derive(Default)]
pub struct CyberarkState {
    inner: Mutex<Option<Session>>,
}

/// Non-secret account projection returned to the UI. There is no secret on an
/// account listing anyway; the password is fetched separately and never exposed.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AccountMeta {
    pub id: String,
    pub name: String,
    pub address: String,
    /// PVWA `userName`.
    pub username: String,
    /// PVWA `safeName`.
    pub safe: String,
    /// PVWA `platformId`.
    pub platform_id: String,
}

// PVWA v10 GET /Accounts response shape (subset we consume).
#[derive(Deserialize)]
struct AccountsResponse {
    #[serde(default)]
    value: Vec<RawAccount>,
    #[serde(default)]
    #[allow(dead_code)]
    count: i64,
}

#[derive(Deserialize)]
struct RawAccount {
    #[serde(default)]
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    address: String,
    #[serde(rename = "userName", default)]
    user_name: String,
    #[serde(rename = "safeName", default)]
    safe_name: String,
    #[serde(rename = "platformId", default)]
    platform_id: String,
}

impl From<RawAccount> for AccountMeta {
    fn from(r: RawAccount) -> Self {
        AccountMeta {
            id: r.id,
            name: r.name,
            address: r.address,
            username: r.user_name,
            safe: r.safe_name,
            platform_id: r.platform_id,
        }
    }
}

// v9 `.svc` fallback logon response shape.
#[derive(Deserialize)]
struct V9LogonResult {
    #[serde(rename = "CyberArkLogonResult", default)]
    cyber_ark_logon_result: String,
}

// ---------------------------------------------------------------------------
// HTTP helpers (pure of Tauri; testable against a mock PVWA)
// ---------------------------------------------------------------------------

fn trim_base(base: &str) -> &str {
    base.trim_end_matches('/')
}

/// Minimal percent-encoding for the `search` query value (RFC 3986 unreserved
/// stays literal) — avoids pulling a urlencoding crate for one call site.
fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Build a reqwest client honoring the config's TLS policy: skip verification
/// when `tls_verify == false`, else optionally pin a custom CA PEM.
fn build_client(
    tls_verify: bool,
    ca_cert_path: &Option<String>,
    timeout: Duration,
) -> Result<reqwest::Client, String> {
    let mut builder = reqwest::Client::builder().timeout(timeout);
    if !tls_verify {
        builder = builder.danger_accept_invalid_certs(true);
    } else if let Some(path) = ca_cert_path {
        let pem = std::fs::read(path).map_err(|e| format!("read CA cert {path}: {e}"))?;
        let cert = reqwest::Certificate::from_pem(&pem)
            .map_err(|e| format!("parse CA cert {path}: {e}"))?;
        builder = builder.add_root_certificate(cert);
    }
    builder
        .build()
        .map_err(|e| format!("build http client: {e}"))
}

/// Extract a token string from a PVWA logon body. v10 returns a bare JSON string
/// (`"abc123"`); tolerate an unquoted body defensively.
fn parse_token_body(text: &str) -> Zeroizing<String> {
    match serde_json::from_str::<String>(text) {
        Ok(tok) => Zeroizing::new(tok),
        Err(_) => Zeroizing::new(text.trim().trim_matches('"').to_string()),
    }
}

fn snippet(text: &str) -> String {
    let t = text.trim();
    if t.len() > 200 {
        format!("{}…", &t[..200])
    } else {
        t.to_string()
    }
}

/// Perform a PVWA logon and return a ready-to-cache `Session`. The method segment
/// is inserted verbatim (Cyberark/LDAP/RADIUS/Windows). On a 404 from the v10
/// endpoint it retries once against the legacy v9 `.svc` service.
async fn do_logon(
    config: &CyberarkConfig,
    username: &str,
    master: &Zeroizing<String>,
) -> Result<Session, String> {
    let base = trim_base(&config.base_url).to_string();
    let method = config.auth_method.trim();
    let timeout = if method.eq_ignore_ascii_case("RADIUS") {
        TIMEOUT_RADIUS
    } else {
        TIMEOUT_DEFAULT
    };
    let client = build_client(config.tls_verify, &config.ca_cert_path, timeout)?;

    let url = format!("{base}/PasswordVault/API/Auth/{method}/Logon");
    let body = serde_json::json!({
        "username": username,
        "password": master.as_str(),
        "concurrentSession": true,
    });
    let resp = client
        .post(&url)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("logon request failed: {e}"))?;

    let status = resp.status();
    if status.is_success() {
        let text = resp
            .text()
            .await
            .map_err(|e| format!("read logon response: {e}"))?;
        return Ok(Session {
            token: parse_token_body(&text),
            base_url: base,
            tls_verify: config.tls_verify,
            ca_cert_path: config.ca_cert_path.clone(),
        });
    }

    // v9 fallback — only when the v10 route is absent (old PVWA).
    if status.as_u16() == 404 {
        return do_logon_v9(config, &base, username, master).await;
    }

    let text = resp.text().await.unwrap_or_default();
    Err(format!(
        "CyberArk logon failed (HTTP {}): {}",
        status.as_u16(),
        snippet(&text)
    ))
}

/// Legacy v9 `.svc` logon. Body is `{username,password}`; the token lives in
/// `CyberArkLogonResult`.
async fn do_logon_v9(
    config: &CyberarkConfig,
    base: &str,
    username: &str,
    master: &Zeroizing<String>,
) -> Result<Session, String> {
    let client = build_client(config.tls_verify, &config.ca_cert_path, TIMEOUT_DEFAULT)?;
    let url = format!(
        "{base}/PasswordVault/WebServices/auth/Cyberark/CyberArkAuthenticationService.svc/Logon"
    );
    let body = serde_json::json!({ "username": username, "password": master.as_str() });
    let resp = client
        .post(&url)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("v9 logon request failed: {e}"))?;
    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        return Err(format!(
            "CyberArk v9 logon failed (HTTP {}): {}",
            status.as_u16(),
            snippet(&text)
        ));
    }
    let parsed: V9LogonResult = resp
        .json()
        .await
        .map_err(|e| format!("parse v9 logon response: {e}"))?;
    if parsed.cyber_ark_logon_result.is_empty() {
        return Err("v9 logon returned an empty token".into());
    }
    Ok(Session {
        token: Zeroizing::new(parsed.cyber_ark_logon_result),
        base_url: base.to_string(),
        tls_verify: config.tls_verify,
        ca_cert_path: config.ca_cert_path.clone(),
    })
}

async fn do_logoff(
    token: &str,
    base: &str,
    tls_verify: bool,
    ca_cert_path: &Option<String>,
) -> Result<(), String> {
    let client = build_client(tls_verify, ca_cert_path, TIMEOUT_DEFAULT)?;
    let url = format!("{}/PasswordVault/API/Auth/Logoff", trim_base(base));
    client
        .post(&url)
        .header("Authorization", token)
        .send()
        .await
        .map_err(|e| format!("logoff request failed: {e}"))?;
    Ok(())
}

async fn do_list(
    token: &str,
    base: &str,
    tls_verify: bool,
    ca_cert_path: &Option<String>,
    search: &str,
) -> Result<Vec<AccountMeta>, String> {
    let client = build_client(tls_verify, ca_cert_path, TIMEOUT_DEFAULT)?;
    let url = format!(
        "{}/PasswordVault/API/Accounts?search={}&limit=50",
        trim_base(base),
        urlencode(search)
    );
    let resp = client
        .get(&url)
        .header("Authorization", token)
        .send()
        .await
        .map_err(|e| format!("list accounts request failed: {e}"))?;
    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        return Err(format!(
            "list accounts failed (HTTP {}): {}",
            status.as_u16(),
            snippet(&text)
        ));
    }
    let parsed: AccountsResponse = resp
        .json()
        .await
        .map_err(|e| format!("parse accounts response: {e}"))?;
    Ok(parsed.value.into_iter().map(AccountMeta::from).collect())
}

async fn do_retrieve(
    token: &str,
    base: &str,
    tls_verify: bool,
    ca_cert_path: &Option<String>,
    account_id: &str,
) -> Result<Zeroizing<String>, String> {
    let client = build_client(tls_verify, ca_cert_path, TIMEOUT_DEFAULT)?;
    let url = format!(
        "{}/PasswordVault/API/Accounts/{}/Password/Retrieve",
        trim_base(base),
        account_id
    );
    let body = serde_json::json!({ "reason": REASON });
    let resp = client
        .post(&url)
        .header("Authorization", token)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("retrieve password request failed: {e}"))?;
    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        return Err(format!(
            "retrieve password failed (HTTP {}): {}",
            status.as_u16(),
            snippet(&text)
        ));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| format!("read retrieve response: {e}"))?;
    // Body is a JSON string = the plaintext password. Keep it in Zeroizing.
    Ok(parse_token_body(&text))
}

// ---------------------------------------------------------------------------
// State-level helpers (take `&CyberarkState`; unit-testable without Tauri)
// ---------------------------------------------------------------------------

/// Snapshot the cached (token, base, tls, ca) without holding the lock across an
/// await point. Returns `Err` if not logged on.
fn snapshot(
    state: &CyberarkState,
) -> Result<(Zeroizing<String>, String, bool, Option<String>), String> {
    let guard = state.inner.lock().map_err(|_| "cyberark state poisoned")?;
    let s = guard.as_ref().ok_or("not logged on to CyberArk")?;
    Ok((
        s.token.clone(),
        s.base_url.clone(),
        s.tls_verify,
        s.ca_cert_path.clone(),
    ))
}

async fn logon_with(
    state: &CyberarkState,
    config: &CyberarkConfig,
    username: &str,
    master: Zeroizing<String>,
) -> Result<(), String> {
    let session = do_logon(config, username, &master).await?;
    // master drops here (Zeroizing) — used once, never cached.
    *state.inner.lock().map_err(|_| "cyberark state poisoned")? = Some(session);
    Ok(())
}

async fn test_connection_with(
    state: &CyberarkState,
    config: &CyberarkConfig,
    username: &str,
    master: Zeroizing<String>,
) -> Result<String, String> {
    let method = config.auth_method.trim().to_string();
    let session = do_logon(config, username, &master).await?;
    let base = session.base_url.clone();
    // Best-effort logoff to prove the token is live, then re-cache so the user
    // can immediately browse accounts without re-authenticating.
    let _ = do_logoff(
        &session.token,
        &base,
        session.tls_verify,
        &session.ca_cert_path,
    )
    .await;
    let relogon = do_logon(config, username, &master).await?;
    *state.inner.lock().map_err(|_| "cyberark state poisoned")? = Some(relogon);
    Ok(format!("OK — authenticated via {method} at {base}"))
}

async fn list_with(
    state: &CyberarkState,
    search: Option<String>,
) -> Result<Vec<AccountMeta>, String> {
    let (token, base, tls, ca) = snapshot(state)?;
    do_list(&token, &base, tls, &ca, search.as_deref().unwrap_or("")).await
}

async fn logoff_with(state: &CyberarkState) -> Result<(), String> {
    let snap = snapshot(state).ok();
    *state.inner.lock().map_err(|_| "cyberark state poisoned")? = None;
    if let Some((token, base, tls, ca)) = snap {
        let _ = do_logoff(&token, &base, tls, &ca).await; // best-effort
    }
    Ok(())
}

fn status_with(state: &CyberarkState) -> Result<bool, String> {
    Ok(state
        .inner
        .lock()
        .map_err(|_| "cyberark state poisoned")?
        .is_some())
}

/// Retrieve an account password for the connect/PTY-injection path. NOT a Tauri
/// command — the plaintext never reaches JS. Snapshots the session first so the
/// state Mutex is not held across the network await.
pub async fn fetch_password(
    state: &CyberarkState,
    account_id: &str,
) -> Result<Zeroizing<String>, String> {
    let (token, base, tls, ca) = snapshot(state)?;
    do_retrieve(&token, &base, tls, &ca, account_id).await
}

// ---------------------------------------------------------------------------
// Tauri commands (thin wrappers; secrets never returned to JS)
// ---------------------------------------------------------------------------

#[tauri::command(async)]
pub async fn cyberark_logon(
    state: State<'_, CyberarkState>,
    config: CyberarkConfig,
    username: String,
    master: String,
) -> Result<(), String> {
    logon_with(state.inner(), &config, &username, Zeroizing::new(master)).await
}

#[tauri::command(async)]
pub async fn cyberark_test_connection(
    state: State<'_, CyberarkState>,
    config: CyberarkConfig,
    username: String,
    master: String,
) -> Result<String, String> {
    test_connection_with(state.inner(), &config, &username, Zeroizing::new(master)).await
}

#[tauri::command(async)]
pub async fn cyberark_list_accounts(
    state: State<'_, CyberarkState>,
    search: Option<String>,
) -> Result<Vec<AccountMeta>, String> {
    list_with(state.inner(), search).await
}

#[tauri::command(async)]
pub async fn cyberark_logoff(state: State<'_, CyberarkState>) -> Result<(), String> {
    logoff_with(state.inner()).await
}

#[tauri::command(async)]
pub async fn cyberark_status(state: State<'_, CyberarkState>) -> Result<bool, String> {
    status_with(state.inner())
}

// ---------------------------------------------------------------------------
// Tests — request shapes + parsing against a mock PVWA (wiremock)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{body_string_contains, header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn cfg(base: &str, auth_method: &str) -> CyberarkConfig {
        CyberarkConfig {
            base_url: base.to_string(),
            username: "vault-user".to_string(),
            auth_method: auth_method.to_string(),
            tls_verify: false,
            ca_cert_path: None,
            credential_source: Default::default(),
        }
    }

    // 1 — logon POST hits /Auth/Cyberark/Logon with username/password/
    // concurrentSession in the body; a bare JSON-string token is cached.
    #[tokio::test]
    async fn logon_shape_and_cache() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/PasswordVault/API/Auth/Cyberark/Logon"))
            .and(body_string_contains("\"username\""))
            .and(body_string_contains("\"password\""))
            .and(body_string_contains("concurrentSession"))
            .respond_with(ResponseTemplate::new(200).set_body_json("tok-123"))
            .mount(&server)
            .await;

        let state = CyberarkState::default();
        logon_with(
            &state,
            &cfg(&server.uri(), "Cyberark"),
            "vaultuser",
            Zeroizing::new("s3cret".into()),
        )
        .await
        .expect("logon should succeed");

        assert!(status_with(&state).unwrap(), "session must be cached");
    }

    // 2 — list_accounts sends Authorization: tok-123 and maps value[] → AccountMeta.
    #[tokio::test]
    async fn list_accounts_maps_fields() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/PasswordVault/API/Auth/Cyberark/Logon"))
            .respond_with(ResponseTemplate::new(200).set_body_json("tok-123"))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/PasswordVault/API/Accounts"))
            .and(header("Authorization", "tok-123"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "value": [
                    {"id":"1","name":"a1","address":"10.0.0.1","userName":"root","safeName":"Linux","platformId":"UnixSSH"},
                    {"id":"2","name":"a2","address":"10.0.0.2","userName":"oracle","safeName":"DB","platformId":"Oracle"}
                ],
                "count": 2
            })))
            .mount(&server)
            .await;

        let state = CyberarkState::default();
        logon_with(
            &state,
            &cfg(&server.uri(), "Cyberark"),
            "u",
            Zeroizing::new("p".into()),
        )
        .await
        .unwrap();

        let accts = list_with(&state, Some("db".into())).await.unwrap();
        assert_eq!(accts.len(), 2);
        assert_eq!(accts[0].id, "1");
        assert_eq!(accts[0].username, "root");
        assert_eq!(accts[0].safe, "Linux");
        assert_eq!(accts[0].platform_id, "UnixSSH");
        assert_eq!(accts[1].address, "10.0.0.2");
        assert_eq!(accts[1].username, "oracle");
    }

    // 3 — fetch_password POSTs to /Accounts/42/Password/Retrieve with the
    // Authorization header and a reason body; returns the secret string.
    #[tokio::test]
    async fn fetch_password_shape() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/PasswordVault/API/Auth/Cyberark/Logon"))
            .respond_with(ResponseTemplate::new(200).set_body_json("tok-xyz"))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/PasswordVault/API/Accounts/42/Password/Retrieve"))
            .and(header("Authorization", "tok-xyz"))
            .and(body_string_contains("reason"))
            .respond_with(ResponseTemplate::new(200).set_body_json("P@ssw0rd!"))
            .mount(&server)
            .await;

        let state = CyberarkState::default();
        logon_with(
            &state,
            &cfg(&server.uri(), "Cyberark"),
            "u",
            Zeroizing::new("p".into()),
        )
        .await
        .unwrap();

        let secret = fetch_password(&state, "42").await.unwrap();
        assert_eq!(&*secret, "P@ssw0rd!");
    }

    // 4 — list without a prior logon is an error, not a panic.
    #[tokio::test]
    async fn list_without_logon_errors() {
        let state = CyberarkState::default();
        let err = list_with(&state, None).await.unwrap_err();
        assert!(err.contains("not logged on"), "unexpected: {err}");
    }

    // 5 — RADIUS builds the /Auth/RADIUS/Logon path exactly.
    #[tokio::test]
    async fn radius_builds_radius_path() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/PasswordVault/API/Auth/RADIUS/Logon"))
            .respond_with(ResponseTemplate::new(200).set_body_json("tok-radius"))
            .expect(1)
            .mount(&server)
            .await;

        let state = CyberarkState::default();
        logon_with(
            &state,
            &cfg(&server.uri(), "RADIUS"),
            "u",
            Zeroizing::new("p".into()),
        )
        .await
        .expect("RADIUS logon should hit /Auth/RADIUS/Logon");
        assert!(status_with(&state).unwrap());
    }
}

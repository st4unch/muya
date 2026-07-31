//! SSH connection manager — server targets, PSMP jump profiles, and CyberArk
//! connection metadata (PRD `ssh-cyberark`, Faz 1). Non-secret config persisted
//! to `~/.claude/muya-ssh-config.json`; passwords/keys NEVER live here (they are
//! in the encrypted store `credstore.rs` or brokered from CyberArk).
//!
//! Dedup rule (AC1.2): a server is unique by normalized `(host, port, username)`.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tauri::ipc::{Channel, InvokeResponseBody};
use tauri::State;
use zeroize::Zeroizing;

const CONFIG_VERSION: u32 = 1;
const DEFAULT_PORT: u16 = 22;

// ---------------------------------------------------------------------------
// Types (mirror PRD §6 data model; no secret fields)
// ---------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Default)]
pub struct CredentialSource {
    /// "local" | "cyberark" | "prompt"
    pub kind: String,
    #[serde(
        rename = "localCredId",
        skip_serializing_if = "Option::is_none",
        default
    )]
    pub local_cred_id: Option<String>,
    #[serde(
        rename = "cyberarkAccountId",
        skip_serializing_if = "Option::is_none",
        default
    )]
    pub cyberark_account_id: Option<String>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Server {
    #[serde(default)]
    pub id: String,
    pub label: String,
    pub host: String,
    #[serde(default = "default_port")]
    pub port: u16,
    pub username: String,
    /// "direct" | "psmp"
    #[serde(rename = "connectionType")]
    pub connection_type: String,
    #[serde(
        rename = "psmpProfileId",
        skip_serializing_if = "Option::is_none",
        default
    )]
    pub psmp_profile_id: Option<String>,
    #[serde(rename = "credentialSource", default)]
    pub credential_source: CredentialSource,
    /// Per-server opt-in (default false): may the `muya-ssh` MCP broker expose
    /// this server to Claude agents (list + open by alias)? Secrets never cross
    /// to the agent regardless — this only gates visibility/open. Old config JSON
    /// lacking `agentAccess` deserializes to `false` (serde `default`).
    #[serde(rename = "agentAccess", default)]
    pub agent_access: bool,
    /// Extra raw `ssh` CLI options inserted before the destination, e.g.
    /// `-X -L 8080:localhost:80 -J jump@host`. Split on whitespace (no shell).
    #[serde(
        rename = "sshOptions",
        skip_serializing_if = "Option::is_none",
        default
    )]
    pub ssh_options: Option<String>,
    #[serde(
        rename = "lastConnectedAt",
        skip_serializing_if = "Option::is_none",
        default
    )]
    pub last_connected_at: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct PsmpProfile {
    #[serde(default)]
    pub id: String,
    pub label: String,
    #[serde(rename = "psmpAddress")]
    pub psmp_address: String,
    #[serde(rename = "vaultUser")]
    pub vault_user: String,
    #[serde(rename = "userDelim", default = "at_delim")]
    pub user_delim: String,
    #[serde(rename = "paramDelim", default = "hash_delim")]
    pub param_delim: String,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct CyberarkConfig {
    #[serde(rename = "baseUrl")]
    pub base_url: String,
    /// Vault username used for PVWA logon (non-secret; persisted). The password is
    /// supplied per-session and never stored.
    #[serde(default)]
    pub username: String,
    #[serde(rename = "authMethod")]
    pub auth_method: String,
    #[serde(rename = "tlsVerify", default = "tls_default")]
    pub tls_verify: bool,
    #[serde(
        rename = "caCertPath",
        skip_serializing_if = "Option::is_none",
        default
    )]
    pub ca_cert_path: Option<String>,
    /// Where the logon username/password come from: "prompt" (session-only) or a
    /// stored credential (kind="local", localCredId). Reusing the store lets the
    /// operator avoid re-typing (operator request 2026-07-24, relaxes D2). The
    /// secret is pulled by Rust at logon time (Faz 3) — never revealed to JS.
    #[serde(rename = "credentialSource", default)]
    pub credential_source: CredentialSource,
}

#[derive(Serialize, Deserialize)]
pub struct SshConfig {
    #[serde(default = "config_version")]
    pub version: u32,
    #[serde(default)]
    pub servers: Vec<Server>,
    #[serde(rename = "psmpProfiles", default)]
    pub psmp_profiles: Vec<PsmpProfile>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub cyberark: Option<CyberarkConfig>,
}

impl Default for SshConfig {
    fn default() -> Self {
        SshConfig {
            version: CONFIG_VERSION,
            servers: vec![],
            psmp_profiles: vec![],
            cyberark: None,
        }
    }
}

fn default_port() -> u16 {
    DEFAULT_PORT
}
fn config_version() -> u32 {
    CONFIG_VERSION
}
fn at_delim() -> String {
    "@".into()
}
fn hash_delim() -> String {
    "#".into()
}
fn tls_default() -> bool {
    true
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

fn config_path_under(home: &str) -> PathBuf {
    Path::new(home).join(".claude/muya-ssh-config.json")
}

fn config_path() -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    Ok(config_path_under(&home))
}

fn load_from(path: &Path) -> SshConfig {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_to(path: &Path, cfg: &SshConfig) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(cfg).map_err(|e| e.to_string())?;
    // Atomic temp+rename (PM3/R12), shared with credstore.
    crate::credstore::atomic_write(path, &bytes)
}

fn load() -> Result<SshConfig, String> {
    Ok(load_from(&config_path()?))
}

fn save(cfg: &SshConfig) -> Result<(), String> {
    save_to(&config_path()?, cfg)
}

// ---------------------------------------------------------------------------
// Dedup + validation (pure, testable)
// ---------------------------------------------------------------------------

/// Normalized identity of a server for dedup: lowercased/trimmed host, port
/// (default 22), trimmed username. (AC1.2)
fn dedup_key(host: &str, port: u16, username: &str) -> (String, u16, String) {
    (
        host.trim().to_lowercase(),
        port,
        username.trim().to_string(),
    )
}

fn validate(server: &Server) -> Result<(), String> {
    if server.host.trim().is_empty() {
        return Err("host is required".into());
    }
    if server.username.trim().is_empty() {
        return Err("username is required".into());
    }
    if server.port == 0 {
        return Err("port must be 1–65535".into());
    }
    if server.connection_type != "direct" && server.connection_type != "psmp" {
        return Err("connectionType must be 'direct' or 'psmp'".into());
    }
    if server.connection_type == "psmp"
        && server.psmp_profile_id.as_deref().unwrap_or("").is_empty()
    {
        return Err("a PSMP server needs a psmpProfileId".into());
    }
    Ok(())
}

/// Insert or update a server in `cfg`, enforcing the dedup rule. Returns the id.
/// New server (empty id) that collides with an existing one → Err. Edit (id set)
/// may keep its own key but must not collide with a *different* server.
fn upsert_server_in(cfg: &mut SshConfig, mut server: Server) -> Result<String, String> {
    if server.port == 0 {
        server.port = DEFAULT_PORT;
    }
    validate(&server)?;
    let key = dedup_key(&server.host, server.port, &server.username);
    let editing_id = if server.id.is_empty() {
        None
    } else {
        Some(server.id.clone())
    };

    let collision = cfg.servers.iter().any(|s| {
        dedup_key(&s.host, s.port, &s.username) == key && Some(&s.id) != editing_id.as_ref()
    });
    if collision {
        return Err(format!(
            "a server for {}@{}:{} already exists (duplicate)",
            key.2, key.0, key.1
        ));
    }

    match editing_id {
        Some(id) => {
            let slot = cfg
                .servers
                .iter_mut()
                .find(|s| s.id == id)
                .ok_or("server not found")?;
            // preserve id + lastConnectedAt unless caller supplied a new one
            let last = slot.last_connected_at.clone();
            *slot = server;
            slot.id = id.clone();
            if slot.last_connected_at.is_none() {
                slot.last_connected_at = last;
            }
            Ok(id)
        }
        None => {
            server.id = crate::credstore::new_id();
            let id = server.id.clone();
            cfg.servers.push(server);
            Ok(id)
        }
    }
}

// ---------------------------------------------------------------------------
// Tauri commands
// ---------------------------------------------------------------------------

/// The command to spawn for a connection. NO secret is ever placed in `args`
/// (PSMP injects the credential; direct password is injected via PTY later).
#[derive(Serialize)]
pub struct ConnectCommand {
    pub program: String,
    pub args: Vec<String>,
    /// Direct connections whose credential comes from the store/CyberArk need the
    /// password injected into the PTY after the prompt (Faz 2 PTY layer). PSMP and
    /// "prompt" sources do not.
    #[serde(rename = "needsPasswordInjection")]
    pub needs_password_injection: bool,
}

/// Extra user-supplied ssh options, whitespace-split into individual args (no
/// shell interpretation). Inserted before the destination. Empty when unset.
fn extra_ssh_opts(server: &Server) -> Vec<String> {
    server
        .ssh_options
        .as_deref()
        .unwrap_or("")
        .split_whitespace()
        .map(str::to_string)
        .collect()
}

/// Whether the connection needs the credential injected into the PTY after the
/// password prompt (stored or CyberArk source). "prompt" lets the user type it.
fn needs_injection(server: &Server) -> bool {
    matches!(server.credential_source.kind.as_str(), "local" | "cyberark")
}

/// Build the `ssh` invocation for a server (pure, testable). PSMP syntax
/// (verified 2026-07-24): `vaultUser@targetUser@targetAddress[#port]@psmpAddress`
/// with configurable `@`/`#` delimiters. Direct: `ssh [-p port] [opts] user@host`.
fn build_connect_command(
    server: &Server,
    psmp: Option<&PsmpProfile>,
) -> Result<ConnectCommand, String> {
    if server.connection_type == "psmp" {
        let p = psmp.ok_or("PSMP server has no profile")?;
        let ud: &str = if p.user_delim.is_empty() {
            "@"
        } else {
            p.user_delim.as_str()
        };
        let pd: &str = if p.param_delim.is_empty() {
            "#"
        } else {
            p.param_delim.as_str()
        };
        let target = if server.port == DEFAULT_PORT {
            server.host.clone()
        } else {
            format!("{}{}{}", server.host, pd, server.port)
        };
        // vaultUser@targetUser@targetAddress@psmpAddress — a single ssh destination arg.
        let dest = format!(
            "{vu}{ud}{tu}{ud}{ta}{ud}{px}",
            vu = p.vault_user,
            tu = server.username,
            ta = target,
            px = p.psmp_address,
            ud = ud
        );
        let mut args = extra_ssh_opts(server);
        args.push(dest);
        return Ok(ConnectCommand {
            program: "ssh".into(),
            args,
            needs_password_injection: needs_injection(server),
        });
    }
    // direct
    let mut args = Vec::new();
    if server.port != DEFAULT_PORT {
        args.push("-p".to_string());
        args.push(server.port.to_string());
    }
    args.extend(extra_ssh_opts(server));
    args.push(format!("{}@{}", server.username, server.host));
    Ok(ConnectCommand {
        program: "ssh".into(),
        args,
        needs_password_injection: needs_injection(server),
    })
}

/// Open an SSH connection for `server_id` in a new PTY, streaming to `on_event`.
/// The command is built here; when the server's credential source is a stored
/// password or a CyberArk account, the secret is resolved IN RUST and injected
/// into the PTY at the password prompt — it never crosses into JS (§9). Returns
/// the PTY session id for pty_write/pty_resize/pty_kill.
#[tauri::command(async)]
pub async fn ssh_pty_connect(
    pty: State<'_, crate::pty::PtyManager>,
    cred: State<'_, crate::credstore::CredStore>,
    cyber: State<'_, crate::cyberark::CyberarkState>,
    on_event: Channel<InvokeResponseBody>,
    server_id: String,
    cols: Option<u16>,
    rows: Option<u16>,
) -> Result<String, String> {
    let cfg = load()?;
    let server = cfg
        .servers
        .iter()
        .find(|s| s.id == server_id)
        .ok_or("server not found")?
        .clone();
    let psmp = server
        .psmp_profile_id
        .as_ref()
        .and_then(|pid| cfg.psmp_profiles.iter().find(|p| &p.id == pid));
    let cmd = build_connect_command(&server, psmp)?;
    // The built argv carries NO secret (PSMP injects the credential; direct
    // password is injected into the PTY later) — safe to log verbatim.
    crate::debuglog::log(&format!(
        "ssh connect: server={} type={} program={} args={:?} cred_source={} injection_armed={}",
        server.label,
        server.connection_type,
        cmd.program,
        cmd.args,
        server.credential_source.kind,
        cmd.needs_password_injection
    ));

    // Resolve the injectable secret (Rust-only). "prompt" injects nothing — the
    // user types the password in the terminal.
    let secret: Option<Zeroizing<String>> = match server.credential_source.kind.as_str() {
        "local" => {
            let id = server.credential_source.local_cred_id.as_deref().ok_or(
                "credential source is 'Local password store' but no credential is selected",
            )?;
            Some(crate::credstore::secret_for(&cred, id)?)
        }
        "cyberark" => {
            let acct = server
                .credential_source
                .cyberark_account_id
                .as_deref()
                .ok_or("credential source is 'CyberArk account' but no account is selected")?;
            crate::debuglog::log(&format!(
                "ssh connect: resolving CyberArk password for account={acct}"
            ));
            Some(crate::cyberark::fetch_password(&cyber, acct).await?)
        }
        _ => None,
    };
    // Metadata only — whether a secret was resolved, never the secret itself.
    crate::debuglog::log(&format!(
        "ssh connect: spawning PTY (program={}, secret_resolved={})",
        cmd.program,
        secret.is_some()
    ));

    crate::pty::spawn_process(
        pty.inner(),
        on_event,
        &cmd.program,
        &cmd.args,
        None,
        cols,
        rows,
        secret,
    )
}

/// Build the base `ssh` invocation for a server, resolving its PSMP profile from
/// the on-disk config. Public for the SSH Agent Broker's `ssh_run` (Faz 2), which
/// appends the remote command as one more argv element. No secret is included;
/// `needs_password_injection` tells the caller whether a password must be injected.
pub(crate) fn connect_command_for(server: &Server) -> Result<ConnectCommand, String> {
    let cfg = load()?;
    let psmp = server
        .psmp_profile_id
        .as_ref()
        .and_then(|pid| cfg.psmp_profiles.iter().find(|p| &p.id == pid));
    build_connect_command(server, psmp)
}

#[tauri::command]
pub fn ssh_build_connect_cmd(id: String) -> Result<ConnectCommand, String> {
    let cfg = load()?;
    let server = cfg
        .servers
        .iter()
        .find(|s| s.id == id)
        .ok_or("server not found")?;
    let psmp = server
        .psmp_profile_id
        .as_ref()
        .and_then(|pid| cfg.psmp_profiles.iter().find(|p| &p.id == pid));
    build_connect_command(server, psmp)
}

#[tauri::command]
pub fn ssh_get_config() -> Result<SshConfig, String> {
    load()
}

#[tauri::command]
pub fn ssh_list_servers() -> Result<Vec<Server>, String> {
    Ok(load()?.servers)
}

#[tauri::command]
pub fn ssh_upsert_server(server: Server) -> Result<String, String> {
    let mut cfg = load()?;
    let id = upsert_server_in(&mut cfg, server)?;
    save(&cfg)?;
    Ok(id)
}

#[tauri::command]
pub fn ssh_remove_server(id: String) -> Result<(), String> {
    let mut cfg = load()?;
    let before = cfg.servers.len();
    cfg.servers.retain(|s| s.id != id);
    if cfg.servers.len() == before {
        return Err("server not found".into());
    }
    save(&cfg)
}

#[tauri::command]
pub fn ssh_upsert_psmp_profile(mut profile: PsmpProfile) -> Result<String, String> {
    if profile.psmp_address.trim().is_empty() || profile.vault_user.trim().is_empty() {
        return Err("psmpAddress and vaultUser are required".into());
    }
    let mut cfg = load()?;
    let id = if profile.id.is_empty() {
        profile.id = crate::credstore::new_id();
        let id = profile.id.clone();
        cfg.psmp_profiles.push(profile);
        id
    } else {
        let id = profile.id.clone();
        match cfg.psmp_profiles.iter_mut().find(|p| p.id == id) {
            Some(slot) => *slot = profile,
            None => cfg.psmp_profiles.push(profile),
        }
        id
    };
    save(&cfg)?;
    Ok(id)
}

#[tauri::command]
pub fn ssh_remove_psmp_profile(id: String) -> Result<(), String> {
    let mut cfg = load()?;
    // Refuse if a server still references this profile.
    if cfg
        .servers
        .iter()
        .any(|s| s.psmp_profile_id.as_deref() == Some(id.as_str()))
    {
        return Err("PSMP profile is in use by a server".into());
    }
    cfg.psmp_profiles.retain(|p| p.id != id);
    save(&cfg)
}

/// Persist CyberArk connection metadata (URL/method/TLS). NO password (§9).
#[tauri::command]
pub fn ssh_set_cyberark_config(config: CyberarkConfig) -> Result<(), String> {
    if config.base_url.trim().is_empty() {
        return Err("baseUrl is required".into());
    }
    let mut cfg = load()?;
    cfg.cyberark = Some(config);
    save(&cfg)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn srv(host: &str, port: u16, user: &str) -> Server {
        Server {
            id: String::new(),
            label: format!("{user}@{host}"),
            host: host.into(),
            port,
            username: user.into(),
            connection_type: "direct".into(),
            psmp_profile_id: None,
            credential_source: CredentialSource {
                kind: "prompt".into(),
                ..Default::default()
            },
            agent_access: false,
            ssh_options: None,
            last_connected_at: None,
            tags: vec![],
        }
    }

    // AC1 (agent-broker) — old config JSON without `agentAccess` loads as false;
    // an explicit `true` round-trips. Guards backward compatibility of the store.
    #[test]
    fn agent_access_defaults_false_when_absent() {
        let legacy = r#"{
            "id":"s1","label":"box","host":"h","port":22,"username":"u",
            "connectionType":"direct","credentialSource":{"kind":"prompt"},"tags":[]
        }"#;
        let s: Server = serde_json::from_str(legacy).unwrap();
        assert!(!s.agent_access, "missing agentAccess must default to false");

        let opt_in = r#"{
            "id":"s2","label":"box","host":"h","port":22,"username":"u",
            "connectionType":"direct","credentialSource":{"kind":"prompt"},
            "agentAccess":true,"tags":[]
        }"#;
        let s2: Server = serde_json::from_str(opt_in).unwrap();
        assert!(s2.agent_access);
        // Serializes under the camelCase key.
        assert!(serde_json::to_string(&s2)
            .unwrap()
            .contains("\"agentAccess\":true"));
    }

    // AC1.2 — adding (host,port,user) twice → second is a duplicate; list has 1.
    #[test]
    fn ac1_2_dedup_rejects_second() {
        let mut cfg = SshConfig::default();
        upsert_server_in(&mut cfg, srv("10.0.0.5", 22, "oracle")).unwrap();
        let dup = upsert_server_in(&mut cfg, srv("10.0.0.5", 22, "oracle"));
        assert!(dup.is_err(), "second identical server must be rejected");
        assert_eq!(cfg.servers.len(), 1);
    }

    // Dedup is case-insensitive on host and treats default port as 22.
    #[test]
    fn dedup_normalizes_host_case_and_port() {
        let mut cfg = SshConfig::default();
        upsert_server_in(&mut cfg, srv("Host.Corp", 22, "root")).unwrap();
        let dup = upsert_server_in(&mut cfg, srv("host.corp", 22, "root"));
        assert!(dup.is_err(), "host case must not defeat dedup");
        assert_eq!(cfg.servers.len(), 1);
    }

    // A different username on the same host is NOT a duplicate.
    #[test]
    fn different_user_is_not_duplicate() {
        let mut cfg = SshConfig::default();
        upsert_server_in(&mut cfg, srv("h", 22, "alice")).unwrap();
        upsert_server_in(&mut cfg, srv("h", 22, "bob")).unwrap();
        assert_eq!(cfg.servers.len(), 2);
    }

    // Editing a server (same id) does not collide with itself.
    #[test]
    fn edit_does_not_self_collide() {
        let mut cfg = SshConfig::default();
        let id = upsert_server_in(&mut cfg, srv("h", 22, "u")).unwrap();
        let mut edit = srv("h", 22, "u");
        edit.id = id.clone();
        edit.label = "renamed".into();
        let out = upsert_server_in(&mut cfg, edit).unwrap();
        assert_eq!(out, id);
        assert_eq!(cfg.servers.len(), 1);
        assert_eq!(cfg.servers[0].label, "renamed");
    }

    // AC1.3 — the serialized config carries no password/secret field.
    #[test]
    fn ac1_3_config_has_no_secret() {
        let mut cfg = SshConfig::default();
        upsert_server_in(&mut cfg, srv("h", 22, "u")).unwrap();
        let json = serde_json::to_string(&cfg).unwrap();
        assert!(
            !json.contains("password"),
            "config must not contain a password field"
        );
        assert!(
            !json.contains("secret"),
            "config must not contain a secret field"
        );
    }

    // PSMP server without a profile id is rejected.
    #[test]
    fn psmp_requires_profile() {
        let mut cfg = SshConfig::default();
        let mut s = srv("h", 22, "u");
        s.connection_type = "psmp".into();
        assert!(upsert_server_in(&mut cfg, s).is_err());
    }

    // Round-trip through disk keeps the servers.
    #[test]
    fn disk_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("muya-ssh-config.json");
        let mut cfg = SshConfig::default();
        upsert_server_in(&mut cfg, srv("h", 2222, "u")).unwrap();
        save_to(&path, &cfg).unwrap();
        let back = load_from(&path);
        assert_eq!(back.servers.len(), 1);
        assert_eq!(back.servers[0].port, 2222);
    }

    fn psmp() -> PsmpProfile {
        PsmpProfile {
            id: "p1".into(),
            label: "bastion".into(),
            psmp_address: "bastion.corp".into(),
            vault_user: "ferhat".into(),
            user_delim: "@".into(),
            param_delim: "#".into(),
        }
    }

    // AC2.1 — PSMP builds `vaultUser@targetUser@targetAddress@psmpAddress`, no secret.
    #[test]
    fn ac2_1_psmp_connection_string() {
        let mut s = srv("10.0.0.5", 22, "oracle");
        s.connection_type = "psmp".into();
        s.psmp_profile_id = Some("p1".into());
        let cmd = build_connect_command(&s, Some(&psmp())).unwrap();
        assert_eq!(cmd.program, "ssh");
        assert_eq!(cmd.args, vec!["ferhat@oracle@10.0.0.5@bastion.corp"]);
        assert!(!cmd.needs_password_injection);
    }

    // PSMP target on a non-standard port → `targetAddress#port` (paramDelim).
    #[test]
    fn psmp_non_standard_target_port() {
        let mut s = srv("10.0.0.5", 2222, "oracle");
        s.connection_type = "psmp".into();
        s.psmp_profile_id = Some("p1".into());
        let cmd = build_connect_command(&s, Some(&psmp())).unwrap();
        assert_eq!(cmd.args, vec!["ferhat@oracle@10.0.0.5#2222@bastion.corp"]);
    }

    // Direct: default port omits -p; non-standard adds `-p <port>`.
    #[test]
    fn direct_port_handling() {
        let cmd = build_connect_command(&srv("h", 22, "u"), None).unwrap();
        assert_eq!(cmd.args, vec!["u@h"]);
        let cmd2 = build_connect_command(&srv("h", 2222, "u"), None).unwrap();
        assert_eq!(cmd2.args, vec!["-p", "2222", "u@h"]);
    }

    // Direct + stored credential → PTY password injection flagged (prompt does not).
    #[test]
    fn direct_local_source_needs_injection() {
        let mut s = srv("h", 22, "u");
        s.credential_source = CredentialSource {
            kind: "local".into(),
            local_cred_id: Some("x".into()),
            ..Default::default()
        };
        assert!(
            build_connect_command(&s, None)
                .unwrap()
                .needs_password_injection
        );
        assert!(
            !build_connect_command(&srv("h", 22, "u"), None)
                .unwrap()
                .needs_password_injection
        );
    }

    // Extra ssh options are whitespace-split and inserted before the destination.
    #[test]
    fn extra_ssh_options_precede_destination() {
        let mut s = srv("h", 22, "u");
        s.ssh_options = Some("-X -L 8080:localhost:80 -J jump@host".into());
        let cmd = build_connect_command(&s, None).unwrap();
        assert_eq!(
            cmd.args,
            vec!["-X", "-L", "8080:localhost:80", "-J", "jump@host", "u@h"]
        );
        // With a non-standard port, `-p N` comes first, then the extra opts, then dest.
        let mut s2 = srv("h", 2222, "u");
        s2.ssh_options = Some("-v".into());
        let cmd2 = build_connect_command(&s2, None).unwrap();
        assert_eq!(cmd2.args, vec!["-p", "2222", "-v", "u@h"]);
    }

    // A PSMP server with no profile is a clear error, not a broken string.
    #[test]
    fn psmp_without_profile_errors() {
        let mut s = srv("h", 22, "u");
        s.connection_type = "psmp".into();
        assert!(build_connect_command(&s, None).is_err());
    }
}

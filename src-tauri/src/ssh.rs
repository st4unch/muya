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
    /// Provenance flag (default false): was this server created by a Claude agent
    /// via the `muya-ssh` broker's `add_server` op (vs. configured by the human in
    /// the UI)? Drives the "added by agent" badge so the operator scrutinizes an
    /// agent-chosen host before typing/attaching a credential (confused-deputy
    /// hardening, PRD D5). Old config JSON lacking `agentAdded` loads as `false`.
    #[serde(rename = "agentAdded", default)]
    pub agent_added: bool,
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
    /// PRD `ssh-scp` — extra `-o KEY=VAL …` tokens (operator-authored, whitespace
    /// split, no shell) that `ssh_scp` appends for this profile's PSMP servers.
    /// The AGENT can never pass `-o` itself (hard-denied by `enforce_scp_arg_policy`);
    /// this is the ONLY way scp gets PSMP-required `-o` options, and only the
    /// operator can set it (UI form / config file). Absent in old config JSON ⇒
    /// `None` (serde `default`) — back-compat, no scpOptions applied.
    #[serde(
        rename = "scpOptions",
        skip_serializing_if = "Option::is_none",
        default
    )]
    pub scp_options: Option<String>,
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

/// Load the on-disk SSH config for the broker's `add_server` op (agentic SSH).
/// Thin `pub(crate)` wrapper over the private `load()`.
pub(crate) fn load_config() -> Result<SshConfig, String> {
    load()
}

/// Persist the SSH config after an agent-side mutation (broker `add_server`).
/// Thin `pub(crate)` wrapper over the private `save()` (atomic temp+rename).
pub(crate) fn save_config(cfg: &SshConfig) -> Result<(), String> {
    save(cfg)
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

/// Reject values an agent could use to smuggle argv/`user@host` injection into the
/// `ssh` invocation. A host/username must be a single, plain token: non-empty and
/// free of whitespace, control chars, newlines, and `@` (which would let an agent
/// rewrite the `user@host` destination — e.g. `host="h -oProxyCommand=..."` or
/// `username="u@evil"`). This is load-bearing: everything downstream trusts these
/// are inert tokens placed verbatim into the ssh destination.
fn reject_injection(field: &str, value: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        return Err(format!("{field} is required"));
    }
    if value.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(format!(
            "{field} must not contain whitespace or control characters"
        ));
    }
    if value.contains('@') {
        return Err(format!("{field} must not contain '@'"));
    }
    Ok(())
}

/// Create a server ON BEHALF OF a Claude agent (broker `add_server` op). Structural
/// guardrails (PRD `ssh-agent-add-server`, operator-overridden D1):
///   * host + username are validated as inert tokens (`reject_injection`) — no
///     whitespace/control/`@`, so an agent cannot inject ssh flags or rewrite the
///     destination.
///   * `connection_type` is FORCED `"direct"` — an agent can never select PSMP
///     (that needs an operator-authored profile).
///   * `ssh_options` is FORCED `None` — agents never get raw ssh flags
///     (`-o ProxyCommand=` would be local RCE on the Muya host).
///   * `agent_access = true` (the agent may use what it added) and
///     `agent_added = true` (provenance → UI badge).
///   * CREATE-ONLY via `upsert_server_in`: a collision with an existing server
///     (especially a human-configured one) returns `Err` — an agent can NEVER
///     overwrite an existing server.
/// `credential_ref` (operator-approved): when `Some`, the server binds
/// `credentialSource = {kind:"local", localCredId: <ref>}` where `<ref>` is a
/// secret NAME (or id) resolved at connect time by `secret_for_ref`. When `None`
/// the server is `{kind:"prompt"}` (the human types the password). The secret value
/// is NEVER stored here — only the reference. Returns the alias (label, else id).
pub(crate) fn agent_add_server_in(
    cfg: &mut SshConfig,
    label: &str,
    host: &str,
    username: &str,
    port: Option<u16>,
    credential_ref: Option<String>,
) -> Result<String, String> {
    reject_injection("host", host)?;
    reject_injection("username", username)?;
    let port = port.unwrap_or(DEFAULT_PORT);
    if port == 0 {
        return Err("port must be 1–65535".into());
    }

    let credential_source = match credential_ref.as_deref() {
        Some(r) if !r.trim().is_empty() => CredentialSource {
            kind: "local".into(),
            local_cred_id: Some(r.to_string()),
            cyberark_account_id: None,
        },
        _ => CredentialSource {
            kind: "prompt".into(),
            ..Default::default()
        },
    };

    let server = Server {
        id: String::new(),
        label: label.trim().to_string(),
        host: host.trim().to_string(),
        port,
        username: username.trim().to_string(),
        connection_type: "direct".into(), // forced — agent cannot select PSMP
        psmp_profile_id: None,
        credential_source,
        agent_access: true, // the agent may use what it added
        ssh_options: None,  // forced — agents never get raw ssh flags (`-o ProxyCommand=`)
        last_connected_at: None,
        tags: vec![],
        agent_added: true,
    };

    // CREATE-ONLY dedup: collision (esp. with a human server) → Err, no overwrite.
    let id = upsert_server_in(cfg, server)?;
    let alias = cfg
        .servers
        .iter()
        .find(|s| s.id == id)
        .map(|s| {
            if s.label.trim().is_empty() {
                s.id.clone()
            } else {
                s.label.clone()
            }
        })
        .unwrap_or_else(|| id.clone());

    let cred_desc = credential_ref
        .as_deref()
        .filter(|r| !r.trim().is_empty())
        .unwrap_or("prompt");
    crate::debuglog::log(&format!(
        "agent added ssh server {alias} ({username}@{host}:{port}, credential={cred_desc})"
    ));
    Ok(alias)
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

/// Directory holding per-connection ControlMaster sockets (0700). `%C` (ssh's hash of
/// the connection params) names each socket, so `ssh_run` and interactive `ssh_open`
/// to the SAME server share ONE master connection — the agent reuses it instead of
/// reconnecting/re-authing per command. CyberArk PSMP documents this for password auth.
fn control_master_dir() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    format!("{home}/.claude/muya-cm")
}

/// Ensure the ControlMaster socket dir exists, private (0700). ssh does NOT create the
/// ControlPath parent, so this must run before any connection. Idempotent.
pub(crate) fn ensure_control_master_dir() {
    let dir = control_master_dir();
    if std::fs::create_dir_all(&dir).is_ok() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        }
    }
}

/// The three `-o` options that turn on connection reuse. Pure — the socket dir is
/// passed in so the builder stays testable. `ControlMaster=auto` makes the first
/// connection the master and later ones reuse it; `ControlPersist=10m` keeps the
/// master alive briefly after the last command so a burst reuses it.
fn control_master_opts(cm_dir: &str) -> Vec<String> {
    vec![
        "-o".to_string(),
        "ControlMaster=auto".to_string(),
        "-o".to_string(),
        format!("ControlPath={cm_dir}/%C"),
        "-o".to_string(),
        "ControlPersist=10m".to_string(),
    ]
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
        // NB: NO ControlMaster for PSMP. CyberArk PSMP invalidates its audited session
        // on its own timeout while the local ControlPath socket lingers, so a reused
        // connection later fails with "Invalid session state / Shared connection closed"
        // (operator-observed on k3s_w2, 2026-08-07 — worked at first, then broke). PSMP
        // servers therefore keep the reliable fresh-connection-per-command behaviour. L41.
        let mut args = extra_ssh_opts(server);
        args.push(dest);
        return Ok(ConnectCommand {
            program: "ssh".into(),
            args,
            needs_password_injection: needs_injection(server),
        });
    }
    // direct — connection reuse is safe here (no PSMP session-state constraint)
    let mut args = Vec::new();
    if server.port != DEFAULT_PORT {
        args.push("-p".to_string());
        args.push(server.port.to_string());
    }
    args.extend(extra_ssh_opts(server));
    args.extend(control_master_opts(&control_master_dir()));
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
            // Resolve by REFERENCE (name OR id): the human UI picker stores an id,
            // while an agent-added server stores the secret NAME. `secret_for_ref`
            // matches either, so both paths work.
            let reference = server.credential_source.local_cred_id.as_deref().ok_or(
                "credential source is 'Local password store' but no credential is selected",
            )?;
            Some(crate::credstore::secret_for_ref(&cred, reference)?)
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

// ---------------------------------------------------------------------------
// SCP command building (PRD `ssh-scp`) — reuses the same server/PSMP config as
// `build_connect_command`, but never lets the agent supply `-o`/port-in-dest:
// Muya alone assembles the destination string and any `-o` options.
// ---------------------------------------------------------------------------

/// Explicit transfer direction — NEVER inferred from argument order/shape (a
/// mistaken inference could turn a download into an upload of the wrong file, or
/// vice versa). The broker parses the agent's `direction` string into this enum
/// before any path is touched.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ScpDirection {
    Upload,
    Download,
}

/// The `scp` invocation to run. Like `ConnectCommand`, NEVER carries a secret —
/// the credential (when needed) is injected into the PTY by `run_with_injection`,
/// exactly as `ssh_run` does.
pub(crate) struct ScpCommand {
    pub program: String,
    pub args: Vec<String>,
    pub needs_password_injection: bool,
}

/// Build the `scp` argv for one transfer (PURE, testable). `extra_args` MUST
/// already be policed by the caller (`enforce_scp_arg_policy` in `broker.rs`) —
/// this function does not re-validate flags, only assembles the command.
/// `local_path` MUST already be guardrail-checked (`local_guard::resolve_local_scp_path`)
/// — this function trusts it verbatim.
///
/// PSMP destination (verified against `docs.cyberark.com`, PRD AC5): SCP has no
/// `#`-delimited "extra params" syntax the way an interactive `ssh` PSMP session
/// does (`#` is not a valid SCP host-spec separator), so the destination is ONLY
/// `vaultUser@targetUser@targetAddress@psmpAddress` — a single `@`-delimited
/// chain — and a non-default port is passed via `-P`, never embedded in the dest.
pub(crate) fn build_scp_command(
    server: &Server,
    psmp: Option<&PsmpProfile>,
    direction: ScpDirection,
    local_path: &str,
    remote_path: &str,
    recursive: bool,
    extra_args: &[String],
) -> Result<ScpCommand, String> {
    let mut args: Vec<String> = Vec::new();
    // Muya-owned diagnostics option — mirrors `assemble_run_args`'s forced
    // `-o LogLevel=ERROR` so verbose ssh/scp chatter can't leak into captured
    // output. Always first, before anything agent- or profile-supplied.
    args.push("-o".to_string());
    args.push("LogLevel=ERROR".to_string());

    // When Muya injects a stored/CyberArk password, force password auth by disabling
    // pubkey. Otherwise scp tries publickey FIRST and, against a PSMP proxy that
    // offers (publickey, keyboard-interactive), the connection is closed with
    // "Permission denied (publickey,keyboard-interactive)" / exit 255 BEFORE the
    // "Vault Password:" prompt ever appears for PTY injection. ssh_run works because
    // the operator put this in the server's ssh_options; the scp builder never
    // inherited it (operator-diagnosed against a real PSMP, 2026-08-05). (L33)
    if needs_injection(server) {
        args.push("-o".to_string());
        args.push("PubkeyAuthentication=no".to_string());
    }

    let dest_spec = if server.connection_type == "psmp" {
        let p = psmp.ok_or("PSMP server has no profile")?;
        // Force the LEGACY scp protocol through PSMP. OpenSSH 9.0+ made scp use the
        // SFTP subsystem by default; CyberArk PSMP proxies the legacy scp/exec channel
        // (the same one ssh_run uses — which is why ssh_run works) but not the SFTP
        // subsystem, so a default scp fails through PSMP (exit 255 / SFTP-negotiation
        // timeout / exit 1). `-O` restores the exec-based protocol PSMP understands.
        // Operator-diagnosed against a real PSMP (k3s_master), 2026-08-06. (L35)
        args.push("-O".to_string());
        if server.port != DEFAULT_PORT {
            args.push("-P".to_string());
            args.push(server.port.to_string());
        }
        // Operator-authored `-o KEY=VAL …` for this PSMP profile ONLY — the agent
        // never supplies `-o` (hard-denied in enforce_scp_arg_policy).
        if let Some(opts) = p.scp_options.as_deref() {
            for tok in opts.split_whitespace() {
                args.push(tok.to_string());
            }
        }
        format!(
            "{vu}@{tu}@{ta}@{px}",
            vu = p.vault_user,
            tu = server.username,
            ta = server.host,
            px = p.psmp_address
        )
    } else {
        if server.port != DEFAULT_PORT {
            args.push("-P".to_string());
            args.push(server.port.to_string());
        }
        format!("{}@{}", server.username, server.host)
    };

    if recursive {
        args.push("-r".to_string());
    }
    // Agent-supplied flags — ALREADY policed by `enforce_scp_arg_policy` before
    // this function is called (fail-closed: `-o/-F/-i/-S/-P` never reach here).
    args.extend(extra_args.iter().cloned());

    let (src, dst) = match direction {
        ScpDirection::Upload => (local_path.to_string(), format!("{dest_spec}:{remote_path}")),
        ScpDirection::Download => (format!("{dest_spec}:{remote_path}"), local_path.to_string()),
    };
    args.push(src);
    args.push(dst);

    Ok(ScpCommand {
        program: "scp".into(),
        args,
        needs_password_injection: needs_injection(server),
    })
}

/// Resolve `server`'s PSMP profile from on-disk config (if any) and build the
/// `scp` argv. Public for the SSH Agent Broker's `ssh_scp` (`broker.rs::handle_scp`).
pub(crate) fn scp_command_for(
    server: &Server,
    direction: ScpDirection,
    local_path: &str,
    remote_path: &str,
    recursive: bool,
    extra_args: &[String],
) -> Result<ScpCommand, String> {
    let cfg = load()?;
    let psmp = server
        .psmp_profile_id
        .as_ref()
        .and_then(|pid| cfg.psmp_profiles.iter().find(|p| &p.id == pid));
    build_scp_command(
        server,
        psmp,
        direction,
        local_path,
        remote_path,
        recursive,
        extra_args,
    )
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

    /// Drop the ControlMaster `-o` options so destination/port/opts-ordering assertions
    /// stay focused. ControlMaster presence is covered by its own test below.
    fn without_cm(args: &[String]) -> Vec<String> {
        let mut out = Vec::new();
        let mut i = 0;
        while i < args.len() {
            if args[i] == "-o"
                && i + 1 < args.len()
                && (args[i + 1] == "ControlMaster=auto"
                    || args[i + 1].starts_with("ControlPath=")
                    || args[i + 1].starts_with("ControlPersist="))
            {
                i += 2;
            } else {
                out.push(args[i].clone());
                i += 1;
            }
        }
        out
    }

    #[test]
    fn control_master_opts_shape() {
        assert_eq!(
            control_master_opts("/tmp/cm"),
            vec![
                "-o",
                "ControlMaster=auto",
                "-o",
                "ControlPath=/tmp/cm/%C",
                "-o",
                "ControlPersist=10m",
            ]
        );
    }

    #[test]
    fn connect_reuse_on_direct_only_never_psmp() {
        // Direct servers get connection reuse (safe)…
        let direct = build_connect_command(&srv("h", 22, "u"), None).unwrap();
        assert!(direct.args.iter().any(|a| a == "ControlMaster=auto"));
        assert!(direct
            .args
            .iter()
            .any(|a| a.starts_with("ControlPath=") && a.ends_with("/%C")));
        assert_eq!(direct.args.last().unwrap(), "u@h"); // destination stays last
                                                        // …but PSMP must NOT (its audited session goes invalid → stale-master failures). L41.
        let mut s = srv("10.0.0.5", 22, "oracle");
        s.connection_type = "psmp".into();
        s.psmp_profile_id = Some("p1".into());
        let psmp_cmd = build_connect_command(&s, Some(&psmp())).unwrap();
        assert!(
            !psmp_cmd.args.iter().any(|a| a == "ControlMaster=auto"),
            "PSMP must not get ControlMaster: {:?}",
            psmp_cmd.args
        );
        assert!(!psmp_cmd.args.iter().any(|a| a.starts_with("ControlPath=")));
        assert_eq!(
            psmp_cmd.args.last().unwrap(),
            "ferhat@oracle@10.0.0.5@bastion.corp"
        );
    }

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
            agent_added: false,
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
            scp_options: None,
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
        assert_eq!(
            without_cm(&cmd.args),
            vec!["ferhat@oracle@10.0.0.5@bastion.corp"]
        );
        assert!(!cmd.needs_password_injection);
    }

    // PSMP target on a non-standard port → `targetAddress#port` (paramDelim).
    #[test]
    fn psmp_non_standard_target_port() {
        let mut s = srv("10.0.0.5", 2222, "oracle");
        s.connection_type = "psmp".into();
        s.psmp_profile_id = Some("p1".into());
        let cmd = build_connect_command(&s, Some(&psmp())).unwrap();
        assert_eq!(
            without_cm(&cmd.args),
            vec!["ferhat@oracle@10.0.0.5#2222@bastion.corp"]
        );
    }

    // Direct: default port omits -p; non-standard adds `-p <port>`.
    #[test]
    fn direct_port_handling() {
        let cmd = build_connect_command(&srv("h", 22, "u"), None).unwrap();
        assert_eq!(without_cm(&cmd.args), vec!["u@h"]);
        let cmd2 = build_connect_command(&srv("h", 2222, "u"), None).unwrap();
        assert_eq!(without_cm(&cmd2.args), vec!["-p", "2222", "u@h"]);
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
            without_cm(&cmd.args),
            vec!["-X", "-L", "8080:localhost:80", "-J", "jump@host", "u@h"]
        );
        // With a non-standard port, `-p N` comes first, then the extra opts, then dest.
        let mut s2 = srv("h", 2222, "u");
        s2.ssh_options = Some("-v".into());
        let cmd2 = build_connect_command(&s2, None).unwrap();
        assert_eq!(without_cm(&cmd2.args), vec!["-p", "2222", "-v", "u@h"]);
    }

    // A PSMP server with no profile is a clear error, not a broken string.
    #[test]
    fn psmp_without_profile_errors() {
        let mut s = srv("h", 22, "u");
        s.connection_type = "psmp".into();
        assert!(build_connect_command(&s, None).is_err());
    }

    // ---- agent_add_server_in (PRD ssh-agent-add-server) ------------------

    // A plain agent-add (no credential) creates a direct, prompt server flagged
    // agent_added + agent_access, with ssh_options forced None.
    #[test]
    fn agent_add_creates_prompt_direct_flagged() {
        let mut cfg = SshConfig::default();
        let alias =
            agent_add_server_in(&mut cfg, "web1", "10.0.0.9", "deploy", None, None).unwrap();
        assert_eq!(alias, "web1");
        assert_eq!(cfg.servers.len(), 1);
        let s = &cfg.servers[0];
        assert!(s.agent_added);
        assert!(s.agent_access);
        assert_eq!(s.connection_type, "direct");
        assert!(s.ssh_options.is_none());
        assert_eq!(s.port, 22, "port defaults to 22");
        assert_eq!(s.credential_source.kind, "prompt");
        assert!(!s.id.is_empty());
    }

    // Passing a credential ref binds credentialSource kind="local" with the ref
    // (a NAME) — resolved at connect time, NOT the secret value.
    #[test]
    fn agent_add_with_credential_ref_binds_local_by_name() {
        let mut cfg = SshConfig::default();
        agent_add_server_in(
            &mut cfg,
            "db",
            "10.0.0.5",
            "oracle",
            Some(2222),
            Some("prod-db-pass".into()),
        )
        .unwrap();
        let s = &cfg.servers[0];
        assert_eq!(s.port, 2222);
        assert_eq!(s.credential_source.kind, "local");
        assert_eq!(
            s.credential_source.local_cred_id.as_deref(),
            Some("prod-db-pass")
        );
        // The stored Server holds only the reference, never a secret value.
        let json = serde_json::to_string(s).unwrap();
        assert!(!json.contains("password") || json.contains("prod-db-pass"));
        assert!(!json.to_lowercase().contains("secret"));
    }

    // Injection-shaped host or username is rejected (argv / user@host smuggling).
    #[test]
    fn agent_add_rejects_injection_in_host_or_user() {
        let mut cfg = SshConfig::default();
        // whitespace (would split into extra argv / flags)
        assert!(agent_add_server_in(
            &mut cfg,
            "x",
            "h -oProxyCommand=touch /tmp/x",
            "u",
            None,
            None
        )
        .is_err());
        // newline
        assert!(agent_add_server_in(&mut cfg, "x", "h\nevil", "u", None, None).is_err());
        // `@` rewrites the destination
        assert!(agent_add_server_in(&mut cfg, "x", "host", "u@evil", None, None).is_err());
        assert!(agent_add_server_in(&mut cfg, "x", "h@evil", "u", None, None).is_err());
        // empty host / user
        assert!(agent_add_server_in(&mut cfg, "x", "", "u", None, None).is_err());
        assert!(agent_add_server_in(&mut cfg, "x", "h", "  ", None, None).is_err());
        // nothing was persisted
        assert_eq!(cfg.servers.len(), 0);
    }

    // CREATE-ONLY: an agent cannot overwrite an existing (esp. human) server.
    #[test]
    fn agent_add_is_create_only_no_overwrite() {
        let mut cfg = SshConfig::default();
        // A human-configured server on the same host/port/user.
        upsert_server_in(&mut cfg, srv("10.0.0.5", 22, "oracle")).unwrap();
        let human_id = cfg.servers[0].id.clone();
        let dup = agent_add_server_in(&mut cfg, "evil", "10.0.0.5", "oracle", Some(22), None);
        assert!(dup.is_err(), "agent must not overwrite an existing server");
        assert_eq!(cfg.servers.len(), 1);
        // The original human server is untouched (not flagged agent_added).
        assert_eq!(cfg.servers[0].id, human_id);
        assert!(!cfg.servers[0].agent_added);
    }

    // agentAdded serde: default false when absent, round-trips under camelCase.
    #[test]
    fn agent_added_serde_default_and_roundtrip() {
        let legacy = r#"{
            "id":"s1","label":"box","host":"h","port":22,"username":"u",
            "connectionType":"direct","credentialSource":{"kind":"prompt"},"tags":[]
        }"#;
        let s: Server = serde_json::from_str(legacy).unwrap();
        assert!(!s.agent_added, "missing agentAdded must default to false");

        let mut cfg = SshConfig::default();
        agent_add_server_in(&mut cfg, "a", "h", "u", None, None).unwrap();
        let json = serde_json::to_string(&cfg.servers[0]).unwrap();
        assert!(json.contains("\"agentAdded\":true"));
    }

    // ---- build_scp_command (PRD ssh-scp) ----------------------------------

    // AC5 — PSMP scp destination is `vaultUser@targetUser@targetAddress@psmpAddress`
    // (ONLY `@`, never the ssh dest's `#paramDelim` port trick), plus the profile's
    // `scpOptions` `-o`s. Pure builder — no live PSMP needed.
    // L35: PSMP scp must force the legacy protocol (-O); a direct scp must not (its
    // SFTP-based transfer works against a normal sshd and is what the Docker e2e uses).
    #[test]
    fn scp_forces_legacy_protocol_for_psmp_only() {
        let mut p = srv("h", 22, "u");
        p.connection_type = "psmp".into();
        let cmd = build_scp_command(
            &p,
            Some(&psmp()),
            ScpDirection::Upload,
            "/l",
            "/r",
            false,
            &[],
        )
        .unwrap();
        assert!(
            cmd.args.iter().any(|a| a == "-O"),
            "psmp scp needs -O: {:?}",
            cmd.args
        );

        let d = srv("h", 22, "u"); // direct
        let cmd2 =
            build_scp_command(&d, None, ScpDirection::Upload, "/l", "/r", false, &[]).unwrap();
        assert!(
            !cmd2.args.iter().any(|a| a == "-O"),
            "direct scp must not force -O: {:?}",
            cmd2.args
        );
    }

    #[test]
    fn ac5_psmp_scp_dest_uses_only_at_delim_plus_scp_options() {
        let mut s = srv("10.0.0.5", 22, "oracle");
        s.connection_type = "psmp".into();
        s.psmp_profile_id = Some("p1".into());
        let mut profile = psmp();
        profile.scp_options = Some("-o ProxyCommand=none -o ServerAliveInterval=30".into());
        let cmd = build_scp_command(
            &s,
            Some(&profile),
            ScpDirection::Upload,
            "/local/file.txt",
            "/remote/file.txt",
            false,
            &[],
        )
        .unwrap();
        assert_eq!(cmd.program, "scp");
        // Muya's -o LogLevel=ERROR, then -O (legacy scp protocol for PSMP, L35), then
        // the profile's scpOptions tokens, then src/dst.
        assert_eq!(
            cmd.args,
            vec![
                "-o",
                "LogLevel=ERROR",
                "-O",
                "-o",
                "ProxyCommand=none",
                "-o",
                "ServerAliveInterval=30",
                "/local/file.txt",
                "ferhat@oracle@10.0.0.5@bastion.corp:/remote/file.txt",
            ]
        );
        // Never a `#` delimiter (illegal as an SCP host-spec separator).
        assert!(!cmd.args.iter().any(|a| a.contains('#')));
    }

    // AC5 — a non-default PSMP target port goes via `-P`, NEVER embedded in the
    // destination string (SCP has no `#port` syntax the way interactive ssh does).
    #[test]
    fn ac5_psmp_scp_non_standard_port_uses_dash_p_not_dest_embed() {
        let mut s = srv("10.0.0.5", 2222, "oracle");
        s.connection_type = "psmp".into();
        s.psmp_profile_id = Some("p1".into());
        let cmd = build_scp_command(
            &s,
            Some(&psmp()),
            ScpDirection::Download,
            "/local/out.txt",
            "/remote/in.txt",
            false,
            &[],
        )
        .unwrap();
        assert!(cmd.args.contains(&"-P".to_string()));
        assert!(cmd.args.contains(&"2222".to_string()));
        // Download: dest_spec:remotePath is the SRC (second-to-last is dest here:
        // src then dst — download puts the remote spec first).
        let dest = cmd
            .args
            .iter()
            .find(|a| a.contains("bastion.corp"))
            .unwrap();
        assert_eq!(dest, "ferhat@oracle@10.0.0.5@bastion.corp:/remote/in.txt");
        assert!(!dest.contains('#'), "no #port embed: {dest}");
    }

    // Direct (non-PSMP) upload/download dest shapes.
    #[test]
    fn direct_scp_upload_and_download_dest_shapes() {
        let s = srv("h", 22, "u");
        let up = build_scp_command(
            &s,
            None,
            ScpDirection::Upload,
            "/local/a.txt",
            "/remote/a.txt",
            false,
            &[],
        )
        .unwrap();
        assert_eq!(
            up.args,
            vec!["-o", "LogLevel=ERROR", "/local/a.txt", "u@h:/remote/a.txt"]
        );
        let down = build_scp_command(
            &s,
            None,
            ScpDirection::Download,
            "/local/b.txt",
            "/remote/b.txt",
            false,
            &[],
        )
        .unwrap();
        assert_eq!(
            down.args,
            vec!["-o", "LogLevel=ERROR", "u@h:/remote/b.txt", "/local/b.txt"]
        );
    }

    // L33 regression: when Muya will inject a password, scp must disable pubkey so it
    // reaches the (keyboard-interactive) password prompt instead of failing pubkey
    // first — the real-PSMP bug the operator diagnosed on 2026-08-05. A "prompt"
    // server (no injection) must NOT get the option.
    #[test]
    fn scp_forces_no_pubkey_only_when_injecting() {
        let mut inject = srv("h", 22, "u");
        inject.credential_source = CredentialSource {
            kind: "local".into(),
            local_cred_id: Some("cred-1".into()),
            ..Default::default()
        };
        let cmd = build_scp_command(
            &inject,
            None,
            ScpDirection::Upload,
            "/l/a",
            "/r/a",
            false,
            &[],
        )
        .unwrap();
        assert!(
            cmd.args
                .windows(2)
                .any(|w| w == ["-o", "PubkeyAuthentication=no"]),
            "injecting scp must disable pubkey; got {:?}",
            cmd.args
        );

        // A "prompt" server (default srv) injects nothing → no PubkeyAuthentication=no.
        let prompt = srv("h", 22, "u");
        let cmd2 = build_scp_command(
            &prompt,
            None,
            ScpDirection::Upload,
            "/l/a",
            "/r/a",
            false,
            &[],
        )
        .unwrap();
        assert!(
            !cmd2.args.iter().any(|a| a == "PubkeyAuthentication=no"),
            "prompt scp must not force pubkey-off; got {:?}",
            cmd2.args
        );
    }

    // `recursive:true` inserts `-r` before src/dst; policed extraArgs (already
    // validated upstream) are appended after it.
    #[test]
    fn recursive_and_extra_args_ordering() {
        let s = srv("h", 22, "u");
        let cmd = build_scp_command(
            &s,
            None,
            ScpDirection::Upload,
            "/local/dir",
            "/remote/dir",
            true,
            &["-p".to_string(), "-C".to_string()],
        )
        .unwrap();
        assert_eq!(
            cmd.args,
            vec![
                "-o",
                "LogLevel=ERROR",
                "-r",
                "-p",
                "-C",
                "/local/dir",
                "u@h:/remote/dir",
            ]
        );
    }

    // A PSMP server with no resolved profile is a clear error, not a broken string.
    #[test]
    fn scp_psmp_without_profile_errors() {
        let mut s = srv("h", 22, "u");
        s.connection_type = "psmp".into();
        assert!(build_scp_command(&s, None, ScpDirection::Upload, "/l", "/r", false, &[]).is_err());
    }

    // `scpOptions` absent in old config JSON deserializes to `None` (back-compat).
    #[test]
    fn psmp_profile_scp_options_defaults_none() {
        let legacy = r#"{
            "id":"p1","label":"bastion","psmpAddress":"bastion.corp","vaultUser":"ferhat"
        }"#;
        let p: PsmpProfile = serde_json::from_str(legacy).unwrap();
        assert!(p.scp_options.is_none());
        // And round-trips when set.
        let mut p2 = p.clone();
        p2.scp_options = Some("-o Foo=Bar".into());
        let json = serde_json::to_string(&p2).unwrap();
        assert!(json.contains("\"scpOptions\":\"-o Foo=Bar\""));
    }

    /// AC1/AC2 — END-TO-END: `build_scp_command` + `pty::run_with_injection` against
    /// a REAL sshd (same Docker container the pre-existing `ssh_run` live tests use:
    /// `lscr.io/linuxserver/openssh-server`, 127.0.0.1:2222, testuser/Sup3rSecret!).
    /// Proves the actual mechanism `ssh_scp` will run in production: (1) upload
    /// writes the real file remotely, independently re-verified via a plain `ssh cat`
    /// (not just scp's own exit code), and (2) download reads a real remote file back
    /// to a local path with matching content. The injected password never appears in
    /// any captured output. `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`
    /// are TEST-ONLY additions (this throwaway container has no stable host key) —
    /// `build_scp_command` itself never sets those (production keeps host-key
    /// checking on); see `ac5_*`/`direct_scp_*` unit tests for the exact argv it emits.
    ///
    /// Ignored by default (needs the container). Run:
    ///   docker start muya-ssh-test  # or `docker run` per pty.rs's test header
    ///   cargo test scp_upload_download_live -- --ignored --nocapture
    #[test]
    #[ignore]
    fn scp_upload_download_live() {
        use zeroize::Zeroizing;

        let dir = tempfile::tempdir().unwrap();
        let upload_src = dir.path().join("upload_src.txt");
        std::fs::write(&upload_src, b"MUYA_SCP_UPLOAD_OK\n").unwrap();
        let download_dst = dir.path().join("download_dst.txt");
        let remote_name = "muya_scp_live_test.txt";
        let pw = || Some(Zeroizing::new("Sup3rSecret!".to_string()));
        let test_only_opts = |mut args: Vec<String>| -> Vec<String> {
            let mut prefixed = vec![
                "-o".to_string(),
                "StrictHostKeyChecking=no".to_string(),
                "-o".to_string(),
                "UserKnownHostsFile=/dev/null".to_string(),
            ];
            prefixed.append(&mut args);
            prefixed
        };

        let server = srv("127.0.0.1", 2222, "testuser");

        // (1) Upload local -> remote (relative remote path = the login's home dir).
        let up = build_scp_command(
            &server,
            None,
            ScpDirection::Upload,
            &upload_src.to_string_lossy(),
            remote_name,
            false,
            &[],
        )
        .unwrap();
        let up_out = crate::pty::run_with_injection(
            &up.program,
            &test_only_opts(up.args),
            pw(),
            std::time::Duration::from_secs(25),
            false,
        )
        .expect("upload run_with_injection");
        assert!(!up_out.timed_out, "upload timed out: {:?}", up_out.stdout);
        assert!(
            !up_out.stdout.contains("Sup3rSecret!"),
            "SECRET LEAKED in upload output: {:?}",
            up_out.stdout
        );

        // Independent re-verification: `ssh cat` the file remotely (not just trusting
        // scp's own exit code) — proves the upload actually landed with the right
        // content, not merely that scp returned 0.
        let cat_args: Vec<String> = test_only_opts(vec![
            "-p".to_string(),
            "2222".to_string(),
            "testuser@127.0.0.1".to_string(),
            format!("cat {remote_name}"),
        ]);
        let cat_out = crate::pty::run_with_injection(
            "ssh",
            &cat_args,
            pw(),
            std::time::Duration::from_secs(25),
            false,
        )
        .expect("cat run_with_injection");
        assert!(
            cat_out.stdout.contains("MUYA_SCP_UPLOAD_OK"),
            "uploaded file content mismatch, remote cat returned: {:?}",
            cat_out.stdout
        );
        assert!(!cat_out.stdout.contains("Sup3rSecret!"));

        // (2) Download remote -> local: read the SAME remote file back to a fresh
        // local path, confirm the bytes match what was uploaded.
        let down = build_scp_command(
            &server,
            None,
            ScpDirection::Download,
            &download_dst.to_string_lossy(),
            remote_name,
            false,
            &[],
        )
        .unwrap();
        let down_out = crate::pty::run_with_injection(
            &down.program,
            &test_only_opts(down.args),
            pw(),
            std::time::Duration::from_secs(25),
            false,
        )
        .expect("download run_with_injection");
        assert!(
            !down_out.timed_out,
            "download timed out: {:?}",
            down_out.stdout
        );
        assert!(!down_out.stdout.contains("Sup3rSecret!"));
        let downloaded = std::fs::read_to_string(&download_dst)
            .expect("downloaded file must exist locally after scp download");
        assert_eq!(
            downloaded, "MUYA_SCP_UPLOAD_OK\n",
            "downloaded content mismatch: {downloaded:?}"
        );

        println!("scp_upload_download_live: upload + independent remote cat + download all PASS");
    }
}

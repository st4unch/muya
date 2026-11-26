//! `Control::Rpc` handler (protocol minor 2): the app's calls into muya-core logic that muyad owns or
//! hosts — session history / search / export, the schedules (muyad is the single owner of the timers,
//! D8) and the preferences stored by muya-core. One JSON object in, one JSON value out; errors are
//! plain English messages the UI can show as they are.

use crate::Muyad;
use crate::rpc_agents;
use crate::rpc_git as git;
use muya_core::{agents, app_prefs, claude_settings, credstore, cyberark, debuglog, history, migrate, schedules, sessions, ssh, workspace_roots};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Weak;
use std::sync::atomic::AtomicBool;

/// The one answer every secret-touching method gives until the Touch ID / unlock decision (S6):
/// the daemon holds no unlocked vault, so it never sees a master password or a secret value.
pub const LOCKED: &str = muya_core::credstore::LOCKED_MSG;
const QUEUE_OFF: &str = "not enabled in this build";
/// Longest transcript text returned by `sessions.transcript`.
const MAX_TRANSCRIPT: usize = 256 * 1024;

#[derive(Deserialize)]
struct ConnectParams {
    id: String,
    cols: Option<u16>,
    rows: Option<u16>,
}

const CYBERARK_LOGON: &str = "Log on to CyberArk first (SSH > CyberArk tab).";

pub struct Rpc {
    schedules: schedules::ScheduleState,
    muyad: Weak<Muyad>,
    /// The password store, shared with the MCP broker (`MuyadBrokerHost`). Same file and format as classic Muya
    /// (`~/.claude/muya-ssh-vault.enc`, `muya_core::credstore`): a classic user's vault opens here unchanged.
    vault: std::sync::Arc<credstore::CredStore>,
    /// When a person last used the store (unlock, or the app's interaction pings): see `vault_idle`.
    idle: std::sync::Arc<crate::vault_idle::IdleClock>,
    cyberark: std::sync::Arc<cyberark::CyberarkState>,
    metrics: rpc_agents::MetricsState,
    /// P10: the bridge (local socket + remote pairing); None = this Rpc serves no bridge.
    bridge: Option<crate::bridge_host::MuyadBridgeHost>,
    /// Host of `sessions.send_command`, built on first use (it only needs the daemon's terminals).
    send_host: std::sync::OnceLock<crate::broker_host::MuyadBrokerHost>,
}

#[derive(Deserialize)]
struct TailParams {
    id: u64,
    #[serde(default)]
    lines: Option<usize>,
}

#[derive(Deserialize)]
struct SendCommandParams {
    /// Terminal ids the operator picked in the app.
    ids: Vec<u64>,
    text: String,
}

#[derive(Deserialize)]
struct CwdParams {
    cwd: String,
}

#[derive(Deserialize)]
struct DiffParams {
    cwd: String,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    staged: bool,
}

#[derive(Deserialize)]
struct LogParams {
    cwd: String,
    #[serde(default = "default_log_limit")]
    limit: usize,
    #[serde(default)]
    skip: usize,
}

fn default_log_limit() -> usize {
    50
}

#[derive(Deserialize)]
struct PlanStatusParams {
    cwd: String,
    slug: String,
    status: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TranscriptParams {
    session_id: String,
    cwd: String,
    #[serde(default = "default_turns")]
    limit: usize,
    #[serde(default)]
    query: Option<String>,
}

fn default_turns() -> usize {
    40
}

#[derive(Deserialize)]
struct IdOnly {
    id: String,
}

#[derive(Deserialize)]
struct AgentsParams {
    #[serde(default)]
    all: bool,
}

#[derive(Deserialize)]
struct QueryParams {
    #[serde(default)]
    query: String,
}

#[derive(Deserialize)]
struct SearchParams {
    query: String,
    #[serde(default)]
    sessions: Vec<sessions::SessionRef>,
}

/// `sessions.archive` / `sessions.restore`: transcript paths (live ones for archive, archived ones for restore) and, for archive, the ids of running sessions.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HousekeepParams {
    paths: Vec<String>,
    #[serde(default)]
    live_ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExportParams {
    session_id: String,
    #[serde(default)]
    cwd: String,
    #[serde(default)]
    path: Option<String>,
    dest: String,
    /// The caller asked the operator and got a yes: replace `dest` if it exists.
    #[serde(default)]
    overwrite: bool,
}

#[derive(Deserialize)]
struct JobParams {
    job: schedules::JobInput,
}

#[derive(Deserialize)]
struct IdParams {
    id: String,
    #[serde(default)]
    enabled: bool,
}

fn parse<T: serde::de::DeserializeOwned>(params: &str) -> Result<T, String> {
    serde_json::from_str(params).map_err(|e| format!("bad parameters: {e}"))
}

fn parse_or_default<T: serde::de::DeserializeOwned>(params: &str) -> Result<T, String> {
    parse(if params.trim().is_empty() { "{}" } else { params })
}

#[derive(Deserialize)]
struct SidParams {
    sid: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VaultAddParams {
    label: String,
    #[serde(default)]
    description: String,
    secret_kind: String,
    secret: String,
    #[serde(default)]
    username: String,
    #[serde(default)]
    group: String,
}

#[derive(Deserialize)]
struct VaultIdParams {
    id: String,
}

/// `vault.save`: the Password Store's add/edit form (same shape as classic's `credstore_cred_upsert`).
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VaultSaveParams {
    #[serde(default)]
    id: Option<String>,
    label: String,
    #[serde(default)]
    username: String,
    secret_kind: String,
    secret: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    group: String,
}

#[derive(Deserialize)]
struct VaultDestParams {
    dest: String,
}

#[derive(Deserialize)]
struct VaultExportMasterParams {
    dest: String,
    master: String,
}

#[derive(Deserialize)]
struct VaultExportCredParams {
    id: String,
    dest: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VaultImportParams {
    label: String,
    #[serde(default)]
    username: String,
    #[serde(default = "default_key_kind")]
    secret_kind: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    group: String,
    src_path: String,
}

fn default_key_kind() -> String {
    "key".into()
}

/// The Password Store methods that read, change or write out secret material: only the app's own connection (the
/// operator) may call them. Agents use the broker, which has no such op; this keeps a future path that forwards agent
/// calls here from reaching the vault.
pub fn vault_operator_only(method: &str) -> bool {
    matches!(
        method,
        "vault.reveal" | "vault.save" | "vault.remove" | "vault.add" | "vault.update" | "vault.export_backup" | "vault.export_master" | "vault.export_cred" | "vault.import_key" | "vault.import_secret"
    )
}

#[derive(Deserialize)]
struct VaultMasterParams {
    master: String,
}

#[derive(Deserialize, Default)]
struct VaultUnlockParams {
    /// The master password. Absent + `biometric: true` = ask the Keychain (Touch ID).
    #[serde(default)]
    master: Option<String>,
    #[serde(default)]
    biometric: bool,
    /// After a master-password unlock, also turn Touch ID on (writes this app's own Keychain item).
    #[serde(default, rename = "enableTouchId")]
    enable_touch_id: bool,
}

#[derive(Deserialize)]
struct VaultUpdateParams {
    /// Name (label) or id of the credential.
    reference: String,
    secret: String,
}

/// Runs one async credstore call to completion on a private runtime (the RPC handlers are synchronous).
fn run_async<T>(f: impl std::future::Future<Output = Result<T, String>>) -> Result<T, String> {
    tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| format!("runtime: {e}"))?.block_on(f)
}

/// A store error that only means "not unlocked" becomes the standard locked text; anything else is shown as it is.
fn locked_or(e: String) -> String {
    if e.to_lowercase().contains("locked") { LOCKED.to_string() } else { e }
}

/// Words for an unlock failure: wrong password vs no file vs damaged file, never a bare "not completed".
pub fn unlock_error(e: &str) -> String {
    let l = e.to_lowercase();
    if l.contains("decryption failed") {
        "Wrong master password.".into()
    } else if l.contains("store not readable") && (l.contains("no such file") || l.contains("not found")) {
        "There is no password store on this Mac yet (~/.claude/muya-ssh-vault.enc).".into()
    } else if l.contains("not a muya ssh vault") || l.contains("store parse") || l.contains("store decode") {
        "The password store file is damaged or is not a Muya vault.".into()
    } else {
        e.to_string()
    }
}

/// Words for a Keychain / Touch ID failure.
pub fn touchid_error(e: String) -> String {
    let l = e.to_lowercase();
    if l.contains("entitlement") || l.contains("-34018") {
        "Touch ID is not available for this build of Muya (macOS refused Keychain access). Use the master password.".into()
    } else if l.contains("could not be found") || l.contains("not found") {
        "Touch ID is not set up in this app yet — unlock with the master password once and turn Touch ID on.".into()
    } else if l.contains("cancel") || l.contains("user canceled") || l.contains("-128") {
        "Touch ID was cancelled.".into()
    } else if l.contains("decryption failed") {
        "The Touch ID key no longer matches the store (the master password changed). Unlock with the master password and turn Touch ID on again.".into()
    } else {
        e
    }
}

fn to_value<T: serde::Serialize>(v: &T) -> Result<Value, String> {
    serde_json::to_value(v).map_err(|e| format!("encode: {e}"))
}

impl Rpc {
    pub fn new(schedules: schedules::ScheduleState) -> Self {
        Self { schedules, muyad: Weak::new(), vault: std::sync::Arc::new(credstore::CredStore::default()), idle: crate::vault_idle::IdleClock::new(), cyberark: std::sync::Arc::default(), metrics: rpc_agents::MetricsState::default(), bridge: None, send_host: std::sync::OnceLock::new() }
    }

    /// Lets the git/plan methods see the folders of the sessions this daemon spawned.
    pub fn with_muyad(mut self, muyad: Weak<Muyad>) -> Self {
        self.muyad = muyad;
        self
    }

    /// Serve `vault.*` from this store (the same one the broker reads); without it the Rpc keeps its own.
    pub fn with_vault(mut self, vault: std::sync::Arc<credstore::CredStore>) -> Self {
        self.vault = vault;
        self
    }

    /// Share the CyberArk logon with the MCP broker (`ssh_open` / `ssh_session_open` fetch passwords with it).
    pub fn with_cyberark(mut self, c: std::sync::Arc<cyberark::CyberarkState>) -> Self {
        self.cyberark = c;
        self
    }

    /// Count idle time on `clock` (shared with the `vault_idle` watcher).
    pub fn with_idle(mut self, clock: std::sync::Arc<crate::vault_idle::IdleClock>) -> Self {
        self.idle = clock;
        self
    }

    pub fn with_bridge(mut self, bridge: crate::bridge_host::MuyadBridgeHost) -> Self {
        self.bridge = Some(bridge);
        self
    }

    fn vault_unlock(&self, params: &str) -> Result<Value, String> {
        let p: VaultUnlockParams = parse_or_default(params)?;
        let status = credstore::credstore_status(&self.vault)?;
        if !status.initialized {
            return Err("There is no password store on this Mac yet (~/.claude/muya-ssh-vault.enc).".into());
        }
        if status.unlocked {
            return Ok(json!({ "unlocked": true, "touchId": null }));
        }
        self.idle.touch();
        let mut touch: Value = Value::Null;
        match p.master {
            Some(master) => {
                let master = zeroize::Zeroizing::new(master);
                if master.is_empty() {
                    return Err("Type the master password.".into());
                }
                run_async(credstore::credstore_unlock(master.to_string(), &self.vault)).map_err(|e| unlock_error(&e))?;
                if p.enable_touch_id {
                    // Best effort: the unlock itself already worked, so a Keychain refusal is reported next to it.
                    touch = match credstore::credstore_enable_biometric_unlock(&self.vault) {
                        Ok(()) => json!({ "enabled": true }),
                        Err(e) => json!({ "enabled": false, "error": touchid_error(e) }),
                    };
                }
            }
            None if p.biometric => {
                run_async(credstore::credstore_unlock_biometric(&self.vault)).map_err(|e| touchid_error(e))?;
            }
            None => return Err("Type the master password.".into()),
        }
        Ok(json!({ "unlocked": true, "touchId": touch }))
    }

    fn on_muyad(&self, f: impl FnOnce(&Muyad) -> Result<Value, String>) -> Result<Value, String> {
        match self.muyad.upgrade() {
            Some(m) => f(&m),
            None => Err("this muyad serves no sessions".into()),
        }
    }

    /// A folder the caller named, accepted only inside Muya's roots (see `rpc_git`).
    fn guard(&self, cwd: &str, cancel: &AtomicBool) -> Result<std::path::PathBuf, String> {
        let spawned = self.muyad.upgrade().map(|m| m.spawn_cwds()).unwrap_or_default();
        git::guard_dir(cwd, &git::all_roots(spawned), cancel)
    }

    /// Runs one call on the calling thread (the connection spawns one thread per call). `cancel` is
    /// polled by the long ones.
    pub fn call(&self, method: &str, params: &str, cancel: &AtomicBool) -> Result<Value, String> {
        // The control socket is the app's own connection (muyactl is read-only and agents use the broker).
        self.call_as(crate::rpc_bridge::Caller::Operator, method, params, cancel)
    }

    pub fn call_as(&self, caller: crate::rpc_bridge::Caller, method: &str, params: &str, cancel: &AtomicBool) -> Result<Value, String> {
        if vault_operator_only(method) && caller != crate::rpc_bridge::Caller::Operator {
            return Err("the Password Store's reveal / edit / export / import are operator-only: use the Password Store tab".into());
        }
        if let Some(bridge) = &self.bridge {
            if let Some(r) = crate::rpc_bridge::call(bridge, method, caller, || parse_or_default::<Value>(params)) {
                return r;
            }
        }
        match method {
            "sessions.history" => to_value(&history::list_session_history()?),
            // Today's Clean up → Archive / Restore (src-tauri history.rs): files only ever move, between ~/.claude/projects and Muya's session-archive.
            "sessions.archived" => to_value(&history::list_archived_sessions()?),
            "sessions.archive" => {
                let p: HousekeepParams = parse(params)?;
                to_value(&history::archive_sessions(p.paths, p.live_ids)?)
            }
            "sessions.restore" => {
                let p: HousekeepParams = parse(params)?;
                to_value(&history::restore_sessions(p.paths)?)
            }
            "sessions.search" => {
                let p: SearchParams = parse(params)?;
                let found = sessions::search_sessions_blocking(&p.query, &p.sessions, cancel);
                to_value(&found)
            }
            "sessions.export" => {
                let p: ExportParams = parse(params)?;
                sessions::export_session_markdown_blocking(&p.session_id, &p.cwd, p.path.as_deref(), &p.dest, p.overwrite)?;
                Ok(json!({ "dest": p.dest }))
            }
            "schedules.list" => {
                let r = self.schedules.list()?;
                let mut v = to_value(&r)?;
                // The app is a client of muyad: when muyad itself holds the timers they are "the service".
                if v["runner"] == "here" {
                    v["runner"] = json!("service");
                }
                Ok(v)
            }
            "schedules.validate" => {
                let p: JobParams = parse(params)?;
                Ok(json!({ "folder": schedules::validate(&p.job)? }))
            }
            "schedules.save" => {
                let p: JobParams = parse(params)?;
                to_value(&self.schedules.save(p.job)?)
            }
            "schedules.set_enabled" => {
                let p: IdParams = parse(params)?;
                self.schedules.set_job_enabled(&p.id, p.enabled)?;
                Ok(Value::Null)
            }
            "schedules.delete" => {
                let p: IdParams = parse(params)?;
                self.schedules.delete_job(&p.id)?;
                Ok(Value::Null)
            }
            "schedules.runs" => {
                let p: IdParams = parse(params)?;
                to_value(&self.schedules.runs(&p.id)?)
            }
            "schedules.run_now" => {
                let p: IdParams = parse(params)?;
                self.schedules.run_now(&p.id)?;
                Ok(Value::Null)
            }
            "prefs.get" => {
                let mut v = to_value(&app_prefs::app_prefs_get())?;
                v["claudeCleanupDays"] = json!(claude_settings::claude_cleanup_days_get());
                Ok(v)
            }
            "prefs.set" => {
                let v: Value = parse(params)?;
                if v.get("keepRunningInBackground").is_some() || v.get("claudeStatusInFooter").is_some() {
                    let mut cur = to_value(&app_prefs::app_prefs_get())?;
                    for k in ["keepRunningInBackground", "claudeStatusInFooter"] {
                        if let Some(x) = v.get(k) {
                            cur[k] = x.clone();
                        }
                    }
                    app_prefs::app_prefs_set(serde_json::from_value(cur).map_err(|e| format!("bad parameters: {e}"))?)?;
                }
                if let Some(days) = v.get("claudeCleanupDays").and_then(Value::as_u64) {
                    claude_settings::claude_cleanup_days_set(u32::try_from(days).map_err(|_| "cleanup days out of range".to_string())?)?;
                }
                let mut out = to_value(&app_prefs::app_prefs_get())?;
                out["claudeCleanupDays"] = json!(claude_settings::claude_cleanup_days_get());
                Ok(out)
            }
            "debug_log.get" => debuglog::debug_log_get(),
            "debug_log.set" => {
                let v: Value = parse(params)?;
                let enabled = v.get("enabled").and_then(Value::as_bool).ok_or("enabled is missing")?;
                let path = v.get("path").and_then(Value::as_str).unwrap_or("").to_string();
                debuglog::debug_log_set(enabled, path)?;
                debuglog::debug_log_get()
            }
            "migrate.run" => {
                let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
                Ok(match migrate::run(std::path::Path::new(&home)) {
                    migrate::Outcome::Migrated { keys } => json!({ "outcome": "migrated", "keys": keys }),
                    migrate::Outcome::AlreadyDone => json!({ "outcome": "already_done" }),
                    migrate::Outcome::NothingToMigrate => json!({ "outcome": "nothing_to_migrate" }),
                    migrate::Outcome::Unreadable(why) => json!({ "outcome": "unreadable", "reason": why }),
                })
            }
            "upgrade.status" => {
                // Also the app's probe for AC21: trying the link here is what makes an approved ptyd get adopted while
                // the onboarding screen polls, and `ptyd_linked` is how the app learns that it is still not approved.
                let m = self.muyad.upgrade().ok_or_else(|| "this muyad serves no sessions".to_string())?;
                let linked = m.ensure_link().is_ok();
                let mut v = m.upgrade_status();
                v["ptyd_linked"] = json!(linked);
                Ok(v)
            }
            "upgrade.resume_plan" => self.on_muyad(|m| Ok(m.resume_plan())),
            "upgrade.resume_done" => self.on_muyad(|m| m.resume_done().map(|()| json!({ "ok": true })).map_err(|e| format!("could not forget the plan: {e}"))),
            // The operator's "Command" dialog: the broker's tracked delivery for several terminals at once.
            "sessions.send_command" => {
                let p: SendCommandParams = parse(params)?;
                let m = self.muyad.upgrade().ok_or("this muyad serves no sessions")?;
                let host = self.send_host.get_or_init(|| crate::broker_host::MuyadBrokerHost::new(m, self.schedules.clone()));
                let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| format!("tokio runtime: {e}"))?;
                let results = rt.block_on(muya_core::broker::operator_send(host, &p.ids, &p.text))?;
                Ok(json!({ "results": results }))
            }
            // The last lines a session printed (works after the process exited: muyad keeps the terminal state until
            // the session is closed). The app shows them in the exit panel of a Claude tab that ended unexpectedly.
            "sessions.tail" => {
                let p: TailParams = parse(params)?;
                self.on_muyad(|m| {
                    let lines = m.screen_lines(p.id).ok_or("no such session")?;
                    Ok(json!({ "lines": crate::tail_lines(lines, p.lines.unwrap_or(20).clamp(1, 200)) }))
                })
            }
            "agents.list" => {
                let p: AgentsParams = parse_or_default(params)?;
                to_value(&agents::list_agent_sessions_sync(Some(p.all))?)
            }
            "sessions.transcript" => {
                let p: TranscriptParams = parse(params)?;
                if p.session_id.is_empty() || p.session_id.contains(['/', '\\', '\0']) || p.session_id.contains("..") {
                    return Err("bad session id".into());
                }
                if !p.cwd.starts_with('/') {
                    return Err("cwd must be an absolute folder path".into());
                }
                let query = p.query.as_deref().map(str::trim).filter(|q| !q.is_empty());
                let mut text = sessions::read_transcript_tail(&p.cwd, &p.session_id, p.limit.clamp(1, 200), query)?;
                let truncated = text.len() > MAX_TRANSCRIPT;
                if truncated {
                    let mut cut = MAX_TRANSCRIPT;
                    while !text.is_char_boundary(cut) {
                        cut -= 1;
                    }
                    text.truncate(cut);
                }
                Ok(json!({ "text": text, "truncated": truncated }))
            }
            "ssh.servers.list" => to_value(&ssh::ssh_list_servers()?),
            "ssh.servers.save" => {
                let v: Value = parse(params)?;
                let server: ssh::Server = serde_json::from_value(v.get("server").cloned().unwrap_or(Value::Null)).map_err(|e| format!("bad parameters: {e}"))?;
                Ok(json!({ "id": ssh::ssh_upsert_server(server)? }))
            }
            "ssh.servers.delete" => {
                let p: IdOnly = parse(params)?;
                ssh::ssh_remove_server(p.id)?;
                Ok(Value::Null)
            }
            "ssh.psmp.list" => to_value(&ssh::ssh_get_config()?.psmp_profiles),
            "ssh.psmp.save" => {
                let v: Value = parse(params)?;
                let profile: ssh::PsmpProfile = serde_json::from_value(v.get("profile").cloned().unwrap_or(Value::Null)).map_err(|e| format!("bad parameters: {e}"))?;
                Ok(json!({ "id": ssh::ssh_upsert_psmp_profile(profile)? }))
            }
            "ssh.psmp.delete" => {
                let p: IdOnly = parse(params)?;
                ssh::ssh_remove_psmp_profile(p.id)?;
                Ok(Value::Null)
            }
            "ssh.connect" => {
                // The daemon spawns `ssh` as a session and injects the stored / CyberArk password (classic ssh_pty_connect).
                let p: ConnectParams = parse(params)?;
                let muyad = self.muyad.upgrade().ok_or("daemon is shutting down")?;
                let cfg = ssh::load_config()?;
                let server = cfg.servers.iter().find(|s| s.id == p.id).ok_or("server not found")?.clone();
                if server.credential_source.kind == "local" && !credstore::credstore_status(&self.vault)?.unlocked {
                    return Err(LOCKED.into());
                }
                let secret = run_async(crate::ssh_connect::resolve_secret(&self.vault, &self.cyberark, &server)).map_err(|e| if e.contains("not logged on") { CYBERARK_LOGON.to_string() } else { e })?;
                let id = muyad.ssh_connect(&p.id, secret, p.cols, p.rows)?;
                Ok(json!({ "session": id }))
            }
            "ssh.cyberark.get" => to_value(&ssh::ssh_get_config()?.cyberark),
            "ssh.cyberark.set" => {
                let v: Value = parse(params)?;
                let config: ssh::CyberarkConfig = serde_json::from_value(v.get("config").cloned().unwrap_or(Value::Null)).map_err(|e| format!("bad parameters: {e}"))?;
                ssh::ssh_set_cyberark_config(config)?;
                Ok(Value::Null)
            }
            "cyberark.status" => Ok(json!({ "loggedOn": run_async(cyberark::cyberark_status(&self.cyberark))? })),
            "cyberark.logoff" => {
                run_async(cyberark::cyberark_logoff(&self.cyberark))?;
                Ok(Value::Null)
            }
            "cyberark.logon" | "cyberark.test" => {
                let v: Value = parse(params)?;
                let config: ssh::CyberarkConfig = serde_json::from_value(v.get("config").cloned().unwrap_or(Value::Null)).map_err(|e| format!("bad parameters: {e}"))?;
                let username = v.get("username").and_then(Value::as_str).unwrap_or_default().to_string();
                let master = zeroize::Zeroizing::new(v.get("master").and_then(Value::as_str).unwrap_or_default().to_string());
                if method == "cyberark.logon" {
                    run_async(cyberark::cyberark_logon(&self.cyberark, &self.vault, config, username, master.to_string()))?;
                    Ok(Value::Null)
                } else {
                    run_async(cyberark::cyberark_test_connection(&self.cyberark, &self.vault, config, username, master.to_string())).map(Value::String)
                }
            }
            "cyberark.accounts.search" => {
                // Listing accounts needs a CyberArk logon, and the logon needs a vault secret.
                let p: QueryParams = parse_or_default(params)?;
                let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| format!("runtime: {e}"))?;
                match rt.block_on(cyberark::cyberark_list_accounts(&self.cyberark, Some(p.query))) {
                    Ok(list) => to_value(&list),
                    Err(e) if e.contains("not logged on") => Err(LOCKED.into()),
                    Err(e) => Err(e),
                }
            }
            "vault.lock" => rpc_agents::vault_lock(self.muyad.upgrade(), &self.vault),
            // The status line of a session this daemon spawned (`statusline.get` takes the capture token).
            "statusline.session" => {
                let p: SidParams = parse(params)?;
                self.on_muyad(|m| Ok(m.status_token(p.sid).map(|t| muya_core::statusline::statusline_get(t).unwrap_or(Value::Null)).unwrap_or(Value::Null)))
            }
            "metrics.get" => self.on_muyad(|m| Ok(self.metrics.get(&m.session_sids()))),
            "vault.status" => {
                let s = credstore::credstore_status(&self.vault)?;
                Ok(json!({
                    "initialized": s.initialized,
                    "unlocked": s.unlocked,
                    // Touch ID is offered only when it was turned on AND this app can see its own Keychain item
                    // (classic's item lives in classic's access group: unlock once with the master password).
                    "biometricAvailable": credstore::credstore_biometric_available() && credstore::keychain_item_visible().unwrap_or(false),
                    "touchidReenableNeeded": credstore::touchid_reenable_needed(),
                }))
            }
            // The master password (or the Touch ID request) arrives over the owner-only, peer-checked daemon
            // socket and never leaves this process; the derived key is wiped on `vault.lock`.
            "vault.unlock" => self.vault_unlock(params),
            // The app saw a mouse / key / scroll event (classic: "any interaction anywhere in Muya"): restart the idle clock.
            "vault.activity" => {
                self.idle.touch();
                Ok(Value::Null)
            }
            "vault.init" => {
                let p: VaultMasterParams = parse(params)?;
                let master = zeroize::Zeroizing::new(p.master);
                if master.trim().is_empty() {
                    return Err("Choose a master password.".into());
                }
                if credstore::credstore_status(&self.vault)?.initialized {
                    return Err("A password store already exists — unlock it with its master password.".into());
                }
                run_async(credstore::credstore_init(master.to_string(), &self.vault))?;
                self.idle.touch();
                Ok(Value::Null)
            }
            "vault.touchid.enable" => {
                credstore::credstore_enable_biometric_unlock(&self.vault).map_err(touchid_error)?;
                Ok(Value::Null)
            }
            "vault.touchid.disable" => {
                credstore::credstore_disable_biometric_unlock()?;
                Ok(Value::Null)
            }
            "vault.list" => match credstore::list_meta(&self.vault) {
                Ok(list) => to_value(&list),
                Err(_) => Err(LOCKED.into()),
            },
            "vault.add" => {
                let p: VaultAddParams = parse(params)?;
                let secret = zeroize::Zeroizing::new(p.secret);
                if !credstore::valid_secret_kind(&p.secret_kind) {
                    return Err("unknown secret kind".into());
                }
                credstore::add_credential(&self.vault, p.label, p.description, p.secret_kind, secret.to_string())
                    .map_err(locked_or)
                    .and_then(|m| {
                        // The agent-facing add has no username/group; the Password Store form does.
                        if p.username.is_empty() && p.group.is_empty() {
                            return to_value(&m);
                        }
                        credstore::credstore_cred_upsert(
                            credstore::CredInput {
                                id: Some(m.id.clone()),
                                label: m.label.clone(),
                                username: p.username.clone(),
                                secret_kind: m.secret_kind.clone(),
                                secret: zeroize::Zeroizing::new(secret.to_string()),
                                description: m.description.clone(),
                                group: p.group.clone(),
                                key_passphrase: None,
                            },
                            &self.vault,
                        )
                        .map_err(locked_or)?;
                        to_value(&credstore::CredMeta { username: p.username, group: p.group, ..m })
                    })
            }
            // The operator's own Password Store tab (eye / edit / delete), as in classic. The reveal goes to the
            // app over this socket only; agents never get a value (their broker returns placeholders).
            "vault.reveal" => {
                let p: VaultIdParams = parse(params)?;
                credstore::reveal_cred(&self.vault, &p.id).map(Value::String).map_err(locked_or)
            }
            "vault.save" => {
                let p: VaultSaveParams = parse(params)?;
                if p.label.trim().is_empty() {
                    return Err("a name is required".into());
                }
                credstore::credstore_cred_upsert(
                    credstore::CredInput {
                        id: p.id,
                        label: p.label.trim().to_string(),
                        username: p.username,
                        secret_kind: p.secret_kind,
                        secret: zeroize::Zeroizing::new(p.secret),
                        description: p.description,
                        group: p.group.trim().to_string(),
                        key_passphrase: None,
                    },
                    &self.vault,
                )
                .map(Value::String)
                .map_err(locked_or)
            }
            // Classic's "Export encrypted store backup": a copy of the sealed file (still needs the master password).
            "vault.export_backup" => {
                let p: VaultDestParams = parse(params)?;
                credstore::credstore_export(p.dest).map(|_| Value::Null)
            }
            // Classic's "Export master password" on the create screen: the typed master as plain text in the picked file
            // (0600), by explicit operator request. The value is never logged and never leaves this process otherwise.
            "vault.export_master" => {
                let p: VaultExportMasterParams = parse(params)?;
                let master = zeroize::Zeroizing::new(p.master);
                credstore::credstore_export_master(p.dest, master.to_string()).map(|_| Value::Null)
            }
            // Classic's per-card Export: the secret written as plain text to the file the operator picked (0600).
            "vault.export_cred" => {
                let p: VaultExportCredParams = parse(params)?;
                credstore::credstore_export_cred(p.id, p.dest, &self.vault).map(|_| Value::Null).map_err(locked_or)
            }
            "vault.import_key" => {
                let p: VaultImportParams = parse(params)?;
                credstore::credstore_import_key(p.label, p.username, p.src_path, &self.vault).map(Value::String).map_err(locked_or)
            }
            "vault.import_secret" => {
                let p: VaultImportParams = parse(params)?;
                credstore::credstore_import_secret(p.label, p.username, p.secret_kind, p.description, p.group, p.src_path, &self.vault).map(Value::String).map_err(locked_or)
            }
            "vault.remove" => {
                let p: VaultIdParams = parse(params)?;
                credstore::credstore_cred_remove(p.id, &self.vault).map(|_| Value::Null).map_err(locked_or)
            }
            "vault.update" => {
                let p: VaultUpdateParams = parse(params)?;
                let secret = zeroize::Zeroizing::new(p.secret);
                credstore::update_credential(&self.vault, &p.reference, secret.to_string()).map_err(locked_or).and_then(|m| to_value(&m))
            }
            "workspace.set_roots" => {
                let v: Value = parse(params)?;
                let roots: Vec<String> = serde_json::from_value(v.get("roots").cloned().unwrap_or(Value::Null)).map_err(|e| format!("bad parameters: {e}"))?;
                if roots.len() > 512 || roots.iter().any(|r| !r.starts_with('/')) {
                    return Err("roots must be at most 512 absolute paths".into());
                }
                workspace_roots::set_workspace_roots(roots)?;
                Ok(Value::Null)
            }
            "git.status" => {
                let p: CwdParams = parse(params)?;
                git::status(&self.guard(&p.cwd, cancel)?, cancel)
            }
            "git.diff" => {
                let p: DiffParams = parse(params)?;
                git::diff(&self.guard(&p.cwd, cancel)?, p.path.as_deref(), p.staged, cancel)
            }
            "git.worktrees" => {
                let p: CwdParams = parse(params)?;
                git::worktrees(&self.guard(&p.cwd, cancel)?, cancel)
            }
            "git.branches" => {
                let p: CwdParams = parse(params)?;
                git::branches(&self.guard(&p.cwd, cancel)?)
            }
            "git.log" => {
                let p: LogParams = parse(params)?;
                git::log(&self.guard(&p.cwd, cancel)?, p.limit, p.skip, cancel)
            }
            "plan.list" => {
                let p: CwdParams = parse(params)?;
                git::plan_list(&self.guard(&p.cwd, cancel)?)
            }
            "plan.set_status" => {
                let p: PlanStatusParams = parse(params)?;
                git::plan_set_status(&self.guard(&p.cwd, cancel)?, &p.slug, &p.status)
            }
            // Destructive (push / merge / delete): an operator decision, not part of this build.
            "queue.run" => Err(QUEUE_OFF.into()),
            other => match git::call_p6(other, params, &|d| self.guard(d, cancel)).or_else(|| rpc_agents::call(other, params, |p| parse_or_default::<Value>(p)))
                .or_else(|| crate::rpc_resources::call(other, params, &|d| self.guard(d, cancel)))
                .or_else(|| crate::rpc_term_history::call(other, params))
                .or_else(|| crate::rpc_vault_notes::call(other, params))
                .or_else(|| crate::switchover_host::call(other, params, &self.muyad)) {
                Some(r) => r,
                None => Err(format!("unknown method '{other}'")),
            },
        }
    }
}

#[cfg(test)]
mod operator_only_tests {
    use super::*;

    #[test]
    fn an_agent_caller_is_refused_every_vault_read_write_export_and_import() {
        let rpc = Rpc::new(schedules::ScheduleState::client());
        let cancel = AtomicBool::new(false);
        for m in ["vault.reveal", "vault.save", "vault.remove", "vault.add", "vault.update", "vault.export_backup", "vault.export_master", "vault.export_cred", "vault.import_key", "vault.import_secret"] {
            let e = rpc.call_as(crate::rpc_bridge::Caller::Agent, m, "{}", &cancel).unwrap_err();
            assert!(e.contains("operator-only"), "{m}: {e}");
            // the operator's own connection is not refused for that reason (it fails on its parameters instead)
            let e = rpc.call_as(crate::rpc_bridge::Caller::Operator, m, "{}", &cancel).unwrap_err();
            assert!(!e.contains("operator-only"), "{m}: {e}");
        }
        assert!(!vault_operator_only("vault.list") && !vault_operator_only("vault.status"));
    }
}

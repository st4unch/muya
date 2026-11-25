//! SSH Agent Broker (PRD `ssh-agent-broker`, Faz 1 — AC3–AC7).
//!
//! A dedicated owner-only Unix-domain socket that lets the `muya-ssh` MCP proxy
//! (a separate stdio process Claude Code spawns — see `src/bin/muya_ssh_mcp.rs`)
//! ask the *running Muya app* to (a) list SSH servers the operator opted into and
//! (b) open a terminal for one by alias — WITHOUT any secret ever reaching the
//! proxy or the model.
//!
//! Trust boundary (deliberately SEPARATE from `bridge.rs`):
//!   * Different socket + env var (`MUYA_SSH_BROKER_SOCK`), different trust domain.
//!     The chat bridge runs `claude -p`; this one only lists/opens SSH targets.
//!   * File mode 0600 AND a `getpeereid` uid check (bridge.rs has NO peer check) —
//!     only processes running as *this* uid may connect. macOS uses `getpeereid`
//!     (SO_PEERCRED is Linux-only; the ADR wrote it generically).
//!
//! Security invariant: passwords/keys are resolved ONLY in the app process and
//! injected into the PTY by the existing `ssh_pty_connect` path. The broker never
//! serializes a secret — `open` merely emits a Tauri event that triggers that
//! path; `list_servers` returns non-secret metadata only.
//!
//! Wire protocol (app <-> proxy): newline-delimited JSON, one request and one
//! response per line (MCP stdio itself is also newline-delimited, but that framing
//! lives in the proxy; this socket speaks a tiny private request/response schema).
//!   Request : {"op":"list_servers"} | {"op":"open","alias":"<label|id>"}
//!   Response: {"ok":true,"servers":[..]} | {"ok":true} | {"ok":false,"error":".."}

use std::collections::{HashMap, HashSet};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::{AsRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex as StdMutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::{Mutex, Semaphore};
use zeroize::Zeroizing;

use crate::ssh::Server;

// ---------------------------------------------------------------------------
// Host seam
// ---------------------------------------------------------------------------

/// Non-secret projection of a vault entry (the broker never sees the stored secret
/// through this type).
#[derive(Clone, Debug)]
pub struct SecretMeta {
    pub label: String,
    pub description: String,
    pub secret_kind: String,
    pub group: String,
}

/// A change to a vault entry made by an agent. `None` leaves a field as it is.
#[derive(Clone, Debug, Default)]
pub struct SecretEdit {
    pub value: Option<String>,
    pub new_name: Option<String>,
    pub description: Option<String>,
    pub kind: Option<String>,
    pub group: Option<String>,
}

impl SecretEdit {
    pub fn is_empty(&self) -> bool {
        self.value.is_none()
            && self.new_name.is_none()
            && self.description.is_none()
            && self.kind.is_none()
            && self.group.is_none()
    }
}

/// Points every server whose credential is `old` at `new` (after a secret rename).
fn retarget_server_credentials(old: &str, new: &str) {
    if let Ok(mut cfg) = crate::ssh::load_config() {
        let mut changed = false;
        for sv in cfg.servers.iter_mut() {
            if sv.credential_source.local_cred_id.as_deref() == Some(old) {
                sv.credential_source.local_cred_id = Some(new.to_string());
                changed = true;
            }
        }
        if changed {
            let _ = crate::ssh::save_config(&cfg);
        }
    }
}

/// Everything the broker needs from the process that hosts it: the Tauri app today,
/// `muyad` later. Async methods use return-position `impl Future` (no `async-trait`);
/// the broker functions are generic over the host, so there is no `dyn` anywhere.
pub trait BrokerHost: Send + Sync + 'static {
    /// Listener + permit pool shared by every request this host serves.
    fn broker(&self) -> &BrokerState;
    /// Persistent agent SSH sessions.
    fn agent_ssh(&self) -> &crate::agent_ssh::AgentSshStore;

    /// Deliver an event to the UI (`ssh-broker-open`, `muya://deliver-message`, ...).
    fn emit(&self, event: &str, payload: serde_json::Value) -> Result<(), String>;

    /// Idempotency for typed deliveries (PRD AC25). `Ok(true)` = first time this key is seen
    /// (already persisted when this returns); `Ok(false)` = a retry, do not type again. A host
    /// without a persistent store (the Tauri app today) delivers every time.
    fn claim_delivery(&self, _key: &str) -> Result<bool, String> {
        Ok(true)
    }

    /// Gives a [`claim_delivery`](Self::claim_delivery) key back after a failed hand-off.
    fn release_delivery(&self, _key: &str) {}

    // ---- password vault ---------------------------------------------------
    fn vault_is_unlocked(&self) -> bool;
    fn vault_list_meta(&self) -> Result<Vec<SecretMeta>, String>;
    fn vault_add_credential(
        &self,
        name: String,
        description: String,
        kind: String,
        value: String,
    ) -> Result<SecretMeta, String>;
    fn vault_secret_for_ref(&self, reference: &str) -> Result<Zeroizing<String>, String>;
    fn vault_secret_for(&self, id: &str) -> Result<Zeroizing<String>, String>;
    fn vault_edit_credential(
        &self,
        reference: &str,
        edit: SecretEdit,
    ) -> Result<SecretMeta, String>;

    /// Fetch a CyberArk account password.
    fn cyberark_password(
        &self,
        account_id: &str,
    ) -> impl std::future::Future<Output = Result<Zeroizing<String>, String>> + Send;

    /// One `schedule*` agent operation (runs the blocking work off the async runtime).
    fn schedule_op(
        &self,
        op: String,
        key: Option<String>,
        fields: Option<serde_json::Value>,
        enabled: Option<bool>,
        limit: Option<usize>,
    ) -> impl std::future::Future<Output = Result<serde_json::Value, String>> + Send;

    /// One `bridge_*` op; the returned JSON is the complete response.
    fn bridge_handle(
        &self,
        op: &str,
        args: &serde_json::Value,
        caller: &str,
    ) -> impl std::future::Future<Output = serde_json::Value> + Send;

    // ---- session registry (blocking; the broker calls these from spawn_blocking) --
    // ---- terminals (the native app's PTY tabs; shell AND agent) ------------------
    // Blocking, like the registry calls below. Hosts that own no PTYs (the Tauri app) keep the
    // defaults and the three terminal tools answer `NATIVE_ONLY`.
    /// Every live terminal with its kind, name and whether it waits on a permission prompt.
    fn terminal_list(&self) -> Result<Vec<TerminalInfo>, String> {
        Err(NATIVE_ONLY.into())
    }
    /// Starts a plain shell tab (named `name`) in `cwd`, optionally running `command`; returns its id.
    fn terminal_open(
        &self,
        _name: &str,
        _cwd: Option<&str>,
        _command: Option<&str>,
    ) -> Result<u64, String> {
        Err(NATIVE_ONLY.into())
    }
    /// Types `text` into terminal `id` as a paste (control bytes neutralised), then Enter when `enter`.
    /// `agent`: the target is a TUI that needs a beat between the paste and its Enter.
    fn terminal_type(
        &self,
        _id: u64,
        _text: &str,
        _enter: bool,
        _agent: bool,
    ) -> Result<(), String> {
        Err(NATIVE_ONLY.into())
    }
    /// Sends `text` to terminal `id` byte for byte (Enter is `"\r"`), nothing neutralised, no wrapping.
    fn terminal_raw(&self, _id: u64, _text: &str) -> Result<(), String> {
        Err(NATIVE_ONLY.into())
    }

    /// `Some` on a host that owns the terminals itself (muyad): `open_session` then waits until the
    /// tab really runs Claude (and its first message was submitted) and `send_to_session` types and
    /// checks the submission itself, instead of firing an event at an app and reporting success.
    /// `None` (the Tauri app): the old fire-and-forget behaviour.
    fn tracking(&self) -> Option<Tracking> {
        None
    }

    /// The visible screen lines of terminal `id` (for the secret gate and the retype guard). `None` = unknown.
    fn terminal_lines(&self, _id: u64) -> Option<Vec<String>> {
        None
    }
    /// Whether the PTY of terminal `id` echoes typed characters (termios ECHO). `None` = unknown.
    fn terminal_echo(&self, _id: u64) -> Option<bool> {
        None
    }

    /// Hosts without their own registry use [`default_list_agent_sessions_fresh`].
    fn list_agent_sessions_fresh(include_all: Option<bool>) -> Result<Vec<AgentSession>, String>;
    /// Hosts without their own transcript reader use [`default_read_transcript_tail`].
    fn read_transcript_tail(
        cwd: &str,
        session_id: &str,
        limit: usize,
        query: Option<&str>,
    ) -> Result<String, String>;
}

/// Answer of the terminal tools on a host that has no PTYs of its own.
pub const NATIVE_ONLY: &str = "terminal tools need the native Muya app";

/// One terminal tab as the broker sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalInfo {
    pub id: u64,
    /// The tab's name: the one `open_terminal` gave, a Claude session's own name, else its folder.
    pub name: String,
    pub cwd: String,
    /// "claude" (a Claude conversation runs in it) or "shell".
    pub kind: String,
    pub claude_session_id: Option<String>,
    /// Why the terminal is blocked, e.g. "permission prompt".
    pub waiting_for: Option<String>,
}

/// Default for [`BrokerHost::list_agent_sessions_fresh`]: `claude agents --json` (+ opencode),
/// cache bypassed. Tauri-free, so the app and muyad share it.
pub fn default_list_agent_sessions_fresh(
    include_all: Option<bool>,
) -> Result<Vec<AgentSession>, String> {
    crate::agents::list_agent_sessions_fresh(include_all)
}

/// Default for [`BrokerHost::read_transcript_tail`]: the Claude transcript JSONL reader.
pub fn default_read_transcript_tail(
    cwd: &str,
    session_id: &str,
    limit: usize,
    query: Option<&str>,
) -> Result<String, String> {
    crate::sessions::read_transcript_tail(cwd, session_id, limit, query)
}

/// Mirrors the frontend `AgentSession` TypeScript interface (camelCase via serde).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSession {
    pub id: String,
    pub name: String,
    pub branch: String,
    pub worktree: String,
    /// One of: working | waiting-for-input | idle | stopped
    pub status: String,
    pub active_task: String,
    pub active_file: String,
    pub tokens_used: u64,
    pub models_used: String,
    pub quota_burn: f64,
    pub duration: String,
    pub created_at: String,
    /// True for background sessions, which `claude attach <id>` can connect to.
    pub attachable: bool,
    /// Id to pass to `claude attach` (short background id, else the full sessionId).
    pub attach_id: String,
    /// OS process id (for stopping interactive sessions that have no background id).
    pub pid: Option<i64>,
    /// Set when this session was spawned by another Claude agent (sub-agent tree).
    pub parent_id: Option<String>,
    /// Why the session is blocked, when `status == "waiting-for-input"` — e.g.
    /// `"permission prompt"`. `claude agents --json` reports this as `waitingFor`;
    /// surfaced so an agent can tell "waiting for a normal reply" apart from
    /// "stuck on a Y/N dialog it should answer" before deciding to act.
    pub waiting_for: Option<String>,
    /// Which CLI this session belongs to — "claude" or "opencode". The Sessions
    /// list merges both, and every action on a row (resume, attach, stop) spells
    /// its flags differently per CLI, so the row must carry its own origin.
    pub agent: String,
}

/// Session ids the agent has opened via `ssh_open` and may write to with `ssh_send`.
/// An id is added when the open is signalled and removed when the tab closes, so a
/// stale id (closed tab) can never be written to. Kept process-wide (not per-request)
/// because opens and sends are separate MCP calls.
static SSH_SESSIONS: LazyLock<StdMutex<HashSet<String>>> =
    LazyLock::new(|| StdMutex::new(HashSet::new()));

/// Live channel subscribers (PRD `bridge-channel-delivery`): Claude session id → the
/// write side of that session's muya-mcp sidecar subscription. A sidecar subscribes
/// only when its `claude` process was started with Muya's channel flag, so a message
/// pushed here appears in the session as a channel event instead of being typed into
/// its terminal. Entries go away when the sidecar's connection closes.
static CHANNELS: LazyLock<StdMutex<HashMap<String, tokio::sync::mpsc::UnboundedSender<String>>>> =
    LazyLock::new(|| StdMutex::new(HashMap::new()));

/// Push one channel event (`{"content": …, "meta": {…}}`) to `session_id`'s sidecar.
/// False when that session has no live subscriber — the caller falls back to the
/// terminal, so a message is never silently dropped.
pub fn push_channel(session_id: &str, event: &serde_json::Value) -> bool {
    let mut map = CHANNELS.lock().unwrap();
    let Some(tx) = map.get(session_id) else {
        return false;
    };
    if tx.send(event.to_string()).is_ok() {
        return true;
    }
    map.remove(session_id); // receiver gone: the sidecar exited
    false
}

/// Channel event for a message from another Claude session on THIS Mac
/// (`send_to_session(deliver:"muya")`). Meta keys are letters/digits/underscores only:
/// Claude Code silently drops any other key.
pub fn session_channel_event(from: &str, text: &str) -> serde_json::Value {
    let mut meta = serde_json::Map::new();
    meta.insert("kind".into(), json!("session"));
    if !from.trim().is_empty() {
        meta.insert("from".into(), json!(from));
    }
    json!({ "content": text, "meta": meta })
}

/// Serve a `subscribe` connection: register it for `session_id`, acknowledge, then
/// forward every pushed event as one line until either side goes away.
async fn serve_subscription(
    session_id: String,
    pid: i32,
    mut reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    mut write_half: tokio::net::unix::OwnedWriteHalf,
) {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    if !try_register_channel(&session_id, pid, &tx) {
        let _ = write_half
            .write_all(b"{\"ok\":false,\"error\":\"session already has a live channel owned by another process\"}\n")
            .await;
        return;
    }
    if write_half.write_all(b"{\"ok\":true}\n").await.is_ok() {
        loop {
            tokio::select! {
                ev = rx.recv() => match ev {
                    Some(mut line) => {
                        line.push('\n');
                        if write_half.write_all(line.as_bytes()).await.is_err() {
                            break;
                        }
                    }
                    None => break,
                },
                // The sidecar never sends more; EOF here means it exited.
                r = read_line_capped(&mut reader, MAX_REQUEST_LINE) => if !matches!(r, Ok(LineRead::Line(_))) { break },
            }
        }
    }
    // Only drop OUR registration — a newer sidecar of the same session may have replaced it.
    let mut map = CHANNELS.lock().unwrap();
    if map
        .get(&session_id)
        .is_some_and(|cur| cur.same_channel(&tx))
    {
        map.remove(&session_id);
        CHANNEL_OWNERS.lock().unwrap().remove(&session_id);
        let mut peers = PEER_SESSIONS.lock().unwrap();
        if peers.get(&pid).is_some_and(|s| *s == session_id) {
            peers.remove(&pid);
        }
    }
}

/// pid of the sidecar process that owns each live channel (H1).
static CHANNEL_OWNERS: LazyLock<StdMutex<HashMap<String, i32>>> =
    LazyLock::new(|| StdMutex::new(HashMap::new()));
/// sidecar pid -> the session it subscribed for: the VERIFIED caller identity of later requests.
static PEER_SESSIONS: LazyLock<StdMutex<HashMap<i32, String>>> =
    LazyLock::new(|| StdMutex::new(HashMap::new()));

fn pid_alive(pid: i32) -> bool {
    pid > 0 && unsafe { libc::kill(pid, 0) } == 0
}

/// Registers `tx` as `session_id`'s channel for the process `pid`. Refuses (false) when another
/// LIVE process already owns it; only the same process may re-register.
fn try_register_channel(
    session_id: &str,
    pid: i32,
    tx: &tokio::sync::mpsc::UnboundedSender<String>,
) -> bool {
    let mut map = CHANNELS.lock().unwrap();
    let mut owners = CHANNEL_OWNERS.lock().unwrap();
    if let (Some(cur), Some(owner)) = (map.get(session_id), owners.get(session_id)) {
        if !cur.is_closed() && *owner != pid && pid_alive(*owner) {
            return false;
        }
    }
    map.insert(session_id.to_string(), tx.clone());
    owners.insert(session_id.to_string(), pid);
    if pid > 0 {
        PEER_SESSIONS
            .lock()
            .unwrap()
            .insert(pid, session_id.to_string());
    }
    true
}

fn verified_caller(pid: Option<i32>) -> String {
    pid.and_then(|p| PEER_SESSIONS.lock().ok().and_then(|m| m.get(&p).cloned()))
        .unwrap_or_default()
}

/// Identity used for ownership: the verified session, else the peer pid.
fn caller_key(req: &BrokerReq) -> String {
    if !req.caller.is_empty() {
        req.caller.clone()
    } else {
        format!("pid:{}", req.caller_pid.unwrap_or(0))
    }
}

/// Shown to the receiving side: who typed. Never the client-supplied name.
fn caller_label(req: &BrokerReq) -> String {
    if !req.caller.is_empty() {
        req.caller.clone()
    } else {
        "unverified session".to_string()
    }
}

/// Audit trail for text an agent typed into a terminal/session: logged, plus a visible marker in the app.
fn audit_typed<H: BrokerHost>(
    host: &H,
    req: &BrokerReq,
    kind: &str,
    target_id: &str,
    target_name: &str,
    bytes: usize,
) {
    let by = caller_label(req);
    crate::debuglog::log(&format!(
        "[audit] {kind} by={by} pid={} -> target={target_name} ({target_id}) bytes={bytes}",
        req.caller_pid.unwrap_or(0)
    ));
    eprintln!("[broker] audit {kind} by={by} target={target_name} bytes={bytes}");
    let _ = host.emit(
        "muya://typed-by",
        json!({ "targetId": target_id, "targetName": target_name, "by": by, "kind": kind, "bytes": bytes }),
    );
}

fn register_ssh_session(id: &str) {
    if let Ok(mut set) = SSH_SESSIONS.lock() {
        set.insert(id.to_string());
    }
}

fn ssh_session_is_open(id: &str) -> bool {
    SSH_SESSIONS.lock().map(|s| s.contains(id)).unwrap_or(false)
}

/// Drop a session id once its terminal tab closes (called from the app via the
/// `ssh_release_session` command). Idempotent.
pub fn release_ssh_session(id: &str) {
    if let Ok(mut set) = SSH_SESSIONS.lock() {
        set.remove(id);
    }
}

/// Session NAMEs opened via `open_session` that `close_session` may close (PRD
/// `close-session`). Keyed by name, not id — `open_session` doesn't mint its own
/// session id, addressing goes through the same `claude agents --json`-backed
/// registry as `list_sessions`/`send_to_session` (PRD `agent-session-open`). An
/// entry is added when `open_session` signals the open and removed once
/// `close_session` succeeds (or the tab closes by any other means) — mirrors
/// `SSH_SESSIONS` above so an agent can never close a session it didn't open
/// (the operator's own main chat, or a "+ New Agent" tab they opened by hand).
static AGENT_OPENED_SESSIONS: LazyLock<StdMutex<HashMap<String, String>>> =
    LazyLock::new(|| StdMutex::new(HashMap::new()));

/// Terminal id -> caller key of whoever opened it with `open_terminal` (M8).
static TERMINAL_OWNERS: LazyLock<StdMutex<HashMap<u64, String>>> =
    LazyLock::new(|| StdMutex::new(HashMap::new()));

/// Whether `opener` opened this terminal (`open_terminal`) or its Claude session (`open_session`).
fn owns_terminal(t: &TerminalInfo, opener: &str) -> bool {
    TERMINAL_OWNERS
        .lock()
        .map(|m| m.get(&t.id).is_some_and(|o| o == opener))
        .unwrap_or(false)
        || agent_session_owned_by(&t.name, opener)
}

/// Records `opener` (the verified caller key) as the owner of the session `name`.
fn register_agent_session(name: &str, opener: &str) {
    if let Ok(mut m) = AGENT_OPENED_SESSIONS.lock() {
        m.insert(name.to_string(), opener.to_string());
    }
}

/// Only the agent that opened a session may close it.
fn agent_session_owned_by(name: &str, opener: &str) -> bool {
    AGENT_OPENED_SESSIONS
        .lock()
        .map(|m| m.get(name).is_some_and(|o| o == opener))
        .unwrap_or(false)
}

fn agent_session_name_taken(name: &str) -> bool {
    AGENT_OPENED_SESSIONS
        .lock()
        .map(|m| m.contains_key(name))
        .unwrap_or(false)
}

/// Drop a session name once it's closed (called from the app via the
/// `release_agent_session` command, on ANY tab close — not just `close_session`
/// ones — so a manually-closed tab's name doesn't stay falsely closable). Idempotent.
pub fn release_agent_session(name: &str) {
    if let Ok(mut m) = AGENT_OPENED_SESSIONS.lock() {
        m.remove(name);
    }
}

/// AC10 — cap on concurrent `ssh_run` commands. Over the cap the broker fails fast
/// with a clear error instead of piling up PTYs / ssh processes (DoS protection).
const MAX_CONCURRENT_RUNS: usize = 4;

/// Wall-clock ceiling for a single `ssh_run` (connect + remote command). Past this
/// the child is killed and `timedOut:true` is returned.
const RUN_TIMEOUT: Duration = Duration::from_secs(60);

// ---------------------------------------------------------------------------
// Managed state
// ---------------------------------------------------------------------------

pub struct BrokerState {
    /// Active listener + its path (if started). Held so a `disable` could drop it;
    /// today it starts once at launch and lives for the app's lifetime.
    pub listener: Mutex<Option<(Arc<UnixListener>, PathBuf)>>,
    /// AC10 — permits for in-flight `ssh_run` commands. Acquired per run; over the
    /// cap `try_acquire` fails fast so the broker never hangs under load.
    pub run_slots: Arc<Semaphore>,
}

impl Default for BrokerState {
    fn default() -> Self {
        BrokerState {
            listener: Mutex::new(None),
            run_slots: Arc::new(Semaphore::new(MAX_CONCURRENT_RUNS)),
        }
    }
}

// ---------------------------------------------------------------------------
// Non-secret wire types
// ---------------------------------------------------------------------------

/// Metadata the agent is allowed to see for an opted-in server. Deliberately
/// carries NO credential source, NO secret, NO internal ids beyond the alias.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ServerMeta {
    /// Stable handle the agent passes back to `open` — the label, or the id when
    /// the label is blank.
    pub alias: String,
    pub host: String,
    pub username: String,
    pub port: u16,
    #[serde(rename = "connectionType")]
    pub connection_type: String,
    /// Servers-page group ("" = Ungrouped).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub group: String,
    /// Whether agents may open/run this server (the operator's "Agent may use this server").
    #[serde(rename = "agentAccess", default)]
    pub agent_access: bool,
    /// PSMP servers: the name of the operator's PSMP profile they go through
    /// (PRD `ssh-agent-psmp`). Absent for direct servers.
    #[serde(
        rename = "psmpProfile",
        skip_serializing_if = "Option::is_none",
        default
    )]
    pub psmp_profile: Option<String>,
}

#[derive(Deserialize, Default, Clone)]
struct BrokerReq {
    op: String,
    #[serde(default)]
    alias: Option<String>,
    /// The remote command for `run` (a SINGLE argv element passed to ssh; AC9).
    #[serde(default)]
    command: Option<String>,
    /// `run` batch mode: many commands over ONE connection, each result framed +
    /// returned separately. Preferred for PSMP (multiplexing is disabled there).
    #[serde(default)]
    commands: Option<Vec<String>>,
    /// The operation name for `run_operation` (Faz 3.1 — looked up in the
    /// operator-authored `~/.claude/muya-agent-ops.json` registry).
    #[serde(default)]
    operation: Option<String>,
    /// Agent-supplied args for `run_operation`, policed by `enforce_arg_policy`
    /// before they reach the fixed program.
    #[serde(default)]
    args: Option<Vec<String>>,
    /// AC17 `add_secret`: the new secret's name (== credential label), operator
    /// note, kind, and value. `value` is write-only — never echoed back.
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    value: Option<String>,
    /// `add_server` (agentic SSH): the new server's host, login username, optional
    /// label + port, and an OPTIONAL credential NAME (from list_secrets) to bind.
    #[serde(default)]
    host: Option<String>,
    #[serde(default)]
    username: Option<String>,
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    port: Option<u16>,
    #[serde(default)]
    credential: Option<String>,
    /// `run_with_secrets`: the program + arguments (no shell), extra environment (values may hold
    /// `{{muya-secret:name}}`), and optional stdin text (may hold placeholders too).
    #[serde(default)]
    argv: Option<Vec<String>>,
    #[serde(default)]
    env: Option<std::collections::BTreeMap<String, String>>,
    #[serde(default)]
    stdin: Option<String>,
    /// Servers-page / vault group for `add_server`, `update_server`, `add_secret`, `update_secret`.
    #[serde(default)]
    group: Option<String>,
    /// `update_secret`: a new name (rename).
    #[serde(rename = "newName", default)]
    new_name: Option<String>,
    /// `add_server` / `update_server` (PRD `ssh-agent-psmp`): the NAME of an
    /// operator-defined PSMP profile; on update "" / "none" / "direct" means direct.
    #[serde(rename = "psmpProfile", default)]
    psmp_profile: Option<String>,
    /// `scp` (PRD `ssh-scp`): explicit transfer direction — "upload" | "download".
    /// NEVER inferred from argument shape/order.
    #[serde(default)]
    direction: Option<String>,
    #[serde(rename = "localPath", default)]
    local_path: Option<String>,
    #[serde(rename = "remotePath", default)]
    remote_path: Option<String>,
    #[serde(default)]
    recursive: Option<bool>,
    /// Schedules (docs/prd-schedules.md): the schedule's id or name, the create /
    /// update fields, the on/off value and the history length.
    #[serde(default)]
    schedule: Option<String>,
    #[serde(default)]
    fields: Option<serde_json::Value>,
    #[serde(default)]
    enabled: Option<bool>,
    /// Agent-supplied extra scp flags, policed by `enforce_scp_arg_policy` before
    /// they ever reach `ssh::build_scp_command`.
    #[serde(rename = "extraArgs", default)]
    extra_args: Option<Vec<String>>,
    /// `send` (PRD `ssh-send`): the ssh_open session id to write to, and the literal
    /// text to type into that terminal's PTY (include a trailing "\n" to run it).
    #[serde(rename = "sessionId", default)]
    session_id: Option<String>,
    /// VERIFIED caller: the Claude session whose sidecar process (peer pid) subscribed on this
    /// socket. Never read from the request body: a client-supplied name is spoofable.
    #[serde(skip)]
    caller: String,
    #[serde(skip)]
    caller_pid: Option<i32>,
    #[serde(default)]
    text: Option<String>,
    /// `compact_session`: optional focus text appended after `/compact`.
    #[serde(default)]
    instructions: Option<String>,
    /// `session_exec` (PRD `ssh-session`): optional per-command timeout in seconds.
    #[serde(rename = "timeoutSecs", default)]
    timeout_secs: Option<u64>,
    /// `list_sessions`/`read_session`/`send_to_session` (PRD `session-messaging`):
    /// the session to address (name or id, fuzzy), how many turns to read, an optional
    /// filter, and the delivery mode ("auto" = native SendMessage, "muya" = Muya types it).
    #[serde(default)]
    target: Option<String>,
    /// `http_request`: method, absolute https URL, headers and body. Any of url/header values/body may hold
    /// `{{muya-secret:name}}`; the daemon substitutes it and redacts the reply.
    #[serde(default)]
    method: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    headers: Option<std::collections::BTreeMap<String, String>>,
    #[serde(default)]
    body: Option<String>,
    /// `bridge_*` (PRD `bridge-mcp`): the tool's arguments, passed through to
    /// `bridge_mcp::handle`.
    #[serde(default)]
    bridge: Option<serde_json::Value>,
    #[serde(default)]
    limit: Option<u32>,
    #[serde(default)]
    query: Option<String>,
    #[serde(default)]
    deliver: Option<String>,
    /// `send_to_session` (deliver "muya"/"keys"): a retry with the same key types once.
    #[serde(rename = "idempotencyKey", default)]
    idempotency_key: Option<String>,
    /// `open_session` (PRD `agent-session-open`): working directory for the new local
    /// Claude session (defaults to the operator's current workspace when absent) and
    /// an optional first prompt to hand it directly on launch. Reuses `name` above.
    #[serde(default)]
    cwd: Option<String>,
    #[serde(rename = "initialMessage", default)]
    initial_message: Option<String>,
    /// `open_session`: which agent CLI to launch — "claude" (default) or
    /// "opencode". Absent means Claude, so every existing caller keeps working.
    #[serde(default)]
    agent: Option<String>,
    /// `open_session`: the caller's own session id — open the new session as a split
    /// pane next to that session's terminal. Absent means a normal tab.
    #[serde(rename = "splitWith", default)]
    split_with: Option<String>,
    /// `open_session`: the caller's own session id — an unattended session reports to it.
    #[serde(rename = "openedBy", default)]
    opened_by: Option<String>,
    /// `open_session`: run the new session with nobody watching (no questions, no plan
    /// approval). Absent means true.
    #[serde(default)]
    unattended: Option<bool>,
    /// `send_terminal` / `broadcast`: press Enter after the text (default true).
    #[serde(default)]
    enter: Option<bool>,
    // `broadcast` reuses `kind` above: which terminals — "all" (default), "claude" or "shell".
    /// `send_terminal` / `broadcast`: also type into a terminal that waits on a permission prompt
    /// (default false — Enter there would answer the prompt).
    #[serde(rename = "includeWaiting", default)]
    include_waiting: Option<bool>,
}

// ---------------------------------------------------------------------------
// Pure, testable core (no I/O, no Tauri)
// ---------------------------------------------------------------------------

fn alias_of(s: &Server) -> String {
    if s.label.trim().is_empty() {
        s.id.clone()
    } else {
        s.label.clone()
    }
}

/// AC4 — the metadata list for `list_servers`: ONLY servers with `agent_access`.
/// Works regardless of store lock state (no secret access).
#[cfg(test)]
pub fn agent_visible(servers: &[Server]) -> Vec<ServerMeta> {
    agent_visible_with(servers, &[])
}

/// `agent_visible` plus each PSMP server's profile name, resolved from `profiles`.
pub fn agent_visible_with(
    servers: &[Server],
    profiles: &[crate::ssh::PsmpProfile],
) -> Vec<ServerMeta> {
    servers
        .iter()
        .filter(|s| s.agent_access)
        .map(|s| server_meta(s, profiles))
        .collect()
}

/// Every configured server (agents manage them all); `agentAccess` says which ones they may open.
pub fn agent_listing_with(
    servers: &[Server],
    profiles: &[crate::ssh::PsmpProfile],
) -> Vec<ServerMeta> {
    servers.iter().map(|s| server_meta(s, profiles)).collect()
}

fn server_meta(s: &Server, profiles: &[crate::ssh::PsmpProfile]) -> ServerMeta {
    {
        ServerMeta {
            alias: alias_of(s),
            host: s.host.clone(),
            username: s.username.clone(),
            port: s.port,
            connection_type: s.connection_type.clone(),
            group: s.group.clone(),
            agent_access: s.agent_access,
            psmp_profile: s
                .psmp_profile_id
                .as_deref()
                .and_then(|pid| profiles.iter().find(|p| p.id == pid))
                .map(crate::ssh::profile_name),
        }
    }
}

/// AC5 — resolve an alias for `open`. Distinguishes "no such server" from
/// "exists but the operator did not opt it in", so the agent gets a clear error.
pub enum OpenResolution<'a> {
    Ok(&'a Server),
    NotAccessible,
    NotFound,
}

/// Finds any server by alias or id, whatever its `agentAccess` (editing/removing is not using).
pub fn find_server<'a>(servers: &'a [Server], alias: &str) -> Option<&'a Server> {
    servers
        .iter()
        .find(|s| alias_of(s) == alias || s.id == alias)
}

pub fn resolve_open<'a>(servers: &'a [Server], alias: &str) -> OpenResolution<'a> {
    // Match on the same alias rule as `agent_visible` (label first, else id),
    // and also allow the raw id, so either handle the agent saw works.
    let hit = servers
        .iter()
        .find(|s| alias_of(s) == alias || s.id == alias);
    match hit {
        None => OpenResolution::NotFound,
        Some(s) if !s.agent_access => OpenResolution::NotAccessible,
        Some(s) => OpenResolution::Ok(s),
    }
}

/// AC9 — assemble the final `ssh` argv for `run` from the base connect args (which
/// END with the ssh destination) plus the remote `command`. The command is pushed
/// as EXACTLY ONE argv element, so shell metacharacters in it (`;`, `&&`, `$()`)
/// can never break our argv or spawn anything on the Muya side — ssh forwards the
/// single element to the remote shell. Also forces `-o LogLevel=ERROR` (before the
/// destination, where ssh requires options) so verbose diagnostics can't leak.
pub fn assemble_run_args(mut base: Vec<String>, command: &str) -> Result<Vec<String>, String> {
    let dest = base.pop().ok_or("empty ssh args (no destination)")?;
    // The base ends `-- <dest>`: options must go BEFORE the `--`, or ssh would read
    // them as the destination/remote command.
    if base.last().map(String::as_str) == Some("--") {
        base.pop();
    }
    base.push("-o".to_string());
    base.push("LogLevel=ERROR".to_string());
    base.push("--".to_string());
    base.push(dest);
    base.push(command.to_string()); // the whole remote command, as ONE argv element
    Ok(base)
}

/// AC4 — fail-closed scp `extraArgs` policy (PRD `ssh-scp`). Mirrors the shape of
/// `agent_ops::enforce_arg_policy`: an unknown/unlisted flag is REJECTED, not
/// merely the explicitly-denied ones — "if in doubt, reject". Every value here
/// MUST be a flag; `ssh_scp`'s typed `localPath`/`remotePath` fields are the ONLY
/// way to supply paths, so a bare (non-flag) `extraArgs` token can never be an
/// attempt to smuggle in an extra positional path/host-spec.
///
/// Denied (hard, argv-injection/RCE risk regardless of allow-list):
///   * `-o` — arbitrary ssh/scp option (`ProxyCommand=` = local RCE)
///   * `-F` — an attacker-controlled ssh_config file
///   * `-i` — an attacker-chosen identity/key file
///   * `-S` — an attacker-chosen ssh program (arbitrary executable)
///   * `-P` — port is Muya-owned (derived from the server config), never agent-set
/// Allowed: `-r` `-p` `-C` `-l` (recursion/preserve-times/compression/bandwidth-limit;
/// `-l` may carry its numeric limit attached, e.g. `-l800`, or as a bare flag).
pub fn enforce_scp_arg_policy(args: &[String]) -> Result<Vec<String>, String> {
    const HARD_DENIED: &[&str] = &["-o", "-F", "-i", "-S", "-P"];
    const ALLOWED: &[&str] = &["-r", "-p", "-C", "-l"];

    let mut out = Vec::with_capacity(args.len());
    for arg in args {
        if arg.contains('\0') {
            return Err("extraArgs argument contains a NUL byte".to_string());
        }
        let stripped = match arg.strip_prefix('-') {
            Some(s) => s,
            None => {
                return Err(format!(
                    "extraArgs entry '{arg}' is not a flag — ssh_scp only accepts scp \
                     FLAGS here; use the localPath/remotePath fields for paths"
                ))
            }
        };
        if stripped.is_empty() || stripped == "-" {
            return Err(format!("bare '{arg}' is not an allowed extraArgs entry"));
        }
        if HARD_DENIED.contains(&arg.as_str()) {
            return Err(format!(
                "flag '{arg}' is denied for ssh_scp (argument-injection / RCE risk) — Muya \
                 sets ssh/scp options itself"
            ));
        }
        // `-l` may carry an attached numeric value (`-l800`); everything else must
        // match an allowed flag exactly.
        let is_allowed = ALLOWED.contains(&arg.as_str())
            || (arg.starts_with("-l")
                && arg[2..].chars().all(|c| c.is_ascii_digit())
                && arg.len() > 2);
        if !is_allowed {
            return Err(format!(
                "flag '{arg}' is not on ssh_scp's allow-list (unknown flags are rejected); \
                 allowed: -r -p -C -l"
            ));
        }
        out.push(arg.clone());
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Socket path + peer authentication
// ---------------------------------------------------------------------------

/// Owner-only socket path. `MUYA_SSH_BROKER_SOCK` overrides (lets a dev/test
/// instance bind an isolated socket). Default `$HOME/.claude/muya-ssh-broker.sock`.
/// Mirrors bridge.rs's per-user convention but with a NEW, separate path.
pub fn socket_path() -> Result<PathBuf, String> {
    if let Ok(p) = std::env::var("MUYA_SSH_BROKER_SOCK") {
        let path = PathBuf::from(p);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("create broker dir: {e}"))?;
            // Best-effort dir lock; the socket's own 0600 is the real barrier.
            let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
        }
        return Ok(path);
    }
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    let dir = Path::new(&home).join(".claude");
    fs::create_dir_all(&dir).map_err(|e| format!("create ~/.claude: {e}"))?;
    Ok(dir.join("muya-ssh-broker.sock"))
}

/// Effective uid of the connected peer via `getpeereid(2)` (macOS/BSD). `None`
/// on failure → treated as an untrusted peer and rejected.
pub fn peer_uid(fd: RawFd) -> Option<u32> {
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    // SAFETY: fd is a live connected socket owned by the caller for this call.
    let rc = unsafe { libc::getpeereid(fd, &mut uid, &mut gid) };
    if rc == 0 {
        Some(uid)
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------

fn err_resp(msg: impl Into<String>) -> String {
    json!({"ok": false, "error": msg.into()}).to_string()
}

// ---- secret placeholders (agents use passwords without seeing them) --------------------

/// Hosts of every configured server entry (the operator's and the agents').
fn known_server_hosts() -> Vec<String> {
    crate::ssh::ssh_list_servers()
        .map(|v| v.into_iter().map(|s| s.host).collect())
        .unwrap_or_default()
}

/// Session id (ssh_open tab or ssh_session_open) -> the secret NAME its server's credential uses.
/// A placeholder naming exactly that secret may be typed into that session without a prompt check.
static SESSION_CREDS: LazyLock<StdMutex<HashMap<String, String>>> =
    LazyLock::new(|| StdMutex::new(HashMap::new()));

fn remember_session_cred(session_id: &str, server: &Server) {
    if server.credential_source.kind == "local" {
        if let (Some(c), Ok(mut m)) = (
            server.credential_source.local_cred_id.clone(),
            SESSION_CREDS.lock(),
        ) {
            m.insert(session_id.to_string(), c);
        }
    }
}

fn session_cred(session_id: &str) -> Option<String> {
    SESSION_CREDS
        .lock()
        .ok()
        .and_then(|m| m.get(session_id).cloned())
}

/// An unverified caller (a socket peer whose session identity the broker could not bind) may not use
/// secrets. A call without a peer pid is the daemon itself (tests, in-process callers).
fn is_unverified(req: &BrokerReq) -> bool {
    req.caller.is_empty() && req.caller_pid.is_some()
}

/// The terminal state the secret gate needs, read from the host: echo flag + prompt line.
fn prompt_state_of<H: BrokerHost>(
    host: &H,
    terminal_id: u64,
) -> Option<crate::pty_state::PromptState> {
    let echo_on = blocking(|| host.terminal_echo(terminal_id))?;
    let lines = blocking(|| host.terminal_lines(terminal_id))?;
    Some(crate::pty_state::PromptState {
        echo_on,
        line: crate::pty_state::prompt_line(&lines),
    })
}

/// Swaps every `{{muya-secret:NAME}}` in `text` for the real value. A placeholder is substituted
/// only (a) when it names `allowed` (the secret of the server the session targets), or (b) when
/// `prompt` shows a terminal at a password prompt (echo off) that names a configured server host.
/// `prompt` is `None` for every other destination (a command line, a shell, ssh_run ...), which
/// then refuses. Text without a placeholder is returned as is.
fn substitute_for<H: BrokerHost>(
    host: &H,
    text: &str,
    verified: bool,
    prompt: Option<&crate::pty_state::PromptState>,
    allowed: Option<&str>,
) -> Result<String, String> {
    substitute_with(host, text, verified, prompt, allowed, &known_server_hosts)
}

/// [`substitute_for`] with the lookup of the configured server hosts injected (tests).
fn substitute_with<H: BrokerHost>(
    host: &H,
    text: &str,
    verified: bool,
    prompt: Option<&crate::pty_state::PromptState>,
    allowed: Option<&str>,
    hosts_of: &dyn Fn() -> Vec<String>,
) -> Result<String, String> {
    if crate::secret_refs::names_in(text).is_empty() {
        return Ok(text.to_string());
    }
    if !verified {
        return Err("secret placeholders need a verified Muya session: this caller could not be tied to a Claude session".into());
    }
    let mut resolve = |name: &str| -> Result<Zeroizing<String>, String> {
        if !secret_exists(host, name)? {
            return Err(format!("no secret named '{name}' (see list_secrets)"));
        }
        if allowed != Some(name) {
            crate::pty_state::secret_gate(name, prompt, &hosts_of())?;
        }
        host.vault_secret_for_ref(name)
    };
    crate::secret_refs::substitute(text, &mut resolve).map(|z| z.as_str().to_string())
}

/// Resolves every placeholder in `text` (no prompt gate: the value goes into a child's env or
/// stdin, never into a terminal or a command line). Names used are pushed to `used`.
fn resolve_for_child<H: BrokerHost>(
    host: &H,
    text: &str,
    used: &mut Vec<String>,
) -> Result<Zeroizing<String>, String> {
    let mut resolve = |name: &str| -> Result<Zeroizing<String>, String> {
        if !secret_exists(host, name)? {
            return Err(format!("no secret named '{name}' (see list_secrets)"));
        }
        if !used.iter().any(|u| u == name) {
            used.push(name.to_string());
        }
        host.vault_secret_for_ref(name)
    };
    crate::secret_refs::substitute(text, &mut resolve)
}

fn valid_env_name(n: &str) -> bool {
    let mut c = n.chars();
    c.next()
        .is_some_and(|f| f.is_ascii_alphabetic() || f == '_')
        && c.all(|x| x.is_ascii_alphanumeric() || x == '_')
        && !n.starts_with("DYLD_")
        && !n.starts_with("LD_")
}

const RUN_OUTPUT_CAP: usize = 256 * 1024;

/// The CLI form (muyactl from a session terminal): tie the peer to a Claude session through its ancestry.
/// A request from a verified sidecar already has its caller and passes untouched.
async fn bind_cli_caller<H: BrokerHost>(req: &mut BrokerReq, what: &str) -> Result<(), String> {
    if !is_unverified(req) {
        return Ok(());
    }
    let pid = req.caller_pid.unwrap_or(0);
    let found = tokio::task::spawn_blocking(move || {
        let chain = ancestors_via(pid, parent_of);
        H::list_agent_sessions_fresh(None)
            .ok()
            .and_then(|v| v.into_iter().find(|s| claim_matches(s.pid, &chain)))
            .map(|s| s.id)
    })
    .await
    .ok()
    .flatten();
    match found {
        Some(id) => {
            req.caller = id;
            Ok(())
        }
        None => Err(format!("{what} needs a verified Muya session: this caller is not running under a Claude session")),
    }
}

/// `run_with_secrets` / `muyactl secret exec`: run a program as the operator user with secrets in its
/// environment / stdin only. The command is an argv array (never a shell string built from values);
/// a placeholder in it is refused (visible to `ps`). The response is redacted by the caller.
async fn handle_run_with_secrets<H: BrokerHost>(host: &H, req: &mut BrokerReq) -> String {
    if let Err(e) = bind_cli_caller::<H>(req, "run_with_secrets").await {
        return err_resp(e);
    }
    let argv = match req
        .argv
        .as_ref()
        .filter(|a| !a.is_empty() && !a[0].trim().is_empty())
    {
        Some(a) => a.clone(),
        None => {
            return err_resp(
                "`run_with_secrets` requires a non-empty `command` (program and arguments)",
            )
        }
    };
    if argv
        .iter()
        .any(|a| !crate::secret_refs::names_in(a).is_empty())
    {
        return err_resp(
            "a secret placeholder cannot be part of the command: arguments are visible to local `ps`. Put it in `env` (VAR: \"{{muya-secret:name}}\") or `stdin` and read it from the environment.",
        );
    }
    if !host.vault_is_unlocked() {
        return err_resp("password store is locked — unlock it in the Password Store tab");
    }
    let cwd = match req.cwd.as_deref().filter(|c| !c.trim().is_empty()) {
        Some(c) if Path::new(c).is_absolute() && Path::new(c).is_dir() => c.to_string(),
        Some(c) => return err_resp(format!("cwd '{c}' is not an existing absolute folder")),
        None => return err_resp("`run_with_secrets` requires an absolute `cwd`"),
    };
    let mut used = Vec::new();
    let mut env: Vec<(String, Zeroizing<String>)> = Vec::new();
    for (k, v) in req.env.clone().unwrap_or_default() {
        if !valid_env_name(&k) {
            return err_resp(format!(
                "env name '{k}' is not allowed (letters, digits, _; no LD_/DYLD_ prefix)"
            ));
        }
        match resolve_for_child(host, &v, &mut used) {
            Ok(val) => env.push((k, val)),
            Err(e) => return err_resp(e),
        }
    }
    let stdin = match req.stdin.as_deref() {
        Some(t) => match resolve_for_child(host, t, &mut used) {
            Ok(v) => Some(v),
            Err(e) => return err_resp(e),
        },
        None => None,
    };
    // Audit: who, what, which secrets. Never a value.
    crate::debuglog::log(&format!(
        "audit: run_with_secrets by={} cwd={cwd} command={} secrets=[{}]",
        caller_label(req),
        argv.join(" "),
        used.join(", ")
    ));
    let timeout = Duration::from_secs(req.timeout_secs.unwrap_or(120).clamp(1, 3600));
    let mut cmd = tokio::process::Command::new(&argv[0]);
    cmd.args(&argv[1..]).current_dir(&cwd).kill_on_drop(true);
    for (k, v) in crate::schedules::login_env() {
        if !env.iter().any(|(n, _)| n == k) {
            cmd.env(k, v);
        }
    }
    for (k, v) in &env {
        cmd.env(k, v.as_str());
    }
    cmd.stdin(if stdin.is_some() {
        std::process::Stdio::piped()
    } else {
        std::process::Stdio::null()
    })
    .stdout(std::process::Stdio::piped())
    .stderr(std::process::Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return err_resp(format!("could not start '{}': {e}", argv[0])),
    };
    if let (Some(text), Some(mut pipe)) = (stdin, child.stdin.take()) {
        let bytes = text.as_bytes().to_vec();
        tokio::spawn(async move {
            let _ = pipe.write_all(&bytes).await;
            drop(pipe);
        });
    }
    match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(Ok(out)) => {
            let cut = |b: &[u8]| String::from_utf8_lossy(&b[..b.len().min(RUN_OUTPUT_CAP)]).into_owned();
            json!({
                "ok": true,
                "exitCode": out.status.code(),
                "stdout": cut(&out.stdout),
                "stderr": cut(&out.stderr),
                "timedOut": false,
                "secrets": used,
            })
            .to_string()
        }
        Ok(Err(e)) => err_resp(format!("run failed: {e}")),
        Err(_) => json!({"ok": true, "exitCode": null, "stdout": "", "stderr": "", "timedOut": true, "secrets": used}).to_string(),
    }
}

const HTTP_BODY_CAP: usize = 256 * 1024;

/// https only; plain http is allowed for the local machine (a dev server) and nothing else.
fn http_url_allowed(url: &reqwest::Url) -> Result<(), String> {
    match url.scheme() {
        "https" => Ok(()),
        "http" => {
            let h = url.host_str().unwrap_or("");
            let local = h.eq_ignore_ascii_case("localhost")
                || h == "[::1]"
                || h.parse::<std::net::Ipv4Addr>().is_ok_and(|a| a.is_loopback());
            if local {
                Ok(())
            } else {
                Err("http_request only allows https:// (plain http only for localhost / 127.0.0.1)".into())
            }
        }
        other => Err(format!("http_request does not support the '{other}' scheme: use https://")),
    }
}

/// `http_request`: one HTTP call made by the daemon. Placeholders in the url, header values and body are
/// substituted here; the agent gets status, headers and body with every secret value redacted by the caller.
/// Redirects are not followed (a redirect could carry the secret to another host).
async fn handle_http_request<H: BrokerHost>(host: &H, req: &mut BrokerReq) -> String {
    if let Err(e) = bind_cli_caller::<H>(req, "http_request").await {
        return err_resp(e);
    }
    let Some(url_t) = req.url.clone().filter(|u| !u.trim().is_empty()) else {
        return err_resp("`http_request` requires an absolute `url`");
    };
    let method = req.method.clone().unwrap_or_else(|| "GET".into()).trim().to_ascii_uppercase();
    let Ok(method) = reqwest::Method::from_bytes(method.as_bytes()) else {
        return err_resp(format!("unknown HTTP method '{method}'"));
    };
    if !host.vault_is_unlocked() {
        return err_resp("password store is locked — unlock it in the Password Store tab");
    }
    let mut used = Vec::new();
    let url_s = match resolve_for_child(host, url_t.trim(), &mut used) {
        Ok(v) => v,
        Err(e) => return err_resp(e),
    };
    let url = match reqwest::Url::parse(&url_s) {
        Ok(u) => u,
        Err(_) => return err_resp("`url` is not a valid absolute URL"),
    };
    if let Err(e) = http_url_allowed(&url) {
        return err_resp(e);
    }
    let mut headers = reqwest::header::HeaderMap::new();
    for (k, v) in req.headers.clone().unwrap_or_default() {
        let val = match resolve_for_child(host, &v, &mut used) {
            Ok(v) => v,
            Err(e) => return err_resp(e),
        };
        let (Ok(name), Ok(mut value)) = (
            reqwest::header::HeaderName::from_bytes(k.trim().as_bytes()),
            reqwest::header::HeaderValue::from_str(&val),
        ) else {
            return err_resp(format!("header '{k}' is not a valid HTTP header"));
        };
        value.set_sensitive(true);
        headers.insert(name, value);
    }
    let body = match req.body.as_deref() {
        Some(t) => match resolve_for_child(host, t, &mut used) {
            Ok(v) => Some(v),
            Err(e) => return err_resp(e),
        },
        None => None,
    };
    // Audit: who, what, which secrets. The url is logged as typed (placeholders, never values), without its query.
    let shown = {
        let mut u = reqwest::Url::parse(url_t.trim()).unwrap_or_else(|_| url.clone());
        u.set_query(None);
        u.to_string()
    };
    crate::debuglog::log(&format!(
        "audit: http_request by={} {method} {shown} secrets=[{}]",
        caller_label(req),
        used.join(", ")
    ));
    let timeout = Duration::from_secs(req.timeout_secs.unwrap_or(30).clamp(1, 120));
    let client = match reqwest::Client::builder().timeout(timeout).redirect(reqwest::redirect::Policy::none()).build() {
        Ok(c) => c,
        Err(e) => return err_resp(format!("http client: {e}")),
    };
    let mut rb = client.request(method, url).headers(headers);
    if let Some(b) = body {
        rb = rb.body(b.as_str().to_owned());
    }
    let resp = match rb.send().await {
        Ok(r) => r,
        Err(e) if e.is_timeout() => return err_resp(format!("the request timed out after {}s", timeout.as_secs())),
        Err(e) => return err_resp(format!("request failed: {}", e.without_url())),
    };
    let status = resp.status().as_u16();
    let out_headers: serde_json::Map<String, serde_json::Value> = resp
        .headers()
        .iter()
        .map(|(k, v)| (k.as_str().to_string(), json!(String::from_utf8_lossy(v.as_bytes()))))
        .collect();
    let bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(e) => return err_resp(format!("reading the response failed: {}", e.without_url())),
    };
    let truncated = bytes.len() > HTTP_BODY_CAP;
    json!({
        "ok": true,
        "status": status,
        "headers": out_headers,
        "body": String::from_utf8_lossy(&bytes[..bytes.len().min(HTTP_BODY_CAP)]),
        "truncated": truncated,
        "secrets": used,
    })
    .to_string()
}

fn secret_exists<H: BrokerHost>(host: &H, name: &str) -> Result<bool, String> {
    Ok(host.vault_list_meta()?.iter().any(|m| m.label == name))
}

/// Replaces any real secret value in a response with its placeholder. Works on the raw strings
/// inside the JSON (before serialization escapes them) and also catches common encodings.
fn redact_resp<H: BrokerHost>(host: &H, resp: String) -> String {
    if !host.vault_is_unlocked() {
        return resp;
    }
    let Ok(metas) = host.vault_list_meta() else {
        return resp;
    };
    let mut secrets = Vec::new();
    for m in metas {
        if let Ok(v) = host.vault_secret_for_ref(&m.label) {
            secrets.push((m.label, v));
        }
    }
    match serde_json::from_str::<serde_json::Value>(&resp) {
        Ok(mut v) => {
            crate::secret_refs::redact_value(&mut v, &secrets);
            v.to_string()
        }
        Err(_) => crate::secret_refs::redact(&resp, &secrets),
    }
}

/// Handle one broker request line → one JSON response string (no trailing NL).
pub async fn handle_request<H: BrokerHost>(host: &H, line: &str) -> String {
    handle_request_from(host, line, None).await
}

/// [`handle_request`] for a request that arrived from peer process `pid`.
pub async fn handle_request_from<H: BrokerHost>(host: &H, line: &str, pid: Option<i32>) -> String {
    let mut req: BrokerReq = match serde_json::from_str(line) {
        Ok(r) => r,
        Err(e) => return err_resp(format!("bad request: {e}")),
    };
    req.caller = verified_caller(pid);
    req.caller_pid = pid;

    // Load current config (non-secret). ssh::ssh_list_servers reads the config
    // file — safe even when the credential store is locked (AC4).
    let servers = match crate::ssh::ssh_list_servers() {
        Ok(s) => s,
        Err(e) => return err_resp(e),
    };

    match req.op.as_str() {
        "list_servers" => {
            let profiles = crate::ssh::load_config()
                .map(|c| c.psmp_profiles)
                .unwrap_or_default();
            let metas = agent_listing_with(&servers, &profiles);
            json!({"ok": true, "servers": metas}).to_string()
        }
        "open" => {
            let alias = match req.alias.as_deref() {
                Some(a) if !a.trim().is_empty() => a,
                _ => return err_resp("`open` requires an `alias`"),
            };
            match resolve_open(&servers, alias) {
                OpenResolution::NotFound => err_resp(format!("no server matches alias '{alias}'")),
                OpenResolution::NotAccessible => err_resp(format!(
                    "server '{alias}' is not agent-accessible (enable 'Agent may use this server')"
                )),
                OpenResolution::Ok(server) => {
                    // Store-lock gate (AC5): a stored-password server cannot be
                    // opened while the store is locked — the injection would fail.
                    // (CyberArk/prompt sources are handled by ssh_pty_connect.)
                    if server.credential_source.kind == "local" {
                        if !host.vault_is_unlocked() {
                            return err_resp(
                                "password store is locked — unlock it in the Password Store tab",
                            );
                        }
                    }
                    // A stable session id the agent keeps and later targets with
                    // ssh_send. The app uses this verbatim as the terminal tab key, so
                    // the id maps 1:1 to that tab's PTY. Nonce = monotonic-ish nanos.
                    let nonce = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_nanos())
                        .unwrap_or(0);
                    let session_id = format!("ssh:{}:{}", server.id, nonce);
                    register_ssh_session(&session_id);
                    remember_session_cred(&session_id, server);
                    // Trigger the existing inject-capable open path in the UI. The
                    // secret is resolved + injected entirely in the app process by
                    // ssh_pty_connect; nothing secret is returned here.
                    let payload = json!({
                        "serverId": server.id,
                        "label": alias_of(server),
                        "sessionId": session_id,
                    });
                    if let Err(e) = host.emit("ssh-broker-open", payload) {
                        release_ssh_session(&session_id);
                        return err_resp(format!("failed to signal open: {e}"));
                    }
                    json!({"ok": true, "sessionId": session_id}).to_string()
                }
            }
        }
        "run" => redact_resp(host, handle_run(host, &servers, &req).await),
        "run_with_secrets" => redact_resp(host, handle_run_with_secrets(host, &mut req).await),
        "http_request" => redact_resp(host, handle_http_request(host, &mut req).await),
        "scp" => handle_scp(host, &servers, &req).await,
        "send" => handle_send(host, &req),
        "open_session" => handle_open_session(host, &req).await,
        "list_sessions" => handle_list_sessions::<H>(&req).await,
        "read_session" => redact_resp(host, handle_read_session::<H>(&req).await),
        "send_to_session" => handle_send_to_session(host, &req).await,
        "compact_session" => handle_compact_session(host, &req).await,
        "usage" => handle_usage::<H>(&req).await,
        "open_terminal" => handle_open_terminal(host, &req),
        "send_terminal" => handle_send_terminal(host, &req),
        "broadcast" => handle_broadcast(host, &req),
        op if op.starts_with("bridge_") => host
            .bridge_handle(
                op,
                req.bridge.as_ref().unwrap_or(&serde_json::Value::Null),
                req.session_id.as_deref().unwrap_or(""),
            )
            .await
            .to_string(),
        "close_session" => handle_close_session(host, &req).await,
        "session_open" => handle_session_open(host, &servers, &req).await,
        "session_exec" => redact_resp(host, handle_session_exec(host, &req).await),
        "session_close" => handle_session_close(host, &req).await,
        // Agentic-SSH — register a NEW server the agent can then ssh_open/ssh_run
        // (PRD ssh-agent-add-server). All guardrails live in `agent_add_server_in`:
        // forced direct/no-ssh_options, host/user injection rejected, CREATE-ONLY
        // (no overwrite), and — operator-approved — an OPTIONAL credential bound BY
        // NAME (resolved+injected Rust-side at connect time; the value never crosses
        // to the agent). No secret is serialized here.
        "add_server" => {
            let target_host = match req.host.as_deref() {
                Some(h) if !h.trim().is_empty() => h,
                _ => return err_resp("`add_server` requires a non-empty `host`"),
            };
            let username = match req.username.as_deref() {
                Some(u) if !u.trim().is_empty() => u,
                _ => return err_resp("`add_server` requires a non-empty `username`"),
            };
            let label = req.label.as_deref().unwrap_or("");
            let credential = req
                .credential
                .as_deref()
                .filter(|c| !c.trim().is_empty())
                .map(|c| crate::secret_refs::unwrap_name(c).to_string());
            let mut cfg = match crate::ssh::load_config() {
                Ok(c) => c,
                Err(e) => return err_resp(e),
            };
            match crate::ssh::agent_add_server_grouped_in(
                &mut cfg,
                label,
                target_host,
                username,
                req.port,
                credential,
                req.psmp_profile.as_deref(),
                req.group.as_deref(),
            ) {
                Ok(alias) => match crate::ssh::save_config(&cfg) {
                    Ok(()) => json!({"ok": true, "alias": alias}).to_string(),
                    Err(e) => err_resp(e),
                },
                Err(e) => err_resp(e),
            }
        }
        // Agents edit any server entry (the operator's too): host/port/user/credential/PSMP/group.
        // Credential -> host changes are written to the audit log (ssh::agent_update_server_in).
        "update_server" => {
            let alias = match req.alias.as_deref() {
                Some(a) if !a.trim().is_empty() => a,
                _ => return err_resp("`update_server` requires an `alias`"),
            };
            let id = match find_server(&servers, alias) {
                Some(s) => s.id.clone(),
                None => {
                    return err_resp(format!(
                        "no SSH server named '{alias}' (see ssh_list_servers)"
                    ))
                }
            };
            // `{{muya-secret:x}}` and `x` both name the secret `x` (add_server unwraps it too).
            let credential: Option<String> = req.credential.as_deref().map(|c| {
                if c.trim().is_empty() {
                    c.to_string()
                } else {
                    crate::secret_refs::unwrap_name(c).to_string()
                }
            });
            let edit = crate::ssh::AgentServerEdit {
                label: req.label.clone(),
                host: req.host.clone(),
                username: req.username.clone(),
                port: req.port,
                credential,
                psmp_profile: req.psmp_profile.clone(),
                group: req.group.clone(),
            };
            let mut cfg = match crate::ssh::load_config() {
                Ok(c) => c,
                Err(e) => return err_resp(e),
            };
            match crate::ssh::agent_update_server_in(&mut cfg, &id, edit) {
                Ok(alias) => match crate::ssh::save_config(&cfg) {
                    Ok(()) => json!({"ok": true, "alias": alias}).to_string(),
                    Err(e) => err_resp(e),
                },
                Err(e) => err_resp(e),
            }
        }
        "remove_server" => {
            let alias = match req.alias.as_deref() {
                Some(a) if !a.trim().is_empty() => a,
                _ => return err_resp("`remove_server` requires an `alias`"),
            };
            let id = match find_server(&servers, alias) {
                Some(s) => s.id.clone(),
                None => {
                    return err_resp(format!(
                        "no SSH server named '{alias}' (see ssh_list_servers)"
                    ))
                }
            };
            let mut cfg = match crate::ssh::load_config() {
                Ok(c) => c,
                Err(e) => return err_resp(e),
            };
            match crate::ssh::agent_remove_server_in(&mut cfg, &id) {
                Ok(alias) => match crate::ssh::save_config(&cfg) {
                    Ok(()) => json!({"ok": true, "alias": alias}).to_string(),
                    Err(e) => err_resp(e),
                },
                Err(e) => err_resp(e),
            }
        }
        // Dev builds only: push a channel event to a session, for live-testing the
        // channel path without a second Mac (PRD bridge-channel-delivery AC7).
        #[cfg(debug_assertions)]
        "debug_push_channel" => {
            let id = req.session_id.clone().unwrap_or_default();
            let ok = push_channel(
                &id,
                &session_channel_event("debug", req.text.as_deref().unwrap_or("")),
            );
            json!({ "ok": ok }).to_string()
        }
        "list_psmp_profiles" => match crate::ssh::load_config() {
            Ok(cfg) => {
                json!({"ok": true, "profiles": crate::ssh::agent_psmp_profiles(&cfg)}).to_string()
            }
            Err(e) => err_resp(e),
        },
        // Faz 3.1 — secret-operation broker (AC12/AC15). These do not touch SSH
        // servers; they surface stored-secret metadata + operator-defined ops.
        "list_secrets" => {
            match host.vault_list_meta() {
                Ok(metas) => {
                    // Project to name (= label) + description + kind. NEVER the secret.
                    let secrets: Vec<_> = metas
                        .iter()
                        .map(|m| {
                            json!({
                                "name": m.label,
                                "description": m.description,
                                "kind": m.secret_kind,
                                "group": m.group,
                            })
                        })
                        .collect();
                    json!({"ok": true, "secrets": secrets}).to_string()
                }
                Err(e) => err_resp(e),
            }
        }
        // AC17 — store a NEW secret the agent generated/received. CREATE-ONLY and
        // unlock-gated in credstore::add_credential; the response carries only the
        // name+kind, NEVER the value (which is never logged either).
        "add_secret" => {
            let name = match req.name.as_deref() {
                Some(n) if !n.trim().is_empty() => n.to_string(),
                _ => return err_resp("`add_secret` requires a non-empty `name`"),
            };
            let value = match req.value.as_deref() {
                Some(v) if !v.is_empty() => v.to_string(),
                _ => return err_resp("`add_secret` requires a non-empty `value`"),
            };
            let kind = req
                .kind
                .as_deref()
                .filter(|k| !k.trim().is_empty())
                .unwrap_or("api_key")
                .to_string();
            let description = req.description.clone().unwrap_or_default();
            let group = req.group.clone().filter(|g| !g.trim().is_empty());
            let added = host.vault_add_credential(name.clone(), description, kind, value);
            let added = match (added, group) {
                (Ok(m), Some(g)) => host.vault_edit_credential(
                    &m.label,
                    SecretEdit {
                        group: Some(g),
                        ..Default::default()
                    },
                ),
                (r, _) => r,
            };
            match added {
                Ok(meta) => json!({
                    "ok": true,
                    "secret": { "name": meta.label, "kind": meta.secret_kind, "group": meta.group },
                })
                .to_string(),
                Err(e) => err_resp(e),
            }
        }
        // Read a secret's VALUE back to the agent. This is the ONE deliberate
        // exception to "never reveal a secret" — operator-approved so an agent can
        // use a stored password to configure another system. Gated only on the
        // human having unlocked the store (secret_for_ref enforces the lock).
        "get_secret" => {
            let name = match req.name.as_deref() {
                Some(n) if !n.trim().is_empty() => n,
                _ => return err_resp("`get_secret` requires a non-empty `name`"),
            };
            // The agent never sees the value: it gets a placeholder that Muya swaps for the real
            // secret when it is typed/run (ssh_send, ssh_run, ssh_session_exec, send_terminal).
            if !host.vault_is_unlocked() {
                return err_resp("password store is locked — unlock it in the Password Store tab");
            }
            match secret_exists(host, name) {
                Ok(true) => json!({
                    "ok": true,
                    "value": crate::secret_refs::placeholder(name),
                    "placeholder": crate::secret_refs::placeholder(name),
                    "note": crate::secret_refs::USAGE_HINT.replace("NAME", name),
                    "usage": crate::secret_refs::USAGE_HINT.replace("NAME", name)
                })
                .to_string(),
                Ok(false) => err_resp(format!("no secret named '{name}' (see list_secrets)")),
                Err(e) => err_resp(e),
            }
        }
        // Update (rotate) an EXISTING secret's value. Update-only + unlock-gated in
        // credstore; the response carries only name+kind, never the value.
        "update_secret" => {
            let name = match req.name.as_deref() {
                Some(n) if !n.trim().is_empty() => n.to_string(),
                _ => return err_resp("`update_secret` requires a non-empty `name`"),
            };
            let edit = SecretEdit {
                value: req.value.clone().filter(|v| !v.is_empty()),
                new_name: req.new_name.clone().filter(|v| !v.trim().is_empty()),
                description: req.description.clone(),
                kind: req.kind.clone().filter(|k| !k.trim().is_empty()),
                group: req.group.clone(),
            };
            if edit.is_empty() {
                return err_resp("`update_secret` needs at least one of value, newName, description, kind, group");
            }
            let renamed = edit.new_name.clone();
            match host.vault_edit_credential(&name, edit) {
                Ok(meta) => {
                    // Servers that referenced the old name keep working under the new one.
                    if let Some(new) = renamed.filter(|n| *n != name) {
                        retarget_server_credentials(&name, &new);
                    }
                    crate::debuglog::log(&format!("audit: agent updated secret '{name}'"));
                    json!({
                        "ok": true,
                        "secret": { "name": meta.label, "kind": meta.secret_kind, "group": meta.group },
                    })
                    .to_string()
                }
                Err(e) => err_resp(e),
            }
        }
        "list_operations" => match crate::agent_ops::load_ops() {
            Ok(ops) => {
                let metas = crate::agent_ops::op_metas(&ops);
                json!({"ok": true, "operations": metas}).to_string()
            }
            Err(e) => err_resp(e),
        },
        "run_operation" => handle_run_operation(host, &req).await,
        op if op.starts_with("schedule") => {
            let (key, fields, enabled, limit) = (
                req.schedule.clone(),
                req.fields.clone(),
                req.enabled,
                req.limit.map(|n| n as usize),
            );
            let res = host
                .schedule_op(op.to_string(), key, fields, enabled, limit)
                .await;
            match res {
                Ok(v) => json!({"ok": true, "result": v}).to_string(),
                Err(e) => err_resp(e),
            }
        }
        other => err_resp(format!("unknown op '{other}'")),
    }
}

/// AC15 — run one operator-defined operation by name. Resolve the op, police the
/// agent args (fail-closed), resolve its secret in Rust, inject it into the CHILD
/// process env, run the fixed program, and return only stdout/stderr/exitCode. The
/// secret is NEVER serialized, logged, or placed in the outer argv.
async fn handle_run_operation<H: BrokerHost>(host: &H, req: &BrokerReq) -> String {
    let name = match req.operation.as_deref() {
        Some(n) if !n.trim().is_empty() => n.to_string(),
        _ => return err_resp("`run_operation` requires an `operation` name"),
    };
    let args = req.args.clone().unwrap_or_default();

    let ops = match crate::agent_ops::load_ops() {
        Ok(o) => o,
        Err(e) => return err_resp(e),
    };
    let op = match crate::agent_ops::resolve_op(&ops, &name) {
        Ok(o) => o.clone(),
        Err(e) => return err_resp(e),
    };

    // AC10 reuse — bound concurrency with the same permit pool as `ssh_run`.
    let broker = host.broker();
    let _permit = match broker.run_slots.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => {
            return err_resp(format!(
                "too many concurrent operations (limit {MAX_CONCURRENT_RUNS}); try again shortly"
            ))
        }
    };

    // Resolve the secret entirely in Rust (only when the op declares one). The
    // store must be unlocked — a locked store yields a clear error, no secret.
    let secret: Option<Zeroizing<String>> = match op.secret_id.as_deref() {
        Some(reference) if !reference.is_empty() => {
            if !host.vault_is_unlocked() {
                return err_resp("password store is locked — unlock it in the Password Store tab");
            }
            // Ops reference the secret by the NAME the operator gave it (label) or
            // by id — not the internal hex id alone. secret_for_ref resolves either.
            match host.vault_secret_for_ref(reference) {
                Ok(s) => Some(s),
                Err(e) => return err_resp(e),
            }
        }
        _ => None,
    };

    // Run the (blocking) fixed program off the async runtime. The secret moves into
    // the closure and is dropped (zeroized) when the closure returns.
    let result = tokio::task::spawn_blocking(move || {
        let secret_ref = secret.as_ref().map(|s| s.as_str());
        crate::agent_ops::execute_op(&op, &args, secret_ref)
    })
    .await;

    match result {
        Ok(Ok(out)) => json!({
            "ok": true,
            "stdout": out.stdout,
            "stderr": out.stderr,
            "exitCode": out.exit_code,
        })
        .to_string(),
        Ok(Err(e)) => err_resp(e),
        Err(e) => err_resp(format!("operation task failed: {e}")),
    }
}

/// AC8/AC9/AC10 — resolve an alias, gate it, resolve the secret in Rust, and run
/// ONE remote command over ssh with the password injected server-side. Returns
/// `{ok,stdout,exitCode,timedOut}` — never the secret.
/// Build ONE remote script that runs each command in sequence over a single connection
/// and frames its output with a per-command marker carrying the exit code. This is how
/// `commands: []` gets many results from ONE ssh connection — the efficient path for PSMP
/// (no multiplexing needed). `nonce` makes the marker unguessable so command output can't
/// forge it. Pure/testable.
fn build_batch_script(commands: &[String], nonce: &str) -> String {
    let mut s = String::new();
    for (i, cmd) in commands.iter().enumerate() {
        s.push_str(cmd);
        s.push('\n');
        // printf frames the marker on its own line (leading + trailing newline).
        s.push_str(&format!(
            "printf '\\n__MUYA_{nonce}_END:{i}:%d__\\n' \"$?\"\n"
        ));
    }
    s
}

/// Parse the framed stdout of `build_batch_script` into `(output, exit_code)` per command,
/// in order. Everything between markers is that command's stdout. Pure/testable.
fn parse_batch_output(stdout: &str, nonce: &str) -> Vec<(String, i32)> {
    let marker_prefix = format!("__MUYA_{nonce}_END:");
    let mut results = Vec::new();
    let mut buf = String::new();
    for line in stdout.lines() {
        if let Some(rest) = line.trim().strip_prefix(&marker_prefix) {
            let rest = rest.strip_suffix("__").unwrap_or(rest);
            let rc = rest
                .rsplit(':')
                .next()
                .and_then(|s| s.parse::<i32>().ok())
                .unwrap_or(-1);
            results.push((buf.trim_end().to_string(), rc));
            buf.clear();
        } else {
            buf.push_str(line);
            buf.push('\n');
        }
    }
    results
}

/// `ssh_send` (PRD `ssh-send`): type `text` into the PTY of a terminal the agent
/// opened with ssh_open. Only ids currently in `SSH_SESSIONS` (opened, tab still open)
/// are writable — a closed or foreign id is refused. Fire-and-forget: the human sees
/// the result on screen; nothing but ok/err comes back to the agent. The text content
/// is NEVER logged (only the id + byte length).
fn handle_send<H: BrokerHost>(host: &H, req: &BrokerReq) -> String {
    let session_id = match req.session_id.as_deref() {
        Some(s) if !s.trim().is_empty() => s.trim(),
        _ => return err_resp("`send` requires a `sessionId` (returned by ssh_open)"),
    };
    let text = match req.text.as_deref() {
        Some(t) => t,
        None => return err_resp("`send` requires `text`"),
    };
    if !ssh_session_is_open(session_id) {
        return err_resp(format!(
            "unknown or closed session '{session_id}' — you may only write to a session \
             you opened with ssh_open, while its terminal tab is still open"
        ));
    }
    // The ssh tab's PTY is not visible to the broker: only the secret of the server this tab opened.
    let allowed = session_cred(session_id);
    let text = match substitute_for(host, text, !is_unverified(req), None, allowed.as_deref()) {
        Ok(t) => t,
        Err(e) => return err_resp(e),
    };
    // Audit trail — id + byte length ONLY; the keystroke content is never logged.
    log::info!("ssh_send → session {session_id} ({} bytes)", text.len());
    let payload = json!({ "sessionId": session_id, "text": text });
    if let Err(e) = host.emit("ssh-broker-send", payload) {
        return err_resp(format!("failed to deliver keystrokes: {e}"));
    }
    json!({"ok": true}).to_string()
}

/// Query the LOCAL ControlMaster socket for a connection (`ssh -O check`). Never touches
/// the remote host or PSMP — it only asks the local ssh whether a master socket is live.
/// Returns a short state for the reuse diagnostics log.
fn master_state(connect_args: &[String]) -> String {
    let out = std::process::Command::new("ssh")
        .arg("-O")
        .arg("check")
        .args(connect_args)
        .output();
    match out {
        Ok(o) => {
            let s = String::from_utf8_lossy(&o.stderr);
            if s.contains("Master running") {
                "alive".to_string()
            } else if s.contains("No such file")
                || s.contains("no match")
                || s.contains("not found")
                || s.contains("Control socket connect")
            {
                "absent".to_string()
            } else {
                format!("other({})", s.trim().replace('\n', " "))
            }
        }
        Err(e) => format!("check-err({e})"),
    }
}

/// True if stderr carries the PSMP stale-master / multiplexing-rejection signature.
fn is_stale_master(stderr: &str) -> bool {
    stderr.contains("Invalid session state")
        || stderr.contains("Failed to receive an allowed pid")
        || stderr.contains("Failed to receive a return code")
        || stderr.contains("PSM SSH Proxy exception")
        || stderr.contains("Shared connection to")
}

/// Last ~200 chars of stderr on one line, for a compact diagnostic log entry.
fn stderr_tail(stderr: &str) -> String {
    let flat = stderr.trim().replace('\n', " ");
    let n = flat.chars().count();
    if n <= 200 {
        flat
    } else {
        flat.chars().skip(n - 200).collect()
    }
}

/// Outcome of matching an agent-supplied `target` against the running sessions.
/// Pure/testable: exact id > exact name (case-insensitive) > substring. Several matches
/// stay ambiguous on purpose so the agent asks the OPERATOR which one — never guesses.
#[derive(Debug, PartialEq)]
pub enum TargetMatch {
    One(usize),
    Many(Vec<usize>),
    None,
}

pub fn resolve_target(target: &str, sessions: &[(String, String)]) -> TargetMatch {
    let t = target.trim().to_lowercase();
    if t.is_empty() {
        return TargetMatch::None;
    }
    // 1) exact id
    if let Some(i) = sessions.iter().position(|(id, _)| id.to_lowercase() == t) {
        return TargetMatch::One(i);
    }
    // 2) exact name
    let exact: Vec<usize> = sessions
        .iter()
        .enumerate()
        .filter(|(_, (_, name))| name.to_lowercase() == t)
        .map(|(i, _)| i)
        .collect();
    if exact.len() == 1 {
        return TargetMatch::One(exact[0]);
    }
    if exact.len() > 1 {
        return TargetMatch::Many(exact);
    }
    // 3) substring on name (or id prefix)
    let loose: Vec<usize> = sessions
        .iter()
        .enumerate()
        .filter(|(_, (id, name))| {
            name.to_lowercase().contains(&t) || id.to_lowercase().starts_with(&t)
        })
        .map(|(i, _)| i)
        .collect();
    match loose.len() {
        0 => TargetMatch::None,
        1 => TargetMatch::One(loose[0]),
        _ => TargetMatch::Many(loose),
    }
}

/// Running sessions as `(id, name)` pairs plus the full records, for the tools below.
pub fn running_sessions<H: BrokerHost>() -> Result<Vec<AgentSession>, String> {
    let all = H::list_agent_sessions_fresh(Some(true))?;
    Ok(all
        .into_iter()
        .filter(|s| s.status != "stopped" && !s.id.is_empty())
        .collect())
}

fn session_pairs(sessions: &[AgentSession]) -> Vec<(String, String)> {
    sessions
        .iter()
        .map(|s| (s.id.clone(), s.name.clone()))
        .collect()
}

/// Size limits of `open_session` fields (the payload becomes one daemon event frame, capped at 16 MiB).
const MAX_NAME_LEN: usize = 256;
const MAX_CWD_LEN: usize = 4096;
const MAX_INITIAL_MESSAGE: usize = 256 * 1024;

/// `open_session` (PRD `agent-session-open`): the local analog of `ssh_open` — no
/// server, no credentials, no session-id minting. Just tells the app to open a new
/// terminal tab running `claude --permission-mode auto --name <name>`
/// (optionally with an initial prompt). The new Claude process registers itself
/// with `claude agents --json` on its own — Muya's `list_sessions`/`send_to_session`
/// (backed by that same registry, see `running_sessions` above) can address it by
/// `name` right away, independent of this app's own tab/PTY bookkeeping.
/// Pure core of `open_session`: validate `name` and build the event payload.
/// Split out so the validation/shape logic is testable without a Tauri `AppHandle`.
fn build_open_session_payload(req: &BrokerReq) -> Result<(String, serde_json::Value), String> {
    let name = match req.name.as_deref() {
        Some(n) if !n.trim().is_empty() => n.trim().to_string(),
        _ => return Err("`open_session` requires a non-empty `name`".to_string()),
    };
    let agent = normalize_agent(req.agent.as_deref())?;
    if name.len() > MAX_NAME_LEN {
        return Err(format!("`name` is too long (limit {MAX_NAME_LEN} bytes)"));
    }
    if req.cwd.as_deref().is_some_and(|c| c.len() > MAX_CWD_LEN) {
        return Err(format!("`cwd` is too long (limit {MAX_CWD_LEN} bytes)"));
    }
    if req
        .initial_message
        .as_deref()
        .is_some_and(|m| m.len() > MAX_INITIAL_MESSAGE)
    {
        return Err(format!(
            "`initial_message` is too long (limit {MAX_INITIAL_MESSAGE} bytes)"
        ));
    }
    let payload = json!({
        "name": name,
        "cwd": req.cwd,
        "initialMessage": req.initial_message,
        "agent": agent,
        "splitWith": req.split_with.as_deref().map(str::trim).filter(|s| !s.is_empty()),
        "openedBy": req.opened_by.as_deref().map(str::trim).filter(|s| !s.is_empty()),
        "unattended": req.unattended.unwrap_or(true),
    });
    Ok((name, payload))
}

/// Which agent CLI `open_session` should launch.
///
/// Absent ⇒ "claude": every caller written before opencode existed keeps its
/// exact behavior. An unknown value is an ERROR rather than a silent fallback to
/// Claude — an agent that asked for opencode and quietly got Claude would send its
/// next message to the wrong kind of session and have no way to notice.
fn normalize_agent(raw: Option<&str>) -> Result<String, String> {
    match raw.map(str::trim).filter(|s| !s.is_empty()) {
        None => Ok("claude".to_string()),
        Some(a) if a.eq_ignore_ascii_case("claude") => Ok("claude".to_string()),
        Some(a) if a.eq_ignore_ascii_case("opencode") => Ok("opencode".to_string()),
        Some(other) => Err(format!(
            "unknown agent '{other}' — expected \"claude\" or \"opencode\""
        )),
    }
}

async fn handle_open_session<H: BrokerHost>(host: &H, req: &BrokerReq) -> String {
    let (name, payload) = match build_open_session_payload(req) {
        Ok(v) => v,
        Err(e) => return err_resp(e),
    };
    let track = host.tracking().filter(|_| payload["agent"] == "claude");
    // Terminals already running Claude under this name: only a NEW one is "the tab we opened".
    let before: HashSet<u64> = match (&track, blocking(|| host.terminal_list())) {
        (Some(_), Ok(terms)) => terms
            .iter()
            .filter(|t| name_matches(&t.name, &name))
            .map(|t| t.id)
            .collect(),
        _ => HashSet::new(),
    };
    // Registered BEFORE the emit (and rolled back if it fails) so a `close_session`
    // that races the tab actually opening still sees this name as ours.
    // The name must be free: registering a name an operator's own tab already uses would make
    // that tab look agent-owned (and closable).
    if agent_session_name_taken(&name)
        || blocking(|| host.terminal_list())
            .map(|t| t.iter().any(|x| x.name.eq_ignore_ascii_case(&name)))
            .unwrap_or(false)
    {
        return err_resp(format!(
            "a session named '{name}' already exists, pick another name"
        ));
    }
    register_agent_session(&name, &caller_key(req));
    if let Err(e) = host.emit("muya://open-agent-session", payload) {
        release_agent_session(&name);
        return err_resp(format!("failed to signal open_session: {e}"));
    }
    let Some(t) = track else {
        return json!({"ok": true, "name": name, "status": "requested"}).to_string();
    };
    match track_open(host, &t, &name, req.initial_message.as_deref(), &before).await {
        Ok(v) => v.to_string(),
        Err(e) => {
            release_agent_session(&name);
            err_resp(e)
        }
    }
}

/// How long and how often the broker checks that what it asked for really happened.
#[derive(Debug, Clone, Copy)]
pub struct Tracking {
    /// Tab opened and Claude registered under its name.
    pub open_wait: Duration,
    /// A typed message shows up as a user turn in the transcript.
    pub submit_wait: Duration,
    pub poll: Duration,
}

impl Default for Tracking {
    fn default() -> Self {
        Tracking {
            open_wait: Duration::from_secs(60),
            submit_wait: Duration::from_secs(45),
            poll: Duration::from_millis(700),
        }
    }
}

/// `claude agents` makes colliding names unique as `name (hint)`.
fn name_matches(have: &str, want: &str) -> bool {
    have == want || have.strip_prefix(want).is_some_and(|r| r.starts_with(" ("))
}

/// The new Claude terminal named `name`, if there is one.
fn pick_new_claude_terminal<'a>(
    terms: &'a [TerminalInfo],
    name: &str,
    before: &HashSet<u64>,
) -> Option<&'a TerminalInfo> {
    terms.iter().find(|t| {
        t.kind == "claude"
            && !before.contains(&t.id)
            && name_matches(&t.name, name)
            && t.claude_session_id.is_some()
    })
}

/// What to look for in the transcript to know a message went in: its first non-empty line, cut to 60 chars.
fn submit_needle(msg: &str) -> String {
    msg.lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("")
        .chars()
        .take(60)
        .collect()
}

/// How many user turns of the session contain `needle` (0 when there is no transcript yet).
fn user_turns_with<H: BrokerHost>(cwd: &str, session_id: &str, needle: &str) -> usize {
    if needle.is_empty() {
        return 0;
    }
    match H::read_transcript_tail(cwd, session_id, 400, Some(needle)) {
        Ok(out) => out.matches("## \u{1F464} User").count(),
        Err(_) => 0,
    }
}

/// `open_session` once the tab was requested: wait for the Claude process, then for its first message.
async fn track_open<H: BrokerHost>(
    host: &H,
    t: &Tracking,
    name: &str,
    message: Option<&str>,
    before: &HashSet<u64>,
) -> Result<serde_json::Value, String> {
    let start = Instant::now();
    let known: HashSet<u64> = blocking(|| host.terminal_list())
        .map(|v| v.iter().map(|x| x.id).collect())
        .unwrap_or_default();
    let mut seen_new_terminal = false;
    let found = loop {
        if let Ok(terms) = blocking(|| host.terminal_list()) {
            if let Some(x) = pick_new_claude_terminal(&terms, name, before) {
                break x.clone();
            }
            seen_new_terminal |= terms.iter().any(|x| !known.contains(&x.id));
        }
        if start.elapsed() >= t.open_wait {
            let why = if seen_new_terminal {
                "a terminal opened but Claude did not start in it (CLI missing, too old, or stuck on a dialog)"
            } else {
                "no terminal opened (is a Muya window attached?)"
            };
            return Err(format!(
                "open_session '{name}': {why} within {}s",
                t.open_wait.as_secs()
            ));
        }
        tokio::time::sleep(t.poll).await;
    };
    let sid = found.claude_session_id.clone().unwrap_or_default();
    let mut out = json!({
        "ok": true, "name": name, "status": "started",
        "terminalId": found.id, "sessionId": sid, "cwd": found.cwd,
    });
    let Some(msg) = message.map(str::trim).filter(|m| !m.is_empty()) else {
        return Ok(out);
    };
    let needle = submit_needle(msg);
    let mut stage = 0;
    let t0 = Instant::now();
    loop {
        if blocking(|| user_turns_with::<H>(&found.cwd, &sid, &needle)) > 0 {
            out["status"] = json!("message_submitted");
            out["retries"] = json!(stage);
            return Ok(out);
        }
        let el = t0.elapsed();
        if el >= t.submit_wait {
            return Err(format!(
                "open_session '{name}': Claude started (terminal {}) but the first message was not submitted within {}s",
                found.id,
                t.submit_wait.as_secs()
            ));
        }
        // 1/3 in: the text sits in the prompt, press Enter. 2/3 in: press Enter once more, but only
        // while the text is still in the input line. The message is never typed a second time: a
        // false "not submitted" (transcript lag, wrapped line) would send it twice.
        if (stage == 0 && el >= t.submit_wait / 3) || (stage == 1 && el >= t.submit_wait * 2 / 3) {
            // M6: Enter on a permission / trust dialog would accept it.
            if let Some(w) = terminal_id_waiting_for(host, found.id) {
                out["status"] = json!("target_waiting_on_dialog");
                out["waitingFor"] = json!(w);
                return Ok(out);
            }
            if stage == 1 {
                // A host that cannot read the screen (None) cannot prove it is gone: Enter alone is harmless.
                let short: String = needle.chars().take(40).collect();
                let in_input = blocking(|| host.terminal_lines(found.id))
                    .is_none_or(|ls| ls.iter().any(|l| l.contains(&short)));
                if !in_input {
                    return Err(format!(
                        "open_session '{name}': the first message was not submitted and is no longer in the input line of terminal {}; not typing it again (it may have been submitted — check with read_session)",
                        found.id
                    ));
                }
            }
            stage += 1;
            let _ = blocking(|| host.terminal_raw(found.id, "\r"));
        }
        tokio::time::sleep(t.poll).await;
    }
}

/// `list_sessions` (PRD `session-messaging`): the RUNNING Claude sessions Muya knows,
/// with the operator's own names — so an agent can address "the password-hardening
/// session" by name instead of guessing.
async fn handle_list_sessions<H: BrokerHost>(req: &BrokerReq) -> String {
    let sessions = match tokio::task::spawn_blocking(running_sessions::<H>).await {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => return err_resp(e),
        Err(e) => return err_resp(format!("list task failed: {e}")),
    };
    let me = req.session_id.as_deref().unwrap_or("");
    let list: Vec<serde_json::Value> = sessions
        .iter()
        .map(|s| {
            json!({
                "id": s.id,
                "name": s.name,
                "cwd": s.worktree,
                "status": s.status,
                // Why it's waiting, when status is waiting-for-input — e.g. "permission
                // prompt" — so an agent can tell that apart from an ordinary chat wait
                // before deciding to answer it (send_to_session deliver:"muya").
                "waitingFor": s.waiting_for,
                "isCurrent": !me.is_empty() && s.id == me,
            })
        })
        .collect();
    json!({ "ok": true, "sessions": list }).to_string()
}

/// `read_session`: read another session's recent conversation (read-only) so an agent can
/// answer "what is that session up to?" without messaging it.
async fn handle_read_session<H: BrokerHost>(req: &BrokerReq) -> String {
    let target = match req.target.as_deref() {
        Some(t) if !t.trim().is_empty() => t.to_string(),
        _ => return err_resp("`read_session` requires a `target` (session name or id)"),
    };
    let limit = req.limit.unwrap_or(20).clamp(1, 200) as usize;
    let query = req.query.clone();
    let result = tokio::task::spawn_blocking(move || -> Result<String, String> {
        let sessions = running_sessions::<H>()?;
        let pairs = session_pairs(&sessions);
        match resolve_target(&target, &pairs) {
            TargetMatch::None => Err(format!("no running session matches '{target}'")),
            TargetMatch::Many(idxs) => Err(format!(
                "'{target}' matches {} sessions ({}) — ask the operator which one and pass its exact name or id",
                idxs.len(),
                idxs.iter()
                    .map(|i| pairs[*i].1.clone())
                    .collect::<Vec<_>>()
                    .join(", ")
            )),
            TargetMatch::One(i) => {
                let s = &sessions[i];
                let body = H::read_transcript_tail(
                    &s.worktree,
                    &s.id,
                    limit,
                    query.as_deref(),
                )?;
                Ok(json!({
                    "ok": true,
                    "session": { "id": s.id, "name": s.name, "cwd": s.worktree, "status": s.status },
                    "content": body,
                })
                .to_string())
            }
        }
    })
    .await;
    match result {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => err_resp(e),
        Err(e) => err_resp(format!("read task failed: {e}")),
    }
}

enum Claim {
    Duplicate,
    /// Delivered for the first time; holds the scoped key to release if the hand-off fails.
    Fresh(Option<String>),
}

/// Only the typing modes ("muya", "keys") are idempotent: "auto" just resolves a name. The key
/// is scoped to the target and mode, so the same key sent elsewhere is a different message.
fn claim_typed_delivery<H: BrokerHost>(
    host: &H,
    key: Option<&str>,
    deliver: &str,
    target_id: &str,
) -> Result<Claim, String> {
    let Some(key) = key.map(str::trim).filter(|k| !k.is_empty()) else {
        return Ok(Claim::Fresh(None));
    };
    if deliver != "muya" && deliver != "keys" {
        return Ok(Claim::Fresh(None));
    }
    if key.len() > 200 {
        return Err("`idempotencyKey` is limited to 200 characters".into());
    }
    let scoped = format!("{deliver}\u{1}{target_id}\u{1}{key}");
    match host.claim_delivery(&scoped) {
        Ok(true) => Ok(Claim::Fresh(Some(scoped))),
        Ok(false) => Ok(Claim::Duplicate),
        Err(e) => Err(format!("could not record the idempotency key: {e}")),
    }
}

/// Cap on `compact_session` instructions (chars).
const COMPACT_INSTRUCTIONS_MAX: usize = 500;

/// Make `instructions` safe to type after `/compact`: one line, no control chars
/// (an ESC could drive the TUI, a newline would submit a half line), whitespace
/// collapsed, capped at `COMPACT_INSTRUCTIONS_MAX` chars. Empty ⇒ `None`.
fn sanitize_compact_instructions(raw: &str) -> Option<String> {
    let spaced: String = raw
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let collapsed = spaced.split_whitespace().collect::<Vec<_>>().join(" ");
    let capped: String = collapsed.chars().take(COMPACT_INSTRUCTIONS_MAX).collect();
    let capped = capped.trim().to_string();
    if capped.is_empty() {
        None
    } else {
        Some(capped)
    }
}

/// Why `/compact` must NOT be typed into this session right now (None ⇒ go).
fn compact_refusal(
    name: &str,
    agent: &str,
    status: &str,
    waiting_for: Option<&str>,
    is_self: bool,
) -> Option<String> {
    if is_self {
        return Some(
            "you cannot compact your own session — ask the operator to run /compact".to_string(),
        );
    }
    if agent != "claude" {
        return Some(format!(
            "'{name}' is a {agent} session — compact_session only works on Claude sessions"
        ));
    }
    if let Some(w) = waiting_for.filter(|w| !w.is_empty()) {
        return Some(format!(
            "'{name}' is stuck waiting on: {w} — answer it first (send_to_session deliver:\"keys\"), then compact"
        ));
    }
    match status {
        "idle" => None,
        "working" => Some(format!(
            "'{name}' is busy (working) — wait until list_sessions shows it idle, then compact"
        )),
        "waiting-for-input" => Some(format!(
            "'{name}' is waiting for input — answer it first, then compact"
        )),
        other => Some(format!(
            "'{name}' is not idle (status: {other}) — cannot compact"
        )),
    }
}

/// The exact line typed into the target: `/compact` or `/compact <instructions>`.
fn compact_line(instructions: Option<&str>) -> String {
    match instructions.and_then(sanitize_compact_instructions) {
        Some(i) => format!("/compact {i}"),
        None => "/compact".to_string(),
    }
}

/// `compact_session`: type `/compact[ instructions]` + Enter into another Claude
/// session's terminal (PRD `mcp-compact-session`). Resolves like send_to_session.
async fn handle_compact_session<H: BrokerHost>(host: &H, req: &BrokerReq) -> String {
    let target = match req.target.as_deref() {
        Some(t) if !t.trim().is_empty() => t.to_string(),
        _ => return err_resp("`compact_session` requires a `target` (session name or id)"),
    };
    let from = req.caller.clone();
    let line = compact_line(req.instructions.as_deref());

    let resolved = tokio::task::spawn_blocking(move || -> Result<AgentSession, String> {
        let sessions = running_sessions::<H>()?;
        let pairs = session_pairs(&sessions);
        match resolve_target(&target, &pairs) {
            TargetMatch::None => Err(format!("no running session matches '{target}'")),
            TargetMatch::Many(idxs) => Err(format!(
                "'{target}' matches {} sessions ({}) — ask the operator which one and pass its exact name or id",
                idxs.len(),
                idxs.iter().map(|i| pairs[*i].1.clone()).collect::<Vec<_>>().join(", ")
            )),
            TargetMatch::One(i) => Ok(sessions[i].clone()),
        }
    })
    .await;
    let s = match resolved {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => return err_resp(e),
        Err(e) => return err_resp(format!("resolve task failed: {e}")),
    };
    let is_self = !from.is_empty() && s.id == from;
    if let Some(why) = compact_refusal(
        &s.name,
        &s.agent,
        &s.status,
        s.waiting_for.as_deref(),
        is_self,
    ) {
        return err_resp(why);
    }
    let payload = json!({ "sessionId": s.id, "text": line, "raw": true, "submit": true });
    if let Err(e) = host.emit("muya://deliver-message", payload) {
        return err_resp(format!("failed to deliver: {e}"));
    }
    json!({
        "ok": true,
        "typed": line,
        "target": { "id": s.id, "name": s.name, "cwd": s.worktree },
    })
    .to_string()
}

/// One rate-limit window from the statusline JSON, or None when absent / already
/// past its reset (Claude drops expired windows itself, but a stale file may not).
fn usage_window(v: &Value, now: u64) -> Option<Value> {
    let used = v.get("used_percentage")?.as_f64()?;
    let resets = v.get("resets_at").and_then(Value::as_u64);
    if resets.is_some_and(|r| r <= now) {
        return None;
    }
    let mut o = json!({ "usedPercentage": used, "resetsAt": resets });
    for (k, out) in [("used_usd", "usedUsd"), ("limit_usd", "limitUsd")] {
        if let Some(x) = v.get(k).and_then(Value::as_f64) {
            o[out] = json!(x);
        }
    }
    if let Some(p) = v.get("period").and_then(Value::as_str) {
        o["period"] = json!(p);
    }
    Some(o)
}

/// Pick the newest captured status that carries `rate_limits` (optionally only the
/// one whose `session_id` is `want_session`) and map it to the tool's shape.
/// Pure: `files` = (status JSON, file mtime secs), `now` = unix secs.
fn usage_from_status(
    files: &[(Value, u64)],
    want_session: Option<&str>,
    now: u64,
) -> Result<Value, String> {
    let best = files
        .iter()
        .filter(|(v, _)| v.get("rate_limits").is_some_and(Value::is_object))
        .filter(|(v, _)| {
            want_session.is_none_or(|w| v.get("session_id").and_then(Value::as_str) == Some(w))
        })
        .max_by_key(|(_, m)| *m);
    let Some((v, mtime)) = best else {
        return Err(match want_session {
            Some(_) => "no usage data captured for that session yet — rate limits appear after its first API response, and only for claude.ai subscription accounts".to_string(),
            None => "no usage data captured yet — rate limits appear after a Claude session's first API response, only for claude.ai Pro/Max/Ultra accounts, and only for sessions started in Muya with the status-line footer enabled".to_string(),
        });
    };
    let rl = &v["rate_limits"];
    let mut windows = serde_json::Map::new();
    for (k, out) in [
        ("five_hour", "fiveHour"),
        ("seven_day", "sevenDay"),
        ("spend_limit", "spendLimit"),
    ] {
        if let Some(w) = rl.get(k).and_then(|w| usage_window(w, now)) {
            windows.insert(out.to_string(), w);
        }
    }
    Ok(json!({
        "windows": windows,
        "capturedAt": mtime,
        "ageSeconds": now.saturating_sub(*mtime),
        "sessionId": v.get("session_id"),
        "note": "Limits are per account; usedPercentage is 0-100, resetsAt is unix seconds. Data is as of capturedAt (the session's last status-line refresh).",
    }))
}

/// `usage`: Claude Code's `/usage` numbers (5-hour / weekly limits) from the
/// status-line JSON Muya already captures per tab — no screen scraping.
async fn handle_usage<H: BrokerHost>(req: &BrokerReq) -> String {
    let want = match req
        .target
        .as_deref()
        .map(str::trim)
        .filter(|t| !t.is_empty())
    {
        None => None,
        Some(t) => {
            let t = t.to_string();
            let r = tokio::task::spawn_blocking(move || -> Result<String, String> {
                let sessions = running_sessions::<H>()?;
                let pairs = session_pairs(&sessions);
                match resolve_target(&t, &pairs) {
                    TargetMatch::None => Err(format!("no running session matches '{t}'")),
                    TargetMatch::Many(idxs) => Err(format!(
                        "'{t}' matches {} sessions ({}) — pass its exact name or id",
                        idxs.len(),
                        idxs.iter()
                            .map(|i| pairs[*i].1.clone())
                            .collect::<Vec<_>>()
                            .join(", ")
                    )),
                    TargetMatch::One(i) => Ok(sessions[i].id.clone()),
                }
            })
            .await;
            match r {
                Ok(Ok(id)) => Some(id),
                Ok(Err(e)) => return err_resp(e),
                Err(e) => return err_resp(format!("resolve task failed: {e}")),
            }
        }
    };
    let files = tokio::task::spawn_blocking(crate::statusline::all_status)
        .await
        .unwrap_or_default();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    match usage_from_status(&files, want.as_deref(), now) {
        Ok(mut v) => {
            v["ok"] = json!(true);
            v.to_string()
        }
        Err(e) => err_resp(e),
    }
}

/// `send_to_session`: resolve a fuzzy target to ONE running session. Default
/// (`deliver: "auto"`) returns the canonical name so the agent delivers with the native,
/// non-interrupting `SendMessage`; `deliver: "muya"` has Muya type it into the target's
/// terminal instead (fallback when native cross-session messaging isn't available),
/// wrapped as a chat message; `deliver: "keys"` types `text` in VERBATIM with no
/// wrapping, for answering an interactive prompt the target is stuck on.
async fn handle_send_to_session<H: BrokerHost>(host: &H, req: &BrokerReq) -> String {
    let target = match req.target.as_deref() {
        Some(t) if !t.trim().is_empty() => t.to_string(),
        _ => return err_resp("`send_to_session` requires a `target` (session name or id)"),
    };
    let text = match req.text.as_deref() {
        Some(t) if !t.trim().is_empty() => t.to_string(),
        _ => return err_resp("`send_to_session` requires non-empty `text`"),
    };
    let deliver = req.deliver.clone().unwrap_or_else(|| "auto".to_string());
    // The sender is the VERIFIED peer, never a name from the request body.
    let from = req.caller.clone();

    let resolved = tokio::task::spawn_blocking(move || -> Result<(String, String, String, String), String> {
        let sessions = running_sessions::<H>()?;
        let pairs = session_pairs(&sessions);
        match resolve_target(&target, &pairs) {
            TargetMatch::None => Err(format!("no running session matches '{target}'")),
            TargetMatch::Many(idxs) => Err(format!(
                "'{target}' matches {} sessions ({}) — ask the operator which one and pass its exact name or id",
                idxs.len(),
                idxs.iter().map(|i| pairs[*i].1.clone()).collect::<Vec<_>>().join(", ")
            )),
            TargetMatch::One(i) => {
                let s = &sessions[i];
                Ok((s.id.clone(), s.name.clone(), s.worktree.clone(), s.status.clone()))
            }
        }
    })
    .await;
    let (id, name, cwd, status) = match resolved {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => return err_resp(e),
        Err(e) => return err_resp(format!("resolve task failed: {e}")),
    };

    // M8: an unverified caller may only type into sessions it opened itself.
    if (deliver == "muya" || deliver == "keys")
        && is_unverified(req)
        && !agent_session_owned_by(&name, &caller_key(req))
    {
        return err_resp(format!(
            "this caller could not be tied to a Claude session, so it may only send to sessions it opened with open_session ('{name}' was not)"
        ));
    }

    // PRD AC25: a retry with the same key must not type the text a second time.
    let claimed = match claim_typed_delivery(host, req.idempotency_key.as_deref(), &deliver, &id) {
        Ok(Claim::Duplicate) => {
            return json!({
                "ok": true,
                "delivered": deliver,
                "duplicate": true,
                "target": { "id": id, "name": name, "cwd": cwd },
            })
            .to_string();
        }
        Ok(Claim::Fresh(k)) => k,
        Err(e) => return err_resp(e),
    };
    let release = |host: &H| {
        if let Some(k) = &claimed {
            host.release_delivery(k);
        }
    };

    if deliver == "muya" {
        // Muya types it into the target terminal, tagged with the sender. This is a
        // CHAT message (wrapped with a "[message from X via Muya]" tag) — not raw
        // keystrokes; a session reads it as ordinary conversational input.
        let sender = caller_label(req);
        // A channel event when the target loaded muya-mcp as a channel (nothing is
        // typed); otherwise its terminal, submitted by the frontend.
        let tracking = host.tracking();
        let needle = submit_needle(&text);
        let baseline = if tracking.is_some() {
            blocking(|| user_turns_with::<H>(&cwd, &id, &needle))
        } else {
            0
        };
        // M6: typing into a permission / trust dialog would answer it (Enter accepts the default).
        if tracking.is_some() && !channel_live(&id) {
            if let Some(w) = terminal_waiting_for(host, &id) {
                release(host);
                return json!({
                    "ok": false, "delivered": false, "state": "target_waiting_on_dialog",
                    "error": format!("'{name}' is waiting on a {w} — nothing was typed; answer it with send_to_session(deliver:\"keys\") or ask the operator"),
                    "target": { "id": id, "name": name, "cwd": cwd },
                })
                .to_string();
            }
        }
        let via = match deliver_chat(host, &id, &text, &sender) {
            Ok(v) => v,
            Err(e) => {
                release(host);
                return err_resp(format!("failed to deliver: {e}"));
            }
        };
        let mut out = json!({
            "ok": true,
            "delivered": "muya",
            "via": via,
            "target": { "id": id, "name": name, "cwd": cwd },
        });
        if let Some(t) = tracking {
            match confirm_chat(
                host,
                &t,
                &id,
                &cwd,
                &needle,
                baseline,
                status == "working",
                via,
            )
            .await
            {
                Ok(state) => out["state"] = json!(state),
                // M5: the text WAS typed. Keep the idempotency key, so a retry with it cannot type it twice.
                Err(e) => return err_resp(e),
            }
        }
        return out.to_string();
    }

    if deliver == "keys" {
        // Raw keystrokes, verbatim, NO "[message from X via Muya]" wrapping — for
        // answering an interactive screen (a permission prompt, the trust-folder
        // dialog) where any extra characters would be typed INTO the menu itself and
        // likely break it. The caller controls the exact bytes, including newlines.
        let prompt = if crate::secret_refs::names_in(&text).is_empty() {
            None
        } else {
            terminal_of_session(host, &id)
                .ok()
                .and_then(|tid| prompt_state_of(host, tid))
        };
        let text = match substitute_for(host, &text, !is_unverified(req), prompt.as_ref(), None) {
            Ok(t) => t,
            Err(e) => {
                release(host);
                return err_resp(e);
            }
        };
        if host.tracking().is_some() {
            // The host types the bytes itself (Enter is "\r"); nothing to confirm: this answers a screen.
            let sent = terminal_of_session(host, &id).and_then(|tid| host.terminal_raw(tid, &text));
            if let Err(e) = sent {
                release(host);
                return err_resp(format!("failed to deliver: {e}"));
            }
        } else {
            let payload = json!({ "sessionId": id, "text": text, "raw": true });
            if let Err(e) = host.emit("muya://deliver-message", payload) {
                release(host);
                return err_resp(format!("failed to deliver: {e}"));
            }
        }
        audit_typed(host, req, "keys", &id, &name, text.len());
        return json!({
            "ok": true,
            "delivered": "keys",
            "target": { "id": id, "name": name, "cwd": cwd },
        })
        .to_string();
    }

    json!({
        "ok": true,
        "deliverWith": "SendMessage",
        "target": { "id": id, "name": name, "cwd": cwd },
        "text": text,
        "from": from,
    })
    .to_string()
}

/// Delivers `text` to Claude session `id` as a chat message from `sender`: a channel event when the
/// target loaded muya-mcp as a channel (nothing is typed), else typed into its terminal by the app.
/// Returns how it went out ("channel" | "terminal").
fn deliver_chat<H: BrokerHost>(
    host: &H,
    id: &str,
    text: &str,
    sender: &str,
) -> Result<&'static str, String> {
    if push_channel(id, &session_channel_event(sender, text)) {
        return Ok("channel");
    }
    if host.tracking().is_some() {
        // The host owns the terminals (muyad): type it ourselves. An event to the app is not a delivery —
        // the native app has no handler for it, and with no window attached nobody would type.
        let tid = terminal_of_session(host, id)?;
        blocking(|| host.terminal_type(tid, &chat_line(sender, text), true, true))?;
        return Ok("terminal");
    }
    host.emit(
        "muya://deliver-message",
        json!({ "sessionId": id, "text": text, "from": sender }),
    )?;
    Ok("terminal")
}

/// True while `session_id` has a live channel subscriber (a message then is not typed at all).
fn channel_live(session_id: &str) -> bool {
    CHANNELS
        .lock()
        .map(|m| m.get(session_id).is_some_and(|tx| !tx.is_closed()))
        .unwrap_or(false)
}

/// Why the terminal running Claude session `session_id` is blocked (a permission / trust dialog), if it is.
fn terminal_waiting_for<H: BrokerHost>(host: &H, session_id: &str) -> Option<String> {
    blocking(|| host.terminal_list())
        .ok()?
        .into_iter()
        .find(|t| t.claude_session_id.as_deref() == Some(session_id))
        .and_then(|t| t.waiting_for)
}

/// Same, by terminal id.
fn terminal_id_waiting_for<H: BrokerHost>(host: &H, terminal_id: u64) -> Option<String> {
    blocking(|| host.terminal_list())
        .ok()?
        .into_iter()
        .find(|t| t.id == terminal_id)
        .and_then(|t| t.waiting_for)
}

/// The line a chat message is typed as into a terminal (same text as the Tauri frontend's `deliveryWrites`).
fn chat_line(sender: &str, text: &str) -> String {
    format!("[message from {sender} via Muya] {text}")
}

/// The terminal that runs Claude session `session_id`.
fn terminal_of_session<H: BrokerHost>(host: &H, session_id: &str) -> Result<u64, String> {
    blocking(|| host.terminal_list())?
        .iter()
        .find(|t| t.claude_session_id.as_deref() == Some(session_id))
        .map(|t| t.id)
        .ok_or_else(|| format!("session '{session_id}' does not run in a Muya terminal, so there is nothing to type into"))
}

/// After a chat message went out: wait until the target's transcript shows it as a NEW user turn.
/// Not submitted after a third of the time: press Enter once (the text sits in the prompt). A busy
/// target queues the message, which the transcript only shows later: that is reported as `queued`.
async fn confirm_chat<H: BrokerHost>(
    host: &H,
    t: &Tracking,
    session_id: &str,
    cwd: &str,
    needle: &str,
    baseline: usize,
    busy: bool,
    via: &str,
) -> Result<&'static str, String> {
    let t0 = Instant::now();
    let mut pressed = false;
    loop {
        if blocking(|| user_turns_with::<H>(cwd, session_id, needle)) > baseline {
            return Ok("submitted");
        }
        let el = t0.elapsed();
        if el >= t.submit_wait {
            return if busy {
                Ok("queued")
            } else {
                Err(format!("the message was sent ({via}) but the session did not take it as a turn within {}s — it may be stuck on a dialog; read it with read_session", t.submit_wait.as_secs()))
            };
        }
        if !pressed && !busy && via == "terminal" && el >= t.submit_wait / 3 {
            pressed = true;
            if let Ok(tid) = terminal_of_session(host, session_id) {
                // M6: Enter on a permission / trust dialog would accept it.
                if terminal_id_waiting_for(host, tid).is_some() {
                    return Ok("target_waiting_on_dialog");
                }
                let _ = blocking(|| host.terminal_raw(tid, "\r"));
            }
        }
        tokio::time::sleep(t.poll).await;
    }
}

/// How an operator-initiated send went for one terminal (`sessions.send_command`).
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct OperatorSendResult {
    /// The terminal id the operator picked.
    pub id: u64,
    pub name: String,
    /// "submitted" (the transcript shows a new turn) | "queued" (the session was busy, it takes the text
    /// after its current turn) | "sent" (typed and Enter pressed, but a slash command does not always
    /// show up in the transcript) | "skipped" (waiting on a dialog, nothing was typed) | "failed".
    pub state: String,
    pub reason: Option<String>,
}

impl OperatorSendResult {
    fn new(id: u64, name: &str, state: &str, reason: Option<String>) -> Self {
        Self {
            id,
            name: name.into(),
            state: state.into(),
            reason,
        }
    }
}

const MAX_OPERATOR_TARGETS: usize = 64;

struct OperatorPending {
    idx: usize,
    tid: u64,
    sid: String,
    cwd: String,
    baseline: usize,
    busy: bool,
    pressed: bool,
}

/// The operator typed `text` (a prompt or a slash command such as `/compact`) in the app and chose the
/// terminals `ids`. Same tracked delivery as `send_to_session`'s typing mode (refuses a terminal that waits
/// on a permission / trust dialog, presses Enter, confirms the new turn in the transcript, reports `queued`
/// for a busy session) with two differences: the text goes in VERBATIM (a slash command must be the first
/// characters of the line, so no "[message from X]" wrapping) and no secret placeholders are substituted
/// (the operator typed it themselves). Results come back in the order of `ids`.
pub async fn operator_send<H: BrokerHost>(
    host: &H,
    ids: &[u64],
    text: &str,
) -> Result<Vec<OperatorSendResult>, String> {
    if text.trim().is_empty() {
        return Err("type a command or a message first".into());
    }
    if text.contains('\0') || text.len() > MAX_TERMINAL_TEXT {
        return Err(format!(
            "the text must be at most {MAX_TERMINAL_TEXT} bytes and contain no NUL"
        ));
    }
    let mut uniq: Vec<u64> = Vec::new();
    for id in ids {
        if !uniq.contains(id) {
            uniq.push(*id);
        }
    }
    if uniq.is_empty() {
        return Err("pick at least one session".into());
    }
    if uniq.len() > MAX_OPERATOR_TARGETS {
        return Err(format!("at most {MAX_OPERATOR_TARGETS} sessions at once"));
    }
    let terms = blocking(|| host.terminal_list())?;
    let running = blocking(running_sessions::<H>).unwrap_or_default();
    let tracking = host.tracking();
    let needle = submit_needle(text);
    let mut results: Vec<Option<OperatorSendResult>> = vec![None; uniq.len()];
    let mut pending: Vec<OperatorPending> = Vec::new();
    for (idx, id) in uniq.iter().enumerate() {
        let Some(t) = terms.iter().find(|t| t.id == *id) else {
            results[idx] = Some(OperatorSendResult::new(
                *id,
                &format!("#{id}"),
                "failed",
                Some("this terminal is gone".into()),
            ));
            continue;
        };
        let Some(sid) = t.claude_session_id.clone().filter(|_| t.kind == "claude") else {
            results[idx] = Some(OperatorSendResult::new(
                *id,
                &t.name,
                "failed",
                Some("no Claude session runs in this terminal".into()),
            ));
            continue;
        };
        // Typing into a permission / trust dialog would answer it (Enter accepts the default).
        if let Some(w) = &t.waiting_for {
            results[idx] = Some(OperatorSendResult::new(
                *id,
                &t.name,
                "skipped",
                Some(format!("waiting on a {w}: nothing was typed")),
            ));
            continue;
        }
        let busy = running.iter().any(|s| s.id == sid && s.status == "working");
        let baseline = if tracking.is_some() {
            blocking(|| user_turns_with::<H>(&t.cwd, &sid, &needle))
        } else {
            0
        };
        if let Err(e) = blocking(|| host.terminal_type(t.id, text, true, true)) {
            results[idx] = Some(OperatorSendResult::new(*id, &t.name, "failed", Some(e)));
            continue;
        }
        crate::debuglog::log(&format!(
            "[audit] operator-send -> target={} ({sid}) bytes={}",
            t.name,
            text.len()
        ));
        if tracking.is_none() {
            results[idx] = Some(OperatorSendResult::new(
                *id,
                &t.name,
                "sent",
                Some("not confirmed (tracking is off)".into()),
            ));
            continue;
        }
        pending.push(OperatorPending {
            idx,
            tid: t.id,
            sid,
            cwd: t.cwd.clone(),
            baseline,
            busy,
            pressed: false,
        });
    }
    if let Some(tr) = tracking {
        let name_of = |tid: u64| {
            terms
                .iter()
                .find(|t| t.id == tid)
                .map(|t| t.name.clone())
                .unwrap_or_default()
        };
        let slash = text.trim_start().starts_with('/');
        let t0 = Instant::now();
        while !pending.is_empty() {
            let el = t0.elapsed();
            let mut still: Vec<OperatorPending> = Vec::new();
            for mut p in pending {
                let name = name_of(p.tid);
                if blocking(|| user_turns_with::<H>(&p.cwd, &p.sid, &needle)) > p.baseline {
                    results[p.idx] = Some(OperatorSendResult::new(p.tid, &name, "submitted", None));
                    continue;
                }
                if el >= tr.submit_wait {
                    results[p.idx] = Some(if p.busy {
                        OperatorSendResult::new(
                            p.tid,
                            &name,
                            "queued",
                            Some(
                                "the session is busy, it takes this after its current turn".into(),
                            ),
                        )
                    } else if slash {
                        OperatorSendResult::new(p.tid, &name, "sent", Some("typed and submitted; a slash command does not always show in the transcript".into()))
                    } else {
                        OperatorSendResult::new(p.tid, &name, "failed", Some(format!("typed, but the session did not take it as a turn within {}s: it may be stuck on a dialog", tr.submit_wait.as_secs())))
                    });
                    continue;
                }
                if !p.pressed && !p.busy && el >= tr.submit_wait / 3 {
                    p.pressed = true;
                    if terminal_id_waiting_for(host, p.tid).is_some() {
                        results[p.idx] = Some(OperatorSendResult::new(
                            p.tid,
                            &name,
                            "skipped",
                            Some("a dialog opened: Enter was not pressed".into()),
                        ));
                        continue;
                    }
                    let _ = blocking(|| host.terminal_raw(p.tid, "\r"));
                }
                still.push(p);
            }
            pending = still;
            if !pending.is_empty() {
                tokio::time::sleep(tr.poll).await;
            }
        }
    }
    Ok(results.into_iter().flatten().collect())
}

/// `close_session` (PRD `close-session`): close a terminal tab Muya itself opened via
/// `open_session` — never a session the operator opened by hand. Resolves `target`
/// exactly like `send_to_session` (id > exact name > substring, never guesses on a
/// tie), then refuses unless the resolved session's name is one `open_session`
/// actually opened (`AGENT_OPENED_SESSIONS` above).
async fn handle_close_session<H: BrokerHost>(host: &H, req: &BrokerReq) -> String {
    let target = match req.target.as_deref() {
        Some(t) if !t.trim().is_empty() => t.to_string(),
        _ => return err_resp("`close_session` requires a `target` (session name or id)"),
    };

    let resolved = tokio::task::spawn_blocking({
        let target = target.clone();
        move || -> Result<(String, String), String> {
            let sessions = running_sessions::<H>()?;
            let pairs = session_pairs(&sessions);
            match resolve_target(&target, &pairs) {
                TargetMatch::None => Err(format!("no running session matches '{target}'")),
                TargetMatch::Many(idxs) => Err(format!(
                    "'{target}' matches {} sessions ({}) — ask the operator which one and pass its exact name or id",
                    idxs.len(),
                    idxs.iter().map(|i| pairs[*i].1.clone()).collect::<Vec<_>>().join(", ")
                )),
                TargetMatch::One(i) => Ok((sessions[i].id.clone(), sessions[i].name.clone())),
            }
        }
    })
    .await;
    let (id, name) = match resolved {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => return err_resp(e),
        Err(e) => return err_resp(format!("resolve task failed: {e}")),
    };

    if !agent_session_owned_by(&name, &caller_key(req)) {
        return err_resp(format!(
            "'{name}' was not opened by you with open_session: you may only close sessions you opened yourself"
        ));
    }

    let payload = json!({ "sessionId": id });
    if let Err(e) = host.emit("muya://close-agent-session", payload) {
        return err_resp(format!("failed to signal close: {e}"));
    }
    release_agent_session(&name);
    json!({"ok": true, "name": name}).to_string()
}

// ---------------------------------------------------------------------------
// Terminals: open_terminal / send_terminal / broadcast (docs/prd-native-mcp-terminal.md)
// ---------------------------------------------------------------------------

/// Largest text one `send_terminal` / `broadcast` types (a paste, not a file transfer).
const MAX_TERMINAL_TEXT: usize = 16 * 1024;
/// Most terminals one `broadcast` touches.
const MAX_BROADCAST_TARGETS: usize = 64;

/// Runs blocking host work from an async handler without stalling the runtime's other tasks.
fn blocking<R>(f: impl FnOnce() -> R) -> R {
    match tokio::runtime::Handle::try_current() {
        Ok(h) if h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread => {
            tokio::task::block_in_place(f)
        }
        _ => f(),
    }
}

/// The text a terminal tool types: non-empty, no NUL, within [`MAX_TERMINAL_TEXT`].
fn check_terminal_text(tool: &str, text: Option<&str>) -> Result<String, String> {
    let text = match text {
        Some(t) if !t.trim().is_empty() => t,
        _ => return Err(format!("`{tool}` requires a non-empty `command`")),
    };
    if text.len() > MAX_TERMINAL_TEXT {
        return Err(format!(
            "the text is too long ({} bytes, limit {MAX_TERMINAL_TEXT})",
            text.len()
        ));
    }
    if text.contains('\0') {
        return Err("the text contains a NUL byte".into());
    }
    Ok(text.to_string())
}

/// One short, single-line, control-free excerpt for the logs.
fn log_preview(text: &str) -> String {
    let cut: String = text.chars().filter(|c| !c.is_control()).take(60).collect();
    cut
}

/// Resolves a `send_terminal` target (terminal id, Claude session id, exact name, then a unique
/// substring of the name) like [`resolve_target`] does for sessions.
fn resolve_terminal(target: &str, terms: &[TerminalInfo]) -> TargetMatch {
    let t = target.trim();
    if let Some(i) = terms
        .iter()
        .position(|x| x.claude_session_id.as_deref() == Some(t))
    {
        return TargetMatch::One(i);
    }
    let pairs: Vec<(String, String)> = terms
        .iter()
        .map(|x| (x.id.to_string(), x.name.clone()))
        .collect();
    resolve_target(t, &pairs)
}

fn terminal_json(t: &TerminalInfo) -> serde_json::Value {
    json!({ "id": t.id, "name": t.name, "cwd": t.cwd, "kind": t.kind })
}

/// Which terminals a broadcast reaches. Pure: `me` is the caller's Claude session id (skipped), and a terminal
/// waiting on a permission prompt is skipped unless `include_waiting`.
fn plan_broadcast<'a>(
    terms: &'a [TerminalInfo],
    kind: &str,
    me: &str,
    include_waiting: bool,
) -> (Vec<&'a TerminalInfo>, Vec<(&'a TerminalInfo, String)>) {
    let (mut hit, mut skipped) = (Vec::new(), Vec::new());
    for t in terms.iter().filter(|t| kind == "all" || t.kind == kind) {
        if !me.is_empty() && t.claude_session_id.as_deref() == Some(me) {
            skipped.push((t, "this is the calling session".to_string()));
        } else if let (Some(w), false) = (&t.waiting_for, include_waiting) {
            skipped.push((t, format!("waiting on a {w}")));
        } else {
            hit.push(t);
        }
    }
    (hit, skipped)
}

/// `open_terminal`: a plain shell tab (not Claude) in the native app, optionally running a first command.
fn handle_open_terminal<H: BrokerHost>(host: &H, req: &BrokerReq) -> String {
    let command = match req.command.as_deref().filter(|c| !c.is_empty()) {
        Some(c) => match check_terminal_text("open_terminal", Some(c)) {
            Ok(c) => Some(c),
            Err(e) => return err_resp(e),
        },
        None => None,
    };
    let cwd = req.cwd.as_deref().map(str::trim).filter(|c| !c.is_empty());
    if cwd.is_some_and(|c| c.len() > MAX_CWD_LEN) {
        return err_resp(format!("`cwd` is too long (limit {MAX_CWD_LEN} bytes)"));
    }
    if let Some(c) = cwd {
        if !std::path::Path::new(c).is_dir() {
            return err_resp(format!("`cwd` is not a folder: {c}"));
        }
    }
    let existing = match blocking(|| host.terminal_list()) {
        Ok(v) => v,
        Err(e) => return err_resp(e),
    };
    let name = match req.name.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
        Some(n) if n.len() > MAX_NAME_LEN => {
            return err_resp(format!("`name` is too long (limit {MAX_NAME_LEN} bytes)"))
        }
        Some(n) if existing.iter().any(|t| t.name.eq_ignore_ascii_case(n)) => {
            return err_resp(format!(
                "a terminal named '{n}' already exists — pick another name"
            ))
        }
        Some(n) => n.to_string(),
        None => (1..)
            .map(|i| format!("terminal-{i}"))
            .find(|c| !existing.iter().any(|t| t.name.eq_ignore_ascii_case(c)))
            .unwrap_or_default(),
    };
    match blocking(|| host.terminal_open(&name, cwd, command.as_deref())) {
        Ok(id) => {
            if let Ok(mut m) = TERMINAL_OWNERS.lock() {
                m.insert(id, caller_key(req));
            }
            eprintln!(
                "[broker] open_terminal id={id} name={name} command_bytes={}",
                command.as_deref().map_or(0, str::len)
            );
            json!({ "ok": true, "id": id, "name": name }).to_string()
        }
        Err(e) => err_resp(e),
    }
}

/// `send_terminal`: raw text (+ Enter) into ONE terminal, shell or agent. Not a chat message.
fn handle_send_terminal<H: BrokerHost>(host: &H, req: &BrokerReq) -> String {
    let target = match req.target.as_deref() {
        Some(t) if !t.trim().is_empty() => t.to_string(),
        _ => return err_resp("`send_terminal` requires a `target` (terminal name or id)"),
    };
    let text = match check_terminal_text(
        "send_terminal",
        req.command.as_deref().or(req.text.as_deref()),
    ) {
        Ok(t) => t,
        Err(e) => return err_resp(e),
    };
    let enter = req.enter.unwrap_or(true);
    let terms = match blocking(|| host.terminal_list()) {
        Ok(v) => v,
        Err(e) => return err_resp(e),
    };
    let t = match resolve_terminal(&target, &terms) {
        TargetMatch::None => return err_resp(format!("no terminal matches '{target}'")),
        TargetMatch::Many(idxs) => {
            return err_resp(format!(
                "'{target}' matches {} terminals ({}) — pass the exact name or id",
                idxs.len(),
                idxs.iter()
                    .map(|i| terms[*i].name.clone())
                    .collect::<Vec<_>>()
                    .join(", ")
            ))
        }
        TargetMatch::One(i) => &terms[i],
    };
    if let (Some(w), false) = (&t.waiting_for, req.include_waiting.unwrap_or(false)) {
        return err_resp(format!(
            "'{}' is waiting on a {w} — Enter would answer it. Use send_to_session(deliver:\"keys\") to answer it on purpose, or pass include_waiting",
            t.name
        ));
    }
    // M8: an unverified caller only types into terminals it opened itself.
    if is_unverified(req) && !owns_terminal(t, &caller_key(req)) {
        return err_resp(
            "this caller could not be tied to a Claude session, so it may only type into terminals it opened itself (open_terminal / open_session)",
        );
    }
    // The operator's secrets are typed only at a password prompt: hand the gate the terminal's state.
    let prompt = if crate::secret_refs::names_in(&text).is_empty() {
        None
    } else {
        prompt_state_of(host, t.id)
    };
    let text = match substitute_for(host, &text, !is_unverified(req), prompt.as_ref(), None) {
        Ok(t) => t,
        Err(e) => return err_resp(e),
    };
    match blocking(|| host.terminal_type(t.id, &text, enter, t.kind == "claude")) {
        Ok(()) => {
            eprintln!(
                "[broker] send_terminal id={} name={} bytes={} enter={enter}",
                t.id,
                t.name,
                text.len()
            );
            // Byte count only: the text may carry a substituted secret.
            crate::debuglog::log(&format!(
                "[terminal] send id={} bytes={} enter={enter}",
                t.id,
                text.len()
            ));
            audit_typed(
                host,
                req,
                "send_terminal",
                &t.id.to_string(),
                &t.name,
                text.len(),
            );
            json!({ "ok": true, "target": terminal_json(t), "bytes": text.len(), "enter": enter })
                .to_string()
        }
        Err(e) => err_resp(e),
    }
}

/// `broadcast`: the same text to every open terminal / session, one result per target.
/// `deliver:"keys"` (default) pastes `command`/`text` + Enter raw; `deliver:"muya"` sends a chat message to
/// the Claude sessions only (a shell would run the wrapper).
fn handle_broadcast<H: BrokerHost>(host: &H, req: &BrokerReq) -> String {
    let text =
        match check_terminal_text("broadcast", req.command.as_deref().or(req.text.as_deref())) {
            Ok(t) => t,
            Err(e) => return err_resp(e),
        };
    if is_unverified(req) {
        return err_resp(
            "broadcast reaches sessions this caller did not open; an unverified caller (not tied to a Claude session) may not use it",
        );
    }
    let kind = req
        .kind
        .as_deref()
        .map(str::trim)
        .filter(|k| !k.is_empty())
        .unwrap_or("all")
        .to_ascii_lowercase();
    if !matches!(kind.as_str(), "all" | "claude" | "shell") {
        return err_resp(format!(
            "unknown kind '{kind}' — expected \"all\", \"claude\" or \"shell\""
        ));
    }
    let deliver = req
        .deliver
        .as_deref()
        .map(str::trim)
        .filter(|d| !d.is_empty())
        .unwrap_or("keys")
        .to_string();
    if deliver != "keys" && deliver != "muya" {
        return err_resp(format!(
            "unknown deliver '{deliver}' — expected \"keys\" or \"muya\""
        ));
    }
    let kind = if deliver == "muya" && kind == "all" {
        "claude".to_string()
    } else {
        kind
    };
    if deliver == "muya" && kind == "shell" {
        return err_resp(
            "deliver:\"muya\" is a chat message for Claude sessions — it cannot go to shells",
        );
    }
    let text = if deliver == "keys" {
        match substitute_for(host, &text, !is_unverified(req), None, None) {
            Ok(t) => t,
            Err(e) => return err_resp(e),
        }
    } else {
        text
    };
    let enter = req.enter.unwrap_or(true);
    let me = req.caller.as_str();
    let terms = match blocking(|| host.terminal_list()) {
        Ok(v) => v,
        Err(e) => return err_resp(e),
    };
    let (hit, skipped) = plan_broadcast(&terms, &kind, me, req.include_waiting.unwrap_or(false));
    if hit.len() > MAX_BROADCAST_TARGETS {
        return err_resp(format!("{} terminals match — broadcast reaches at most {MAX_BROADCAST_TARGETS}; narrow it with `kind`", hit.len()));
    }
    let sender = caller_label(req);
    let mut results = Vec::new();
    for t in &hit {
        let r: Result<serde_json::Value, String> = if deliver == "muya" {
            match t.claude_session_id.as_deref() {
                Some(cid) => {
                    deliver_chat(host, cid, &text, &sender).map(|via| json!({ "via": via }))
                }
                None => Err("no Claude session id".into()),
            }
        } else {
            let r = blocking(|| host.terminal_type(t.id, &text, enter, t.kind == "claude"))
                .map(|()| json!({}));
            if r.is_ok() {
                audit_typed(
                    host,
                    req,
                    "broadcast",
                    &t.id.to_string(),
                    &t.name,
                    text.len(),
                );
            }
            r
        };
        let mut row = terminal_json(t);
        match r {
            Ok(extra) => {
                row["status"] = json!("sent");
                if let (Some(o), Some(e)) = (row.as_object_mut(), extra.as_object()) {
                    o.extend(e.clone());
                }
            }
            Err(e) => {
                row["status"] = json!("failed");
                row["error"] = json!(e);
            }
        }
        results.push(row);
    }
    for (t, why) in &skipped {
        let mut row = terminal_json(t);
        row["status"] = json!("skipped");
        row["reason"] = json!(why);
        results.push(row);
    }
    let sent = results.iter().filter(|r| r["status"] == "sent").count();
    eprintln!(
        "[broker] broadcast kind={kind} deliver={deliver} bytes={} sent={sent} skipped={}",
        text.len(),
        skipped.len()
    );
    crate::debuglog::log(&format!(
        "[terminal] broadcast kind={kind} deliver={deliver} sent={sent} bytes={}",
        text.len()
    ));
    json!({ "ok": true, "sent": sent, "skipped": skipped.len(), "results": results }).to_string()
}

/// `ssh_session_open` (PRD `ssh-session`, Faz 2): open a persistent, headless SSH session
/// (one PSMP connection = one OTP) the agent can then run many commands in. The password
/// is injected into the PTY Rust-side, never returned. Returns a `sessionId`.
async fn handle_session_open<H: BrokerHost>(
    host: &H,
    servers: &[Server],
    req: &BrokerReq,
) -> String {
    let alias = match req.alias.as_deref() {
        Some(a) if !a.trim().is_empty() => a,
        _ => return err_resp("`session_open` requires an `alias`"),
    };
    let server = match resolve_open(servers, alias) {
        OpenResolution::NotFound => return err_resp(format!("no server matches alias '{alias}'")),
        OpenResolution::NotAccessible => {
            return err_resp(format!(
                "server '{alias}' is not agent-accessible (enable 'Agent may use this server')"
            ))
        }
        OpenResolution::Ok(s) => s,
    };
    let secret = match resolve_injectable_secret(host, server, "ssh_session_open").await {
        Ok(s) => s,
        Err(e) => return err_resp(e),
    };
    let base = match crate::ssh::connect_command_for(server) {
        Ok(c) => c,
        Err(e) => return err_resp(e),
    };
    let program = base.program.clone();
    let args = base.args.clone();
    let is_psmp = server.connection_type == "psmp";
    let store = host.agent_ssh().clone();
    let result = tokio::task::spawn_blocking(move || {
        crate::agent_ssh::open(&store, &program, &args, secret, is_psmp)
    })
    .await;
    match result {
        Ok(Ok(session_id)) => {
            remember_session_cred(&session_id, server);
            json!({ "ok": true, "sessionId": session_id }).to_string()
        }
        Ok(Err(e)) => err_resp(e),
        Err(e) => err_resp(format!("session open task failed: {e}")),
    }
}

/// `ssh_session_exec`: run one command inside an open session and return its output +
/// exit code. Shell state (cd/env/sudo) is preserved between calls.
async fn handle_session_exec<H: BrokerHost>(host: &H, req: &BrokerReq) -> String {
    let session_id = match req.session_id.as_deref() {
        Some(s) if !s.trim().is_empty() => s.to_string(),
        _ => return err_resp("`session_exec` requires a `sessionId` (from ssh_session_open)"),
    };
    let command = match req.command.as_deref() {
        Some(c) if !c.trim().is_empty() => c.to_string(),
        _ => return err_resp("`session_exec` requires a non-empty `command`"),
    };
    let allowed = session_cred(&session_id);
    let command = match substitute_for(
        host,
        &command,
        !is_unverified(req),
        None,
        allowed.as_deref(),
    ) {
        Ok(c) => c,
        Err(e) => return err_resp(e),
    };
    let timeout = req.timeout_secs.map(std::time::Duration::from_secs);
    let store = host.agent_ssh().clone();
    let result = tokio::task::spawn_blocking(move || {
        crate::agent_ssh::exec(&store, &session_id, &command, timeout)
    })
    .await;
    match result {
        Ok(Ok(out)) => json!({
            "ok": true,
            "stdout": out.stdout,
            "exitCode": out.exit_code,
            "timedOut": out.timed_out,
        })
        .to_string(),
        Ok(Err(e)) => err_resp(e),
        Err(e) => err_resp(format!("session exec task failed: {e}")),
    }
}

/// `ssh_session_close`: end a persistent session (kills the ssh process).
async fn handle_session_close<H: BrokerHost>(host: &H, req: &BrokerReq) -> String {
    let session_id = match req.session_id.as_deref() {
        Some(s) if !s.trim().is_empty() => s,
        _ => return err_resp("`session_close` requires a `sessionId`"),
    };
    match crate::agent_ssh::close(host.agent_ssh(), session_id) {
        Ok(()) => json!({ "ok": true }).to_string(),
        Err(e) => err_resp(e),
    }
}

async fn handle_run<H: BrokerHost>(host: &H, servers: &[Server], req: &BrokerReq) -> String {
    let alias = match req.alias.as_deref() {
        Some(a) if !a.trim().is_empty() => a,
        _ => return err_resp("`run` requires an `alias`"),
    };
    // `commands: []` (batch) runs many commands over ONE connection and frames each
    // result — the efficient path (esp. PSMP, where multiplexing is disabled). A single
    // `command` keeps the original one-shot shape. `batch_nonce` = Some when batching.
    let batch_commands: Option<Vec<String>> = req
        .commands
        .as_ref()
        .filter(|c| !c.is_empty())
        .map(|c| c.iter().map(|s| s.to_string()).collect());
    let (command, batch_nonce) = if let Some(cmds) = &batch_commands {
        if cmds.iter().all(|c| c.trim().is_empty()) {
            return err_resp("`commands` must contain at least one non-empty command");
        }
        let nonce = format!(
            "{:x}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        );
        (build_batch_script(cmds, &nonce), Some(nonce))
    } else {
        match req.command.as_deref() {
            Some(c) if !c.trim().is_empty() => (c.to_string(), None),
            _ => {
                return err_resp(
                    "`run` requires a non-empty `command` (or a non-empty `commands` array)",
                )
            }
        }
    };

    // H2: the command becomes part of the local `ssh host <cmd>` argv, which any local process can read
    // with `ps`. A placeholder would have to be replaced by the real value there, so it is refused.
    if !crate::secret_refs::names_in(&command).is_empty() {
        return err_resp(
            "ssh_run cannot take a secret placeholder: the command line is visible to local `ps`. \
             Use ssh_session_exec (the password never reaches a command line) or answer the password prompt of an ssh_open tab.",
        );
    }

    let server = match resolve_open(servers, alias) {
        OpenResolution::NotFound => return err_resp(format!("no server matches alias '{alias}'")),
        OpenResolution::NotAccessible => {
            return err_resp(format!(
                "server '{alias}' is not agent-accessible (enable 'Agent may use this server')"
            ))
        }
        OpenResolution::Ok(s) => s,
    };

    // AC10 — bound concurrency: acquire a permit or fail fast (held for the run).
    let broker = host.broker();
    let _permit = match broker.run_slots.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => {
            return err_resp(format!(
            "too many concurrent ssh_run commands (limit {MAX_CONCURRENT_RUNS}); try again shortly"
        ))
        }
    };

    // Resolve the injectable secret entirely in Rust. `prompt` sources have no
    // stored password to inject, so a non-interactive run cannot authenticate.
    let secret: Option<Zeroizing<String>> =
        match resolve_injectable_secret(host, server, "ssh_run").await {
            Ok(s) => s,
            Err(e) => return err_resp(e),
        };

    // Build the ssh argv (destination last), then append the remote command as ONE
    // argv element (AC9). No shell on the Muya side.
    let base = match crate::ssh::connect_command_for(server) {
        Ok(c) => c,
        Err(e) => return err_resp(e),
    };
    let program = base.program.clone();
    // Keep the base connect args (options + dest, no remote command) so we can query the
    // ControlMaster socket state with `ssh -O check` for the reuse diagnostics below.
    let connect_args = base.args.clone();
    let args = match assemble_run_args(base.args, &command) {
        Ok(a) => a,
        Err(e) => return err_resp(e),
    };

    // AC2/AC3 — the challenge-gate and push-timeout hint are PSMP-only; direct SSH
    // never sets `is_psmp`, so its behavior (incl. AC4's `passcode:` → inject) is
    // byte-for-byte the pre-hardening path.
    let is_psmp = server.connection_type == "psmp";

    // ControlMaster reuse diagnostics (L41/L42): log whether a master already exists
    // BEFORE this command, so a shared PSMP log shows the "created → reused → reused →
    // stale-fail" progression. `ssh -O check` is a LOCAL socket query — it never talks
    // to the remote/PSMP.
    // Use the SAME debug logger as the `ssh connect:` / `ssh_scp:` audit lines
    // (~/.claude/muya-debug.log, gated by the Settings debug toggle) so all SSH
    // diagnostics land in one file the operator is already watching.
    crate::debuglog::log(&format!(
        "[ssh-cm] run server={} host={} psmp={} master_before={}",
        server.id,
        server.host,
        is_psmp,
        master_state(&connect_args)
    ));

    // AC8 — run the blocking PTY capture off the async runtime.
    let started = std::time::Instant::now();
    let result = tokio::task::spawn_blocking(move || {
        crate::askpass::run_with_askpass(&program, &args, secret, RUN_TIMEOUT, is_psmp)
    })
    .await;
    let dur_ms = started.elapsed().as_millis();
    match &result {
        Ok(Ok(out)) => crate::debuglog::log(&format!(
            "[ssh-cm] done server={} exit={:?} dur={}ms timedOut={} injected={} stale={} master_after={} stderr_tail={:?}",
            server.id, out.exit_code, dur_ms, out.timed_out, out.injected,
            is_stale_master(&out.stderr), master_state(&connect_args), stderr_tail(&out.stderr)
        )),
        Ok(Err(e)) => crate::debuglog::log(&format!("[ssh-cm] run-err server={} dur={}ms err={}", server.id, dur_ms, e)),
        Err(e) => crate::debuglog::log(&format!("[ssh-cm] join-err server={} err={}", server.id, e)),
    }

    match result {
        // AC2 — a 2FA/OTP/passcode challenge was seen: the secret was withheld,
        // never written into the PTY. Report a fail-fast, actionable error instead
        // of the usual ok:true shape so an agent doesn't mistake this for success.
        Ok(Ok(out)) if out.challenge_detected => err_resp(
            "PSMP requested a 2FA/interactive challenge (passcode/OTP/verification code) — \
             non-interactive ssh_run does not support this; use ssh_open for an interactive \
             session instead.",
        ),
        Ok(Ok(out)) => {
            let mut resp = json!({
                "ok": true,
                "stdout": out.stdout,
                "stderr": out.stderr,
                "exitCode": out.exit_code,
                "timedOut": out.timed_out,
            });
            // Batch mode: split the framed stdout into one result per command (each with
            // its own exit code) so the agent gets N answers from this ONE connection.
            if let (Some(nonce), Some(cmds)) = (&batch_nonce, &batch_commands) {
                let parsed = parse_batch_output(&out.stdout, nonce);
                let results: Vec<serde_json::Value> = cmds
                    .iter()
                    .enumerate()
                    .map(|(i, c)| {
                        let (stdout, exit) = parsed
                            .get(i)
                            .cloned()
                            .unwrap_or_else(|| (String::new(), -1));
                        json!({ "command": c, "stdout": stdout, "exitCode": exit })
                    })
                    .collect();
                resp["results"] = json!(results);
            }
            // AC3 — timed out with NO prompt ever seen on a PSMP connection: most
            // likely a RADIUS push notification waiting for out-of-band approval,
            // which looks identical to a hung connection otherwise. Flag it so the
            // agent doesn't retry the same non-interactive call.
            if is_psmp && out.timed_out && !out.injected {
                resp["message"] = json!(
                    "Timed out with no password/2FA prompt seen — this may be a PSMP RADIUS \
                     push notification awaiting out-of-band approval. Try ssh_open for an \
                     interactive session instead of retrying ssh_run."
                );
            }
            resp.to_string()
        }
        Ok(Err(e)) => err_resp(e),
        Err(e) => err_resp(format!("run task failed: {e}")),
    }
}

/// Shared secret resolution for both `ssh_run` and `ssh_scp` — identical gating
/// (store-unlock, local vs cyberark, `prompt` has nothing to inject) so the two
/// tools present the exact same auth behavior. `tool_name` only flavors the
/// "needs a stored/CyberArk credential" error message.
async fn resolve_injectable_secret<H: BrokerHost>(
    host: &H,
    server: &Server,
    tool_name: &str,
) -> Result<Option<Zeroizing<String>>, String> {
    match server.credential_source.kind.as_str() {
        "local" => {
            if !host.vault_is_unlocked() {
                return Err(
                    "password store is locked — unlock it in the Password Store tab".into(),
                );
            }
            let id = server
                .credential_source
                .local_cred_id
                .as_deref()
                .ok_or("server uses the local store but no credential is selected")?;
            host.vault_secret_for(id).map(Some)
        }
        "cyberark" => {
            let acct = server
                .credential_source
                .cyberark_account_id
                .as_deref()
                .ok_or("server uses CyberArk but no account is selected")?;
            host.cyberark_password(acct).await.map(Some)
        }
        _ => Err(format!(
            "{tool_name} needs a stored or CyberArk credential; a 'prompt' server has no \
             password to inject non-interactively — switch it to a stored/CyberArk credential"
        )),
    }
}

/// AC1/AC2/AC3/AC4/AC5/AC6/AC7 — resolve an alias, gate it, guardrail-check the
/// LOCAL path against the operator's configured workspace roots, police the
/// agent's `extraArgs`, resolve the secret in Rust, build the scp argv (Muya owns
/// all `-o`/port/PSMP-dest assembly), and run it through the SAME PTY-injection +
/// 2FA-challenge-gate path as `ssh_run`. Returns `{ok,direction,localPath,
/// remotePath,exitCode,timedOut}` — never the secret, never a filesystem write/read
/// outside the resolved local path.
async fn handle_scp<H: BrokerHost>(host: &H, servers: &[Server], req: &BrokerReq) -> String {
    let alias = match req.alias.as_deref() {
        Some(a) if !a.trim().is_empty() => a,
        _ => return err_resp("`scp` requires an `alias`"),
    };
    // AC — explicit enum, never inferred from arg shape/order.
    let direction = match req.direction.as_deref() {
        Some("upload") => crate::ssh::ScpDirection::Upload,
        Some("download") => crate::ssh::ScpDirection::Download,
        Some(other) => {
            return err_resp(format!(
                "`direction` must be 'upload' or 'download', got '{other}'"
            ))
        }
        None => return err_resp("`scp` requires a `direction` ('upload' or 'download')"),
    };
    let local_path_raw = match req.local_path.as_deref() {
        Some(p) if !p.trim().is_empty() => p,
        _ => return err_resp("`scp` requires a non-empty `localPath`"),
    };
    let remote_path = match req.remote_path.as_deref() {
        Some(p) if !p.trim().is_empty() => p.to_string(),
        _ => return err_resp("`scp` requires a non-empty `remotePath`"),
    };
    let recursive = req.recursive.unwrap_or(false);
    let extra_args_raw = req.extra_args.clone().unwrap_or_default();

    let server = match resolve_open(servers, alias) {
        OpenResolution::NotFound => return err_resp(format!("no server matches alias '{alias}'")),
        OpenResolution::NotAccessible => {
            return err_resp(format!(
                "server '{alias}' is not agent-accessible (enable 'Agent may use this server')"
            ))
        }
        OpenResolution::Ok(s) => s,
    };

    // AC3 (CRITICAL — before anything else touches the filesystem or runs scp):
    // localPath must canonicalize to a child of a configured workspace root.
    let for_download = direction == crate::ssh::ScpDirection::Download;
    let roots = match crate::workspace_roots::load_workspace_roots() {
        Ok(r) => r,
        Err(e) => return err_resp(e),
    };
    let resolved_local =
        match crate::local_guard::resolve_local_scp_path(local_path_raw, &roots, for_download) {
            Ok(p) => p,
            Err(e) => return err_resp(e),
        };
    let resolved_local_str = resolved_local.to_string_lossy().into_owned();

    // AC4 — fail-closed extraArgs policy, before the args ever reach the builder.
    let extra_args = match enforce_scp_arg_policy(&extra_args_raw) {
        Ok(a) => a,
        Err(e) => return err_resp(e),
    };

    // AC10 reuse — same concurrency cap/pool as ssh_run.
    let broker = host.broker();
    let _permit = match broker.run_slots.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => {
            return err_resp(format!(
                "too many concurrent ssh_run/ssh_scp commands (limit {MAX_CONCURRENT_RUNS}); \
                 try again shortly"
            ))
        }
    };

    let secret: Option<Zeroizing<String>> =
        match resolve_injectable_secret(host, server, "ssh_scp").await {
            Ok(s) => s,
            Err(e) => return err_resp(e),
        };

    // AC5 — Muya assembles the scp argv (PSMP dest, -o's, -P) entirely server-side;
    // extraArgs were already policed above.
    let cmd = match crate::ssh::scp_command_for(
        server,
        direction,
        &resolved_local_str,
        &remote_path,
        recursive,
        &extra_args,
    ) {
        Ok(c) => c,
        Err(e) => return err_resp(e),
    };
    let program = cmd.program.clone();
    let args = cmd.args.clone();
    // Audit trail parity with ssh_pty_connect's connect log — no secret, just
    // metadata (whether a credential will be injected, never the value).
    crate::debuglog::log(&format!(
        "ssh_scp: alias={alias} type={} program={program} injection_armed={}",
        server.connection_type, cmd.needs_password_injection
    ));

    // AC6 — same PSMP 2FA/OTP challenge gate as ssh_run (is_psmp reuse).
    let is_psmp = server.connection_type == "psmp";

    let direction_str = match direction {
        crate::ssh::ScpDirection::Upload => "upload",
        crate::ssh::ScpDirection::Download => "download",
    };

    // AC7/AC8 — same bounded PTY capture + timeout as ssh_run; the secret is only
    // ever written into the PTY, never into argv/stdout/logs.
    let result = tokio::task::spawn_blocking(move || {
        crate::askpass::run_with_askpass(&program, &args, secret, RUN_TIMEOUT, is_psmp)
    })
    .await;

    match result {
        // AC6 — a 2FA/OTP/passcode challenge was seen: withheld, never injected.
        Ok(Ok(out)) if out.challenge_detected => err_resp(
            "PSMP requested a 2FA/interactive challenge (passcode/OTP/verification code) — \
             non-interactive ssh_scp does not support this; use ssh_open for an interactive \
             session instead.",
        ),
        Ok(Ok(out)) => {
            let mut resp = json!({
                "ok": true,
                "direction": direction_str,
                "localPath": resolved_local_str,
                "remotePath": remote_path,
                "stderr": out.stderr,
                "exitCode": out.exit_code,
                "timedOut": out.timed_out,
            });
            if is_psmp && out.timed_out && !out.injected {
                resp["message"] = json!(
                    "Timed out with no password/2FA prompt seen — this may be a PSMP RADIUS \
                     push notification awaiting out-of-band approval. Try ssh_open for an \
                     interactive session instead of retrying ssh_scp."
                );
            }
            resp.to_string()
        }
        Ok(Err(e)) => err_resp(e),
        Err(e) => err_resp(format!("scp task failed: {e}")),
    }
}

// ---------------------------------------------------------------------------
// Listener
// ---------------------------------------------------------------------------

/// Error returned when another running Muya instance already serves the broker.
pub const BROKER_OWNED_ELSEWHERE: &str =
    "another running Muya instance already serves the SSH broker — this instance leaves it (and the MCP registration) alone";

/// Does something accept connections on this Unix socket right now?
fn socket_is_live(path: &Path) -> bool {
    std::os::unix::net::UnixStream::connect(path).is_ok()
}

/// Bind the broker socket (0600), enforce the peer-uid check, and serve requests.
/// Idempotent: a second call while already listening is a no-op.
pub async fn enable_broker_listener<H: BrokerHost>(
    state: &BrokerState,
    host: H,
) -> Result<(), String> {
    let mut guard = state.listener.lock().await;
    if guard.is_some() {
        return Ok(());
    }
    let path = socket_path()?;
    if path.exists() {
        // Only a DEAD socket may be replaced. This used to unlink unconditionally, so a
        // second Muya (a dev/test build, a second copy) took over the socket of the one
        // already running: that instance's agents' MCP calls silently went to the new
        // one. A live socket means another instance owns the broker — leave it alone.
        if socket_is_live(&path) {
            return Err(BROKER_OWNED_ELSEWHERE.to_string());
        }
        fs::remove_file(&path).map_err(|e| format!("remove stale broker socket: {e}"))?;
    }
    let listener =
        UnixListener::bind(&path).map_err(|e| format!("bind broker UDS {path:?}: {e}"))?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("chmod broker socket: {e}"))?;

    let listener = Arc::new(listener);
    let accept_listener = listener.clone();
    let host = Arc::new(host);
    tokio::spawn(async move {
        let me = unsafe { libc::getuid() };
        loop {
            match accept_listener.accept().await {
                Ok((stream, _addr)) => {
                    // Peer authentication: reject any uid but our own.
                    match peer_uid(stream.as_raw_fd()) {
                        Some(uid) if uid == me => {}
                        #[allow(unused_variables)] // used only in debug builds
                        other => {
                            #[cfg(debug_assertions)]
                            eprintln!("[ssh-broker] rejected peer uid {other:?} (mine={me})");
                            drop(stream); // close without serving
                            continue;
                        }
                    }
                    let host2 = host.clone();
                    tokio::spawn(async move {
                        serve_connection(stream, host2).await;
                    });
                }
                #[allow(unused_variables)] // used only in debug builds
                Err(e) => {
                    #[cfg(debug_assertions)]
                    eprintln!("[ssh-broker] accept loop exiting: {e}");
                    break;
                }
            }
        }
    });

    *guard = Some((listener, path));
    Ok(())
}

/// `{"op":"subscribe","sessionId":"…"}` → the session id; anything else → None.
fn subscribe_request(line: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    if v.get("op")?.as_str()? != "subscribe" {
        return None;
    }
    let id = v.get("sessionId")?.as_str()?.trim();
    (!id.is_empty()).then(|| id.to_string())
}

/// Longest request line the broker reads (an `open_session` with a long prompt is a few KiB; 1 MiB is generous).
const MAX_REQUEST_LINE: usize = 1 << 20;

enum LineRead {
    Eof,
    Line(String),
    /// More than the cap arrived without a newline; the rest was not buffered.
    TooLong,
}

/// `read_line` with a cap: a peer that never sends a newline cannot grow the buffer past `cap`.
async fn read_line_capped<R: tokio::io::AsyncBufRead + Unpin>(
    r: &mut R,
    cap: usize,
) -> std::io::Result<LineRead> {
    let mut buf: Vec<u8> = Vec::new();
    loop {
        let chunk = r.fill_buf().await?;
        if chunk.is_empty() {
            return Ok(if buf.is_empty() {
                LineRead::Eof
            } else {
                LineRead::Line(String::from_utf8_lossy(&buf).into_owned())
            });
        }
        let (take, done) = match chunk.iter().position(|&b| b == b'\n') {
            Some(i) => (i + 1, true),
            None => (chunk.len(), false),
        };
        if buf.len() + take > cap + 1 {
            return Ok(LineRead::TooLong);
        }
        buf.extend_from_slice(&chunk[..take]);
        r.consume(take);
        if done {
            buf.pop(); // the newline
            if buf.last() == Some(&b'\r') {
                buf.pop();
            }
            return Ok(LineRead::Line(String::from_utf8_lossy(&buf).into_owned()));
        }
    }
}

/// Parent pid (macOS `proc_pidinfo`), `None` when unreadable.
fn parent_of(pid: i32) -> Option<i32> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let rc = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        )
    };
    (rc == size).then_some(info.pbi_ppid as i32)
}

/// `pid` and its ancestors (nearest first), via `parent`. Capped; stops at launchd or an unreadable link.
fn ancestors_via(pid: i32, parent: impl Fn(i32) -> Option<i32>) -> Vec<i32> {
    let mut out = vec![pid];
    let mut cur = pid;
    for _ in 0..64 {
        match parent(cur) {
            Some(p) if p > 1 && !out.contains(&p) => {
                out.push(p);
                cur = p;
            }
            _ => break,
        }
    }
    out
}

/// Whether a sidecar (process `pid`) may claim Claude session `session_id`: when the registry knows the
/// session's Claude process, the sidecar must run under it. An id the registry does not know yet
/// (a session that has not registered) cannot be checked and is accepted.
fn claim_matches(session_claude_pid: Option<i64>, ancestors: &[i32]) -> bool {
    match session_claude_pid.and_then(|p| i32::try_from(p).ok()) {
        Some(p) if p > 1 => ancestors.contains(&p),
        _ => true,
    }
}

async fn check_session_claim<H: BrokerHost>(session_id: &str, pid: i32) -> Result<(), String> {
    let sessions = match tokio::task::spawn_blocking(|| H::list_agent_sessions_fresh(None)).await {
        Ok(Ok(s)) => s,
        _ => return Ok(()), // no registry to check against (claude missing): same as unknown
    };
    let Some(found) = sessions.iter().find(|s| s.id == session_id) else {
        return Ok(());
    };
    if claim_matches(found.pid, &ancestors_via(pid, parent_of)) {
        Ok(())
    } else {
        Err(format!("session '{session_id}' belongs to another Claude process than the one this sidecar runs under"))
    }
}

async fn serve_connection<H: BrokerHost>(stream: tokio::net::UnixStream, host: Arc<H>) {
    // Fail closed: a peer whose pid cannot be read cannot be checked by any of the guards below.
    let Some(peer_pid) = stream.peer_cred().ok().and_then(|c| c.pid()).map(Some) else {
        let mut stream = stream;
        let _ = stream
            .write_all(format!("{}\n", err_resp("peer process could not be identified")).as_bytes())
            .await;
        return;
    };
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    loop {
        match read_line_capped(&mut reader, MAX_REQUEST_LINE).await {
            Ok(LineRead::Line(line)) => {
                if line.trim().is_empty() {
                    continue;
                }
                // A sidecar's long-lived channel subscription takes over the connection.
                if let Some(session_id) = subscribe_request(&line) {
                    // M8: the session id is the caller's identity later on, so it must be the Claude
                    // process this sidecar actually runs under, not an id another process made up.
                    if let Err(e) =
                        check_session_claim::<H>(&session_id, peer_pid.unwrap_or(0)).await
                    {
                        let _ = write_half
                            .write_all(format!("{}\n", err_resp(e)).as_bytes())
                            .await;
                        return;
                    }
                    serve_subscription(session_id, peer_pid.unwrap_or(0), reader, write_half).await;
                    return;
                }
                let mut resp = handle_request_from(&*host, &line, peer_pid).await;
                resp.push('\n');
                if write_half.write_all(resp.as_bytes()).await.is_err() {
                    break;
                }
            }
            Ok(LineRead::TooLong) => {
                let _ = write_half
                    .write_all(
                        format!("{}\n", err_resp("request too large (limit 1 MiB per line)"))
                            .as_bytes(),
                    )
                    .await;
                break;
            }
            _ => break, // EOF or read error
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // ---- channel delivery (PRD bridge-channel-delivery) ------------------

    #[test]
    fn subscribe_request_needs_op_and_session() {
        assert_eq!(
            subscribe_request(r#"{"op":"subscribe","sessionId":"abc"}"#).as_deref(),
            Some("abc")
        );
        assert_eq!(
            subscribe_request(r#"{"op":"subscribe","sessionId":"  "}"#),
            None
        );
        assert_eq!(subscribe_request(r#"{"op":"list_servers"}"#), None);
        assert_eq!(subscribe_request("not json"), None);
    }

    #[test]
    fn push_channel_reaches_a_live_subscriber_and_reports_a_missing_one() {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        CHANNELS.lock().unwrap().insert("sess-live".into(), tx);
        let ev = session_channel_event("api", "done");
        assert!(push_channel("sess-live", &ev));
        assert_eq!(rx.try_recv().unwrap(), ev.to_string());
        drop(rx); // the sidecar went away
        assert!(
            !push_channel("sess-live", &ev),
            "a closed subscriber must fall back"
        );
        assert!(!CHANNELS.lock().unwrap().contains_key("sess-live"));
        assert!(!push_channel("sess-none", &ev));
    }

    #[test]
    fn channel_meta_keys_survive_claude_code() {
        // Claude Code silently drops meta keys with anything but letters/digits/_.
        let ev = session_channel_event("api", "hi");
        for k in ev["meta"].as_object().unwrap().keys() {
            assert!(
                k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'),
                "{k}"
            );
        }
        assert_eq!(ev["meta"]["kind"], "session");
        assert!(session_channel_event("", "hi")["meta"]
            .get("from")
            .is_none());
    }
    use crate::ssh::{CredentialSource, Server};

    fn srv(id: &str, label: &str, agent: bool, kind: &str) -> Server {
        Server {
            id: id.into(),
            label: label.into(),
            host: "h".into(),
            port: 22,
            username: "u".into(),
            connection_type: "direct".into(),
            psmp_profile_id: None,
            credential_source: CredentialSource {
                kind: kind.into(),
                ..Default::default()
            },
            agent_access: agent,
            ssh_options: None,
            last_connected_at: None,
            tags: vec![],
            group: String::new(),
            agent_added: false,
        }
    }

    fn sess() -> Vec<(String, String)> {
        vec![
            ("abc123".into(), "password güçlendirme".into()),
            ("def456".into(), "frontend refactor".into()),
            ("ghi789".into(), "password rotation".into()),
        ]
    }

    // A second Muya must not steal the running one's broker socket: a live socket is
    // detected, a dead leftover is not.
    #[test]
    fn live_and_dead_broker_sockets_are_told_apart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("b.sock");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        assert!(socket_is_live(&path));
        drop(listener); // the socket FILE stays, nobody accepts any more
        assert!(path.exists());
        // A process another test spawned at the same moment can hold a copy of the listener
        // (macOS sets FD_CLOEXEC only after socket() returns) until it exits; wait for that.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while socket_is_live(&path) {
            assert!(
                std::time::Instant::now() < deadline,
                "a closed listener still accepts"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    #[test]
    fn open_session_payload_requires_nonempty_name() {
        let req = BrokerReq {
            op: "open_session".into(),
            ..Default::default()
        };
        assert!(build_open_session_payload(&req).is_err());
        let blank = BrokerReq {
            op: "open_session".into(),
            name: Some("   ".into()),
            ..Default::default()
        };
        assert!(build_open_session_payload(&blank).is_err());
    }

    #[test]
    fn open_session_payload_trims_name_and_carries_optional_fields() {
        let req = BrokerReq {
            op: "open_session".into(),
            name: Some("  worker  ".into()),
            cwd: Some("/tmp/x".into()),
            initial_message: Some("start on the migration".into()),
            ..Default::default()
        };
        let (name, payload) = build_open_session_payload(&req).unwrap();
        assert_eq!(name, "worker");
        assert_eq!(payload["name"], "worker");
        assert_eq!(payload["cwd"], "/tmp/x");
        assert_eq!(payload["initialMessage"], "start on the migration");
    }

    #[test]
    fn open_session_payload_omits_optional_fields_when_absent() {
        let req = BrokerReq {
            op: "open_session".into(),
            name: Some("worker".into()),
            ..Default::default()
        };
        let (_, payload) = build_open_session_payload(&req).unwrap();
        assert!(payload["cwd"].is_null());
        assert!(payload["initialMessage"].is_null());
        assert!(payload["splitWith"].is_null());
    }

    #[test]
    fn open_session_payload_carries_split_anchor_and_drops_a_blank_one() {
        let req = BrokerReq {
            op: "open_session".into(),
            name: Some("worker".into()),
            split_with: Some(" abc-123 ".into()),
            ..Default::default()
        };
        let (_, payload) = build_open_session_payload(&req).unwrap();
        assert_eq!(payload["splitWith"], "abc-123");
        let blank = BrokerReq {
            split_with: Some("  ".into()),
            ..req
        };
        assert!(build_open_session_payload(&blank).unwrap().1["splitWith"].is_null());
    }

    #[test]
    fn open_session_rejects_oversize_fields() {
        let ok = BrokerReq {
            op: "open_session".into(),
            name: Some("w".into()),
            ..Default::default()
        };
        assert!(build_open_session_payload(&ok).is_ok());
        let long_msg = BrokerReq {
            initial_message: Some("x".repeat(MAX_INITIAL_MESSAGE + 1)),
            ..ok.clone()
        };
        assert!(build_open_session_payload(&long_msg)
            .unwrap_err()
            .contains("initial_message"));
        let at_limit = BrokerReq {
            initial_message: Some("x".repeat(MAX_INITIAL_MESSAGE)),
            ..ok.clone()
        };
        assert!(build_open_session_payload(&at_limit).is_ok());
        let long_name = BrokerReq {
            name: Some("n".repeat(MAX_NAME_LEN + 1)),
            ..ok.clone()
        };
        assert!(build_open_session_payload(&long_name)
            .unwrap_err()
            .contains("name"));
        let long_cwd = BrokerReq {
            cwd: Some("/".repeat(MAX_CWD_LEN + 1)),
            ..ok.clone()
        };
        assert!(build_open_session_payload(&long_cwd)
            .unwrap_err()
            .contains("cwd"));
    }

    #[tokio::test]
    async fn request_lines_are_capped_without_buffering_the_rest() {
        // A line over the cap is refused; the reader never held more than the cap (it stops at the first chunk past it).
        let big = vec![b'a'; 4096];
        let mut r = BufReader::with_capacity(512, &big[..]);
        assert!(matches!(
            read_line_capped(&mut r, 1024).await.unwrap(),
            LineRead::TooLong
        ));
        // Lines at or under the cap come through, CRLF and last-line-without-newline included.
        let mut r = BufReader::new(&b"{\"op\":1}\r\nsecond\n\ntail"[..]);
        assert!(
            matches!(read_line_capped(&mut r, 64).await.unwrap(), LineRead::Line(l) if l == "{\"op\":1}")
        );
        assert!(
            matches!(read_line_capped(&mut r, 64).await.unwrap(), LineRead::Line(l) if l == "second")
        );
        assert!(
            matches!(read_line_capped(&mut r, 64).await.unwrap(), LineRead::Line(l) if l.is_empty())
        );
        assert!(
            matches!(read_line_capped(&mut r, 64).await.unwrap(), LineRead::Line(l) if l == "tail")
        );
        assert!(matches!(
            read_line_capped(&mut r, 64).await.unwrap(),
            LineRead::Eof
        ));
        let exact = [vec![b'b'; 100], vec![b'\n']].concat();
        let mut r = BufReader::new(&exact[..]);
        assert!(
            matches!(read_line_capped(&mut r, 100).await.unwrap(), LineRead::Line(l) if l.len() == 100)
        );
    }

    #[test]
    fn open_session_payload_is_unattended_by_default_and_names_the_opener() {
        let req = BrokerReq {
            op: "open_session".into(),
            name: Some("worker".into()),
            opened_by: Some(" abc-123 ".into()),
            ..Default::default()
        };
        let (_, payload) = build_open_session_payload(&req).unwrap();
        assert_eq!(payload["openedBy"], "abc-123");
        assert_eq!(payload["unattended"], true);
        let attended = BrokerReq {
            unattended: Some(false),
            opened_by: Some(" ".into()),
            ..req
        };
        let (_, payload) = build_open_session_payload(&attended).unwrap();
        assert_eq!(payload["unattended"], false);
        assert!(payload["openedBy"].is_null());
    }

    #[test]
    fn resolve_target_prefers_exact_id_then_name_then_substring() {
        // exact id
        assert_eq!(resolve_target("def456", &sess()), TargetMatch::One(1));
        // exact name (case-insensitive)
        assert_eq!(
            resolve_target("Frontend Refactor", &sess()),
            TargetMatch::One(1)
        );
        // unique substring
        assert_eq!(resolve_target("refactor", &sess()), TargetMatch::One(1));
        assert_eq!(resolve_target("rotation", &sess()), TargetMatch::One(2));
    }

    #[test]
    fn resolve_target_ambiguous_returns_candidates_never_guesses() {
        // "password" hits two sessions → the agent must ask the operator.
        assert_eq!(
            resolve_target("password", &sess()),
            TargetMatch::Many(vec![0, 2])
        );
        // …but the fuller name disambiguates.
        assert_eq!(resolve_target("güçlendirme", &sess()), TargetMatch::One(0));
    }

    #[test]
    fn resolve_target_none_for_unknown_or_empty() {
        assert_eq!(resolve_target("nope", &sess()), TargetMatch::None);
        assert_eq!(resolve_target("  ", &sess()), TargetMatch::None);
    }

    #[test]
    fn batch_script_frames_each_command_with_exit_marker() {
        let script = build_batch_script(&["echo a".into(), "false".into()], "abc123");
        assert!(script.contains("echo a\n"));
        assert!(script.contains("__MUYA_abc123_END:0:%d__"));
        assert!(script.contains("false\n"));
        assert!(script.contains("__MUYA_abc123_END:1:%d__"));
    }

    #[test]
    fn parse_batch_output_splits_per_command_with_rc() {
        // Simulate what the remote emitted for the script above.
        let out = "a\n__MUYA_abc123_END:0:0__\n__MUYA_abc123_END:1:1__";
        let parsed = parse_batch_output(out, "abc123");
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0], ("a".to_string(), 0));
        assert_eq!(parsed[1], (String::new(), 1)); // `false` → no output, rc 1
    }

    #[test]
    fn parse_batch_ignores_forged_marker_with_wrong_nonce() {
        // Command output that tries to look like a marker but has the wrong nonce is
        // treated as plain output, not a frame boundary.
        let out = "__MUYA_WRONG_END:0:0__\nreal\n__MUYA_right_END:0:0__";
        let parsed = parse_batch_output(out, "right");
        assert_eq!(parsed.len(), 1);
        assert!(parsed[0].0.contains("real"));
        assert!(parsed[0].0.contains("__MUYA_WRONG_END")); // forged line kept as output
    }

    #[test]
    fn stale_master_signature_matches_psmp_errors() {
        assert!(is_stale_master(
            "PSM SSH Proxy exception occurred. 479E ... Invalid session state. (Codes: -1, -3)"
        ));
        assert!(is_stale_master(
            "Failed to receive an allowed pid message. Error code [2]."
        ));
        assert!(is_stale_master("Shared connection to 10.0.0.67 closed."));
        assert!(!is_stale_master("bash: command not found"));
        assert!(!is_stale_master(""));
    }

    #[test]
    fn stderr_tail_flattens_and_caps() {
        assert_eq!(stderr_tail("  a\nb  "), "a b");
        let long: String = "x".repeat(300);
        assert_eq!(stderr_tail(&long).chars().count(), 200);
    }

    // ssh_send gate: a session is writable only after ssh_open registers it, and not
    // after it's released (tab closed).
    #[test]
    fn ssh_session_registration_gates_send() {
        let id = "ssh:test-server:12345";
        assert!(!ssh_session_is_open(id), "unknown id must not be writable");
        register_ssh_session(id);
        assert!(ssh_session_is_open(id), "registered id is writable");
        release_ssh_session(id);
        assert!(
            !ssh_session_is_open(id),
            "released id is no longer writable"
        );
    }

    #[test]
    #[test]
    fn open_session_defaults_to_claude_and_rejects_an_unknown_agent() {
        // Absent ⇒ claude: every caller written before opencode existed must keep
        // its exact behavior.
        assert_eq!(normalize_agent(None).unwrap(), "claude");
        assert_eq!(normalize_agent(Some("")).unwrap(), "claude");
        assert_eq!(normalize_agent(Some("  ")).unwrap(), "claude");
        assert_eq!(normalize_agent(Some("OpenCode")).unwrap(), "opencode");
        assert_eq!(normalize_agent(Some(" claude ")).unwrap(), "claude");

        // An unknown agent must NOT silently become Claude: an agent that asked for
        // opencode and quietly got Claude would address the wrong session next and
        // have no way to notice.
        let err = normalize_agent(Some("gpt")).unwrap_err();
        assert!(err.contains("gpt"), "{err}");
        assert!(
            err.contains("opencode"),
            "error must name the valid options: {err}"
        );
    }

    #[test]
    fn open_session_payload_carries_the_agent_to_the_frontend() {
        let mut req = BrokerReq {
            name: Some("migration".into()),
            agent: Some("opencode".into()),
            ..Default::default()
        };
        let (name, payload) = build_open_session_payload(&req).unwrap();
        assert_eq!(name, "migration");
        assert_eq!(payload["agent"], "opencode");

        // Default path unchanged.
        req.agent = None;
        let (_, payload) = build_open_session_payload(&req).unwrap();
        assert_eq!(payload["agent"], "claude");
    }

    #[test]
    fn agent_session_registration_gates_close() {
        let name = "muya-close-session-test-registration";
        assert!(
            !agent_session_owned_by(name, "opener-a"),
            "unregistered name must not be closable"
        );
        register_agent_session(name, "opener-a");
        assert!(
            agent_session_owned_by(name, "opener-a"),
            "the opener may close it"
        );
        assert!(
            !agent_session_owned_by(name, "opener-b"),
            "another agent may not close it"
        );
        assert!(agent_session_name_taken(name));
        release_agent_session(name);
        assert!(
            !agent_session_owned_by(name, "opener-a"),
            "released name is no longer closable"
        );
        // Idempotent — releasing twice must not panic.
        release_agent_session(name);
    }

    #[test]
    fn channel_cannot_be_hijacked_by_another_live_process() {
        let (tx1, _rx1) = tokio::sync::mpsc::unbounded_channel::<String>();
        let (tx2, _rx2) = tokio::sync::mpsc::unbounded_channel::<String>();
        let me = std::process::id() as i32;
        let id = "sess-h1-test";
        assert!(try_register_channel(id, me, &tx1));
        // Same process may re-register.
        assert!(try_register_channel(id, me, &tx1));
        // Another live process (pid 1 = launchd, alive) may not take over.
        assert!(!try_register_channel(id, 1, &tx2));
        assert_eq!(verified_caller(Some(me)), id);
        CHANNELS.lock().unwrap().remove(id);
        CHANNEL_OWNERS.lock().unwrap().remove(id);
        PEER_SESSIONS.lock().unwrap().remove(&me);
    }

    // AC4 — only opted-in servers are visible; two servers, one opt-in → 1.
    #[test]
    fn ac4_list_returns_only_opted_in() {
        let servers = vec![
            srv("1", "prod", true, "prompt"),
            srv("2", "secret-box", false, "prompt"),
        ];
        let metas = agent_visible(&servers);
        assert_eq!(metas.len(), 1);
        assert_eq!(metas[0].alias, "prod");
        assert_eq!(metas[0].host, "h");
    }

    // Alias falls back to id when the label is blank.
    #[test]
    fn alias_falls_back_to_id() {
        let servers = vec![srv("abc123", "", true, "prompt")];
        assert_eq!(agent_visible(&servers)[0].alias, "abc123");
    }

    // AC5 — resolution distinguishes accessible / not-opted-in / missing.
    #[test]
    fn ac5_resolve_open_paths() {
        let servers = vec![
            srv("1", "prod", true, "prompt"),
            srv("2", "locked", false, "prompt"),
        ];
        assert!(matches!(
            resolve_open(&servers, "prod"),
            OpenResolution::Ok(_)
        ));
        assert!(matches!(
            resolve_open(&servers, "locked"),
            OpenResolution::NotAccessible
        ));
        assert!(matches!(
            resolve_open(&servers, "ghost"),
            OpenResolution::NotFound
        ));
    }

    // AC7 — the serialized metadata carries no secret/credential fields.
    #[test]
    fn ac7_meta_has_no_secret() {
        let servers = vec![srv("1", "prod", true, "local")];
        let metas = agent_visible(&servers);
        let json = serde_json::to_string(&metas).unwrap();
        for banned in [
            "password",
            "secret",
            "token",
            "credentialSource",
            "localCredId",
        ] {
            assert!(
                !json.contains(banned),
                "broker metadata leaked `{banned}`: {json}"
            );
        }
    }

    // AC9 — the remote command is passed as EXACTLY ONE argv element, even when it
    // contains shell metacharacters, and `-o LogLevel=ERROR` is forced before the
    // destination. Nothing on the Muya side splits or interprets the command.
    #[test]
    fn ac9_remote_command_is_single_argv_element() {
        // base ssh args as build_connect_command would produce: [-p, 2222, u@h]
        let base = vec!["-p".into(), "2222".into(), "u@h".into()];
        let args = assemble_run_args(base, "echo hi; whoami && id").unwrap();
        // Destination stays put; options inserted before it; command is the LAST,
        // single element carrying the entire remote command verbatim.
        assert_eq!(
            args,
            vec![
                "-p",
                "2222",
                "-o",
                "LogLevel=ERROR",
                "--",
                "u@h",
                "echo hi; whoami && id",
            ]
        );
        // The real base from build_connect_command ends `-- u@h`: options still go
        // before the `--`, never after it (they'd become the destination/command).
        let real = vec!["-p".into(), "2222".into(), "--".into(), "u@h".into()];
        assert_eq!(
            assemble_run_args(real, "id").unwrap(),
            vec!["-p", "2222", "-o", "LogLevel=ERROR", "--", "u@h", "id"]
        );
        // The metacharacters live in ONE element — never split into extra argv.
        assert_eq!(args.last().unwrap(), "echo hi; whoami && id");
        assert_eq!(args.iter().filter(|a| a.contains("whoami")).count(), 1);
    }

    // AC9 — an empty base (no destination) is a clear error, not a panic.
    #[test]
    fn assemble_run_args_rejects_empty_base() {
        assert!(assemble_run_args(vec![], "echo hi").is_err());
    }

    // AC10 — the concurrency limiter admits exactly N and fails the (N+1)th fast.
    #[test]
    fn ac10_run_slots_cap_is_enforced() {
        let sem = std::sync::Arc::new(Semaphore::new(MAX_CONCURRENT_RUNS));
        let mut held = Vec::new();
        for _ in 0..MAX_CONCURRENT_RUNS {
            held.push(
                sem.clone()
                    .try_acquire_owned()
                    .expect("permit within the cap must succeed"),
            );
        }
        // One over the cap → immediate error, no blocking/hang.
        assert!(
            sem.clone().try_acquire_owned().is_err(),
            "the (N+1)th ssh_run must be rejected"
        );
        // Releasing one permit frees a slot again.
        held.pop();
        assert!(
            sem.clone().try_acquire_owned().is_ok(),
            "a freed slot must be reusable"
        );
    }

    // AC3 — a bound socket is 0600 and a same-process peer passes the uid check.
    #[test]
    fn ac3_socket_0600_and_peer_uid_self() {
        use std::io::{Read, Write};
        use std::os::unix::net::{UnixListener as StdListener, UnixStream as StdStream};

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("broker.sock");
        let listener = StdListener::bind(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();

        // AC3a: socket file is owner-only 0600.
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "broker socket must be 0600, got {mode:o}");

        // AC3b: connect from the same process → getpeereid == our own uid.
        let handle = std::thread::spawn(move || {
            let (mut conn, _) = listener.accept().unwrap();
            let uid = peer_uid(conn.as_raw_fd());
            let mut buf = [0u8; 4];
            let _ = conn.read(&mut buf);
            uid
        });
        let mut client = StdStream::connect(&path).unwrap();
        client.write_all(b"ping").unwrap();
        let peer = handle.join().unwrap();
        assert_eq!(
            peer,
            Some(unsafe { libc::getuid() }),
            "same-process peer uid must equal our uid"
        );
    }

    // ---- enforce_scp_arg_policy (PRD ssh-scp, AC4) ------------------------

    fn a(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|s| s.to_string()).collect()
    }

    // Allowed scp flags pass through unchanged.
    #[test]
    fn ac4_allowed_scp_flags_pass() {
        let out = enforce_scp_arg_policy(&a(&["-r", "-p", "-C"])).unwrap();
        assert_eq!(out, a(&["-r", "-p", "-C"]));
        // `-l` bare and with an attached numeric limit both pass.
        assert!(enforce_scp_arg_policy(&a(&["-l"])).is_ok());
        assert!(enforce_scp_arg_policy(&a(&["-l800"])).is_ok());
    }

    // Hard-denied flags (argv-injection/RCE surface) are rejected even alone.
    #[test]
    fn ac4_denied_scp_flags_rejected() {
        for flag in ["-o", "-F", "-i", "-S", "-P"] {
            assert!(
                enforce_scp_arg_policy(&a(&[flag])).is_err(),
                "{flag} must be rejected"
            );
        }
        // A denied flag with an attached/following value is still rejected at the
        // flag itself (fail fast, no partial trust of the value).
        assert!(enforce_scp_arg_policy(&a(&["-o", "ProxyCommand=touch /tmp/x"])).is_err());
        assert!(enforce_scp_arg_policy(&a(&["-i", "/etc/passwd"])).is_err());
    }

    // An unknown flag (not on the small allow-list) is rejected — fail-closed.
    #[test]
    fn ac4_unknown_flag_rejected() {
        assert!(enforce_scp_arg_policy(&a(&["-v"])).is_err());
        assert!(enforce_scp_arg_policy(&a(&["--recursive"])).is_err());
    }

    // A bare (non-flag) token is rejected — extraArgs is FLAGS ONLY; paths must go
    // through the typed localPath/remotePath fields, never smuggled in here.
    #[test]
    fn ac4_bare_positional_rejected() {
        assert!(enforce_scp_arg_policy(&a(&["/etc/passwd"])).is_err());
        assert!(enforce_scp_arg_policy(&a(&["evil@host:/path"])).is_err());
    }

    // NUL bytes and bare dashes are rejected.
    #[test]
    fn ac4_nul_and_bare_dash_rejected() {
        assert!(enforce_scp_arg_policy(&["a\0b".to_string()]).is_err());
        assert!(enforce_scp_arg_policy(&a(&["-"])).is_err());
    }

    // ---- terminal tools (open_terminal / send_terminal / broadcast) ------------

    use std::sync::Mutex as M;

    /// A host with a fixed set of terminals that records what it was asked to type / open.
    struct TermHost {
        broker: BrokerState,
        ssh: crate::agent_ssh::AgentSshStore,
        terms: Vec<TerminalInfo>,
        typed: M<Vec<(u64, String, bool, bool)>>,
        opened: M<Vec<(String, Option<String>, Option<String>)>>,
        events: M<Vec<String>>,
        fail_id: Option<u64>,
        /// `Some`: a host that owns the terminals (muyad) — open_session / send_to_session confirm.
        track: Option<Tracking>,
        /// Terminals that appear once the app got the open event (empty: the app never opens a tab).
        on_emit: M<Vec<TerminalInfo>>,
        appeared: M<Vec<TerminalInfo>>,
        /// Typing into the terminal makes the transcript grow (false: the text is swallowed).
        submits: bool,
        /// A bare Enter (terminal_raw "\r") submits what sits in the input line.
        enter_submits: bool,
        /// (label, description, value) of the fake vault; empty = locked.
        vault: Vec<(String, String, String)>,
        /// The visible screen of every terminal, and its echo flag (None = unknown).
        lines: Option<Vec<String>>,
        echo: Option<bool>,
        /// cwd of the terminal an Enter submits for.
        enter_cwd: String,
        claimed: M<HashSet<String>>,
    }
    /// Sessions `list_agent_sessions_fresh` reports (tests use distinct ids).
    static FAKE_SESSIONS: LazyLock<M<Vec<AgentSession>>> = LazyLock::new(Default::default);
    fn fake_session(id: &str, name: &str, cwd: &str) -> AgentSession {
        AgentSession {
            id: id.into(),
            name: name.into(),
            branch: String::new(),
            worktree: cwd.into(),
            status: "idle".into(),
            active_task: String::new(),
            active_file: String::new(),
            tokens_used: 0,
            models_used: String::new(),
            quota_burn: 0.0,
            duration: String::new(),
            created_at: String::new(),
            attachable: false,
            attach_id: String::new(),
            pid: None,
            parent_id: None,
            waiting_for: None,
            agent: "claude".into(),
        }
    }
    /// cwd -> number of user turns the fake transcript holds (each test uses its own cwd).
    static TURNS: LazyLock<M<HashMap<String, usize>>> = LazyLock::new(Default::default);
    fn set_turns(cwd: &str, n: usize) {
        TURNS.lock().unwrap().insert(cwd.into(), n);
    }

    fn term(
        id: u64,
        name: &str,
        kind: &str,
        claude: Option<&str>,
        waiting: Option<&str>,
    ) -> TerminalInfo {
        TerminalInfo {
            id,
            name: name.into(),
            cwd: "/tmp".into(),
            kind: kind.into(),
            claude_session_id: claude.map(Into::into),
            waiting_for: waiting.map(Into::into),
        }
    }

    fn term_host(terms: Vec<TerminalInfo>) -> TermHost {
        TermHost {
            broker: BrokerState::default(),
            ssh: Default::default(),
            terms,
            typed: M::new(vec![]),
            opened: M::new(vec![]),
            events: M::new(vec![]),
            fail_id: None,
            track: None,
            on_emit: M::new(vec![]),
            appeared: M::new(vec![]),
            submits: true,
            enter_submits: false,
            vault: vec![],
            lines: None,
            echo: None,
            enter_cwd: String::new(),
            claimed: M::new(HashSet::new()),
        }
    }

    impl BrokerHost for TermHost {
        fn tracking(&self) -> Option<Tracking> {
            self.track
        }
        fn terminal_raw(&self, id: u64, text: &str) -> Result<(), String> {
            self.typed
                .lock()
                .unwrap()
                .push((id, text.into(), false, false));
            if self.enter_submits && text == "\r" {
                let n = TURNS
                    .lock()
                    .unwrap()
                    .get(&self.enter_cwd)
                    .copied()
                    .unwrap_or(0);
                set_turns(&self.enter_cwd, n + 1);
            }
            Ok(())
        }
        fn terminal_lines(&self, _: u64) -> Option<Vec<String>> {
            self.lines.clone()
        }
        fn terminal_echo(&self, _: u64) -> Option<bool> {
            self.echo
        }
        fn broker(&self) -> &BrokerState {
            &self.broker
        }
        fn agent_ssh(&self) -> &crate::agent_ssh::AgentSshStore {
            &self.ssh
        }
        fn emit(&self, event: &str, _: serde_json::Value) -> Result<(), String> {
            self.events.lock().unwrap().push(event.into());
            let added = self.on_emit.lock().unwrap().clone();
            self.appeared.lock().unwrap().extend(added);
            Ok(())
        }
        fn vault_is_unlocked(&self) -> bool {
            !self.vault.is_empty()
        }
        fn vault_list_meta(&self) -> Result<Vec<SecretMeta>, String> {
            if self.vault.is_empty() {
                return Err("locked".into());
            }
            Ok(self
                .vault
                .iter()
                .map(|(l, d, _)| SecretMeta {
                    label: l.clone(),
                    description: d.clone(),
                    secret_kind: "password".into(),
                    group: String::new(),
                })
                .collect())
        }
        fn vault_add_credential(
            &self,
            _: String,
            _: String,
            _: String,
            _: String,
        ) -> Result<SecretMeta, String> {
            Err("locked".into())
        }
        fn vault_secret_for_ref(&self, r: &str) -> Result<Zeroizing<String>, String> {
            self.vault
                .iter()
                .find(|(l, _, _)| l == r)
                .map(|(_, _, v)| Zeroizing::new(v.clone()))
                .ok_or_else(|| "locked".to_string())
        }
        fn vault_secret_for(&self, _: &str) -> Result<Zeroizing<String>, String> {
            Err("locked".into())
        }
        fn vault_edit_credential(&self, _: &str, _: SecretEdit) -> Result<SecretMeta, String> {
            Err("locked".into())
        }
        async fn cyberark_password(&self, _: &str) -> Result<Zeroizing<String>, String> {
            Err("n/a".into())
        }
        async fn schedule_op(
            &self,
            _: String,
            _: Option<String>,
            _: Option<serde_json::Value>,
            _: Option<bool>,
            _: Option<usize>,
        ) -> Result<serde_json::Value, String> {
            Err("n/a".into())
        }
        async fn bridge_handle(
            &self,
            _: &str,
            _: &serde_json::Value,
            _: &str,
        ) -> serde_json::Value {
            json!({})
        }
        fn list_agent_sessions_fresh(_: Option<bool>) -> Result<Vec<AgentSession>, String> {
            Ok(FAKE_SESSIONS.lock().unwrap().clone())
        }
        fn claim_delivery(&self, key: &str) -> Result<bool, String> {
            Ok(self.claimed.lock().unwrap().insert(key.to_string()))
        }
        fn release_delivery(&self, key: &str) {
            self.claimed.lock().unwrap().remove(key);
        }
        fn read_transcript_tail(
            cwd: &str,
            _: &str,
            _: usize,
            _: Option<&str>,
        ) -> Result<String, String> {
            let n = TURNS.lock().unwrap().get(cwd).copied().unwrap_or(0);
            Ok("## \u{1F464} User\nx\n\n".repeat(n))
        }
        fn terminal_list(&self) -> Result<Vec<TerminalInfo>, String> {
            let mut v = self.terms.clone();
            v.extend(self.appeared.lock().unwrap().clone());
            Ok(v)
        }
        fn terminal_open(
            &self,
            name: &str,
            cwd: Option<&str>,
            command: Option<&str>,
        ) -> Result<u64, String> {
            self.opened.lock().unwrap().push((
                name.into(),
                cwd.map(Into::into),
                command.map(Into::into),
            ));
            Ok(99)
        }
        fn terminal_type(
            &self,
            id: u64,
            text: &str,
            enter: bool,
            agent: bool,
        ) -> Result<(), String> {
            if self.fail_id == Some(id) {
                return Err("session gone".into());
            }
            self.typed
                .lock()
                .unwrap()
                .push((id, text.into(), enter, agent));
            if self.submits {
                let cwd = self
                    .terms
                    .iter()
                    .chain(self.appeared.lock().unwrap().iter())
                    .find(|t| t.id == id)
                    .map(|t| t.cwd.clone())
                    .unwrap_or_default();
                let n = TURNS.lock().unwrap().get(&cwd).copied().unwrap_or(0);
                set_turns(&cwd, n + 1);
            }
            Ok(())
        }
    }

    fn call<H: BrokerHost>(host: &H, req: serde_json::Value) -> serde_json::Value {
        let mut req: BrokerReq = serde_json::from_value(req).unwrap();
        // Tests stand in for the verified-peer lookup: a body sessionId plays the subscribed sidecar.
        req.caller = req.session_id.clone().unwrap_or_default();
        let out = match req.op.as_str() {
            "open_terminal" => handle_open_terminal(host, &req),
            "send_terminal" => handle_send_terminal(host, &req),
            "broadcast" => handle_broadcast(host, &req),
            "run_with_secrets" => redact_resp(
                host,
                futures_lite_block(handle_run_with_secrets(host, &mut req)),
            ),
            "http_request" => redact_resp(
                host,
                futures_lite_block(handle_http_request(host, &mut req)),
            ),
            other => panic!("{other}"),
        };
        serde_json::from_str(&out).unwrap()
    }

    fn three() -> TermHost {
        term_host(vec![
            term(1, "build", "shell", None, None),
            term(2, "api work", "claude", Some("sess-api"), None),
            term(3, "me", "claude", Some("sess-me"), None),
            term(
                4,
                "prompted",
                "claude",
                Some("sess-p"),
                Some("permission prompt"),
            ),
        ])
    }

    #[test]
    fn terminal_target_resolution_id_claude_id_name_substring() {
        let h = three();
        for (t, want) in [
            ("1", 1),
            ("build", 1),
            ("sess-api", 2),
            ("API WORK", 2),
            ("prom", 4),
        ] {
            let r = call(
                &h,
                json!({"op":"send_terminal","target":t,"command":"x","includeWaiting":true}),
            );
            assert_eq!(r["ok"], true, "{t}: {r}");
            assert_eq!(r["target"]["id"], want, "{t}");
        }
        let r = call(
            &h,
            json!({"op":"send_terminal","target":"nope","command":"x"}),
        );
        assert_eq!(r["ok"], false);
        // "e" is a substring of several names: ambiguous, never a guess.
        let r = call(&h, json!({"op":"send_terminal","target":"e","command":"x"}));
        assert_eq!(r["ok"], false);
        assert!(r["error"].as_str().unwrap().contains("matches"), "{r}");
    }

    #[test]
    fn send_terminal_raw_text_enter_default_and_off_and_agent_flag() {
        let h = three();
        call(
            &h,
            json!({"op":"send_terminal","target":"build","command":"echo hi"}),
        );
        call(
            &h,
            json!({"op":"send_terminal","target":"build","command":"ls","enter":false}),
        );
        call(
            &h,
            json!({"op":"send_terminal","target":"api work","command":"/help"}),
        );
        let t = h.typed.lock().unwrap().clone();
        assert_eq!(t[0], (1, "echo hi".to_string(), true, false));
        assert_eq!(t[1], (1, "ls".to_string(), false, false));
        assert_eq!(t[2], (2, "/help".to_string(), true, true));
    }

    #[test]
    fn terminal_text_is_capped_and_validated() {
        let h = three();
        let big = "a".repeat(MAX_TERMINAL_TEXT + 1);
        assert_eq!(
            call(
                &h,
                json!({"op":"send_terminal","target":"build","command":big})
            )["ok"],
            false
        );
        assert_eq!(
            call(&h, json!({"op":"broadcast","command":big}))["ok"],
            false
        );
        assert_eq!(
            call(
                &h,
                json!({"op":"send_terminal","target":"build","command":"   "})
            )["ok"],
            false
        );
        assert_eq!(
            call(
                &h,
                json!({"op":"send_terminal","target":"build","command":"a\u{0}b"})
            )["ok"],
            false
        );
        let ok = "a".repeat(MAX_TERMINAL_TEXT);
        assert_eq!(
            call(
                &h,
                json!({"op":"send_terminal","target":"build","command":ok})
            )["ok"],
            true
        );
        assert!(
            h.typed.lock().unwrap().len() == 1,
            "only the in-limit text was typed"
        );
    }

    #[test]
    fn send_terminal_with_a_secret_placeholder_never_types_when_it_cannot_be_resolved() {
        let h = three();
        let r = call(
            &h,
            json!({"op":"send_terminal","target":"build","command":"echo {{muya-secret:prod-db}}"}),
        );
        assert_eq!(r["ok"], false, "{r}");
        assert!(
            h.typed.lock().unwrap().is_empty(),
            "nothing typed, placeholder not leaked as text"
        );
    }

    #[test]
    fn send_terminal_refuses_a_permission_prompt_unless_asked() {
        let h = three();
        let r = call(
            &h,
            json!({"op":"send_terminal","target":"prompted","command":"y"}),
        );
        assert_eq!(r["ok"], false);
        assert!(
            r["error"].as_str().unwrap().contains("permission prompt"),
            "{r}"
        );
        assert!(h.typed.lock().unwrap().is_empty());
        assert_eq!(
            call(
                &h,
                json!({"op":"send_terminal","target":"prompted","command":"y","includeWaiting":true})
            )["ok"],
            true
        );
    }

    #[test]
    fn broadcast_skips_self_and_waiting_and_reports_each_target() {
        let h = three();
        let r = call(
            &h,
            json!({"op":"broadcast","command":"echo B","sessionId":"sess-me"}),
        );
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["sent"], 2);
        assert_eq!(r["skipped"], 2);
        let typed = h.typed.lock().unwrap().clone();
        assert_eq!(typed.iter().map(|t| t.0).collect::<Vec<_>>(), vec![1, 2]);
        assert!(typed.iter().all(|t| t.1 == "echo B" && t.2));
        let rows = r["results"].as_array().unwrap();
        let by = |id: u64| rows.iter().find(|x| x["id"] == id).unwrap();
        assert_eq!(by(3)["status"], "skipped");
        assert_eq!(by(3)["reason"], "this is the calling session");
        assert_eq!(by(4)["status"], "skipped");
        assert!(by(4)["reason"]
            .as_str()
            .unwrap()
            .contains("permission prompt"));
        assert_eq!(by(1)["status"], "sent");
    }

    #[test]
    fn broadcast_include_waiting_and_kind_filter() {
        let h = three();
        let r = call(&h, json!({"op":"broadcast","command":"x","kind":"shell"}));
        assert_eq!(
            (r["sent"].as_u64(), r["skipped"].as_u64()),
            (Some(1), Some(0))
        );
        let r = call(
            &h,
            json!({"op":"broadcast","command":"x","kind":"claude","includeWaiting":true,"sessionId":"sess-me"}),
        );
        assert_eq!(
            (r["sent"].as_u64(), r["skipped"].as_u64()),
            (Some(2), Some(1))
        );
        assert_eq!(
            call(&h, json!({"op":"broadcast","command":"x","kind":"bogus"}))["ok"],
            false
        );
    }

    #[test]
    fn broadcast_one_failure_does_not_stop_the_rest() {
        let mut h = three();
        h.fail_id = Some(1);
        let r = call(&h, json!({"op":"broadcast","command":"x"}));
        assert_eq!(r["sent"], 2); // 2 and 3; 4 waits on a prompt, 1 fails
        let rows = r["results"].as_array().unwrap();
        assert_eq!(
            rows.iter().find(|x| x["id"] == 1).unwrap()["status"],
            "failed"
        );
        assert_eq!(
            rows.iter().find(|x| x["id"] == 2).unwrap()["status"],
            "sent"
        );
    }

    #[test]
    fn broadcast_muya_delivery_is_chat_for_claude_only() {
        let h = three();
        let r = call(
            &h,
            json!({"op":"broadcast","text":"hello all","deliver":"muya","sessionId":"sess-me"}),
        );
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["sent"], 1, "{r}"); // sess-api only: self and the prompted one are skipped, shells never get chat
        assert!(
            h.typed.lock().unwrap().is_empty(),
            "no raw typing in muya mode"
        );
        assert_eq!(
            h.events.lock().unwrap().as_slice(),
            ["muya://deliver-message"]
        );
        assert_eq!(
            call(
                &h,
                json!({"op":"broadcast","text":"x","deliver":"muya","kind":"shell"})
            )["ok"],
            false
        );
    }

    #[test]
    fn open_terminal_names_validates_and_passes_the_command() {
        let h = three();
        let r = call(
            &h,
            json!({"op":"open_terminal","name":"logs","cwd":"/tmp","command":"tail -f x"}),
        );
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(
            (r["id"].as_u64(), r["name"].as_str()),
            (Some(99), Some("logs"))
        );
        assert_eq!(
            h.opened.lock().unwrap()[0],
            (
                "logs".to_string(),
                Some("/tmp".to_string()),
                Some("tail -f x".to_string())
            )
        );
        let r = call(&h, json!({"op":"open_terminal"}));
        assert_eq!(r["name"], "terminal-1");
        assert_eq!(
            call(&h, json!({"op":"open_terminal","name":"BUILD"}))["ok"],
            false,
            "name taken (case-insensitive)"
        );
        assert_eq!(
            call(
                &h,
                json!({"op":"open_terminal","cwd":"/definitely/not/here"})
            )["ok"],
            false
        );
        assert_eq!(
            call(
                &h,
                json!({"op":"open_terminal","command":"a".repeat(MAX_TERMINAL_TEXT + 1)})
            )["ok"],
            false
        );
    }

    #[test]
    fn terminal_tools_say_native_only_on_a_host_without_ptys() {
        struct Bare(TermHost);
        impl BrokerHost for Bare {
            fn broker(&self) -> &BrokerState {
                self.0.broker()
            }
            fn agent_ssh(&self) -> &crate::agent_ssh::AgentSshStore {
                self.0.agent_ssh()
            }
            fn emit(&self, e: &str, p: serde_json::Value) -> Result<(), String> {
                self.0.emit(e, p)
            }
            fn vault_is_unlocked(&self) -> bool {
                false
            }
            fn vault_list_meta(&self) -> Result<Vec<SecretMeta>, String> {
                Err("l".into())
            }
            fn vault_add_credential(
                &self,
                _: String,
                _: String,
                _: String,
                _: String,
            ) -> Result<SecretMeta, String> {
                Err("l".into())
            }
            fn vault_secret_for_ref(&self, _: &str) -> Result<Zeroizing<String>, String> {
                Err("l".into())
            }
            fn vault_secret_for(&self, _: &str) -> Result<Zeroizing<String>, String> {
                Err("l".into())
            }
            fn vault_edit_credential(&self, _: &str, _: SecretEdit) -> Result<SecretMeta, String> {
                Err("l".into())
            }
            async fn cyberark_password(&self, _: &str) -> Result<Zeroizing<String>, String> {
                Err("n".into())
            }
            async fn schedule_op(
                &self,
                _: String,
                _: Option<String>,
                _: Option<serde_json::Value>,
                _: Option<bool>,
                _: Option<usize>,
            ) -> Result<serde_json::Value, String> {
                Err("n".into())
            }
            async fn bridge_handle(
                &self,
                _: &str,
                _: &serde_json::Value,
                _: &str,
            ) -> serde_json::Value {
                json!({})
            }
            fn list_agent_sessions_fresh(_: Option<bool>) -> Result<Vec<AgentSession>, String> {
                Ok(vec![])
            }
            fn read_transcript_tail(
                _: &str,
                _: &str,
                _: usize,
                _: Option<&str>,
            ) -> Result<String, String> {
                Ok(String::new())
            }
        }
        let h = Bare(three());
        for req in [
            json!({"op":"open_terminal"}),
            json!({"op":"send_terminal","target":"1","command":"x"}),
            json!({"op":"broadcast","command":"x"}),
        ] {
            let r = call(&h, req);
            assert_eq!(r["ok"], false);
            assert_eq!(r["error"], NATIVE_ONLY);
        }
    }

    // ---- tracked open_session / send_to_session (host owns the terminals) ------

    fn fast() -> Tracking {
        Tracking {
            open_wait: Duration::from_millis(600),
            submit_wait: Duration::from_millis(900),
            poll: Duration::from_millis(20),
        }
    }
    fn mkterm(id: u64, name: &str, cwd: &str, sid: &str) -> TerminalInfo {
        TerminalInfo {
            id,
            name: name.into(),
            cwd: cwd.into(),
            kind: "claude".into(),
            claude_session_id: Some(sid.into()),
            waiting_for: None,
        }
    }
    fn tracked(cwd: &str, appears: bool, submits: bool) -> TermHost {
        let mut h = term_host(vec![]);
        h.track = Some(fast());
        h.submits = submits;
        if appears {
            h.on_emit
                .lock()
                .unwrap()
                .push(mkterm(7, &format!("w{cwd}"), cwd, "sid-7"));
        }
        h
    }
    fn open_req(cwd: &str, msg: Option<&str>) -> BrokerReq {
        BrokerReq {
            op: "open_session".into(),
            name: Some(format!("w{cwd}")),
            cwd: Some(cwd.into()),
            initial_message: msg.map(Into::into),
            ..Default::default()
        }
    }
    async fn open(h: &TermHost, cwd: &str, msg: Option<&str>) -> serde_json::Value {
        serde_json::from_str(&handle_open_session(h, &open_req(cwd, msg)).await).unwrap()
    }

    #[tokio::test]
    async fn open_session_reports_success_only_once_claude_runs_in_the_new_tab() {
        let h = tracked("/t/open-ok", true, true);
        let v = open(&h, "/t/open-ok", None).await;
        assert_eq!(v["ok"], true, "{v}");
        assert_eq!(v["status"], "started");
        assert_eq!(
            (v["terminalId"].as_u64(), v["sessionId"].as_str()),
            (Some(7), Some("sid-7"))
        );
    }

    #[tokio::test]
    async fn open_session_is_an_error_when_no_tab_appears() {
        let h = tracked("/t/open-none", false, true);
        let v = open(&h, "/t/open-none", None).await;
        assert_eq!(v["ok"], false, "{v}");
        assert!(
            v["error"].as_str().unwrap().contains("no terminal opened"),
            "{v}"
        );
        // the name is not left registered as ours: close_session must not trust it
        assert!(!agent_session_name_taken("w/t/open-none"));
    }

    #[tokio::test]
    async fn open_session_waits_for_the_first_message_to_be_submitted() {
        // Nothing in the transcript at first: Enter (a third in) submits what sits in the input line.
        let mut h = tracked("/t/open-msg", true, true);
        h.enter_submits = true;
        h.enter_cwd = "/t/open-msg".into();
        let v = open(&h, "/t/open-msg", Some("do the thing")).await;
        assert_eq!(v["ok"], true, "{v}");
        assert_eq!(v["status"], "message_submitted", "{v}");
        let typed = h.typed.lock().unwrap().clone();
        assert!(
            typed.iter().any(|(_, t, _, _)| t == "\r"),
            "Enter pressed: {typed:?}"
        );
        assert!(
            typed.iter().all(|(_, t, _, _)| t == "\r"),
            "text never typed by the broker: {typed:?}"
        );
    }

    #[tokio::test]
    async fn a_first_message_is_never_typed_twice_even_when_the_transcript_lags() {
        // The transcript never shows it (lag / wrapped line): the old code retyped the whole message
        // at two thirds. Now only Enter is ever pressed, and only while the text is in the input line.
        let mut h = tracked("/t/open-lag", true, false);
        h.lines = Some(vec!["> do the thing".into()]);
        let v = open(&h, "/t/open-lag", Some("do the thing")).await;
        assert_eq!(v["ok"], false, "{v}");
        let typed = h.typed.lock().unwrap().clone();
        assert!(
            !typed.is_empty() && typed.iter().all(|(_, t, _, _)| t == "\r"),
            "{typed:?}"
        );
        assert!(typed.len() <= 2, "{typed:?}");
        // text gone from the input line at 2/3: no second Enter, an explicit error instead
        let mut h = tracked("/t/open-gone", true, false);
        h.lines = Some(vec!["> ".into()]);
        let v = open(&h, "/t/open-gone", Some("do the thing")).await;
        assert_eq!(v["ok"], false, "{v}");
        assert!(
            v["error"].as_str().unwrap().contains("not typing it again"),
            "{v}"
        );
        assert_eq!(
            h.typed.lock().unwrap().len(),
            1,
            "one Enter at 1/3, nothing after"
        );
    }

    #[tokio::test]
    async fn enter_is_never_pressed_on_a_dialog() {
        let cwd = "/t/open-dialog";
        let mut h = tracked(cwd, true, false);
        h.on_emit.lock().unwrap()[0].waiting_for = Some("permission prompt".into());
        let v = open(&h, cwd, Some("hello")).await;
        assert_eq!(v["status"], "target_waiting_on_dialog", "{v}");
        assert!(
            h.typed.lock().unwrap().is_empty(),
            "nothing typed or pressed"
        );
        // confirm_chat: same guard
        let cwd = "/t/chat-dialog";
        let mut h = tracked(cwd, false, false);
        let mut t = mkterm(4, "big", cwd, "sid-d");
        t.waiting_for = Some("trust dialog".into());
        h.terms = vec![t];
        let r = confirm_chat(&h, &fast(), "sid-d", cwd, "ping", 0, false, "terminal").await;
        assert_eq!(r, Ok("target_waiting_on_dialog"));
        assert!(h.typed.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn open_session_fails_when_the_message_never_lands() {
        let h = tracked("/t/open-swallow", true, false);
        let v = open(&h, "/t/open-swallow", Some("hello")).await;
        assert_eq!(v["ok"], false, "{v}");
        assert!(
            v["error"].as_str().unwrap().contains("not submitted"),
            "{v}"
        );
    }

    #[tokio::test]
    async fn a_chat_message_is_typed_into_the_terminal_and_confirmed_from_the_transcript() {
        let cwd = "/t/chat-ok";
        let mut h = tracked(cwd, false, true);
        h.terms = vec![mkterm(3, "big", cwd, "sid-3")];
        let before = user_turns_with::<TermHost>(cwd, "sid-3", "ping");
        assert_eq!(
            deliver_chat(&h, "sid-3", "ping", "boss").unwrap(),
            "terminal"
        );
        assert!(
            h.events.lock().unwrap().is_empty(),
            "no event to an app that has no handler"
        );
        assert_eq!(
            h.typed.lock().unwrap()[0],
            (
                3,
                "[message from boss via Muya] ping".to_string(),
                true,
                true
            )
        );
        let st = confirm_chat(&h, &fast(), "sid-3", cwd, "ping", before, false, "terminal").await;
        assert_eq!(st, Ok("submitted"));
    }

    #[tokio::test]
    async fn an_unsubmitted_chat_message_is_an_error_not_delivered() {
        let cwd = "/t/chat-stuck";
        let mut h = tracked(cwd, false, false);
        h.terms = vec![mkterm(4, "big", cwd, "sid-4")];
        deliver_chat(&h, "sid-4", "ping", "boss").unwrap();
        let e = confirm_chat(&h, &fast(), "sid-4", cwd, "ping", 0, false, "terminal")
            .await
            .unwrap_err();
        assert!(e.contains("did not take it"), "{e}");
        // a busy target queues the text: that is reported as such, not as a failure
        assert_eq!(
            confirm_chat(&h, &fast(), "sid-4", cwd, "ping", 0, true, "terminal").await,
            Ok("queued")
        );
    }

    fn op_state(r: &[OperatorSendResult], id: u64) -> String {
        r.iter()
            .find(|x| x.id == id)
            .map(|x| x.state.clone())
            .unwrap_or_default()
    }

    #[tokio::test]
    async fn operator_send_types_verbatim_and_maps_every_outcome() {
        for (sid, cwd) in [
            ("op-a", "/t/op-a"),
            ("op-b", "/t/op-b"),
            ("op-w", "/t/op-w"),
        ] {
            FAKE_SESSIONS
                .lock()
                .unwrap()
                .push(fake_session(sid, sid, cwd));
        }
        let mut shell = mkterm(13, "plain shell", "/t/op-sh", "x");
        shell.kind = "shell".into();
        shell.claude_session_id = None;
        let mut waiting = mkterm(14, "prompted", "/t/op-p", "op-p");
        waiting.waiting_for = Some("permission prompt".into());
        let mut h = tracked("/t/op-a", false, true);
        h.terms = vec![
            mkterm(11, "a", "/t/op-a", "op-a"),
            mkterm(12, "b", "/t/op-b", "op-b"),
            shell,
            waiting,
        ];
        let r = operator_send(&h, &[11, 12, 13, 14, 99, 11], "/compact")
            .await
            .unwrap();
        // duplicates collapse, order follows the request
        assert_eq!(
            r.iter().map(|x| x.id).collect::<Vec<_>>(),
            vec![11, 12, 13, 14, 99]
        );
        assert_eq!(op_state(&r, 11), "submitted");
        assert_eq!(op_state(&r, 12), "submitted");
        assert_eq!(op_state(&r, 13), "failed");
        assert_eq!(op_state(&r, 14), "skipped");
        assert_eq!(op_state(&r, 99), "failed");
        // typed exactly as written (no "[message from ..]" wrapper), only into the two Claude terminals
        let typed = h.typed.lock().unwrap().clone();
        assert_eq!(typed.len(), 2, "{typed:?}");
        assert!(typed.iter().all(|t| t.1 == "/compact" && t.2), "{typed:?}");
        assert_eq!(typed.iter().map(|t| t.0).collect::<Vec<_>>(), vec![11, 12]);
    }

    #[tokio::test]
    async fn operator_send_reports_queued_sent_and_unsubmitted() {
        let mut busy = fake_session("op-busy", "busy", "/t/op-busy");
        busy.status = "working".into();
        FAKE_SESSIONS.lock().unwrap().push(busy);
        FAKE_SESSIONS
            .lock()
            .unwrap()
            .push(fake_session("op-idle", "idle", "/t/op-idle"));
        let mut h = tracked("/t/op-busy", false, false); // the transcript never shows the text
        h.terms = vec![
            mkterm(21, "busy", "/t/op-busy", "op-busy"),
            mkterm(22, "idle", "/t/op-idle", "op-idle"),
        ];
        let r = operator_send(&h, &[21, 22], "please continue")
            .await
            .unwrap();
        assert_eq!(op_state(&r, 21), "queued");
        assert_eq!(op_state(&r, 22), "failed");
        assert!(r[1].reason.as_deref().unwrap().contains("did not take it"));
        // a slash command is not always visible in the transcript: honest "sent", not "failed"
        let r = operator_send(&h, &[22], "/model sonnet").await.unwrap();
        assert_eq!(op_state(&r, 22), "sent");
    }

    #[tokio::test]
    async fn operator_send_rejects_bad_input_and_reports_a_failed_type() {
        let h = tracked("/t/op-x", false, true);
        assert!(operator_send(&h, &[1], "   ").await.is_err());
        assert!(operator_send(&h, &[], "/cost").await.is_err());
        assert!(operator_send(&h, &(0..65).collect::<Vec<u64>>(), "/cost")
            .await
            .is_err());
        FAKE_SESSIONS
            .lock()
            .unwrap()
            .push(fake_session("op-f", "f", "/t/op-f"));
        let mut h = tracked("/t/op-f", false, true);
        h.terms = vec![mkterm(31, "f", "/t/op-f", "op-f")];
        h.fail_id = Some(31);
        let r = operator_send(&h, &[31], "/cost").await.unwrap();
        assert_eq!(
            (r[0].state.as_str(), r[0].reason.as_deref()),
            ("failed", Some("session gone"))
        );
    }

    #[test]
    fn needle_is_the_first_line_cut_short() {
        assert_eq!(submit_needle("\n  hello world \nsecond"), "hello world");
        assert_eq!(submit_needle(&"x".repeat(100)).len(), 60);
    }

    #[test]
    fn only_a_new_claude_terminal_with_the_name_counts() {
        let mut shell = mkterm(2, "w", "/", "x");
        shell.kind = "shell".into();
        shell.claude_session_id = None;
        let terms = vec![
            mkterm(1, "w", "/", "a"),
            shell,
            mkterm(3, "w (ab12)", "/", "b"),
        ];
        let before: HashSet<u64> = [1].into();
        assert_eq!(
            pick_new_claude_terminal(&terms, "w", &before).map(|t| t.id),
            Some(3)
        );
        assert!(pick_new_claude_terminal(&terms, "other", &before).is_none());
    }

    // ---- review fixes: secrets only at a password prompt, no retype, dialog guard, M8, H1, H2 ----

    fn vault_host() -> TermHost {
        let mut h = term_host(vec![term(1, "build", "shell", None, None)]);
        h.vault = vec![
            (
                "prod-db".into(),
                "operator's".into(),
                "hunter2-secret".into(),
            ),
            ("mine".into(), "mine".into(), "agent-made-pw".into()),
        ];
        h
    }
    fn hosts() -> Vec<String> {
        vec!["10.0.0.5".into()]
    }
    fn st(echo_on: bool, line: &str) -> crate::pty_state::PromptState {
        crate::pty_state::PromptState {
            echo_on,
            line: line.into(),
        }
    }

    #[test]
    fn a_secret_is_typed_only_at_a_password_prompt_of_a_configured_server_with_echo_off() {
        let h = vault_host();
        let t = "{{muya-secret:prod-db}}";
        // right prompt, echo off: substituted (operator's and agent's secret alike, no binding)
        for name in ["prod-db", "mine"] {
            let ok = substitute_with(
                &h,
                &format!("{{{{muya-secret:{name}}}}}"),
                true,
                Some(&st(false, "alice@10.0.0.5's password:")),
                None,
                &hosts,
            )
            .unwrap();
            assert!(ok == "hunter2-secret" || ok == "agent-made-pw");
        }
        // echo ON (a shell: `echo {{..}}|rev`, curl ...): refused, even when the line looks like a prompt
        for line in ["alice@10.0.0.5's password:", "$ echo "] {
            let e = substitute_with(&h, t, true, Some(&st(true, line)), None, &hosts).unwrap_err();
            assert!(
                e.contains("can only be typed into a password prompt"),
                "{e}"
            );
        }
        // a prompt of a host that is not a configured server: refused
        let e = substitute_with(
            &h,
            t,
            true,
            Some(&st(false, "root@evil.example's password:")),
            None,
            &hosts,
        )
        .unwrap_err();
        assert!(e.contains("does not name"), "{e}");
        // no terminal state at all (ssh_run, keys, broadcast): refused
        assert!(substitute_with(
            &h,
            "echo {{muya-secret:prod-db}}|rev",
            true,
            None,
            None,
            &hosts
        )
        .is_err());
        // unknown secret
        assert!(
            substitute_with(&h, "{{muya-secret:nope}}", true, None, Some("nope"), &hosts).is_err()
        );
    }

    #[test]
    fn a_session_may_use_the_secret_of_its_own_server_but_not_unverified_callers() {
        let h = vault_host();
        assert_eq!(
            substitute_with(
                &h,
                "x {{muya-secret:mine}}",
                true,
                None,
                Some("mine"),
                &hosts
            )
            .unwrap(),
            "x agent-made-pw"
        );
        // a different secret in that session still needs a password prompt
        assert!(substitute_with(
            &h,
            "{{muya-secret:prod-db}}",
            true,
            None,
            Some("mine"),
            &hosts
        )
        .is_err());
        let e = substitute_with(
            &h,
            "{{muya-secret:mine}}",
            false,
            None,
            Some("mine"),
            &hosts,
        )
        .unwrap_err();
        assert!(e.contains("verified"), "{e}");
        assert_eq!(
            substitute_with(&h, "no placeholder", false, None, None, &hosts).unwrap(),
            "no placeholder"
        );
    }

    #[test]
    fn send_terminal_types_an_operator_secret_only_into_a_prompt_state_the_gate_accepts() {
        // The terminal state comes from the host: echo on = a shell, so nothing may be typed.
        let mut h = vault_host();
        h.echo = Some(true);
        h.lines = Some(vec!["$ ".into()]);
        let r = call(
            &h,
            json!({"op":"send_terminal","target":"build","command":"{{muya-secret:prod-db}}"}),
        );
        assert_eq!(r["ok"], false, "{r}");
        assert!(h.typed.lock().unwrap().is_empty(), "nothing typed");
        // state unreadable: fails closed
        let h = vault_host();
        let r = call(
            &h,
            json!({"op":"send_terminal","target":"build","command":"{{muya-secret:prod-db}}"}),
        );
        assert_eq!(r["ok"], false, "{r}");
        assert!(h.typed.lock().unwrap().is_empty());
        // no secret is typed into a shell line any more, agent-made or not
        let r = call(
            &h,
            json!({"op":"send_terminal","target":"build","command":"echo {{muya-secret:mine}}"}),
        );
        assert_eq!(r["ok"], false, "{r}");
        assert!(h.typed.lock().unwrap().is_empty());
    }

    #[test]
    fn ssh_run_refuses_a_placeholder_so_no_secret_reaches_the_local_argv() {
        let h = vault_host();
        let req: BrokerReq = serde_json::from_value(
            json!({"op":"run","alias":"x","command":"sleep 30; : {{muya-secret:mine}}"}),
        )
        .unwrap();
        let out = futures_lite_block(handle_run(&h, &[], &req));
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], false);
        assert!(
            v["error"]
                .as_str()
                .unwrap()
                .contains("visible to local `ps`"),
            "{v}"
        );
        let req: BrokerReq = serde_json::from_value(
            json!({"op":"run","alias":"x","commands":["id","echo {{muya-secret:mine}}"]}),
        )
        .unwrap();
        assert!(futures_lite_block(handle_run(&h, &[], &req)).contains("visible to local"));
    }

    /// A one-shot local HTTP server that answers 200 and echoes the request it got (headers + body) back.
    fn echo_server() -> (u16, std::thread::JoinHandle<String>) {
        use std::io::{Read, Write};
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let t = std::thread::spawn(move || {
            let (mut c, _) = l.accept().unwrap();
            let mut buf = vec![0u8; 8192];
            let mut got = Vec::new();
            loop {
                let n = c.read(&mut buf).unwrap();
                got.extend_from_slice(&buf[..n]);
                let text = String::from_utf8_lossy(&got).to_string();
                if let Some(i) = text.find("\r\n\r\n") {
                    let want: usize = text[..i]
                        .to_ascii_lowercase()
                        .lines()
                        .find_map(|l| l.strip_prefix("content-length:").map(|v| v.trim().parse().unwrap()))
                        .unwrap_or(0);
                    if got.len() >= i + 4 + want {
                        break;
                    }
                }
                if n == 0 {
                    break;
                }
            }
            let text = String::from_utf8_lossy(&got).to_string();
            let _ = write!(c, "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nx-echo: {}\r\nconnection: close\r\n\r\n{}", text.len(), "agent-made-pw", text);
            text
        });
        (port, t)
    }

    #[test]
    fn http_request_substitutes_headers_and_body_and_redacts_the_reply() {
        let h = vault_host();
        let (port, server) = echo_server();
        let r = call(
            &h,
            json!({"op":"http_request","method":"POST","url":format!("http://127.0.0.1:{port}/v1/x"),
                   "headers":{"Authorization":"Bearer {{muya-secret:mine}}"},"body":"k={{muya-secret:mine}}"}),
        );
        let seen = server.join().unwrap();
        assert!(seen.contains("agent-made-pw"), "the server must get the real value: {seen}");
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["status"], 200);
        let out = r.to_string();
        assert!(!out.contains("agent-made-pw"), "plaintext leaked: {out}");
        assert!(r["body"].as_str().unwrap().contains("Bearer {{muya-secret:mine}}"), "{r}");
        assert_eq!(r["headers"]["x-echo"], "{{muya-secret:mine}}");
        assert_eq!(r["secrets"], json!(["mine"]));
    }

    #[test]
    fn http_request_refuses_plain_http_to_other_hosts_and_unknown_secrets() {
        let h = vault_host();
        let r = call(&h, json!({"op":"http_request","url":"http://example.com/"}));
        assert_eq!(r["ok"], false);
        assert!(r["error"].as_str().unwrap().contains("https"), "{r}");
        let r = call(&h, json!({"op":"http_request","url":"ftp://example.com/"}));
        assert_eq!(r["ok"], false);
        let r = call(&h, json!({"op":"http_request","url":"https://example.com/","headers":{"A":"{{muya-secret:nope}}"}}));
        assert_eq!(r["ok"], false);
        assert!(r["error"].as_str().unwrap().contains("no secret named"), "{r}");
    }

    #[test]
    fn get_secret_usage_hint_names_the_working_tools() {
        let h = crate::secret_refs::USAGE_HINT.replace("NAME", "k");
        for needle in ["http_request", "run_with_secrets", "muyactl secret exec --env API_KEY=k", "{{muya-secret:k}}", "NOT the secret"] {
            assert!(h.contains(needle), "{needle} missing: {h}");
        }
    }

    fn run_secret_req(extra: serde_json::Value) -> serde_json::Value {
        let mut base = json!({"op":"run_with_secrets","cwd":"/tmp"});
        for (k, v) in extra.as_object().unwrap() {
            base[k] = v.clone();
        }
        base
    }

    #[test]
    fn run_with_secrets_puts_the_secret_in_the_env_and_redacts_an_echo_of_it() {
        let h = vault_host();
        let r = call(
            &h,
            run_secret_req(json!({
                "argv": ["/bin/sh", "-c", "echo \"pw=$PW\"; echo \"$PW\" | base64; printf %s \"$PW\" | od -An -tx1 | tr -d ' \\n'; echo; echo err-$PW >&2; exit 3"],
                "env": {"PW": "{{muya-secret:mine}}"},
            })),
        );
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["exitCode"], 3);
        let out = r.to_string();
        assert!(!out.contains("agent-made-pw"), "{out}");
        assert!(
            r["stdout"]
                .as_str()
                .unwrap()
                .contains("pw={{muya-secret:mine}}"),
            "{r}"
        );
        assert!(
            r["stderr"]
                .as_str()
                .unwrap()
                .contains("{{muya-secret:mine}}"),
            "{r}"
        );
        assert!(
            !out.contains("YWdlbnQtbWFkZS1wdw"),
            "base64 form leaked: {out}"
        );
        assert_eq!(r["secrets"], json!(["mine"]));
    }

    #[test]
    fn run_with_secrets_passes_stdin_and_refuses_placeholders_in_argv() {
        let h = vault_host();
        let r = call(
            &h,
            run_secret_req(json!({"argv": ["/bin/cat"], "stdin": "{{muya-secret:mine}}"})),
        );
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["stdout"], "{{muya-secret:mine}}");
        let r = call(
            &h,
            run_secret_req(json!({"argv": ["/bin/echo", "{{muya-secret:mine}}"]})),
        );
        assert_eq!(r["ok"], false);
        assert!(
            r["error"]
                .as_str()
                .unwrap()
                .contains("visible to local `ps`"),
            "{r}"
        );
        // bad env name, unknown secret, bad cwd
        let r = call(
            &h,
            run_secret_req(json!({"argv": ["/bin/true"], "env": {"LD_PRELOAD": "x"}})),
        );
        assert_eq!(r["ok"], false, "{r}");
        let r = call(
            &h,
            run_secret_req(json!({"argv": ["/bin/true"], "env": {"A": "{{muya-secret:nope}}"}})),
        );
        assert_eq!(r["ok"], false, "{r}");
        let r = call(
            &h,
            json!({"op":"run_with_secrets","argv":["/bin/true"],"cwd":"relative"}),
        );
        assert_eq!(r["ok"], false, "{r}");
    }

    fn futures_lite_block<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(f)
    }

    #[test]
    fn the_server_listing_shows_every_entry_with_group_and_access() {
        let mk = |label: &str, access: bool, group: &str| -> Server {
            serde_json::from_value(json!({
                "id": label, "label": label, "host": "h", "port": 22, "username": "u",
                "connectionType": "direct", "agentAccess": access, "group": group
            }))
            .unwrap()
        };
        let servers = vec![mk("a", true, "prod"), mk("b", false, "")];
        let all = agent_listing_with(&servers, &[]);
        assert_eq!(all.len(), 2);
        assert_eq!((all[0].group.as_str(), all[0].agent_access), ("prod", true));
        assert!(!all[1].agent_access);
        assert_eq!(agent_visible_with(&servers, &[]).len(), 1);
        assert!(
            find_server(&servers, "b").is_some(),
            "managing an entry does not need agentAccess"
        );
    }

    #[test]
    fn a_secret_edit_with_nothing_in_it_is_empty() {
        assert!(SecretEdit::default().is_empty());
        assert!(!SecretEdit {
            group: Some("g".into()),
            ..Default::default()
        }
        .is_empty());
    }

    #[test]
    fn an_unverified_caller_may_only_type_into_what_it_opened() {
        let h = three();
        let mut req: BrokerReq =
            serde_json::from_value(json!({"op":"send_terminal","target":"build","command":"ls"}))
                .unwrap();
        req.caller_pid = Some(4242); // a socket peer whose session could not be verified
        let out: serde_json::Value = serde_json::from_str(&handle_send_terminal(&h, &req)).unwrap();
        assert_eq!(out["ok"], false, "{out}");
        assert!(h.typed.lock().unwrap().is_empty());
        // its own terminal is fine
        TERMINAL_OWNERS.lock().unwrap().insert(1, caller_key(&req));
        let out: serde_json::Value = serde_json::from_str(&handle_send_terminal(&h, &req)).unwrap();
        assert_eq!(out["ok"], true, "{out}");
        // broadcast is refused outright, and so are secrets
        let mut b: BrokerReq =
            serde_json::from_value(json!({"op":"broadcast","command":"ls"})).unwrap();
        b.caller_pid = Some(4242);
        assert!(handle_broadcast(&h, &b).contains("unverified"));
        // a verified caller (session known) is unaffected
        let v = call(
            &h,
            json!({"op":"send_terminal","target":"2","command":"ls","sessionId":"sess-me"}),
        );
        assert_eq!(v["ok"], true, "{v}");
    }

    #[tokio::test]
    async fn an_unverified_caller_cannot_send_to_a_session_it_did_not_open() {
        FAKE_SESSIONS
            .lock()
            .unwrap()
            .push(fake_session("sid-m8", "m8-target", "/t/m8"));
        let h = tracked("/t/m8", false, true);
        let mut req: BrokerReq = serde_json::from_value(
            json!({"op":"send_to_session","target":"sid-m8","text":"rm -rf","deliver":"keys"}),
        )
        .unwrap();
        req.caller_pid = Some(4243);
        let v: serde_json::Value =
            serde_json::from_str(&handle_send_to_session(&h, &req).await).unwrap();
        assert_eq!(v["ok"], false, "{v}");
        assert!(v["error"].as_str().unwrap().contains("open_session"), "{v}");
    }

    #[tokio::test]
    async fn a_delivered_message_keeps_its_idempotency_key_when_confirmation_fails() {
        // M5: the text WAS typed; a retry with the same key must not type it again.
        let cwd = "/t/m5";
        FAKE_SESSIONS
            .lock()
            .unwrap()
            .push(fake_session("sid-m5", "m5-target", cwd));
        let mut h = tracked(cwd, false, false); // typed text never reaches the transcript
        h.terms = vec![mkterm(5, "m5-target", cwd, "sid-m5")];
        let req: BrokerReq = serde_json::from_value(json!({
            "op":"send_to_session","target":"sid-m5","text":"ping","deliver":"muya","idempotencyKey":"k1"
        })).unwrap();
        let first: serde_json::Value =
            serde_json::from_str(&handle_send_to_session(&h, &req).await).unwrap();
        assert_eq!(first["ok"], false, "{first}");
        let typed_once = h
            .typed
            .lock()
            .unwrap()
            .iter()
            .filter(|t| t.1.contains("ping"))
            .count();
        assert_eq!(typed_once, 1);
        let again: serde_json::Value =
            serde_json::from_str(&handle_send_to_session(&h, &req).await).unwrap();
        assert_eq!(again["duplicate"], true, "{again}");
        assert_eq!(
            h.typed
                .lock()
                .unwrap()
                .iter()
                .filter(|t| t.1.contains("ping"))
                .count(),
            1,
            "never typed twice"
        );
    }

    #[tokio::test]
    async fn a_chat_message_is_not_typed_into_a_dialog() {
        let cwd = "/t/m6";
        FAKE_SESSIONS
            .lock()
            .unwrap()
            .push(fake_session("sid-m6", "m6-target", cwd));
        let mut h = tracked(cwd, false, true);
        let mut t = mkterm(6, "m6-target", cwd, "sid-m6");
        t.waiting_for = Some("permission prompt".into());
        h.terms = vec![t];
        let req: BrokerReq = serde_json::from_value(json!({"op":"send_to_session","target":"sid-m6","text":"hello","deliver":"muya","idempotencyKey":"k6"})).unwrap();
        let v: serde_json::Value =
            serde_json::from_str(&handle_send_to_session(&h, &req).await).unwrap();
        assert_eq!(v["state"], "target_waiting_on_dialog", "{v}");
        assert!(h.typed.lock().unwrap().is_empty(), "nothing typed");
        assert!(
            h.claimed.lock().unwrap().is_empty(),
            "key released: nothing was delivered"
        );
    }

    #[test]
    fn a_sidecar_may_only_claim_the_session_of_its_own_claude_process() {
        let chain = ancestors_via(300, |p| match p {
            300 => Some(200),
            200 => Some(100),
            100 => Some(1),
            _ => None,
        });
        assert_eq!(chain, vec![300, 200, 100]);
        assert!(claim_matches(Some(200), &chain));
        assert!(!claim_matches(Some(999), &chain));
        assert!(
            claim_matches(None, &chain),
            "unknown session pid cannot be checked"
        );
        assert!(ancestors_via(5, |_| Some(5)).len() == 1, "loops end");
    }

    // ---- compact_session / usage (ported from classic main) ----
    #[test]
    fn compact_sanitize_makes_one_clean_capped_line() {
        assert_eq!(sanitize_compact_instructions("  keep\nthe  API\u{1b}[31m plan "), Some("keep the API [31m plan".into()));
        assert_eq!(sanitize_compact_instructions("\n\t \u{7}"), None);
        let long = "é".repeat(900);
        assert_eq!(sanitize_compact_instructions(&long).unwrap().chars().count(), COMPACT_INSTRUCTIONS_MAX);
        assert_eq!(compact_line(None), "/compact");
        assert_eq!(compact_line(Some("  ")), "/compact");
        assert_eq!(compact_line(Some("focus on X\nrm -rf")), "/compact focus on X rm -rf");
    }

    #[test]
    fn compact_refusal_only_lets_an_idle_other_claude_session_through() {
        assert!(compact_refusal("w", "claude", "idle", None, false).is_none());
        assert!(compact_refusal("w", "claude", "idle", Some(""), false).is_none());
        assert!(compact_refusal("w", "claude", "idle", None, true).unwrap().contains("own session"));
        assert!(compact_refusal("w", "opencode", "idle", None, false).unwrap().contains("opencode"));
        assert!(compact_refusal("w", "claude", "working", None, false).unwrap().contains("busy"));
        assert!(compact_refusal("w", "claude", "waiting-for-input", Some("permission prompt"), false).unwrap().contains("permission prompt"));
        assert!(compact_refusal("w", "claude", "waiting-for-input", None, false).unwrap().contains("waiting"));
        assert!(compact_refusal("w", "claude", "stopped", None, false).is_some());
    }

    #[test]
    fn usage_picks_newest_with_limits_and_drops_expired_windows() {
        let now = 1_000_000u64;
        let old = json!({"session_id":"a","rate_limits":{"five_hour":{"used_percentage":10.0,"resets_at":now+100}}});
        let new = json!({"session_id":"b","rate_limits":{
            "five_hour":{"used_percentage":23.5,"resets_at":now+5400},
            "seven_day":{"used_percentage":41.2,"resets_at":now-5},
            "spend_limit":{"used_percentage":62.8,"resets_at":now+9,"used_usd":5.0,"limit_usd":8.0,"period":"monthly"}}});
        let nolimits = json!({"session_id":"c"});
        let files = vec![(old, now - 500), (new, now - 20), (nolimits, now - 1)];
        let v = usage_from_status(&files, None, now).unwrap();
        assert_eq!(v["sessionId"], "b");
        assert_eq!(v["ageSeconds"], 20);
        assert_eq!(v["windows"]["fiveHour"]["usedPercentage"], 23.5);
        assert!(v["windows"].get("sevenDay").is_none(), "expired window dropped");
        assert_eq!(v["windows"]["spendLimit"]["limitUsd"], 8.0);
        assert_eq!(v["windows"]["spendLimit"]["period"], "monthly");
        // Per-session filter, and clear errors when nothing matches.
        assert_eq!(usage_from_status(&files, Some("a"), now).unwrap()["sessionId"], "a");
        assert!(usage_from_status(&files, Some("zzz"), now).unwrap_err().contains("that session"));
        assert!(usage_from_status(&[], None, now).unwrap_err().contains("no usage data"));
    }

}

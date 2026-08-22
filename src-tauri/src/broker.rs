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

use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::{AsRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex as StdMutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::json;
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::{Mutex, Semaphore};
use zeroize::Zeroizing;

use crate::ssh::Server;

/// Name of the MCP entry written to `~/.claude/.mcp.json` and of the proxy binary.
const MCP_ENTRY_NAME: &str = "muya-mcp";
/// Prior name of this MCP server; removed from `~/.claude.json` on register so the
/// rename doesn't leave a stale duplicate pointing at the same binary.
const MCP_LEGACY_ENTRY_NAME: &str = "muya-ssh";
const MCP_BIN_NAME: &str = "muya-ssh-mcp";

/// Session ids the agent has opened via `ssh_open` and may write to with `ssh_send`.
/// An id is added when the open is signalled and removed when the tab closes, so a
/// stale id (closed tab) can never be written to. Kept process-wide (not per-request)
/// because opens and sends are separate MCP calls.
static SSH_SESSIONS: LazyLock<StdMutex<HashSet<String>>> =
    LazyLock::new(|| StdMutex::new(HashSet::new()));

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
static AGENT_OPENED_SESSIONS: LazyLock<StdMutex<HashSet<String>>> =
    LazyLock::new(|| StdMutex::new(HashSet::new()));

fn register_agent_session(name: &str) {
    if let Ok(mut set) = AGENT_OPENED_SESSIONS.lock() {
        set.insert(name.to_string());
    }
}

fn agent_session_is_open(name: &str) -> bool {
    AGENT_OPENED_SESSIONS
        .lock()
        .map(|s| s.contains(name))
        .unwrap_or(false)
}

/// Drop a session name once it's closed (called from the app via the
/// `release_agent_session` command, on ANY tab close — not just `close_session`
/// ones — so a manually-closed tab's name doesn't stay falsely closable). Idempotent.
pub fn release_agent_session(name: &str) {
    if let Ok(mut set) = AGENT_OPENED_SESSIONS.lock() {
        set.remove(name);
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
}

#[derive(Deserialize, Default)]
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
    /// Agent-supplied extra scp flags, policed by `enforce_scp_arg_policy` before
    /// they ever reach `ssh::build_scp_command`.
    #[serde(rename = "extraArgs", default)]
    extra_args: Option<Vec<String>>,
    /// `send` (PRD `ssh-send`): the ssh_open session id to write to, and the literal
    /// text to type into that terminal's PTY (include a trailing "\n" to run it).
    #[serde(rename = "sessionId", default)]
    session_id: Option<String>,
    #[serde(default)]
    text: Option<String>,
    /// `session_exec` (PRD `ssh-session`): optional per-command timeout in seconds.
    #[serde(rename = "timeoutSecs", default)]
    timeout_secs: Option<u64>,
    /// `list_sessions`/`read_session`/`send_to_session` (PRD `session-messaging`):
    /// the session to address (name or id, fuzzy), how many turns to read, an optional
    /// filter, and the delivery mode ("auto" = native SendMessage, "muya" = Muya types it).
    #[serde(default)]
    target: Option<String>,
    #[serde(default)]
    limit: Option<u32>,
    #[serde(default)]
    query: Option<String>,
    #[serde(default)]
    deliver: Option<String>,
    /// `open_session` (PRD `agent-session-open`): working directory for the new local
    /// Claude session (defaults to the operator's current workspace when absent) and
    /// an optional first prompt to hand it directly on launch. Reuses `name` above.
    #[serde(default)]
    cwd: Option<String>,
    #[serde(rename = "initialMessage", default)]
    initial_message: Option<String>,
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
pub(crate) fn agent_visible(servers: &[Server]) -> Vec<ServerMeta> {
    servers
        .iter()
        .filter(|s| s.agent_access)
        .map(|s| ServerMeta {
            alias: alias_of(s),
            host: s.host.clone(),
            username: s.username.clone(),
            port: s.port,
            connection_type: s.connection_type.clone(),
        })
        .collect()
}

/// AC5 — resolve an alias for `open`. Distinguishes "no such server" from
/// "exists but the operator did not opt it in", so the agent gets a clear error.
pub(crate) enum OpenResolution<'a> {
    Ok(&'a Server),
    NotAccessible,
    NotFound,
}

pub(crate) fn resolve_open<'a>(servers: &'a [Server], alias: &str) -> OpenResolution<'a> {
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
pub(crate) fn assemble_run_args(
    mut base: Vec<String>,
    command: &str,
) -> Result<Vec<String>, String> {
    let dest = base.pop().ok_or("empty ssh args (no destination)")?;
    base.push("-o".to_string());
    base.push("LogLevel=ERROR".to_string());
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
pub(crate) fn enforce_scp_arg_policy(args: &[String]) -> Result<Vec<String>, String> {
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
pub(crate) fn socket_path() -> Result<PathBuf, String> {
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
fn peer_uid(fd: RawFd) -> Option<u32> {
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

/// Handle one broker request line → one JSON response string (no trailing NL).
async fn handle_request(app: &AppHandle, line: &str) -> String {
    let req: BrokerReq = match serde_json::from_str(line) {
        Ok(r) => r,
        Err(e) => return err_resp(format!("bad request: {e}")),
    };

    // Load current config (non-secret). ssh::ssh_list_servers reads the config
    // file — safe even when the credential store is locked (AC4).
    let servers = match crate::ssh::ssh_list_servers() {
        Ok(s) => s,
        Err(e) => return err_resp(e),
    };

    match req.op.as_str() {
        "list_servers" => {
            let metas = agent_visible(&servers);
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
                        let store: State<crate::credstore::CredStore> = app.state();
                        if !crate::credstore::is_unlocked(&store) {
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
                    // Trigger the existing inject-capable open path in the UI. The
                    // secret is resolved + injected entirely in the app process by
                    // ssh_pty_connect; nothing secret is returned here.
                    let payload = json!({
                        "serverId": server.id,
                        "label": alias_of(server),
                        "sessionId": session_id,
                    });
                    if let Err(e) = app.emit("ssh-broker-open", payload) {
                        release_ssh_session(&session_id);
                        return err_resp(format!("failed to signal open: {e}"));
                    }
                    json!({"ok": true, "sessionId": session_id}).to_string()
                }
            }
        }
        "run" => handle_run(app, &servers, &req).await,
        "scp" => handle_scp(app, &servers, &req).await,
        "send" => handle_send(app, &req),
        "open_session" => handle_open_session(app, &req),
        "list_sessions" => handle_list_sessions(&req).await,
        "read_session" => handle_read_session(&req).await,
        "send_to_session" => handle_send_to_session(app, &req).await,
        "close_session" => handle_close_session(app, &req).await,
        "session_open" => handle_session_open(app, &servers, &req).await,
        "session_exec" => handle_session_exec(app, &req).await,
        "session_close" => handle_session_close(app, &req).await,
        // Agentic-SSH — register a NEW server the agent can then ssh_open/ssh_run
        // (PRD ssh-agent-add-server). All guardrails live in `agent_add_server_in`:
        // forced direct/no-ssh_options, host/user injection rejected, CREATE-ONLY
        // (no overwrite), and — operator-approved — an OPTIONAL credential bound BY
        // NAME (resolved+injected Rust-side at connect time; the value never crosses
        // to the agent). No secret is serialized here.
        "add_server" => {
            let host = match req.host.as_deref() {
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
                .map(|c| c.to_string());
            let mut cfg = match crate::ssh::load_config() {
                Ok(c) => c,
                Err(e) => return err_resp(e),
            };
            match crate::ssh::agent_add_server_in(
                &mut cfg, label, host, username, req.port, credential,
            ) {
                Ok(alias) => match crate::ssh::save_config(&cfg) {
                    Ok(()) => json!({"ok": true, "alias": alias}).to_string(),
                    Err(e) => err_resp(e),
                },
                Err(e) => err_resp(e),
            }
        }
        // Faz 3.1 — secret-operation broker (AC12/AC15). These do not touch SSH
        // servers; they surface stored-secret metadata + operator-defined ops.
        "list_secrets" => {
            let store: State<crate::credstore::CredStore> = app.state();
            match crate::credstore::list_meta(&store) {
                Ok(metas) => {
                    // Project to name (= label) + description + kind. NEVER the secret.
                    let secrets: Vec<_> = metas
                        .iter()
                        .map(|m| {
                            json!({
                                "name": m.label,
                                "description": m.description,
                                "kind": m.secret_kind,
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
            let store: State<crate::credstore::CredStore> = app.state();
            match crate::credstore::add_credential(&store, name, description, kind, value) {
                Ok(meta) => json!({
                    "ok": true,
                    "secret": { "name": meta.label, "kind": meta.secret_kind },
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
            let store: State<crate::credstore::CredStore> = app.state();
            match crate::credstore::secret_for_ref(&store, name) {
                Ok(s) => json!({"ok": true, "value": s.as_str()}).to_string(),
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
            let value = match req.value.as_deref() {
                Some(v) if !v.is_empty() => v.to_string(),
                _ => return err_resp("`update_secret` requires a non-empty `value`"),
            };
            let store: State<crate::credstore::CredStore> = app.state();
            match crate::credstore::update_credential(&store, &name, value) {
                Ok(meta) => json!({
                    "ok": true,
                    "secret": { "name": meta.label, "kind": meta.secret_kind },
                })
                .to_string(),
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
        "run_operation" => handle_run_operation(app, &req).await,
        other => err_resp(format!("unknown op '{other}'")),
    }
}

/// AC15 — run one operator-defined operation by name. Resolve the op, police the
/// agent args (fail-closed), resolve its secret in Rust, inject it into the CHILD
/// process env, run the fixed program, and return only stdout/stderr/exitCode. The
/// secret is NEVER serialized, logged, or placed in the outer argv.
async fn handle_run_operation(app: &AppHandle, req: &BrokerReq) -> String {
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
    let broker: State<BrokerState> = app.state();
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
            let store: State<crate::credstore::CredStore> = app.state();
            if !crate::credstore::is_unlocked(&store) {
                return err_resp("password store is locked — unlock it in the Password Store tab");
            }
            // Ops reference the secret by the NAME the operator gave it (label) or
            // by id — not the internal hex id alone. secret_for_ref resolves either.
            match crate::credstore::secret_for_ref(&store, reference) {
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
fn handle_send(app: &AppHandle, req: &BrokerReq) -> String {
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
    // Audit trail — id + byte length ONLY; the keystroke content is never logged.
    log::info!("ssh_send → session {session_id} ({} bytes)", text.len());
    let payload = json!({ "sessionId": session_id, "text": text });
    if let Err(e) = app.emit("ssh-broker-send", payload) {
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
pub(crate) enum TargetMatch {
    One(usize),
    Many(Vec<usize>),
    None,
}

pub(crate) fn resolve_target(target: &str, sessions: &[(String, String)]) -> TargetMatch {
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
fn running_sessions() -> Result<Vec<crate::agents::AgentSession>, String> {
    let all = crate::agents::list_agent_sessions_sync(Some(true))?;
    Ok(all
        .into_iter()
        .filter(|s| s.status != "stopped" && !s.id.is_empty())
        .collect())
}

fn session_pairs(sessions: &[crate::agents::AgentSession]) -> Vec<(String, String)> {
    sessions
        .iter()
        .map(|s| (s.id.clone(), s.name.clone()))
        .collect()
}

/// `open_session` (PRD `agent-session-open`): the local analog of `ssh_open` — no
/// server, no credentials, no session-id minting. Just tells the app to open a new
/// terminal tab running `claude --dangerously-skip-permissions --name <name>`
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
    let payload = json!({
        "name": name,
        "cwd": req.cwd,
        "initialMessage": req.initial_message,
    });
    Ok((name, payload))
}

fn handle_open_session(app: &AppHandle, req: &BrokerReq) -> String {
    let (name, payload) = match build_open_session_payload(req) {
        Ok(v) => v,
        Err(e) => return err_resp(e),
    };
    // Registered BEFORE the emit (and rolled back if it fails) so a `close_session`
    // that races the tab actually opening still sees this name as ours.
    register_agent_session(&name);
    if let Err(e) = app.emit("muya://open-agent-session", payload) {
        release_agent_session(&name);
        return err_resp(format!("failed to signal open_session: {e}"));
    }
    json!({"ok": true, "name": name}).to_string()
}

/// `list_sessions` (PRD `session-messaging`): the RUNNING Claude sessions Muya knows,
/// with the operator's own names — so an agent can address "the password-hardening
/// session" by name instead of guessing.
async fn handle_list_sessions(req: &BrokerReq) -> String {
    let sessions = match tokio::task::spawn_blocking(running_sessions).await {
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
                "isCurrent": !me.is_empty() && s.id == me,
            })
        })
        .collect();
    json!({ "ok": true, "sessions": list }).to_string()
}

/// `read_session`: read another session's recent conversation (read-only) so an agent can
/// answer "what is that session up to?" without messaging it.
async fn handle_read_session(req: &BrokerReq) -> String {
    let target = match req.target.as_deref() {
        Some(t) if !t.trim().is_empty() => t.to_string(),
        _ => return err_resp("`read_session` requires a `target` (session name or id)"),
    };
    let limit = req.limit.unwrap_or(20).clamp(1, 200) as usize;
    let query = req.query.clone();
    let result = tokio::task::spawn_blocking(move || -> Result<String, String> {
        let sessions = running_sessions()?;
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
                let body = crate::sessions::read_transcript_tail(
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

/// `send_to_session`: resolve a fuzzy target to ONE running session. Default
/// (`deliver: "auto"`) returns the canonical name so the agent delivers with the native,
/// non-interrupting `SendMessage`; `deliver: "muya"` has Muya type it into the target's
/// terminal instead (fallback when native cross-session messaging isn't available).
async fn handle_send_to_session(app: &AppHandle, req: &BrokerReq) -> String {
    let target = match req.target.as_deref() {
        Some(t) if !t.trim().is_empty() => t.to_string(),
        _ => return err_resp("`send_to_session` requires a `target` (session name or id)"),
    };
    let text = match req.text.as_deref() {
        Some(t) if !t.trim().is_empty() => t.to_string(),
        _ => return err_resp("`send_to_session` requires non-empty `text`"),
    };
    let deliver = req.deliver.clone().unwrap_or_else(|| "auto".to_string());
    let from = req.session_id.clone().unwrap_or_default();

    let resolved = tokio::task::spawn_blocking(move || -> Result<(String, String, String), String> {
        let sessions = running_sessions()?;
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
                Ok((s.id.clone(), s.name.clone(), s.worktree.clone()))
            }
        }
    })
    .await;
    let (id, name, cwd) = match resolved {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => return err_resp(e),
        Err(e) => return err_resp(format!("resolve task failed: {e}")),
    };

    if deliver == "muya" {
        // Muya types it into the target terminal, tagged with the sender.
        let sender = if from.is_empty() {
            "another Muya session".to_string()
        } else {
            from.clone()
        };
        let payload = json!({ "sessionId": id, "text": text, "from": sender });
        if let Err(e) = app.emit("muya://deliver-message", payload) {
            return err_resp(format!("failed to deliver: {e}"));
        }
        return json!({
            "ok": true,
            "delivered": "muya",
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

/// `close_session` (PRD `close-session`): close a terminal tab Muya itself opened via
/// `open_session` — never a session the operator opened by hand. Resolves `target`
/// exactly like `send_to_session` (id > exact name > substring, never guesses on a
/// tie), then refuses unless the resolved session's name is one `open_session`
/// actually opened (`AGENT_OPENED_SESSIONS` above).
async fn handle_close_session(app: &AppHandle, req: &BrokerReq) -> String {
    let target = match req.target.as_deref() {
        Some(t) if !t.trim().is_empty() => t.to_string(),
        _ => return err_resp("`close_session` requires a `target` (session name or id)"),
    };

    let resolved = tokio::task::spawn_blocking({
        let target = target.clone();
        move || -> Result<(String, String), String> {
            let sessions = running_sessions()?;
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

    if !agent_session_is_open(&name) {
        return err_resp(format!(
            "'{name}' was not opened with open_session — you may only close sessions you opened yourself"
        ));
    }

    let payload = json!({ "sessionId": id });
    if let Err(e) = app.emit("muya://close-agent-session", payload) {
        return err_resp(format!("failed to signal close: {e}"));
    }
    release_agent_session(&name);
    json!({"ok": true, "name": name}).to_string()
}

/// `ssh_session_open` (PRD `ssh-session`, Faz 2): open a persistent, headless SSH session
/// (one PSMP connection = one OTP) the agent can then run many commands in. The password
/// is injected into the PTY Rust-side, never returned. Returns a `sessionId`.
async fn handle_session_open(app: &AppHandle, servers: &[Server], req: &BrokerReq) -> String {
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
    let secret = match resolve_injectable_secret(app, server, "ssh_session_open").await {
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
    let store = app
        .state::<crate::agent_ssh::AgentSshStore>()
        .inner()
        .clone();
    let result = tokio::task::spawn_blocking(move || {
        crate::agent_ssh::open(&store, &program, &args, secret, is_psmp)
    })
    .await;
    match result {
        Ok(Ok(session_id)) => json!({ "ok": true, "sessionId": session_id }).to_string(),
        Ok(Err(e)) => err_resp(e),
        Err(e) => err_resp(format!("session open task failed: {e}")),
    }
}

/// `ssh_session_exec`: run one command inside an open session and return its output +
/// exit code. Shell state (cd/env/sudo) is preserved between calls.
async fn handle_session_exec(app: &AppHandle, req: &BrokerReq) -> String {
    let session_id = match req.session_id.as_deref() {
        Some(s) if !s.trim().is_empty() => s.to_string(),
        _ => return err_resp("`session_exec` requires a `sessionId` (from ssh_session_open)"),
    };
    let command = match req.command.as_deref() {
        Some(c) if !c.trim().is_empty() => c.to_string(),
        _ => return err_resp("`session_exec` requires a non-empty `command`"),
    };
    let timeout = req.timeout_secs.map(std::time::Duration::from_secs);
    let store = app
        .state::<crate::agent_ssh::AgentSshStore>()
        .inner()
        .clone();
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
async fn handle_session_close(app: &AppHandle, req: &BrokerReq) -> String {
    let session_id = match req.session_id.as_deref() {
        Some(s) if !s.trim().is_empty() => s,
        _ => return err_resp("`session_close` requires a `sessionId`"),
    };
    let store = app.state::<crate::agent_ssh::AgentSshStore>();
    match crate::agent_ssh::close(store.inner(), session_id) {
        Ok(()) => json!({ "ok": true }).to_string(),
        Err(e) => err_resp(e),
    }
}

async fn handle_run(app: &AppHandle, servers: &[Server], req: &BrokerReq) -> String {
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
    let broker: State<BrokerState> = app.state();
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
        match resolve_injectable_secret(app, server, "ssh_run").await {
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
async fn resolve_injectable_secret(
    app: &AppHandle,
    server: &Server,
    tool_name: &str,
) -> Result<Option<Zeroizing<String>>, String> {
    match server.credential_source.kind.as_str() {
        "local" => {
            let store: State<crate::credstore::CredStore> = app.state();
            if !crate::credstore::is_unlocked(&store) {
                return Err(
                    "password store is locked — unlock it in the Password Store tab".into(),
                );
            }
            let id = server
                .credential_source
                .local_cred_id
                .as_deref()
                .ok_or("server uses the local store but no credential is selected")?;
            crate::credstore::secret_for(&store, id).map(Some)
        }
        "cyberark" => {
            let acct = server
                .credential_source
                .cyberark_account_id
                .as_deref()
                .ok_or("server uses CyberArk but no account is selected")?;
            let cyber: State<crate::cyberark::CyberarkState> = app.state();
            crate::cyberark::fetch_password(&cyber, acct)
                .await
                .map(Some)
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
async fn handle_scp(app: &AppHandle, servers: &[Server], req: &BrokerReq) -> String {
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
    let broker: State<BrokerState> = app.state();
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
        match resolve_injectable_secret(app, server, "ssh_scp").await {
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

/// Bind the broker socket (0600), enforce the peer-uid check, and serve requests.
/// Idempotent: a second call while already listening is a no-op.
pub async fn enable_broker_listener(state: &BrokerState, app: AppHandle) -> Result<(), String> {
    let mut guard = state.listener.lock().await;
    if guard.is_some() {
        return Ok(());
    }
    let path = socket_path()?;
    if path.exists() {
        fs::remove_file(&path).map_err(|e| format!("remove stale broker socket: {e}"))?;
    }
    let listener =
        UnixListener::bind(&path).map_err(|e| format!("bind broker UDS {path:?}: {e}"))?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("chmod broker socket: {e}"))?;

    let listener = Arc::new(listener);
    let accept_listener = listener.clone();
    let app_for_loop = app.clone();
    tauri::async_runtime::spawn(async move {
        let me = unsafe { libc::getuid() };
        loop {
            match accept_listener.accept().await {
                Ok((stream, _addr)) => {
                    // Peer authentication: reject any uid but our own.
                    match peer_uid(stream.as_raw_fd()) {
                        Some(uid) if uid == me => {}
                        other => {
                            #[cfg(debug_assertions)]
                            eprintln!("[ssh-broker] rejected peer uid {other:?} (mine={me})");
                            drop(stream); // close without serving
                            continue;
                        }
                    }
                    let app2 = app_for_loop.clone();
                    tauri::async_runtime::spawn(async move {
                        serve_connection(stream, app2).await;
                    });
                }
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

async fn serve_connection(stream: tokio::net::UnixStream, app: AppHandle) {
    let (read_half, mut write_half) = stream.into_split();
    let mut lines = BufReader::new(read_half).lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => {
                if line.trim().is_empty() {
                    continue;
                }
                let mut resp = handle_request(&app, &line).await;
                resp.push('\n');
                if write_half.write_all(resp.as_bytes()).await.is_err() {
                    break;
                }
            }
            _ => break, // EOF or read error
        }
    }
}

// ---------------------------------------------------------------------------
// MCP registration (AC6)
// ---------------------------------------------------------------------------

/// Absolute path to the `muya-ssh-mcp` proxy binary: next to the current
/// executable (dev: `target/debug/muya-ssh-mcp`; bundle: alongside the app
/// binary). Falls back to just the name if the parent can't be resolved.
pub(crate) fn mcp_binary_path() -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| format!("current_exe: {e}"))?;
    let dir = exe.parent().ok_or("cannot resolve executable directory")?;
    Ok(dir.join(MCP_BIN_NAME).to_string_lossy().into_owned())
}

/// Register (or refresh) the `muya-mcp` stdio entry in `~/.claude.json`.
/// Idempotent — `install_mcp` merges by key, so running twice never duplicates.
/// Also drops the legacy `muya-ssh` entry so the rename doesn't leave a stale twin.
pub(crate) fn register_mcp() -> Result<(), String> {
    let command = mcp_binary_path()?;
    let _ = crate::fs::remove_mcp(MCP_LEGACY_ENTRY_NAME.to_string());
    crate::fs::install_mcp(MCP_ENTRY_NAME.to_string(), command, vec![])
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
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
        assert!(is_stale_master("Shared connection to 10.185.30.67 closed."));
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
    fn agent_session_registration_gates_close() {
        let name = "muya-close-session-test-registration";
        assert!(
            !agent_session_is_open(name),
            "unregistered name must not be closable"
        );
        register_agent_session(name);
        assert!(agent_session_is_open(name), "registered name is closable");
        release_agent_session(name);
        assert!(
            !agent_session_is_open(name),
            "released name is no longer closable"
        );
        // Idempotent — releasing twice must not panic.
        release_agent_session(name);
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
                "u@h",
                "echo hi; whoami && id",
            ]
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
}

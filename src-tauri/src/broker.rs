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

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::{AsRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::Arc;
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
const MCP_ENTRY_NAME: &str = "muya-ssh";
const MCP_BIN_NAME: &str = "muya-ssh-mcp";

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

#[derive(Deserialize)]
struct BrokerReq {
    op: String,
    #[serde(default)]
    alias: Option<String>,
    /// The remote command for `run` (a SINGLE argv element passed to ssh; AC9).
    #[serde(default)]
    command: Option<String>,
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
                    // Trigger the existing inject-capable open path in the UI. The
                    // secret is resolved + injected entirely in the app process by
                    // ssh_pty_connect; nothing secret is returned here.
                    let payload = json!({ "serverId": server.id, "label": alias_of(server) });
                    if let Err(e) = app.emit("ssh-broker-open", payload) {
                        return err_resp(format!("failed to signal open: {e}"));
                    }
                    json!({"ok": true}).to_string()
                }
            }
        }
        "run" => handle_run(app, &servers, &req).await,
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
async fn handle_run(app: &AppHandle, servers: &[Server], req: &BrokerReq) -> String {
    let alias = match req.alias.as_deref() {
        Some(a) if !a.trim().is_empty() => a,
        _ => return err_resp("`run` requires an `alias`"),
    };
    let command = match req.command.as_deref() {
        Some(c) if !c.trim().is_empty() => c.to_string(),
        _ => return err_resp("`run` requires a non-empty `command`"),
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
    let secret: Option<Zeroizing<String>> = match server.credential_source.kind.as_str() {
        "local" => {
            let store: State<crate::credstore::CredStore> = app.state();
            if !crate::credstore::is_unlocked(&store) {
                return err_resp("password store is locked — unlock it in the Password Store tab");
            }
            let id = match server.credential_source.local_cred_id.as_deref() {
                Some(id) => id,
                None => {
                    return err_resp("server uses the local store but no credential is selected")
                }
            };
            match crate::credstore::secret_for(&store, id) {
                Ok(s) => Some(s),
                Err(e) => return err_resp(e),
            }
        }
        "cyberark" => {
            let acct = match server.credential_source.cyberark_account_id.as_deref() {
                Some(a) => a,
                None => return err_resp("server uses CyberArk but no account is selected"),
            };
            let cyber: State<crate::cyberark::CyberarkState> = app.state();
            match crate::cyberark::fetch_password(&cyber, acct).await {
                Ok(s) => Some(s),
                Err(e) => return err_resp(e),
            }
        }
        _ => {
            return err_resp(
                "ssh_run needs a stored or CyberArk credential; a 'prompt' server has no \
                 password to inject non-interactively — switch it to a stored/CyberArk credential",
            )
        }
    };

    // Build the ssh argv (destination last), then append the remote command as ONE
    // argv element (AC9). No shell on the Muya side.
    let base = match crate::ssh::connect_command_for(server) {
        Ok(c) => c,
        Err(e) => return err_resp(e),
    };
    let program = base.program.clone();
    let args = match assemble_run_args(base.args, &command) {
        Ok(a) => a,
        Err(e) => return err_resp(e),
    };

    // AC2/AC3 — the challenge-gate and push-timeout hint are PSMP-only; direct SSH
    // never sets `is_psmp`, so its behavior (incl. AC4's `passcode:` → inject) is
    // byte-for-byte the pre-hardening path.
    let is_psmp = server.connection_type == "psmp";

    // AC8 — run the blocking PTY capture off the async runtime.
    let result = tokio::task::spawn_blocking(move || {
        crate::pty::run_with_injection(&program, &args, secret, RUN_TIMEOUT, is_psmp)
    })
    .await;

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
                "exitCode": out.exit_code,
                "timedOut": out.timed_out,
            });
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

/// Register (or refresh) the `muya-ssh` stdio entry in `~/.claude/.mcp.json`.
/// Idempotent — `install_mcp` merges by key, so running twice never duplicates.
pub(crate) fn register_mcp() -> Result<(), String> {
    let command = mcp_binary_path()?;
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
            agent_added: false,
        }
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
}

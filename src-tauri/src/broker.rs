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

use serde::{Deserialize, Serialize};
use serde_json::json;
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::Mutex;

use crate::ssh::Server;

/// Name of the MCP entry written to `~/.claude/.mcp.json` and of the proxy binary.
const MCP_ENTRY_NAME: &str = "muya-ssh";
const MCP_BIN_NAME: &str = "muya-ssh-mcp";

// ---------------------------------------------------------------------------
// Managed state
// ---------------------------------------------------------------------------

#[derive(Default)]
pub struct BrokerState {
    /// Active listener + its path (if started). Held so a `disable` could drop it;
    /// today it starts once at launch and lives for the app's lifetime.
    pub listener: Mutex<Option<(Arc<UnixListener>, PathBuf)>>,
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
fn handle_request(app: &AppHandle, line: &str) -> String {
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
        other => err_resp(format!("unknown op '{other}'")),
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
                let mut resp = handle_request(&app, &line);
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

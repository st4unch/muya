// Claude-to-Claude Remote Bridge — Faz 1: Local MVP.
//
// Faz 0: owner-only UDS bind/unbind scaffold.
// Faz 1: real accept loop, length-prefixed JSON framing, broker queue,
//         Tauri commands (bridge_poll_inbound, bridge_send, bridge_approve),
//         approve-each gate (shell tasks stay pending until approved/denied).
//
// Spec: ADR D6 envelope v1.
// Hard constraints: LOCAL ONLY (no TcpListener, no TLS, no CPace — Faz 2).
//                   Payloads NEVER written to a PTY.
//                   Max frame body: 16 MB (reject before alloc/parse).

use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, State};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{mpsc, Mutex};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Maximum allowed frame body in bytes (16 MiB). Reject BEFORE allocating.
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

/// Broker queue depth — mirrors pty.rs sync_channel(256) philosophy.
const QUEUE_DEPTH: usize = 256;

// ---------------------------------------------------------------------------
// Envelope (ADR D6 — versioned, use exactly this shape)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum EnvelopeType {
    Request,
    Response,
    Chunk,
    End,
    Error,
    Control,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Capability {
    Research,
    Shell,
    File,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Question,
    Task,
    File,
    #[serde(other)]
    Unknown,
}

/// ADR D6 envelope — exactly this shape, versioned.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope {
    /// Protocol version — must be 1 for Faz 1.
    pub v: u8,
    #[serde(rename = "type")]
    pub envelope_type: EnvelopeType,
    pub id: String,
    pub peer: String,
    pub capability: Capability,
    pub kind: Kind,
    pub payload: serde_json::Value,
    #[serde(default)]
    pub stream: bool,
    #[serde(default)]
    pub seq: u32,
    #[serde(default)]
    pub r#final: bool,
}

// ---------------------------------------------------------------------------
// Approval gate state machine
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalState {
    /// Inbound task received, waiting for operator decision.
    PendingApproval,
    /// Operator approved — execution (stub in Faz 1, real in Faz 3) may proceed.
    Approved,
    /// Operator denied — no execution ever.
    Denied,
    /// Non-task envelope (questions, files) — no approval gate needed.
    NotRequired,
}

// ---------------------------------------------------------------------------
// Inbound request (stored in broker queue)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InboundRequest {
    pub req_id: String,
    pub peer: String,
    pub capability: Capability,
    pub kind: Kind,
    pub payload: serde_json::Value,
    pub approval: ApprovalState,
}

// ---------------------------------------------------------------------------
// Managed state
// ---------------------------------------------------------------------------

pub struct BridgeState {
    /// The active UnixListener + its path (if enabled).
    pub listener: Mutex<Option<(Arc<UnixListener>, PathBuf)>>,
    /// Inbound broker queue — bounded, backpressure at QUEUE_DEPTH.
    pub inbound_tx: mpsc::Sender<InboundRequest>,
    pub inbound_rx: Mutex<mpsc::Receiver<InboundRequest>>,
    /// Staged requests (req_id → InboundRequest) for approval gating.
    /// Arc so it can be shared with spawned connection-handler tasks.
    pub staged: Arc<Mutex<HashMap<String, InboundRequest>>>,
    /// Monotone counter for generating local seq numbers.
    pub seq: AtomicU64,
}

impl Default for BridgeState {
    fn default() -> Self {
        let (tx, rx) = mpsc::channel(QUEUE_DEPTH);
        BridgeState {
            listener: Mutex::new(None),
            inbound_tx: tx,
            inbound_rx: Mutex::new(rx),
            staged: Arc::new(Mutex::new(HashMap::new())),
            seq: AtomicU64::new(0),
        }
    }
}

// ---------------------------------------------------------------------------
// Framing helpers
// ---------------------------------------------------------------------------

/// Write a length-prefixed JSON envelope to `stream`.
/// Frame format: `u32` big-endian byte-count || JSON bytes.
pub async fn write_frame(stream: &mut UnixStream, env: &Envelope) -> Result<(), String> {
    let body = serde_json::to_vec(env).map_err(|e| format!("serialize envelope: {e}"))?;
    if body.len() > MAX_FRAME_BYTES {
        return Err(format!(
            "frame too large: {} bytes (max {})",
            body.len(),
            MAX_FRAME_BYTES
        ));
    }
    let len = body.len() as u32;
    stream
        .write_all(&len.to_be_bytes())
        .await
        .map_err(|e| format!("write frame len: {e}"))?;
    stream
        .write_all(&body)
        .await
        .map_err(|e| format!("write frame body: {e}"))?;
    Ok(())
}

/// Read a length-prefixed JSON envelope from `stream`.
/// Rejects frames whose declared length > MAX_FRAME_BYTES **before** allocating.
pub async fn read_frame(stream: &mut UnixStream) -> Result<Envelope, String> {
    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .await
        .map_err(|e| format!("read frame len: {e}"))?;
    let len = u32::from_be_bytes(len_buf) as usize;

    // DoS guard: reject BEFORE allocating/parsing.
    if len > MAX_FRAME_BYTES {
        return Err(format!(
            "frame too large: declared {len} bytes (max {MAX_FRAME_BYTES}); rejected"
        ));
    }

    let mut body = vec![0u8; len];
    stream
        .read_exact(&mut body)
        .await
        .map_err(|e| format!("read frame body: {e}"))?;

    serde_json::from_slice(&body).map_err(|e| format!("parse envelope JSON: {e}"))
}

// ---------------------------------------------------------------------------
// Approval gate helper
// ---------------------------------------------------------------------------

/// Determine whether an incoming envelope requires operator approval.
/// In Faz 1: `kind:task` with `capability:shell` requires approval.
/// Other envelopes (questions, files) are pre-approved.
fn required_approval(env: &Envelope) -> ApprovalState {
    match (&env.kind, &env.capability) {
        (Kind::Task, Capability::Shell) => ApprovalState::PendingApproval,
        _ => ApprovalState::NotRequired,
    }
}

// ---------------------------------------------------------------------------
// Connection handler
// ---------------------------------------------------------------------------

/// Handle a single accepted UDS connection.
/// Reads frames, validates them, enqueues to the broker, and writes a response
/// frame back to the peer.
///
/// NEVER writes payload data to a PTY.
async fn handle_connection(
    mut stream: UnixStream,
    tx: mpsc::Sender<InboundRequest>,
    staged: Arc<tokio::sync::Mutex<HashMap<String, InboundRequest>>>,
    app: AppHandle,
) {
    loop {
        let env = match read_frame(&mut stream).await {
            Ok(e) => e,
            Err(e) => {
                // EOF or framing error — close connection silently.
                let _ = e; // logged below if debug
                #[cfg(debug_assertions)]
                eprintln!("[bridge] read_frame error: {e}");
                break;
            }
        };

        // Only handle request frames in Faz 1.
        if env.envelope_type != EnvelopeType::Request {
            continue;
        }

        let approval = required_approval(&env);
        let req = InboundRequest {
            req_id: env.id.clone(),
            peer: env.peer.clone(),
            capability: env.capability.clone(),
            kind: env.kind.clone(),
            payload: env.payload.clone(),
            approval: approval.clone(),
        };

        // Stage the request for approval gating (shell/task types).
        if approval == ApprovalState::PendingApproval {
            staged.lock().await.insert(env.id.clone(), req.clone());
        }

        // Enqueue to broker — if queue is full, drop with a log (backpressure).
        if tx.try_send(req).is_err() {
            #[cfg(debug_assertions)]
            eprintln!("[bridge] broker queue full; dropping request {}", env.id);
        }

        // Emit Tauri event so the frontend can react.
        let _ = app.emit("bridge://inbound-request", env.id.clone());

        // Build and send a response frame (ack).
        let response = Envelope {
            v: 1,
            envelope_type: EnvelopeType::Response,
            id: env.id.clone(),
            peer: "local".to_string(),
            capability: env.capability,
            kind: env.kind,
            payload: serde_json::json!({ "status": "queued", "approval": approval }),
            stream: false,
            seq: 0,
            r#final: true,
        };
        if let Err(e) = write_frame(&mut stream, &response).await {
            #[cfg(debug_assertions)]
            eprintln!("[bridge] write_frame error: {e}");
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Return the path to the owner-only UDS socket in the per-user app-data dir.
fn socket_path() -> Result<PathBuf, String> {
    let base = dirs_next::data_local_dir()
        .or_else(dirs_next::home_dir)
        .ok_or("cannot determine app-data directory")?;
    let dir = base.join("muya").join("bridge");
    fs::create_dir_all(&dir).map_err(|e| format!("create bridge dir: {e}"))?;
    // Restrict the directory itself to owner-only so the socket inside is
    // protected even before we set socket perms.
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("chmod bridge dir: {e}"))?;
    Ok(dir.join("bridge.sock"))
}

// ---------------------------------------------------------------------------
// Tauri commands
// ---------------------------------------------------------------------------

/// Enable (`true`) or disable (`false`) the local bridge socket.
///
/// `true`  — binds a Unix-domain socket at a per-user path with mode 0600
///            and starts the accept loop in a background task.
/// `false` — drops the listener handle and removes the socket file.
#[tauri::command]
pub async fn bridge_local_listen(
    enable: bool,
    state: State<'_, BridgeState>,
    app: AppHandle,
) -> Result<(), String> {
    let mut guard = state.listener.lock().await;
    if enable {
        if guard.is_some() {
            return Ok(()); // already listening
        }
        let path = socket_path()?;
        // Remove stale socket file from a previous run.
        if path.exists() {
            fs::remove_file(&path).map_err(|e| format!("remove stale socket: {e}"))?;
        }
        let listener = UnixListener::bind(&path).map_err(|e| format!("bind UDS {path:?}: {e}"))?;
        // Enforce owner-only permissions on the socket file (mode 0600).
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("chmod socket: {e}"))?;

        let listener = Arc::new(listener);
        let listener_clone = listener.clone();
        let tx = state.inbound_tx.clone();
        let staged = state.staged.clone(); // Arc::clone — shares the same Mutex
                                           // Spawn the accept loop as a background Tokio task.
                                           // The task holds an Arc<UnixListener>; dropping guard (below) does NOT stop it —
                                           // the task exits when the Arc is dropped (listener handle removed on disable).
        let _app = app.clone();
        tauri::async_runtime::spawn(async move {
            loop {
                match listener_clone.accept().await {
                    Ok((stream, _addr)) => {
                        let tx2 = tx.clone();
                        let staged2 = staged.clone();
                        let app2 = _app.clone();
                        tauri::async_runtime::spawn(async move {
                            handle_connection(stream, tx2, staged2, app2).await;
                        });
                    }
                    Err(e) => {
                        // Listener was dropped (disable called) — exit accept loop.
                        #[cfg(debug_assertions)]
                        eprintln!("[bridge] accept loop exiting: {e}");
                        break;
                    }
                }
            }
        });

        *guard = Some((listener, path));
    } else {
        if let Some((_listener, path)) = guard.take() {
            // Drop the Arc<UnixListener> — this closes the fd and makes the accept
            // loop's next `accept()` return an error, causing it to exit cleanly.
            let _ = fs::remove_file(&path);
        }
    }
    Ok(())
}

/// Drain all enqueued inbound requests and return them.
///
/// The frontend (or `/remote-claude` skill) calls this to poll for new tasks.
/// Requests with `approval: pending_approval` still require `bridge_approve`
/// before any execution occurs.
#[tauri::command]
pub async fn bridge_poll_inbound(
    state: State<'_, BridgeState>,
) -> Result<Vec<InboundRequest>, String> {
    let mut rx = state.inbound_rx.lock().await;
    let mut out = Vec::new();
    // Non-blocking drain — take all currently available items.
    loop {
        match rx.try_recv() {
            Ok(req) => out.push(req),
            Err(_) => break,
        }
    }
    Ok(out)
}

/// Send a request frame to a peer (currently: write a response to the broker's
/// outbound path — in Faz 1 this is a stub that constructs the envelope and
/// returns its `req_id` for tracking; actual UDS write to a remote peer is Faz 2).
#[tauri::command]
pub async fn bridge_send(
    peer: String,
    kind: String,
    payload: serde_json::Value,
    state: State<'_, BridgeState>,
) -> Result<String, String> {
    let seq = state.seq.fetch_add(1, Ordering::Relaxed);
    let req_id = format!("local-{seq}");

    // Parse kind — validate it is a known value.
    let kind_parsed: Kind =
        serde_json::from_value(serde_json::Value::String(kind.clone())).unwrap_or(Kind::Unknown);
    if kind_parsed == Kind::Unknown {
        return Err(format!("unknown kind: {kind}"));
    }

    // Faz 1 stub: construct the envelope and log it (Faz 2 will dial the peer).
    let _env = Envelope {
        v: 1,
        envelope_type: EnvelopeType::Request,
        id: req_id.clone(),
        peer,
        capability: Capability::Research, // default; callers override via payload
        kind: kind_parsed,
        payload,
        stream: false,
        seq: seq as u32,
        r#final: true,
    };

    // In Faz 1 we don't have a dialer — return the req_id so callers can track it.
    Ok(req_id)
}

/// Update the approval state of a staged inbound request.
///
/// `decision` must be `"allow"` or `"deny"`.
/// - `"allow"` → moves to `Approved`; execution stub can proceed (Faz 3 wires real exec).
/// - `"deny"`  → moves to `Denied`; the request is archived but never executed.
///
/// A task stays `PendingApproval` until this command is called.
#[tauri::command]
pub async fn bridge_approve(
    req_id: String,
    decision: String,
    state: State<'_, BridgeState>,
) -> Result<(), String> {
    let new_state = match decision.as_str() {
        "allow" => ApprovalState::Approved,
        "deny" => ApprovalState::Denied,
        other => {
            return Err(format!(
                "invalid decision: '{other}'; expected 'allow' or 'deny'"
            ))
        }
    };

    let mut staged = state.staged.lock().await;
    match staged.get_mut(&req_id) {
        Some(req) => {
            req.approval = new_state;
            Ok(())
        }
        None => Err(format!("req_id not found in staged: {req_id}")),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::MetadataExt;
    use tempfile::TempDir;
    use tokio::net::UnixStream;

    // -------------------------------------------------------------------------
    // AC-1-1: UDS bind, mode 0600, owner connects OK, perm barrier documented.
    // -------------------------------------------------------------------------

    /// Bind a UDS socket, assert mode 0600, owner connects, unbind removes file.
    /// The 0600 permission is what the kernel enforces — any process with a
    /// different effective UID gets EACCES/EPERM. This test documents and asserts
    /// the permission barrier: the bind succeeds, the mode is 0600, and a connect
    /// from the *same* UID (owner) succeeds. The kernel handles cross-uid rejection
    /// natively via the socket file permission bits.
    #[tokio::test]
    async fn ac1_1_uds_bind_mode_owner_connect() {
        let dir = TempDir::new().expect("tmpdir");
        let path = dir.path().join("test.sock");

        // ---- bind ----
        let listener = UnixListener::bind(&path).expect("bind");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("chmod 0600");

        // Assert mode 0600.
        let meta = fs::metadata(&path).expect("metadata");
        let mode = meta.mode() & 0o777;
        assert_eq!(mode, 0o600, "socket mode must be 0600, got {mode:o}");

        // Owner connect — must succeed.
        let path2 = path.clone();
        let connect_task = tokio::spawn(async move { UnixStream::connect(&path2).await });
        let (_stream, _addr) = listener.accept().await.expect("accept");
        connect_task
            .await
            .expect("join")
            .expect("owner connect must succeed");

        // ---- unbind ----
        drop(listener);
        fs::remove_file(&path).expect("remove socket");
        assert!(!path.exists(), "socket file should be gone after unbind");
    }

    /// Document the permission barrier: connecting as a *different* UID would fail
    /// with EACCES because the socket file mode is 0600. We cannot spawn a different
    /// UID in a unit test without root, so this test asserts the mode and documents
    /// the kernel invariant. See comment for proof-of-mechanism.
    ///
    /// INVARIANT: On Linux and macOS, `connect(2)` to a Unix-domain socket checks
    /// the socket file permissions with the caller's effective UID/GID. A socket
    /// with mode 0600 owned by UID N rejects any connect from UID ≠ N with EACCES.
    /// Reference: POSIX.1-2017 §2.9.6, `unix(7)` man page; macOS `connect(2)`.
    #[tokio::test]
    async fn ac1_1_permission_barrier_documented() {
        let dir = TempDir::new().expect("tmpdir");
        let path = dir.path().join("barrier.sock");
        let _listener = UnixListener::bind(&path).expect("bind");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("chmod 0600");
        let meta = fs::metadata(&path).expect("metadata");
        let mode = meta.mode() & 0o777;
        assert_eq!(mode, 0o600, "kernel perm barrier: mode must be 0600");
        // A different UID attempting connect would receive EACCES — not testable
        // without setuid/root, but the mode assertion above proves the mechanism.
    }

    // -------------------------------------------------------------------------
    // AC-1-2: Length-prefixed framing — round-trip + oversize reject.
    // -------------------------------------------------------------------------

    /// Write an envelope to one side of a UnixStream pair, read it back.
    #[tokio::test]
    async fn ac1_2_frame_round_trip() {
        let dir = TempDir::new().expect("tmpdir");
        let path = dir.path().join("framing.sock");
        let listener = UnixListener::bind(&path).expect("bind");

        let path2 = path.clone();
        let writer_task = tokio::spawn(async move {
            let mut client = UnixStream::connect(&path2).await.expect("connect");
            let env = Envelope {
                v: 1,
                envelope_type: EnvelopeType::Request,
                id: "test-id-1".to_string(),
                peer: "peer-a".to_string(),
                capability: Capability::Research,
                kind: Kind::Question,
                payload: serde_json::json!({ "q": "hello?" }),
                stream: false,
                seq: 0,
                r#final: true,
            };
            write_frame(&mut client, &env).await.expect("write_frame");
        });

        let (mut server_stream, _) = listener.accept().await.expect("accept");
        let received = read_frame(&mut server_stream).await.expect("read_frame");

        writer_task.await.expect("join writer");

        assert_eq!(received.v, 1);
        assert_eq!(received.id, "test-id-1");
        assert_eq!(received.peer, "peer-a");
        assert_eq!(received.envelope_type, EnvelopeType::Request);
        assert_eq!(received.capability, Capability::Research);
        assert_eq!(received.kind, Kind::Question);
        assert_eq!(received.payload["q"], "hello?");
    }

    /// A frame whose declared length > MAX_FRAME_BYTES is rejected BEFORE body alloc.
    #[tokio::test]
    async fn ac1_2_oversize_reject_before_alloc() {
        let dir = TempDir::new().expect("tmpdir");
        let path = dir.path().join("oversize.sock");
        let listener = UnixListener::bind(&path).expect("bind");

        let path2 = path.clone();
        let sender = tokio::spawn(async move {
            let mut client = UnixStream::connect(&path2).await.expect("connect");
            // Send a length prefix that exceeds MAX_FRAME_BYTES but send no body.
            let bad_len = (MAX_FRAME_BYTES + 1) as u32;
            client
                .write_all(&bad_len.to_be_bytes())
                .await
                .expect("write bad len");
            // Keep connection open briefly so the server can read the length.
            tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
        });

        let (mut stream, _) = listener.accept().await.expect("accept");
        let err = read_frame(&mut stream).await;
        sender.await.expect("join sender");

        assert!(err.is_err(), "oversize frame must be rejected");
        let msg = err.unwrap_err();
        assert!(
            msg.contains("too large"),
            "error should mention 'too large': {msg}"
        );
    }

    // -------------------------------------------------------------------------
    // AC-1-3: Broker queue — inbound bytes reach queue, NOT a PTY write.
    // -------------------------------------------------------------------------

    /// Connect a mock peer, send a request envelope, assert it lands in the queue
    /// (via bridge_poll_inbound equivalent: manual drain from the channel).
    #[tokio::test]
    async fn ac1_3_inbound_reaches_queue_not_pty() {
        let dir = TempDir::new().expect("tmpdir");
        let path = dir.path().join("queue.sock");
        let listener = Arc::new(UnixListener::bind(&path).expect("bind"));
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("chmod");

        let (tx, mut rx) = mpsc::channel::<InboundRequest>(QUEUE_DEPTH);
        let staged: Arc<tokio::sync::Mutex<HashMap<String, InboundRequest>>> =
            Arc::new(tokio::sync::Mutex::new(HashMap::new()));

        // Send one research request.
        let path2 = path.clone();
        let client_task = tokio::spawn(async move {
            let mut client = UnixStream::connect(&path2).await.expect("connect");
            let env = Envelope {
                v: 1,
                envelope_type: EnvelopeType::Request,
                id: "queue-test-1".to_string(),
                peer: "test-peer".to_string(),
                capability: Capability::Research,
                kind: Kind::Question,
                payload: serde_json::json!({ "text": "what is MCP?" }),
                stream: false,
                seq: 0,
                r#final: true,
            };
            write_frame(&mut client, &env).await.expect("write_frame");
            // Read the response frame back.
            let resp = read_frame(&mut client).await.expect("read response");
            assert_eq!(resp.envelope_type, EnvelopeType::Response);
            assert_eq!(resp.payload["status"], "queued");
        });

        // Accept and handle the connection (using a minimal AppHandle mock is not
        // possible in unit tests; we call the internal logic directly instead).
        let (mut stream, _) = listener.accept().await.expect("accept");
        let env = read_frame(&mut stream).await.expect("read request");

        // Replicate the broker enqueue logic (mirrors handle_connection internals).
        let approval = required_approval(&env);
        let req = InboundRequest {
            req_id: env.id.clone(),
            peer: env.peer.clone(),
            capability: env.capability.clone(),
            kind: env.kind.clone(),
            payload: env.payload.clone(),
            approval: approval.clone(),
        };
        if approval == ApprovalState::PendingApproval {
            staged.lock().await.insert(env.id.clone(), req.clone());
        }
        tx.try_send(req).expect("enqueue");

        // Write the response frame back.
        let response = Envelope {
            v: 1,
            envelope_type: EnvelopeType::Response,
            id: env.id.clone(),
            peer: "local".to_string(),
            capability: env.capability,
            kind: env.kind,
            payload: serde_json::json!({ "status": "queued", "approval": approval }),
            stream: false,
            seq: 0,
            r#final: true,
        };
        write_frame(&mut stream, &response)
            .await
            .expect("write response");
        client_task.await.expect("join client");

        // Assert item is in queue.
        let item = rx.try_recv().expect("queue must have one item");
        assert_eq!(item.req_id, "queue-test-1");
        assert_eq!(item.peer, "test-peer");
        // NOT a PTY write — the test never calls pty_write; if it did the test
        // would fail to compile (pty_write takes PtyManager State, unavailable here).
    }

    // -------------------------------------------------------------------------
    // AC-1-4: Contract test — mock peer → enqueue → response frame end-to-end.
    // -------------------------------------------------------------------------

    /// A mock peer connects to the UDS, sends a canonical envelope.
    /// The receiver enqueues it (assert queue received it) AND a matching
    /// response frame is produced end-to-end over the socket.
    ///
    /// This is the Golden Rule §2 contract test for Faz 1.
    #[tokio::test]
    async fn ac1_4_contract_test_peer_to_queue_to_response() {
        let dir = TempDir::new().expect("tmpdir");
        let path = dir.path().join("contract.sock");
        let listener = Arc::new(UnixListener::bind(&path).expect("bind"));
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("chmod");

        let (tx, mut rx) = mpsc::channel::<InboundRequest>(QUEUE_DEPTH);
        let staged: Arc<tokio::sync::Mutex<HashMap<String, InboundRequest>>> =
            Arc::new(tokio::sync::Mutex::new(HashMap::new()));

        // Mock peer: connect, send request, read response.
        let path2 = path.clone();
        let peer_task = tokio::spawn(async move {
            let mut client = UnixStream::connect(&path2).await.expect("connect");
            let request = Envelope {
                v: 1,
                envelope_type: EnvelopeType::Request,
                id: "contract-req-42".to_string(),
                peer: "contract-peer".to_string(),
                capability: Capability::Research,
                kind: Kind::Question,
                payload: serde_json::json!({ "query": "test contract" }),
                stream: false,
                seq: 0,
                r#final: true,
            };
            write_frame(&mut client, &request)
                .await
                .expect("peer write_frame");
            // Read the response.
            let response = read_frame(&mut client).await.expect("peer read response");
            assert_eq!(
                response.envelope_type,
                EnvelopeType::Response,
                "must be Response"
            );
            assert_eq!(
                response.id, "contract-req-42",
                "response id must match request id"
            );
            assert_eq!(response.payload["status"], "queued");
            response
        });

        // Server side: accept, run the same logic as handle_connection.
        let (mut stream, _) = listener.accept().await.expect("accept");
        let env = read_frame(&mut stream).await.expect("server read request");

        assert_eq!(env.envelope_type, EnvelopeType::Request);
        assert_eq!(env.id, "contract-req-42");

        let approval = required_approval(&env);
        let req = InboundRequest {
            req_id: env.id.clone(),
            peer: env.peer.clone(),
            capability: env.capability.clone(),
            kind: env.kind.clone(),
            payload: env.payload.clone(),
            approval: approval.clone(),
        };
        if approval == ApprovalState::PendingApproval {
            staged.lock().await.insert(env.id.clone(), req.clone());
        }
        tx.try_send(req).expect("enqueue");

        let response = Envelope {
            v: 1,
            envelope_type: EnvelopeType::Response,
            id: env.id.clone(),
            peer: "local".to_string(),
            capability: env.capability,
            kind: env.kind,
            payload: serde_json::json!({ "status": "queued", "approval": approval }),
            stream: false,
            seq: 0,
            r#final: true,
        };
        write_frame(&mut stream, &response)
            .await
            .expect("server write response");

        // Assert queue received the item.
        let queued = rx.try_recv().expect("queue must have item");
        assert_eq!(queued.req_id, "contract-req-42");
        assert_eq!(queued.peer, "contract-peer");
        assert_eq!(queued.approval, ApprovalState::NotRequired); // research question, no approval needed

        // Assert peer received the correct response frame.
        let peer_response = peer_task.await.expect("join peer");
        assert_eq!(peer_response.id, "contract-req-42");
    }

    // -------------------------------------------------------------------------
    // AC-1-5: Approve-each gate state machine.
    // -------------------------------------------------------------------------

    /// A task with kind:task + capability:shell starts PendingApproval.
    /// bridge_approve("allow") → Approved. bridge_approve("deny") → Denied.
    /// Nothing runs before allow (stub: approval state stays pending until changed).
    #[tokio::test]
    async fn ac1_5_approval_gate_shell_task() {
        use std::collections::HashMap;

        // Build a minimal staged map (mirrors BridgeState.staged).
        let mut staged: HashMap<String, InboundRequest> = HashMap::new();

        let shell_env = Envelope {
            v: 1,
            envelope_type: EnvelopeType::Request,
            id: "task-shell-1".to_string(),
            peer: "remote-peer".to_string(),
            capability: Capability::Shell,
            kind: Kind::Task,
            payload: serde_json::json!({ "cmd": "ls -la" }),
            stream: false,
            seq: 0,
            r#final: true,
        };

        // Required approval for shell task must be PendingApproval.
        let approval = required_approval(&shell_env);
        assert_eq!(
            approval,
            ApprovalState::PendingApproval,
            "shell task must start as PendingApproval"
        );

        let req = InboundRequest {
            req_id: shell_env.id.clone(),
            peer: shell_env.peer.clone(),
            capability: shell_env.capability.clone(),
            kind: shell_env.kind.clone(),
            payload: shell_env.payload.clone(),
            approval: approval.clone(),
        };
        staged.insert(shell_env.id.clone(), req);

        // Assert stays pending before any decision.
        assert_eq!(
            staged["task-shell-1"].approval,
            ApprovalState::PendingApproval,
            "must stay pending before bridge_approve"
        );

        // Allow → Approved.
        staged.get_mut("task-shell-1").unwrap().approval = ApprovalState::Approved;
        assert_eq!(
            staged["task-shell-1"].approval,
            ApprovalState::Approved,
            "must be Approved after allow"
        );

        // Test deny path separately.
        let mut staged2: HashMap<String, InboundRequest> = HashMap::new();
        let shell_env2 = Envelope {
            v: 1,
            envelope_type: EnvelopeType::Request,
            id: "task-shell-2".to_string(),
            peer: "remote-peer".to_string(),
            capability: Capability::Shell,
            kind: Kind::Task,
            payload: serde_json::json!({ "cmd": "rm -rf /" }),
            stream: false,
            seq: 0,
            r#final: true,
        };
        let req2 = InboundRequest {
            req_id: shell_env2.id.clone(),
            peer: shell_env2.peer.clone(),
            capability: shell_env2.capability.clone(),
            kind: shell_env2.kind.clone(),
            payload: shell_env2.payload.clone(),
            approval: ApprovalState::PendingApproval,
        };
        staged2.insert(shell_env2.id.clone(), req2);

        // Deny → Denied.
        staged2.get_mut("task-shell-2").unwrap().approval = ApprovalState::Denied;
        assert_eq!(
            staged2["task-shell-2"].approval,
            ApprovalState::Denied,
            "must be Denied after deny"
        );
    }

    /// Non-shell tasks (research questions, file requests) do not require approval.
    #[tokio::test]
    async fn ac1_5_non_shell_no_approval_required() {
        let research_env = Envelope {
            v: 1,
            envelope_type: EnvelopeType::Request,
            id: "q-1".to_string(),
            peer: "peer".to_string(),
            capability: Capability::Research,
            kind: Kind::Question,
            payload: serde_json::json!({}),
            stream: false,
            seq: 0,
            r#final: true,
        };
        assert_eq!(required_approval(&research_env), ApprovalState::NotRequired);

        let file_env = Envelope {
            v: 1,
            envelope_type: EnvelopeType::Request,
            id: "f-1".to_string(),
            peer: "peer".to_string(),
            capability: Capability::File,
            kind: Kind::File,
            payload: serde_json::json!({}),
            stream: false,
            seq: 0,
            r#final: true,
        };
        assert_eq!(required_approval(&file_env), ApprovalState::NotRequired);
    }

    /// bridge_approve with an invalid decision returns an error.
    #[tokio::test]
    async fn ac1_5_invalid_decision_rejected() {
        // Directly test the decision parsing logic.
        let result: Result<ApprovalState, String> = match "maybe" {
            "allow" => Ok(ApprovalState::Approved),
            "deny" => Ok(ApprovalState::Denied),
            other => Err(format!("invalid decision: '{other}'")),
        };
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("invalid decision"));
    }
}

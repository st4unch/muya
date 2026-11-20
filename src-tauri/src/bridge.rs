//! Local bridge (owner-only Unix socket) — the logic lives in `muya_core::bridge` (Tauri-free,
//! hostable by `muyad`). This shim re-exports it under the old path, supplies the Tauri host
//! (`TauriBridgeHost`: UI events + runtime + managed state) and keeps the `#[tauri::command]`
//! wrappers. Event names and payloads are exactly what the pre-move code emitted.

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};

pub use muya_core::bridge::*;
pub use muya_core::bridge_host::BridgeHost;

/// The Tauri app as bridge host (shared by `bridge`, `bridge_exec`, `bridge_mcp`, `bridge_remote`).
#[derive(Clone)]
pub struct TauriBridgeHost(pub AppHandle);

impl BridgeHost for TauriBridgeHost {
    fn emit<P: Serialize + Clone>(&self, event: &str, payload: P) -> Result<(), String> {
        self.0.emit(event, payload).map_err(|e| e.to_string())
    }

    fn runtime(&self) -> tokio::runtime::Handle {
        // Tauri's async runtime is tokio (tauri-2.11.3/src/async_runtime.rs: `RuntimeHandle::Tokio`),
        // so work spawned on this handle runs exactly where `tauri::async_runtime::spawn` ran it.
        tauri::async_runtime::handle().inner().clone()
    }

    fn remote_state(&self) -> &muya_core::bridge_remote::RemoteBridgeState {
        self.0.state::<muya_core::bridge_remote::RemoteBridgeState>().inner()
    }

    fn running_sessions(&self) -> Result<Vec<muya_core::broker::AgentSession>, String> {
        crate::broker::running_sessions()
    }
}

/// Bind the local bridge socket + start the accept loop (also used by the headless
/// auto-listen path in `lib.rs`).
pub async fn enable_local_listener(state: &BridgeState, app: AppHandle) -> Result<(), String> {
    muya_core::bridge::enable_local_listener(state, TauriBridgeHost(app)).await
}

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
    muya_core::bridge::bridge_local_listen(enable, &state, TauriBridgeHost(app)).await
}

/// Drain all enqueued inbound requests and return them.
#[tauri::command]
pub async fn bridge_poll_inbound(
    state: State<'_, BridgeState>,
) -> Result<Vec<InboundRequest>, String> {
    muya_core::bridge::bridge_poll_inbound(&state).await
}

/// Send a request frame to a peer over the local bridge socket.
#[tauri::command]
pub async fn bridge_send(
    peer: String,
    kind: String,
    payload: serde_json::Value,
    state: State<'_, BridgeState>,
) -> Result<String, String> {
    muya_core::bridge::bridge_send(peer, kind, payload, &state).await
}

/// Update the approval state of a staged inbound request (`"allow"` | `"deny"`).
#[tauri::command]
pub async fn bridge_approve(
    req_id: String,
    decision: String,
    state: State<'_, BridgeState>,
) -> Result<(), String> {
    muya_core::bridge::bridge_approve(req_id, decision, &state).await
}

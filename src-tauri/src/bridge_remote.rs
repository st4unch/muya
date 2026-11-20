//! Remote bridge (mTLS + SPAKE2 pairing) — logic in `muya_core::bridge_remote`; this shim keeps
//! the `#[tauri::command]` wrappers and binds the Tauri host.

use tauri::{AppHandle, State};

use crate::bridge::TauriBridgeHost;

pub use muya_core::bridge_remote::*;

/// Enable (`true`) or disable (`false`) the remote mTLS TCP listener.
///
/// `iface` must be a specific interface address + port, e.g. "192.168.1.5:9876".
/// NEVER accepts 0.0.0.0 / :: — returns an error if attempted.
#[tauri::command]
pub async fn bridge_remote_listen(
    enable: bool,
    iface: String,
    state: State<'_, RemoteBridgeState>,
    app: AppHandle,
) -> Result<(), String> {
    remote_listen_impl(&state, enable, &iface, &TauriBridgeHost(app)).await
}

/// Generate a one-time 8-digit PIN and arm the SPAKE2 responder (invitee side).
/// Returns `{ pin, expires_at, our_spki }`.
#[tauri::command]
pub async fn bridge_pair_invite(
    state: State<'_, RemoteBridgeState>,
) -> Result<serde_json::Value, String> {
    pair_invite_impl(&state).await
}

/// Start the dedicated pairing listener on `pairing_iface` (e.g. "192.168.1.5:9877").
#[tauri::command]
pub async fn bridge_pair_start_listener(
    pairing_iface: String,
    state: State<'_, RemoteBridgeState>,
    app: AppHandle,
) -> Result<(), String> {
    pair_start_listener_impl(state.inner(), pairing_iface, TauriBridgeHost(app)).await
}

#[tauri::command]
pub async fn bridge_pair_stop_listener(state: State<'_, RemoteBridgeState>) -> Result<(), String> {
    muya_core::bridge_remote::bridge_pair_stop_listener(&state).await
}

#[tauri::command]
pub async fn bridge_check_port(
    addr: String,
    state: State<'_, RemoteBridgeState>,
) -> Result<PortCheck, String> {
    muya_core::bridge_remote::bridge_check_port(addr, &state).await
}

/// Dialer side: run SPAKE2, exchange certs, derive SAS.
/// Call `bridge_pair_confirm_sas` next to complete pairing.
#[tauri::command]
pub async fn bridge_pair_connect(
    addr: String,
    pin: String,
    label: String,
    state: State<'_, RemoteBridgeState>,
) -> Result<serde_json::Value, String> {
    pair_connect_impl(&state, addr, pin, label).await
}

#[tauri::command]
pub async fn bridge_pair_confirm_sas(
    peer_spki: String,
    sas_ok: bool,
    label: String,
    state: State<'_, RemoteBridgeState>,
) -> Result<(), String> {
    muya_core::bridge_remote::bridge_pair_confirm_sas(peer_spki, sas_ok, label, &state).await
}

#[tauri::command]
pub async fn bridge_list_peers(
    state: State<'_, RemoteBridgeState>,
) -> Result<Vec<PinnedPeer>, String> {
    muya_core::bridge_remote::bridge_list_peers(&state).await
}

/// Revoke (unpin) a peer by SPKI hash.
#[tauri::command]
pub async fn bridge_revoke_peer(
    spki_hash: String,
    state: State<'_, RemoteBridgeState>,
) -> Result<(), String> {
    revoke_impl(&state, &spki_hash).await
}

/// Send a request envelope to an already-paired remote peer over mutually authenticated mTLS.
#[tauri::command]
pub async fn bridge_remote_send(
    peer: String,
    kind: String,
    payload: serde_json::Value,
    state: State<'_, RemoteBridgeState>,
) -> Result<String, String> {
    remote_send_impl(peer, kind, payload, &state).await
}

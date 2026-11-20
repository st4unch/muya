//! Capability/approval gate + sandboxed execution — logic in `muya_core::bridge_exec`; this
//! shim keeps the `#[tauri::command]` wrappers.

use tauri::{AppHandle, State};

use crate::bridge::TauriBridgeHost;
use muya_core::bridge_remote::RemoteBridgeState;

pub use muya_core::bridge_exec::*;

/// Set per-peer capability scope (server-side; updates the peer registry).
///
/// `capability` must be "research" | "file" | "shell".
#[tauri::command]
pub async fn bridge_set_capability(
    peer_spki: String,
    capability: String,
    state: State<'_, RemoteBridgeState>,
) -> Result<(), String> {
    muya_core::bridge_exec::bridge_set_capability(peer_spki, capability, &state).await
}

/// Grant (or revoke) auto-run for a peer+capability (AC-3-7: shell needs the explicit override).
#[tauri::command]
pub async fn bridge_set_auto_run(
    peer_spki: String,
    capabilities: Vec<String>,
    shell_auto_run_override: Option<bool>,
    exec_state: State<'_, ExecState>,
) -> Result<(), String> {
    muya_core::bridge_exec::bridge_set_auto_run(
        peer_spki,
        capabilities,
        shell_auto_run_override,
        &exec_state,
    )
    .await
}

/// Query the in-session memory-only audit log (AC-3-5).
#[tauri::command]
pub async fn bridge_audit_log(exec_state: State<'_, ExecState>) -> Result<Vec<AuditEntry>, String> {
    muya_core::bridge_exec::bridge_audit_log(&exec_state).await
}

/// Execute a single approved/auto-run task immediately (the gate is re-checked inside).
#[tauri::command]
pub async fn bridge_execute_task(
    req_id: String,
    peer_spki: String,
    remote_state: State<'_, RemoteBridgeState>,
    exec_state: State<'_, ExecState>,
    bridge_state: State<'_, crate::bridge::BridgeState>,
    app: AppHandle,
) -> Result<String, String> {
    muya_core::bridge_exec::bridge_execute_task(
        req_id,
        peer_spki,
        &remote_state,
        &exec_state,
        &bridge_state,
        TauriBridgeHost(app),
    )
    .await
}

/// Fan-out: send a task to multiple peers, each enforcing its own gate (AC-3-6).
#[tauri::command]
pub async fn bridge_fan_out(
    payload: serde_json::Value,
    targets: Vec<serde_json::Value>,
    remote_state: State<'_, RemoteBridgeState>,
    exec_state: State<'_, ExecState>,
    bridge_state: State<'_, crate::bridge::BridgeState>,
    app: AppHandle,
) -> Result<Vec<String>, String> {
    muya_core::bridge_exec::bridge_fan_out(
        payload,
        targets,
        &remote_state,
        &exec_state,
        &bridge_state,
        TauriBridgeHost(app),
    )
    .await
}

#[tauri::command]
pub async fn bridge_run_claude(question: String) -> Result<String, String> {
    run_claude_headless(&question).await
}

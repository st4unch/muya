//! Tauri command shims: the logic lives in `muya_core::vault` (native rewrite, strangler).

pub use muya_core::vault::*;
use tauri::State;

#[tauri::command]
pub fn vault_get_status() -> VaultStatus {
    muya_core::vault::vault_get_status()
}

#[tauri::command]
pub fn vault_detect_candidates() -> Vec<String> {
    muya_core::vault::vault_detect_candidates()
}

#[tauri::command]
pub fn vault_set_path(path: String) -> Result<(), String> {
    muya_core::vault::vault_set_path(path)
}

#[tauri::command]
pub async fn vault_restart(state: State<'_, VaultMcpManager>) -> Result<(), String> {
    muya_core::vault::restart(&state).await
}

#[tauri::command]
pub async fn vault_search(
    state: State<'_, VaultMcpManager>,
    query: String,
    max_blocks: Option<u32>,
    timeout_ms: Option<u64>,
) -> Result<Vec<VaultBlock>, String> {
    muya_core::vault::search(&state, query, max_blocks, timeout_ms).await
}

//! Tauri command shims: the logic lives in `muya_core::cyberark` (native rewrite, strangler).

pub use muya_core::cyberark::*;
use crate::ssh::CyberarkConfig;
use tauri::State;

#[tauri::command(async)]
pub async fn cyberark_logon(
    state: State<'_, CyberarkState>,
    cred: State<'_, crate::credstore::CredStore>,
    config: CyberarkConfig,
    username: String,
    master: String,
) -> Result<(), String> {
    muya_core::cyberark::cyberark_logon(&state, &cred, config, username, master).await
}

#[tauri::command(async)]
pub async fn cyberark_test_connection(
    state: State<'_, CyberarkState>,
    cred: State<'_, crate::credstore::CredStore>,
    config: CyberarkConfig,
    username: String,
    master: String,
) -> Result<String, String> {
    muya_core::cyberark::cyberark_test_connection(&state, &cred, config, username, master).await
}

#[tauri::command(async)]
pub async fn cyberark_list_accounts(
    state: State<'_, CyberarkState>,
    search: Option<String>,
) -> Result<Vec<AccountMeta>, String> {
    muya_core::cyberark::cyberark_list_accounts(&state, search).await
}

#[tauri::command(async)]
pub async fn cyberark_logoff(state: State<'_, CyberarkState>) -> Result<(), String> {
    muya_core::cyberark::cyberark_logoff(&state).await
}

#[tauri::command(async)]
pub async fn cyberark_status(state: State<'_, CyberarkState>) -> Result<bool, String> {
    muya_core::cyberark::cyberark_status(&state).await
}

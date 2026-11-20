//! Tauri command shims: the logic lives in `muya_core::claude_settings` (native rewrite, strangler).

pub use muya_core::claude_settings::*;

#[tauri::command]
pub fn claude_cleanup_days_get() -> Option<u64> {
    muya_core::claude_settings::claude_cleanup_days_get()
}

#[tauri::command(async)]
pub fn claude_cleanup_days_set(days: u32) -> Result<(), String> {
    muya_core::claude_settings::claude_cleanup_days_set(days)
}

//! Tauri command shim: the logic lives in `muya_core::debuglog` (native rewrite, strangler).

pub use muya_core::debuglog::*;

#[tauri::command]
pub fn debug_log_set(enabled: bool, path: String) -> Result<(), String> {
    muya_core::debuglog::debug_log_set(enabled, path)
}

#[tauri::command]
pub fn debug_log_get() -> Result<serde_json::Value, String> {
    muya_core::debuglog::debug_log_get()
}

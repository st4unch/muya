//! Tauri command shims: the logic lives in `muya_core::statusline` (native rewrite, strangler).

pub use muya_core::statusline::*;
use serde_json::Value;

#[tauri::command]
pub fn statusline_settings_path() -> Option<String> {
    muya_core::statusline::statusline_settings_path()
}

#[tauri::command]
pub fn statusline_get(pty_id: String) -> Option<Value> {
    muya_core::statusline::statusline_get(pty_id)
}

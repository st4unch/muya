//! Tauri command shims: the logic lives in `muya_core::term_history` (native rewrite, strangler).

pub use muya_core::term_history::*;

#[tauri::command]
pub async fn term_history_entries() -> Vec<TermEntries> {
    muya_core::term_history::term_history_entries().await
}

#[tauri::command]
pub async fn term_history_full(key: String) -> Result<Option<TermEntries>, String> {
    muya_core::term_history::term_history_full(key).await
}

#[tauri::command]
pub async fn term_history_export(dest: String, text: String) -> Result<(), String> {
    muya_core::term_history::term_history_export(dest, text).await
}

#[tauri::command]
pub fn term_history_delete(key: String) -> Result<(), String> {
    muya_core::term_history::term_history_delete(key)
}

//! Tauri command shims: the logic lives in `muya_core::file_history` (native rewrite, strangler).

pub use muya_core::file_history::*;

#[tauri::command(async)]
pub fn file_history_snapshot(
    path: String,
    content: String,
    kind: String,
) -> Result<Option<FileVersion>, String> {
    muya_core::file_history::file_history_snapshot(path, content, kind)
}

#[tauri::command(async)]
pub fn file_history_list(path: String) -> Result<Vec<FileVersion>, String> {
    muya_core::file_history::file_history_list(path)
}

#[tauri::command(async)]
pub fn file_history_read(path: String, id: String) -> Result<String, String> {
    muya_core::file_history::file_history_read(path, id)
}

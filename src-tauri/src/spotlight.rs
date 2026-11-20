//! Tauri command shims: the logic lives in `muya_core::spotlight` (native rewrite, strangler).

pub use muya_core::spotlight::*;

#[tauri::command]
pub async fn spotlight_search(query: String, roots: Vec<String>) -> Result<Vec<String>, String> {
    muya_core::spotlight::spotlight_search(query, roots).await
}

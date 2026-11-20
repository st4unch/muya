//! Tauri command shims: the logic lives in `muya_core::sessions` (native rewrite, strangler).

pub use muya_core::sessions::*;

#[tauri::command(async)]
pub async fn search_session_contents(
    query: String,
    sessions: Vec<SessionRef>,
) -> Result<Vec<SessionMatch>, String> {
    muya_core::sessions::search_session_contents(query, sessions).await
}

#[tauri::command(async)]
pub async fn export_session_markdown(
    session_id: String,
    cwd: String,
    dest: String,
) -> Result<(), String> {
    muya_core::sessions::export_session_markdown(session_id, cwd, dest).await
}

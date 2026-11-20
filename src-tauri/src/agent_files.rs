//! Tauri command shims: the logic lives in `muya_core::agent_files` (native rewrite, strangler).

pub use muya_core::agent_files::*;

#[tauri::command(async)]
pub fn session_touched_files(cwd: String, session_id: String) -> Result<Vec<TouchedFile>, String> {
    muya_core::agent_files::session_touched_files(cwd, session_id)
}

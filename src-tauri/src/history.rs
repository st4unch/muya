//! Tauri command shims: the logic lives in `muya_core::history` (native rewrite, strangler).

pub use muya_core::history::*;

#[tauri::command(async)]
pub fn list_session_history() -> Result<Vec<SessionHistoryEntry>, String> {
    muya_core::history::list_session_history()
}

#[tauri::command(async)]
pub fn read_session_transcript(
    path: String,
    max_messages: Option<usize>,
) -> Result<Vec<TranscriptMessage>, String> {
    muya_core::history::read_session_transcript(path, max_messages)
}

#[tauri::command(async)]
pub fn archive_sessions(
    paths: Vec<String>,
    live_ids: Vec<String>,
) -> Result<HousekeepingResult, String> {
    muya_core::history::archive_sessions(paths, live_ids)
}

#[tauri::command(async)]
pub fn restore_sessions(paths: Vec<String>) -> Result<HousekeepingResult, String> {
    muya_core::history::restore_sessions(paths)
}

#[tauri::command(async)]
pub fn list_archived_sessions() -> Result<Vec<SessionHistoryEntry>, String> {
    muya_core::history::list_archived_sessions()
}

#[tauri::command(async)]
pub fn trash_sessions(
    paths: Vec<String>,
    live_ids: Vec<String>,
) -> Result<HousekeepingResult, String> {
    muya_core::history::trash_sessions(paths, live_ids)
}

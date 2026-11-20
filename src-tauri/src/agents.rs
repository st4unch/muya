//! Tauri command shims: the logic lives in `muya_core::agents` (native rewrite, strangler).

pub use muya_core::agents::*;

#[tauri::command(async)]
pub fn claude_channels_supported() -> bool {
    muya_core::agents::claude_channels_supported()
}

#[tauri::command(async)]
pub async fn list_agent_sessions(include_all: Option<bool>) -> Result<Vec<AgentSession>, String> {
    muya_core::agents::list_agent_sessions(include_all).await
}

#[tauri::command(async)]
pub fn kill_session(id: Option<String>, pid: Option<i64>) -> Result<String, String> {
    muya_core::agents::kill_session(id, pid)
}

#[tauri::command(async)]
pub fn stop_agent(id: String) -> Result<String, String> {
    muya_core::agents::stop_agent(id)
}

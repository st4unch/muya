//! Tauri command shims: the logic lives in `muya_core::slash_commands` (native rewrite, strangler).

pub use muya_core::slash_commands::*;

#[tauri::command(async)]
pub fn list_slash_commands(agent: String, cwd: Option<String>) -> Vec<SlashCommand> {
    muya_core::slash_commands::list_slash_commands(agent, cwd)
}

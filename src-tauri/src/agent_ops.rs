//! Tauri command shims: the logic lives in `muya_core::agent_ops` (native rewrite, strangler).
//! `agent_ops_upsert` stays operator-only: agents reach operations only through the broker's
//! list/run ops, never this command.

pub use muya_core::agent_ops::*;

#[tauri::command]
pub fn agent_ops_list() -> Result<Vec<OpMeta>, String> {
    muya_core::agent_ops::agent_ops_list()
}

#[tauri::command]
pub fn agent_ops_upsert(op: OpDefinition) -> Result<(), String> {
    muya_core::agent_ops::agent_ops_upsert(op)
}

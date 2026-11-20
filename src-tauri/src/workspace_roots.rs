//! Tauri command shim: the logic lives in `muya_core::workspace_roots` (native rewrite, strangler).

pub(crate) use muya_core::workspace_roots::load_workspace_roots;

#[tauri::command]
pub fn set_workspace_roots(roots: Vec<String>) -> Result<(), String> {
    muya_core::workspace_roots::set_workspace_roots(roots)
}

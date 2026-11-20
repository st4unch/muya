//! Tauri command shims: the logic lives in `muya_core::login_item` (native rewrite, strangler).

pub use muya_core::login_item::*;

#[tauri::command]
pub fn login_item_get() -> bool {
    muya_core::login_item::login_item_get()
}

#[tauri::command]
pub fn login_item_set(enabled: bool) -> Result<bool, String> {
    muya_core::login_item::login_item_set(enabled)
}

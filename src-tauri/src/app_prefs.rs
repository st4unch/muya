//! Tauri command shims: the logic lives in `muya_core::app_prefs` (native rewrite, strangler).

pub use muya_core::app_prefs::*;

#[tauri::command]
pub fn app_prefs_get() -> AppPrefs {
    muya_core::app_prefs::app_prefs_get()
}

#[tauri::command]
pub fn app_prefs_set(prefs: AppPrefs) -> Result<(), String> {
    muya_core::app_prefs::app_prefs_set(prefs)
}

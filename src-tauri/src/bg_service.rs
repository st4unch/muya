//! Tauri command shims: the logic lives in `muya_core::bg_service` (native rewrite, strangler).

pub use muya_core::bg_service::*;

#[tauri::command]
pub fn bg_service_status() -> ServiceStatus {
    muya_core::bg_service::bg_service_status()
}

#[tauri::command]
pub fn bg_service_set(enabled: bool) -> Result<ServiceStatus, String> {
    muya_core::bg_service::bg_service_set(enabled)
}

#[tauri::command]
pub fn bg_service_open_settings() {
    muya_core::bg_service::bg_service_open_settings()
}

/// `muya --scheduler`: the timer loop alone, no window. Runs until launchd stops it.
pub fn run() {
    log::info!("schedules: background service started");
    tauri::async_runtime::block_on(muya_core::schedules::run_timer(muya_core::schedules::ScheduleState::service()));
}

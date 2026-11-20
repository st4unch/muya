//! Tauri command shim: the logic lives in `muya_core::metrics` (native rewrite, strangler).

pub use muya_core::metrics::*;
use tauri::State;

/// Current CPU% and RAM (MB) used by the app's main process.
#[tauri::command(async)]
pub fn app_metrics(state: State<Metrics>) -> AppMetrics {
    muya_core::metrics::sample(&state, std::process::id())
}

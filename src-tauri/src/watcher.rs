//! Tauri command shims: the logic lives in `muya_core::watcher` (native rewrite, strangler).

pub use muya_core::watcher::*;
use tauri::{AppHandle, Emitter, State};

#[tauri::command]
pub fn start_watching(
    app: AppHandle,
    state: State<WatchState>,
    paths: Vec<String>,
) -> Result<(), String> {
    let a1 = app.clone();
    let a2 = app;
    state.start(
        &paths,
        move || {
            let _ = a1.emit("fs-changed", ());
        },
        move |files| {
            let _ = a2.emit("fs-files-changed", files);
        },
    )
}

/// The files the UI currently has open. Changes to them arrive on `fs-files-changed`
/// with these exact strings. They must also be under a watched path (roots, or passed
/// to `start_watching` themselves) — this only decides what gets the fast lane.
#[tauri::command]
pub fn set_watched_files(state: State<WatchState>, paths: Vec<String>) -> Result<(), String> {
    state.set_open_files(&paths)
}

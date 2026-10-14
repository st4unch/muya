// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // The background schedules service (bg_service.rs) is this binary without a window.
    if std::env::args().nth(1).as_deref() == Some("--scheduler") {
        return muya_lib::run_scheduler();
    }
    muya_lib::run()
}

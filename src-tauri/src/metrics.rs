//! Live resource usage of THIS app process (not the whole machine). A persistent
//! `System` is kept so CPU% reflects usage between polls.

use std::sync::Mutex;

use serde::Serialize;
use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System};
use tauri::State;

pub struct Metrics(pub Mutex<System>);

impl Default for Metrics {
    fn default() -> Self {
        Metrics(Mutex::new(System::new()))
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppMetrics {
    /// CPU usage of this process, percent (can exceed 100 on multi-core).
    pub cpu: f32,
    /// Resident memory of this process, in MB.
    pub mem_mb: f64,
}

/// Current CPU% and RAM (MB) used by the app's main process.
#[tauri::command(async)]
pub fn app_metrics(state: State<Metrics>) -> AppMetrics {
    let Ok(pid) = sysinfo::get_current_pid() else {
        return AppMetrics {
            cpu: 0.0,
            mem_mb: 0.0,
        };
    };
    let mut sys = state.0.lock().unwrap();
    sys.refresh_processes_specifics(
        ProcessesToUpdate::Some(&[pid]),
        true,
        // Only what the readout shows: `everything()` also re-read the command line,
        // environment, cwd, exe and disk usage of the process on every 2.5 s poll.
        ProcessRefreshKind::nothing().with_cpu().with_memory(),
    );
    if let Some(p) = sys.process(pid) {
        AppMetrics {
            cpu: p.cpu_usage(),
            mem_mb: p.memory() as f64 / 1_048_576.0,
        }
    } else {
        AppMetrics {
            cpu: 0.0,
            mem_mb: 0.0,
        }
    }
}

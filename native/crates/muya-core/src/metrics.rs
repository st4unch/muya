//! Live CPU / RAM of the processes the header readout cares about. A persistent `System` is kept so
//! CPU% reflects usage between two polls (the first poll after start reads 0). Moved from
//! `src-tauri` without behaviour change for the single-process readout ([`sample`]); [`sample_many`]
//! is the daemon-side variant (muyad answers `metrics.get` for itself, ptyd and the sessions).

use std::sync::Mutex;

use serde::Serialize;
use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

pub struct Metrics(pub Mutex<System>);

impl Default for Metrics {
    fn default() -> Self {
        Metrics(Mutex::new(System::new()))
    }
}

#[derive(Serialize, Debug, Clone, Copy, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AppMetrics {
    /// CPU usage, percent (can exceed 100 on multi-core).
    pub cpu: f32,
    /// Resident memory, in MB.
    pub mem_mb: f64,
}

pub const ZERO: AppMetrics = AppMetrics { cpu: 0.0, mem_mb: 0.0 };

/// Only what the readout shows: `everything()` also re-reads the command line, environment, cwd,
/// exe and disk usage of the process on every poll.
fn kind() -> ProcessRefreshKind {
    ProcessRefreshKind::nothing().with_cpu().with_memory()
}

/// CPU% and RAM (MB) of one process — the app's header readout.
pub fn sample(state: &Metrics, pid: u32) -> AppMetrics {
    let Ok(mut sys) = state.0.lock() else { return ZERO };
    let pid = Pid::from_u32(pid);
    sys.refresh_processes_specifics(ProcessesToUpdate::Some(&[pid]), true, kind());
    sys.process(pid).map_or(ZERO, |p| AppMetrics { cpu: p.cpu_usage(), mem_mb: p.memory() as f64 / 1_048_576.0 })
}

/// Pids of this user's processes whose executable name is exactly `name` (one scan of the process
/// table, names and owners only — callers cache the answer instead of polling it).
pub fn pids_named(state: &Metrics, name: &str) -> Vec<u32> {
    let Ok(mut sys) = state.0.lock() else { return Vec::new() };
    sys.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing().with_user(UpdateKind::OnlyIfNotSet));
    let me = sys.process(Pid::from_u32(std::process::id())).and_then(|p| p.user_id().cloned());
    sys.processes_by_exact_name(name.as_ref()).filter(|p| me.is_none() || p.user_id() == me.as_ref()).map(|p| p.pid().as_u32()).collect()
}

/// One row per requested process (missing ones are left out) plus their sum.
pub fn sample_many(state: &Metrics, procs: &[(&str, u32)]) -> (AppMetrics, Vec<serde_json::Value>) {
    let Ok(mut sys) = state.0.lock() else { return (ZERO, Vec::new()) };
    let pids: Vec<Pid> = procs.iter().map(|(_, p)| Pid::from_u32(*p)).collect();
    sys.refresh_processes_specifics(ProcessesToUpdate::Some(&pids), true, kind());
    let (mut total, mut rows) = (ZERO, Vec::new());
    for (name, pid) in procs {
        if let Some(p) = sys.process(Pid::from_u32(*pid)) {
            let (cpu, mem_mb) = (p.cpu_usage(), p.memory() as f64 / 1_048_576.0);
            total.cpu += cpu;
            total.mem_mb += mem_mb;
            rows.push(serde_json::json!({ "name": name, "pid": pid, "cpu": cpu, "memMb": mem_mb }));
        }
    }
    (total, rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sample_reads_this_process_and_misses_a_dead_pid() {
        let m = Metrics::default();
        let me = sample(&m, std::process::id());
        assert!(me.mem_mb > 1.0, "own RSS should be more than 1 MB: {me:?}");
        // pid 0x7fff_fff0 does not exist.
        assert_eq!(sample(&m, 0x7fff_fff0), ZERO);
        let (total, rows) = sample_many(&m, &[("self", std::process::id()), ("ghost", 0x7fff_fff0)]);
        assert_eq!(rows.len(), 1);
        assert!(total.mem_mb > 1.0);
    }
}

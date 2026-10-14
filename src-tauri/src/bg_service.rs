//! "Run when Muya is closed" (docs/prd-schedules-background.md): the schedules
//! timer as a background service.
//!
//! The service is this same `muya` binary started as `muya --scheduler` (no window),
//! registered with `SMAppService.agent`. Its plist ships inside the bundle at
//! `Contents/Library/LaunchAgents/` with `AssociatedBundleIdentifiers` set to Muya's,
//! so System Settings → Login Items lists it under "Muya". Off by default; the
//! Schedules page asks.
//!
//! The service and the window share the lock in schedules.rs: while the service's
//! heartbeat is fresh the window leaves the timers to it.

use objc2_foundation::NSString;
use objc2_service_management::{SMAppService, SMAppServiceStatus};
use serde::Serialize;

use crate::schedules;

pub const PLIST: &str = "com.staunch.muya.scheduler.plist";

/// What the Schedules page shows next to the switch.
#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ServiceStatus {
    /// "off", "on", "approval" (macOS wants the user's OK in Login Items) or
    /// "unavailable" (macOS before 13, or a build without the bundled plist).
    pub state: &'static str,
    /// The service's heartbeat is fresh: it is running right now.
    pub running: bool,
    /// The version the running service reported.
    pub version: Option<String>,
}

/// The bundled plist, when this is a real app bundle that has one.
fn bundled() -> bool {
    std::env::current_exe()
        .ok()
        .and_then(|exe| {
            // …/Muya.app/Contents/MacOS/muya → …/Muya.app/Contents
            exe.parent()?
                .parent()
                .map(|c| c.join("Library/LaunchAgents").join(PLIST))
        })
        .is_some_and(|p| p.is_file())
}

fn supported() -> bool {
    objc2::available!(macos = 13.0) && bundled()
}

fn service() -> objc2::rc::Retained<SMAppService> {
    unsafe { SMAppService::agentServiceWithPlistName(&NSString::from_str(PLIST)) }
}

fn state_of(st: SMAppServiceStatus) -> &'static str {
    if st == SMAppServiceStatus::Enabled {
        "on"
    } else if st == SMAppServiceStatus::RequiresApproval {
        "approval"
    } else {
        "off"
    }
}

fn current() -> ServiceStatus {
    let hb = schedules::service_heartbeat();
    let state = if supported() {
        state_of(unsafe { service().status() })
    } else {
        "unavailable"
    };
    ServiceStatus {
        state,
        running: hb.is_some(),
        version: hb.map(|h| h.version),
    }
}

#[tauri::command]
pub fn bg_service_status() -> ServiceStatus {
    current()
}

#[tauri::command]
pub fn bg_service_set(enabled: bool) -> Result<ServiceStatus, String> {
    if !supported() {
        return Err(
            "The background service needs macOS 13 or later and the installed Muya app.".into(),
        );
    }
    let svc = service();
    let st = unsafe { svc.status() };
    if enabled && st != SMAppServiceStatus::Enabled {
        unsafe { svc.registerAndReturnError() }.map_err(|e| {
            format!(
                "Couldn't start the background service: {}",
                e.localizedDescription()
            )
        })?;
    } else if !enabled
        && (st == SMAppServiceStatus::Enabled || st == SMAppServiceStatus::RequiresApproval)
    {
        unsafe { svc.unregisterAndReturnError() }.map_err(|e| {
            format!(
                "Couldn't stop the background service: {}",
                e.localizedDescription()
            )
        })?;
        // The window takes the timers back on its next tick.
        schedules::clear_service_heartbeat();
    }
    Ok(current())
}

/// System Settings → General → Login Items, where the user approves the service.
#[tauri::command]
pub fn bg_service_open_settings() {
    unsafe { SMAppService::openSystemSettingsLoginItems() };
}

/// `muya --scheduler`: the timer loop alone, no window. Runs until launchd stops it.
pub fn run() {
    log::info!("schedules: background service started");
    tauri::async_runtime::block_on(schedules::run_timer(schedules::ScheduleState::service()));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_test_binary_has_no_bundled_plist() {
        assert!(!bundled());
        assert_eq!(current().state, "unavailable");
        assert!(bg_service_set(true).is_err());
    }
}

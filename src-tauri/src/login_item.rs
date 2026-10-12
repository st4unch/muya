//! "Open Muya at login".
//!
//! macOS 13+: the app registers itself with `SMAppService.mainApp`, so System Settings
//! → Login Items lists it as "Muya" with its icon. A LaunchAgent plist (what earlier
//! versions wrote) is listed there under the signing developer's name instead, so a
//! leftover one is moved over to SMAppService at startup.
//!
//! Older macOS: a per-user LaunchAgent. The agent runs `/usr/bin/open -a <bundle>`, so the app starts exactly as if the
//! user double-clicked it (LaunchServices, normal activation, not a launchd child).
//! The bundle path is resolved behind App Translocation, so a quarantined launch
//! still registers the copy the user actually keeps on disk. While the switch is on,
//! every launch rewrites the file, so moving the app keeps the login item working.

use std::path::{Path, PathBuf};

use crate::app_location;

/// launchd label and file name; matches the bundle identifier.
const LABEL: &str = "com.staunch.muya";

fn agent_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(
        Path::new(&home)
            .join("Library/LaunchAgents")
            .join(format!("{LABEL}.plist")),
    )
}

/// The `.app` to open at login: the running bundle, or the original behind a
/// translocation. None for a bare binary (dev/test) — nothing sensible to register.
fn bundle_to_launch() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let exe = exe.to_string_lossy();
    let root = PathBuf::from(app_location::bundle_root_from_exe(&exe)?);
    if app_location::path_is_translocated(&exe) {
        return app_location::original_bundle(&root);
    }
    Some(root)
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn plist_for(bundle: &Path) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>{}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
"#,
        xml_escape(&bundle.to_string_lossy())
    )
}

/// `SMAppService.mainApp`, on macOS 13+ (None before: the class doesn't exist there).
mod main_app {
    use objc2_service_management::{SMAppService, SMAppServiceStatus};

    pub fn supported() -> bool {
        objc2::available!(macos = 13.0)
    }

    pub fn enabled() -> Option<bool> {
        supported().then(|| unsafe { SMAppService::mainAppService().status() } == SMAppServiceStatus::Enabled)
    }

    /// Register (or unregister); the status afterwards. Never opens System Settings.
    pub fn apply(on: bool) -> Result<SMAppServiceStatus, String> {
        let svc = unsafe { SMAppService::mainAppService() };
        let st = unsafe { svc.status() };
        if on && st != SMAppServiceStatus::Enabled {
            unsafe { svc.registerAndReturnError() }
                .map_err(|e| format!("Couldn't add Muya to Login Items: {}", e.localizedDescription()))?;
        } else if !on && (st == SMAppServiceStatus::Enabled || st == SMAppServiceStatus::RequiresApproval) {
            unsafe { svc.unregisterAndReturnError() }
                .map_err(|e| format!("Couldn't remove Muya from Login Items: {}", e.localizedDescription()))?;
        }
        Ok(unsafe { svc.status() })
    }

    /// The Settings switch: like `apply`, but when macOS still wants the user's OK
    /// (they turned Muya off in Login Items before), open that page and say so.
    pub fn set(on: bool) -> Result<bool, String> {
        let st = apply(on)?;
        if on && st == SMAppServiceStatus::RequiresApproval {
            unsafe { SMAppService::openSystemSettingsLoginItems() };
            return Err("Turn Muya on in System Settings → General → Login Items, then try again.".into());
        }
        Ok(st == SMAppServiceStatus::Enabled)
    }

    pub fn is_enabled(st: SMAppServiceStatus) -> bool {
        st == SMAppServiceStatus::Enabled
    }
}

fn write_agent(file: &Path, bundle: &Path) -> Result<(), String> {
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("Couldn't create {}: {e}", dir.display()))?;
    }
    std::fs::write(file, plist_for(bundle))
        .map_err(|e| format!("Couldn't write the login item: {e}"))
}

fn legacy_exists() -> bool {
    agent_path().is_some_and(|p| p.exists())
}

fn remove_legacy() {
    if let Some(f) = agent_path() {
        let _ = std::fs::remove_file(f);
    }
}

#[tauri::command]
pub fn login_item_get() -> bool {
    main_app::enabled().unwrap_or(false) || legacy_exists()
}

#[tauri::command]
pub fn login_item_set(enabled: bool) -> Result<bool, String> {
    if main_app::supported() {
        // Drop the old LaunchAgent either way: on, SMAppService replaces it; off, it
        // would still open Muya at login.
        remove_legacy();
        return main_app::set(enabled);
    }
    let file = agent_path().ok_or("HOME is not set")?;
    if enabled {
        let bundle = bundle_to_launch()
            .ok_or("Muya isn't running from an app bundle, so there's nothing to open at login")?;
        write_agent(&file, &bundle)?;
    } else if file.exists() {
        std::fs::remove_file(&file).map_err(|e| format!("Couldn't remove the login item: {e}"))?;
    }
    Ok(login_item_get())
}

/// At startup: move a LaunchAgent left by an earlier version over to SMAppService
/// (macOS 13+); otherwise, if the login item is on, point it at wherever the app
/// lives now.
pub fn refresh() {
    if main_app::supported() {
        if legacy_exists()
            && bundle_to_launch().is_some()
            && main_app::apply(true).is_ok_and(main_app::is_enabled)
        {
            remove_legacy();
        }
        return;
    }
    let (Some(file), Some(bundle)) = (agent_path(), bundle_to_launch()) else {
        return;
    };
    if file.exists() && std::fs::read_to_string(&file).ok().as_deref() != Some(&plist_for(&bundle))
    {
        let _ = write_agent(&file, &bundle);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plist_opens_the_bundle_through_launch_services() {
        let p = plist_for(Path::new("/Applications/Muya.app"));
        assert!(p.contains("<string>/usr/bin/open</string>"));
        assert!(p.contains("<string>-a</string>"));
        assert!(p.contains("<string>/Applications/Muya.app</string>"));
        assert!(p.contains("<key>RunAtLoad</key>\n  <true/>"));
        assert!(p.contains(&format!("<string>{LABEL}</string>")));
    }

    #[test]
    fn plist_escapes_the_path() {
        let p = plist_for(Path::new("/tmp/A&B <x>/Muya.app"));
        assert!(p.contains("/tmp/A&amp;B &lt;x&gt;/Muya.app"));
    }

    #[test]
    fn write_agent_creates_the_folder() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("LaunchAgents/x.plist");
        write_agent(&file, Path::new("/Applications/Muya.app")).unwrap();
        assert!(std::fs::read_to_string(&file).unwrap().contains("Muya.app"));
    }

    #[test]
    fn plist_is_valid_for_plutil() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("x.plist");
        write_agent(&file, Path::new("/tmp/A&B/Muya.app")).unwrap();
        let ok = std::process::Command::new("/usr/bin/plutil")
            .arg("-lint")
            .arg(&file)
            .status();
        if let Ok(s) = ok {
            assert!(s.success());
        }
    }
}

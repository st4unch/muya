//! "Open Muya at login" — a per-user LaunchAgent that opens the app when the user
//! logs in.
//!
//! The agent runs `/usr/bin/open -a <bundle>`, so the app starts exactly as if the
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

fn write_agent(file: &Path, bundle: &Path) -> Result<(), String> {
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("Couldn't create {}: {e}", dir.display()))?;
    }
    std::fs::write(file, plist_for(bundle))
        .map_err(|e| format!("Couldn't write the login item: {e}"))
}

#[tauri::command]
pub fn login_item_get() -> bool {
    agent_path().is_some_and(|p| p.exists())
}

#[tauri::command]
pub fn login_item_set(enabled: bool) -> Result<bool, String> {
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

/// At startup: if the login item is on, point it at wherever the app lives now.
pub fn refresh() {
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

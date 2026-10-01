//! Double-click on Muya's own title bar (the header drawn in the webview — the window
//! uses an overlay title bar, so macOS never sees these clicks) does what the operator
//! chose in System Settings › Desktop & Dock › "Double-click a window's title bar to":
//! zoom (the default), fill, minimize, or nothing.

use std::process::Command;
use std::sync::OnceLock;

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum Action {
    Zoom,
    Minimize,
    Nothing,
}

/// `defaults read -g AppleActionOnDoubleClick`: "Maximize"/"Fill" (or unset) zoom,
/// "Minimize" minimizes, "None" does nothing.
fn parse_action(value: &str) -> Action {
    match value.trim() {
        "Minimize" => Action::Minimize,
        "None" | "Do Nothing" => Action::Nothing,
        _ => Action::Zoom,
    }
}

fn action() -> Action {
    // Read once per run: it is a rarely changed system preference, and a process spawn
    // per double-click would add visible latency.
    static ACTION: OnceLock<Action> = OnceLock::new();
    *ACTION.get_or_init(|| {
        Command::new("/usr/bin/defaults")
            .args(["read", "-g", "AppleActionOnDoubleClick"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| parse_action(&String::from_utf8_lossy(&o.stdout)))
            .unwrap_or(Action::Zoom)
    })
}

#[tauri::command]
pub fn title_bar_double_click(window: tauri::WebviewWindow) -> Result<(), String> {
    let r = match action() {
        Action::Nothing => Ok(()),
        Action::Minimize => window.minimize(),
        Action::Zoom => {
            if window.is_fullscreen().unwrap_or(false) {
                return Ok(()); // full screen has no title bar to zoom from
            }
            if window.is_maximized().unwrap_or(false) {
                window.unmaximize()
            } else {
                window.maximize()
            }
        }
    };
    r.map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_macos_preference_values() {
        assert_eq!(parse_action("Maximize\n"), Action::Zoom);
        assert_eq!(parse_action("Fill"), Action::Zoom);
        assert_eq!(parse_action(""), Action::Zoom);
        assert_eq!(parse_action("Minimize\n"), Action::Minimize);
        assert_eq!(parse_action("None"), Action::Nothing);
    }
}

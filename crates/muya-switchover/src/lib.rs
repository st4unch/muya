//! Shared logic for switching between classic Muya (Tauri) and Muya Native.
//!
//! Pure and testable: no Tauri, no UI. Platform actions (download, codesign,
//! Trash, launch) are behind the traits in [`swap`] and [`verify`].

pub mod manifest;
pub mod offer;
pub mod swap;
pub mod sysplatform;
pub mod verify;
pub mod version;

/// Apple Developer Team ID every shipped Muya app must be signed with. Compiled in,
/// never read from a manifest.
pub const TEAM_ID: &str = "7PG95YYJ64";
pub const CLASSIC_BUNDLE_ID: &str = "com.staunch.muya";
pub const NATIVE_BUNDLE_ID: &str = "com.staunch.muya.native";

/// Marker the freshly launched app writes so the old app knows it is safe to go.
pub fn healthy_marker_path(support_dir: &std::path::Path) -> std::path::PathBuf {
    support_dir.join("switchover").join("native-healthy.json")
}
pub fn state_path(support_dir: &std::path::Path) -> std::path::PathBuf {
    support_dir.join("switchover").join("switch.json")
}

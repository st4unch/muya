//! Move an app bundle to the macOS Trash the way Finder does (recoverable, "Put Back" works).

use std::path::{Path, PathBuf};

/// `NSFileManager trashItemAtURL`: returns where the item landed in the Trash (None if macOS does not say).
pub fn trash_item(path: &Path) -> Result<Option<PathBuf>, String> {
    use objc2::rc::Retained;
    use objc2_foundation::{NSFileManager, NSString, NSURL};
    let url = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
    let fm = NSFileManager::defaultManager();
    let mut out: Option<Retained<NSURL>> = None;
    fm.trashItemAtURL_resultingItemURL_error(&url, Some(&mut out)).map_err(|e| e.localizedDescription().to_string())?;
    Ok(out.and_then(|u| u.path()).map(|p| PathBuf::from(p.to_string())))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Needs a real (non-sandboxed) login session; creates and trashes one tiny folder.
    #[test]
    fn trashes_and_reports_where() {
        let d = std::env::temp_dir().join(format!("muya-trash-test-{}.app", std::process::id()));
        std::fs::create_dir_all(d.join("Contents")).unwrap();
        let landed = trash_item(&d).expect("trash");
        assert!(!d.exists(), "gone from its place");
        if let Some(p) = landed {
            assert!(p.exists(), "item is in the Trash at {}", p.display());
            std::fs::remove_dir_all(p).ok(); // our own test folder
        }
    }
}

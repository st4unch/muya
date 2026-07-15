// Claude-to-Claude Remote Bridge — Faz 0 scaffold.
//
// Faz 0 creates/removes a Unix-domain socket (mode 0600) in the per-user
// app-data directory and holds the listener handle in Tauri managed state.
// The real listener loop (accepting connections, auth, relay) is Faz 1.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use tauri::State;
use tokio::net::UnixListener;
use tokio::sync::Mutex;

// ---------------------------------------------------------------------------
// Managed state
// ---------------------------------------------------------------------------

/// Holds the active UnixListener (if the bridge is enabled).
pub struct BridgeState(pub Mutex<Option<(UnixListener, PathBuf)>>);

impl Default for BridgeState {
    fn default() -> Self {
        BridgeState(Mutex::new(None))
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Return the path to the owner-only UDS socket in the per-user app-data dir.
fn socket_path() -> Result<PathBuf, String> {
    let base = dirs_next::data_local_dir()
        .or_else(dirs_next::home_dir)
        .ok_or("cannot determine app-data directory")?;
    let dir = base.join("muya").join("bridge");
    fs::create_dir_all(&dir).map_err(|e| format!("create bridge dir: {e}"))?;
    // Restrict the directory itself to owner-only so the socket inside is
    // protected even before we set socket perms.
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("chmod bridge dir: {e}"))?;
    Ok(dir.join("bridge.sock"))
}

// ---------------------------------------------------------------------------
// Tauri commands
// ---------------------------------------------------------------------------

/// Enable (`true`) or disable (`false`) the local bridge socket.
///
/// `true`  — binds a Unix-domain socket at a per-user path with mode 0600
///            and stores the listener handle in managed state.
/// `false` — drops the listener handle and removes the socket file.
#[tauri::command]
pub async fn bridge_local_listen(
    enable: bool,
    state: State<'_, BridgeState>,
) -> Result<(), String> {
    let mut guard = state.0.lock().await;
    if enable {
        if guard.is_some() {
            return Ok(()); // already listening
        }
        let path = socket_path()?;
        // Remove stale socket file from a previous run.
        if path.exists() {
            fs::remove_file(&path).map_err(|e| format!("remove stale socket: {e}"))?;
        }
        let listener = UnixListener::bind(&path).map_err(|e| format!("bind UDS {path:?}: {e}"))?;
        // Enforce owner-only permissions on the socket file (mode 0600).
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("chmod socket: {e}"))?;
        *guard = Some((listener, path));
    } else {
        if let Some((_listener, path)) = guard.take() {
            // Drop the listener first, then clean up the file.
            let _ = fs::remove_file(&path);
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::MetadataExt;
    use tempfile::TempDir;

    /// Create a socket path inside a tempdir, bind it, check mode 0600,
    /// then unbind and verify the file is removed.
    #[tokio::test]
    async fn test_bind_and_unbind_uds() {
        let dir = TempDir::new().expect("tmpdir");
        let path = dir.path().join("test.sock");

        // ---- bind ----
        if path.exists() {
            fs::remove_file(&path).unwrap();
        }
        let listener = UnixListener::bind(&path).expect("bind");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("chmod socket");

        // Verify mode bits: lower 9 bits must be 0600 (owner rw, group/other none).
        let meta = fs::metadata(&path).expect("metadata");
        let mode = meta.mode() & 0o777;
        assert_eq!(mode, 0o600, "socket mode must be 0600, got {mode:o}");

        // ---- unbind ----
        drop(listener);
        fs::remove_file(&path).expect("remove socket");
        assert!(!path.exists(), "socket file should be gone after unbind");
    }
}

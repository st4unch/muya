//! Real-time filesystem watching for tracked projects/worktrees. Emits a debounced
//! `fs-changed` Tauri event so the frontend can refresh PM status / branches / the
//! file tree immediately instead of waiting for the next poll.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use tauri::{AppHandle, Emitter, State};

/// Holds the live watcher plus a stop flag for its trailing-edge flusher thread so
/// a restart (roots changed) tears the old thread down instead of leaking it.
pub struct WatchHandle {
    _watcher: RecommendedWatcher,
    stop: Arc<AtomicBool>,
}

pub struct WatchState(pub Mutex<Option<WatchHandle>>);

impl Default for WatchState {
    fn default() -> Self {
        WatchState(Mutex::new(None))
    }
}

fn noisy(ev: &Event) -> bool {
    ev.paths.iter().any(|p| {
        let s = p.to_string_lossy();
        s.contains("/node_modules/") || s.contains("/.git/") || s.contains("/target/")
    })
}

/// (Re)start watching the given paths recursively. Replaces any previous watcher.
#[tauri::command]
pub fn start_watching(
    app: AppHandle,
    state: State<WatchState>,
    paths: Vec<String>,
) -> Result<(), String> {
    // Stop the previous generation's flusher thread before swapping in a new watcher.
    if let Some(prev) = state.0.lock().unwrap().take() {
        prev.stop.store(true, Ordering::Relaxed);
    }

    // Shared between the notify callback and the flusher thread: `pending` marks an
    // unseen change, `last_emit` gates the leading edge.
    let pending = Arc::new(AtomicBool::new(false));
    let last_emit = Arc::new(Mutex::new(Instant::now() - Duration::from_secs(2)));
    let debounce = Duration::from_millis(1500);

    let cb_pending = pending.clone();
    let cb_last = last_emit.clone();
    let cb_app = app.clone();
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<Event>| {
        let Ok(ev) = res else { return };
        if noisy(&ev) {
            return;
        }
        // Leading edge: emit at once if it's been quiet, so a lone change refreshes the
        // UI instantly. Otherwise mark `pending` and let the flusher deliver the
        // TRAILING edge — a leading-only debounce silently drops any change that lands
        // within the window of a prior one (agent edit + external add), which left the
        // file tree stale (L38).
        let mut l = cb_last.lock().unwrap();
        if l.elapsed() >= debounce {
            *l = Instant::now();
            drop(l);
            cb_pending.store(false, Ordering::Relaxed);
            let _ = cb_app.emit("fs-changed", ());
        } else {
            cb_pending.store(true, Ordering::Relaxed);
        }
    })
    .map_err(|e| e.to_string())?;

    for p in &paths {
        let path = Path::new(p);
        if path.exists() {
            let _ = watcher.watch(path, RecursiveMode::Recursive);
        }
    }

    // Trailing-edge flusher: once the burst settles (no change for `debounce`), emit the
    // coalesced `fs-changed` so the last change is never lost. Tied to `stop` so a
    // restart ends it.
    let stop = Arc::new(AtomicBool::new(false));
    let flush_stop = stop.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_millis(400));
        if flush_stop.load(Ordering::Relaxed) {
            break;
        }
        if pending.load(Ordering::Relaxed) {
            let mut l = last_emit.lock().unwrap();
            if l.elapsed() >= debounce {
                *l = Instant::now();
                drop(l);
                pending.store(false, Ordering::Relaxed);
                let _ = app.emit("fs-changed", ());
            }
        }
    });

    *state.0.lock().unwrap() = Some(WatchHandle {
        _watcher: watcher,
        stop,
    });
    Ok(())
}

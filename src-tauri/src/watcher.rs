//! Real-time filesystem watching for tracked projects/worktrees and open files.
//!
//! Two channels, because they need different things:
//!
//! * `fs-changed` (no payload) — "something under a watched root changed". Drives the
//!   file tree, git status and PM views. Coalesced: at most one per `DEBOUNCE`, with a
//!   trailing edge so the last change of a burst is never lost (L38).
//! * `fs-files-changed` (payload: the paths as the UI opened them) — one of the files
//!   the UI has OPEN changed. Sent within ~`FILE_SETTLE` of the change, regardless of
//!   the debounce window, so an editor reflects an agent's or another editor's write
//!   right away.
//!
//! Why the second channel: with a busy root (the operator had their whole home folder
//! as a workspace) events never stop — ~14/s measured, 2026-09-30 — so the debounce's
//! instant leading edge never fired and EVERY change, including to the file on screen,
//! waited out the 1.5 s window before any view even re-read it.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use tauri::{AppHandle, Emitter, State};

const DEBOUNCE: Duration = Duration::from_millis(1500);
/// A file write is a burst of events (create/modify/metadata/rename); wait this long
/// after the last one so the view reads the finished file, once.
const FILE_SETTLE: Duration = Duration::from_millis(120);
const TICK: Duration = Duration::from_millis(40);

/// Canonical path → the path(s) the UI opened it by. FSEvents reports canonical paths
/// (`/private/tmp/x`), the UI may hold `/tmp/x`; matching must go through this map.
type OpenFiles = Arc<RwLock<HashMap<PathBuf, Vec<String>>>>;

/// Holds the live watcher plus a stop flag for its flusher thread so a restart (roots
/// changed) tears the old thread down instead of leaking it.
pub struct WatchHandle {
    _watcher: RecommendedWatcher,
    stop: Arc<AtomicBool>,
}

impl Drop for WatchHandle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

pub struct WatchState {
    handle: Mutex<Option<WatchHandle>>,
    open_files: OpenFiles,
}

impl Default for WatchState {
    fn default() -> Self {
        WatchState {
            handle: Mutex::new(None),
            open_files: Arc::new(RwLock::new(HashMap::new())),
        }
    }
}

/// Paths no view ever needs: dependency/build/VCS internals, and — unless a watched
/// root lives inside it — `~/Library` (caches, app support, mail, browser profiles),
/// which is most of the churn when the home folder itself is a workspace.
struct NoiseFilter {
    library: Option<String>,
}

impl NoiseFilter {
    fn new(roots: &[String], home: Option<&str>) -> Self {
        let library = home.map(|h| format!("{}/Library/", h.trim_end_matches('/')));
        let library = library.filter(|lib| {
            !roots
                .iter()
                .any(|r| format!("{r}/").starts_with(lib.as_str()))
        });
        NoiseFilter { library }
    }

    fn is_noise(&self, p: &Path) -> bool {
        let s = p.to_string_lossy();
        s.contains("/node_modules/")
            || s.contains("/.git/")
            || s.contains("/target/")
            || self
                .library
                .as_deref()
                .is_some_and(|lib| s.starts_with(lib))
    }
}

/// Canonicalize for matching against FSEvents paths. A file that doesn't exist yet
/// (about to be created) canonicalizes through its parent.
fn canonical(p: &Path) -> PathBuf {
    if let Ok(c) = std::fs::canonicalize(p) {
        return c;
    }
    match (
        p.parent().and_then(|d| std::fs::canonicalize(d).ok()),
        p.file_name(),
    ) {
        (Some(dir), Some(name)) => dir.join(name),
        _ => p.to_path_buf(),
    }
}

fn build_open_files(paths: &[String]) -> HashMap<PathBuf, Vec<String>> {
    let mut map: HashMap<PathBuf, Vec<String>> = HashMap::new();
    for p in paths {
        let entry = map.entry(canonical(Path::new(p))).or_default();
        if !entry.contains(p) {
            entry.push(p.clone());
        }
    }
    map
}

/// Start watching `roots` (recursive). `emit_changed` fires on the coalesced tree
/// channel; `emit_files` with the UI's own paths of open files that changed.
fn spawn_watch(
    roots: &[String],
    open_files: OpenFiles,
    home: Option<String>,
    emit_changed: impl Fn() + Send + Sync + 'static,
    emit_files: impl Fn(Vec<String>) + Send + Sync + 'static,
) -> Result<WatchHandle, String> {
    let noise = NoiseFilter::new(roots, home.as_deref());
    let emit_changed = Arc::new(emit_changed);

    // Tree channel: `pending` marks an unseen change, `last_emit` gates the leading edge.
    let pending = Arc::new(AtomicBool::new(false));
    let last_emit = Arc::new(Mutex::new(Instant::now() - DEBOUNCE - DEBOUNCE));
    // File channel: which open files changed, and when the last event for them came.
    let files_pending: Arc<Mutex<(HashSet<String>, Instant)>> =
        Arc::new(Mutex::new((HashSet::new(), Instant::now())));

    let cb_pending = pending.clone();
    let cb_last = last_emit.clone();
    let cb_emit = emit_changed.clone();
    let cb_files = files_pending.clone();
    let cb_open = open_files.clone();
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<Event>| {
        let Ok(ev) = res else { return };
        let paths: Vec<&PathBuf> = ev.paths.iter().filter(|p| !noise.is_noise(p)).collect();
        if paths.is_empty() {
            return;
        }

        // Open files first: they must not wait for the tree debounce.
        if let Ok(map) = cb_open.read() {
            let hits: Vec<String> = paths
                .iter()
                .filter_map(|p| map.get(*p))
                .flatten()
                .cloned()
                .collect();
            if !hits.is_empty() {
                if let Ok(mut fp) = cb_files.lock() {
                    fp.0.extend(hits);
                    fp.1 = Instant::now();
                }
            }
        }

        // Tree channel. Leading edge: emit at once if it's been quiet, so a lone change
        // refreshes instantly. Otherwise mark `pending` for the trailing edge — a
        // leading-only debounce silently drops a change landing inside the window (L38).
        let mut l = match cb_last.lock() {
            Ok(l) => l,
            Err(_) => return,
        };
        if l.elapsed() >= DEBOUNCE {
            *l = Instant::now();
            drop(l);
            cb_pending.store(false, Ordering::Relaxed);
            cb_emit();
        } else {
            cb_pending.store(true, Ordering::Relaxed);
        }
    })
    .map_err(|e| e.to_string())?;

    for p in roots {
        let path = Path::new(p);
        if path.exists() {
            if let Err(e) = watcher.watch(path, RecursiveMode::Recursive) {
                // Was silently ignored before; a root that can't be watched is worth a line.
                log::warn!("[watcher] cannot watch {p}: {e}");
            }
        }
    }

    // Flusher: trailing edge of the tree channel, and the settled file batch.
    let stop = Arc::new(AtomicBool::new(false));
    let flush_stop = stop.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(TICK);
        if flush_stop.load(Ordering::Relaxed) {
            break;
        }
        let batch = match files_pending.lock() {
            Ok(mut fp) if !fp.0.is_empty() && fp.1.elapsed() >= FILE_SETTLE => {
                let mut v: Vec<String> = fp.0.drain().collect();
                v.sort();
                Some(v)
            }
            _ => None,
        };
        if let Some(v) = batch {
            emit_files(v);
        }
        if pending.load(Ordering::Relaxed) {
            if let Ok(mut l) = last_emit.lock() {
                if l.elapsed() >= DEBOUNCE {
                    *l = Instant::now();
                    drop(l);
                    pending.store(false, Ordering::Relaxed);
                    emit_changed();
                }
            }
        }
    });

    Ok(WatchHandle {
        _watcher: watcher,
        stop,
    })
}

/// (Re)start watching the given roots recursively. Replaces any previous watcher.
#[tauri::command]
pub fn start_watching(
    app: AppHandle,
    state: State<WatchState>,
    paths: Vec<String>,
) -> Result<(), String> {
    // Dropping the previous handle stops its flusher (see Drop).
    drop(state.handle.lock().map_err(|e| e.to_string())?.take());
    let a1 = app.clone();
    let a2 = app;
    let handle = spawn_watch(
        &paths,
        state.open_files.clone(),
        std::env::var("HOME").ok(),
        move || {
            let _ = a1.emit("fs-changed", ());
        },
        move |files| {
            let _ = a2.emit("fs-files-changed", files);
        },
    )?;
    *state.handle.lock().map_err(|e| e.to_string())? = Some(handle);
    Ok(())
}

/// The files the UI currently has open. Changes to them arrive on `fs-files-changed`
/// with these exact strings. They must also be under a watched path (roots, or passed
/// to `start_watching` themselves) — this only decides what gets the fast lane.
#[tauri::command]
pub fn set_watched_files(state: State<WatchState>, paths: Vec<String>) -> Result<(), String> {
    *state.open_files.write().map_err(|e| e.to_string())? = build_open_files(&paths);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn library_is_noise_unless_a_root_lives_there() {
        let f = NoiseFilter::new(&["/Users/u".into()], Some("/Users/u"));
        assert!(f.is_noise(Path::new("/Users/u/Library/Caches/x")));
        assert!(!f.is_noise(Path::new("/Users/u/Documents/a.md")));
        assert!(f.is_noise(Path::new("/Users/u/p/node_modules/x/y.js")));

        let f = NoiseFilter::new(
            &["/Users/u/Library/Mobile Documents/proj".into()],
            Some("/Users/u"),
        );
        assert!(!f.is_noise(Path::new("/Users/u/Library/Mobile Documents/proj/a.md")));
    }

    #[test]
    fn open_files_map_by_canonical_path_back_to_the_ui_spelling() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().canonicalize().unwrap();
        std::fs::write(real.join("a.md"), "x").unwrap();
        let link = real.join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let ui = link.join("a.md").to_string_lossy().into_owned();
        let map = build_open_files(&[ui.clone()]);
        assert_eq!(map.get(&real.join("a.md")), Some(&vec![ui]));
    }

    /// Real FSEvents. The editor's file must be reported by the path the UI opened it
    /// with, quickly, even while the watched root is noisy (the tree channel's debounce
    /// window is constantly open).
    #[test]
    fn an_open_file_change_arrives_fast_under_constant_noise() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let link = root.join("via-link");
        std::fs::create_dir_all(root.join("work")).unwrap();
        std::os::unix::fs::symlink(root.join("work"), &link).unwrap();
        let target_ui = link.join("notes.md").to_string_lossy().into_owned();
        std::fs::write(root.join("work/notes.md"), "v1").unwrap();

        let open: OpenFiles = Arc::new(RwLock::new(build_open_files(&[target_ui.clone()])));
        let (tx, rx) = mpsc::channel::<(Instant, Vec<String>)>();
        let _h = spawn_watch(
            &[root.to_string_lossy().into_owned()],
            open,
            None,
            || {},
            move |v| {
                let _ = tx.send((Instant::now(), v));
            },
        )
        .unwrap();
        std::thread::sleep(Duration::from_millis(500)); // stream warm-up

        // Constant noise elsewhere in the root, like a home folder full of caches.
        let noise_root = root.clone();
        let noise_stop = Arc::new(AtomicBool::new(false));
        let ns = noise_stop.clone();
        let noise = std::thread::spawn(move || {
            let mut i = 0;
            while !ns.load(Ordering::Relaxed) {
                std::fs::write(noise_root.join(format!("noise-{}", i % 5)), i.to_string()).unwrap();
                i += 1;
                std::thread::sleep(Duration::from_millis(60));
            }
        });
        std::thread::sleep(Duration::from_millis(700));

        // An agent-style atomic write: temp file + rename over the open file.
        let written = Instant::now();
        std::fs::write(root.join("work/.notes.tmp"), "v2").unwrap();
        std::fs::rename(root.join("work/.notes.tmp"), root.join("work/notes.md")).unwrap();

        let got = rx.recv_timeout(Duration::from_secs(3));
        noise_stop.store(true, Ordering::Relaxed);
        noise.join().unwrap();
        let (at, files) = got.expect("open-file change was never reported");
        assert_eq!(files, vec![target_ui]);
        let latency = at.duration_since(written);
        assert!(
            latency < Duration::from_millis(900),
            "took {latency:?} — must not wait for the 1.5s window"
        );
    }
}

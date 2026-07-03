// Apex Mission Control — Tauri backend entry point.
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::Manager;

// Double-press quit guard: two ⌘Q presses within 700 ms required to quit.
static LAST_QUIT_MS: AtomicU64 = AtomicU64::new(0);
const QUIT_DOUBLE_PRESS_MS: u64 = 700;
use tauri::Emitter;

// Files opened via "Open With" / file association before the frontend listener is ready.
static STARTUP_FILES: Mutex<Vec<String>> = Mutex::new(Vec::new());

#[tauri::command]
fn get_startup_files() -> Vec<String> {
    STARTUP_FILES
        .lock()
        .map(|mut v| v.drain(..).collect())
        .unwrap_or_default()
}

mod agents;
mod fs;
mod history;
mod metrics;
mod pm;
mod pty;
#[cfg(test)]
mod testutil;
mod vault;
mod watcher;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            // Native menu bar. We rebuild it explicitly (instead of the default) so we
            // can add File > New File; the Edit submenu is re-added by hand because a
            // custom menu drops the platform defaults that terminal/editor copy-paste
            // relies on.
            let new_file = MenuItemBuilder::with_id("new_file", "New File")
                .accelerator("CmdOrCtrl+N")
                .build(app)?;
            // Own ⌘W ourselves so it closes the active in-app tab instead of the
            // window. The default `.close_window()` item closes the single window =
            // quits the whole app; the operator wants ⌘W to drop just the open
            // session/file and only ⌘Q (or the red close button) to quit.
            let close_tab = MenuItemBuilder::with_id("close_tab", "Close Tab")
                .accelerator("CmdOrCtrl+W")
                .build(app)?;
            // Custom quit item so we can intercept ⌘Q for double-press guard.
            // The built-in .quit() calls NSApplication.terminate() directly,
            // bypassing RunEvent::ExitRequested, so we must own it here.
            let quit_item = MenuItemBuilder::with_id("quit", "Quit Muya")
                .accelerator("CmdOrCtrl+Q")
                .build(app)?;
            let app_menu = SubmenuBuilder::new(app, "Apex")
                .about(None)
                .separator()
                .services()
                .separator()
                .hide()
                .hide_others()
                .show_all()
                .separator()
                .item(&quit_item)
                .build()?;
            let file_menu = SubmenuBuilder::new(app, "File")
                .item(&new_file)
                .separator()
                .item(&close_tab)
                .build()?;
            let edit_menu = SubmenuBuilder::new(app, "Edit")
                .undo()
                .redo()
                .separator()
                .cut()
                .copy()
                .paste()
                .select_all()
                .build()?;
            let menu = MenuBuilder::new(app)
                .items(&[&app_menu, &file_menu, &edit_menu])
                .build()?;
            app.set_menu(menu)?;
            // AC-1-7: Spawn vault MCP subprocess + warmup at startup.
            // warmup_vault runs asynchronously so it never blocks the setup hook.
            let vault_arc = app.state::<vault::VaultMcpManager>().0.clone();
            tauri::async_runtime::spawn(async move {
                vault::warmup_vault(vault_arc).await;
            });

            Ok(())
        })
        .on_menu_event(|app, event| match event.id().as_ref() {
            "new_file" => {
                let _ = app.emit("menu:new-file", ());
            }
            "close_tab" => {
                let _ = app.emit("menu:close-tab", ());
            }
            "quit" => {
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64;
                let last = LAST_QUIT_MS.load(Ordering::Relaxed);
                if now.saturating_sub(last) < QUIT_DOUBLE_PRESS_MS {
                    // Kill active PTY children before exit so no shells are orphaned.
                    pty::kill_all(&*app.state::<pty::PtyManager>());
                    app.exit(0);
                } else {
                    LAST_QUIT_MS.store(now, Ordering::Relaxed);
                }
            }
            _ => {}
        })
        .manage(pty::PtyManager::default())
        .manage(metrics::Metrics::default())
        .manage(watcher::WatchState::default())
        .manage(vault::VaultMcpManager::default())
        .invoke_handler(tauri::generate_handler![
            agents::list_agent_sessions,
            agents::stop_agent,
            agents::kill_session,
            history::list_session_history,
            fs::list_dir,
            fs::read_file,
            fs::write_file,
            fs::create_file,
            fs::read_head_file,
            fs::create_worktree,
            fs::remove_worktree,
            fs::list_branches,
            fs::branch_detail,
            pm::pm_status,
            pm::pm_check_merge,
            pm::pm_merge,
            pm::pm_push,
            pm::pm_collisions,
            metrics::app_metrics,
            watcher::start_watching,
            pty::pty_spawn,
            pty::pty_write,
            pty::pty_resize,
            pty::pty_kill,
            fs::list_claude_resources,
            fs::fetch_skill_marketplace,
            fs::fetch_mcp_marketplace,
            fs::install_skill,
            fs::install_mcp,
            fs::git_status,
            fs::reveal_in_finder,
            fs::rename_entry,
            fs::delete_entry,
            get_startup_files,
            vault::vault_search,
            fs::scan_prd_docs
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            #[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
            if let tauri::RunEvent::Opened { urls } = event {
                let paths: Vec<String> = urls
                    .iter()
                    .filter_map(|u| u.to_file_path().ok())
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect();
                // Store for get_startup_files (startup case, before JS listener is ready).
                if let Ok(mut pending) = STARTUP_FILES.lock() {
                    pending.extend(paths.clone());
                }
                // Also emit for the already-running case.
                for path in paths {
                    let _ = app_handle.emit("apex://open-file", path);
                }
            }
        });
}

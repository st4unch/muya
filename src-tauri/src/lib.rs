// Apex Mission Control — Tauri backend entry point.
use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::Emitter;

mod agents;
mod fs;
mod history;
mod metrics;
mod pm;
mod pty;
#[cfg(test)]
mod testutil;
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
            let app_menu = SubmenuBuilder::new(app, "Apex")
                .about(None)
                .separator()
                .services()
                .separator()
                .hide()
                .hide_others()
                .show_all()
                .separator()
                .quit()
                .build()?;
            let file_menu = SubmenuBuilder::new(app, "File")
                .item(&new_file)
                .separator()
                .close_window()
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
            Ok(())
        })
        .on_menu_event(|app, event| {
            if event.id().as_ref() == "new_file" {
                let _ = app.emit("menu:new-file", ());
            }
        })
        .manage(pty::PtyManager::default())
        .manage(metrics::Metrics::default())
        .manage(watcher::WatchState::default())
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
            pty::pty_kill
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

// Apex Mission Control — Tauri backend entry point.
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::image::Image;
use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::tray::TrayIconBuilder;
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

/// Called by the frontend when an SSH terminal tab closes, so the broker stops
/// accepting `ssh_send` to that (now dead) session id.
#[tauri::command]
fn ssh_release_session(session_id: String) {
    crate::broker::release_ssh_session(&session_id);
}

/// Called by the frontend whenever an `open_session`-opened terminal tab closes
/// (via `close_session` or the operator closing it by hand), so the broker stops
/// considering that name closable/owned (PRD `close-session`).
#[tauri::command]
fn release_agent_session(name: String) {
    crate::broker::release_agent_session(&name);
}

mod agent_ops;
mod agent_ssh;
mod agents;
mod app_location;
mod app_prefs;
mod askpass;
mod bg_service;
mod bridge;
mod bridge_exec;
mod bridge_mcp;
mod bridge_remote;
mod broker;
mod credstore;
mod cyberark;
mod debuglog;
mod fs;
mod history;
mod local_guard;
mod login_item;
mod metrics;
mod opencode;
mod pm;
mod pty;
mod sessions;
mod slash_commands;
mod spotlight;
mod ssh;
mod statusline;
mod term_history;
#[cfg(test)]
mod testutil;
mod agent_files;
mod titlebar;
mod validate;
mod schedules;
mod vault;
mod watcher;
mod workspace_roots;

/// Frontend errors (window.onerror / unhandledrejection) are forwarded here so
/// they land in the same persistent log file as the Rust logs.
#[tauri::command]
fn frontend_log(level: String, message: String) {
    match level.as_str() {
        "error" => log::error!("[frontend] {message}"),
        "warn" => log::warn!("[frontend] {message}"),
        _ => log::info!("[frontend] {message}"),
    }
}

/// Red close button: hide instead of quit while "Keep running when the window is
/// closed" is on, so sessions and schedules keep running
/// (docs/prd-schedules-background.md). Called from the run loop, where Tauri hands
/// the user's close request over before acting on it; ⌘Q and the updater's relaunch
/// go through app.exit/restart and never reach here.
fn hide_on_close<R: tauri::Runtime>(app: &tauri::AppHandle<R>, event: &tauri::RunEvent) {
    if let tauri::RunEvent::WindowEvent {
        label,
        event: tauri::WindowEvent::CloseRequested { api, .. },
        ..
    } = event
    {
        if app_prefs::keep_running_in_background() {
            api.prevent_close();
            if let Some(w) = app.get_webview_window(label) {
                let _ = w.hide();
            }
        }
    }
}

/// Bring the main window back (Dock click, menu bar icon, a file opened from Finder).
fn show_main<R: tauri::Runtime>(app: &tauri::AppHandle<R>) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.set_focus();
    }
}

/// Quit for real: kill PTY children so no shells are orphaned, close only THIS
/// instance's SSH masters (a second Muya's stay up), then exit.
fn quit_now(app: &tauri::AppHandle) {
    pty::kill_all(&*app.state::<pty::PtyManager>());
    crate::ssh::close_own_control_masters();
    crate::statusline::cleanup();
    app.exit(0);
}

/// Menu bar icon: while the red close button keeps Muya running with the window
/// hidden, the icon shows it is still there and reopens or quits it
/// (docs/prd-menubar-icon.md). Its items land in `.on_menu_event` as `tray_*`.
fn build_tray(app: &tauri::App) -> tauri::Result<()> {
    let open = MenuItemBuilder::with_id("tray_open", "Open Muya").build(app)?;
    let settings = MenuItemBuilder::with_id("tray_settings", "Settings…").build(app)?;
    let quit = MenuItemBuilder::with_id("tray_quit", "Quit Muya").build(app)?;
    let menu = MenuBuilder::new(app)
        .items(&[&open, &settings])
        .separator()
        .item(&quit)
        .build()?;
    TrayIconBuilder::with_id("muya")
        .icon(Image::from_bytes(include_bytes!("../icons/tray-icon.png"))?)
        .tooltip("Muya")
        .menu(&menu)
        .build(app)?;
    Ok(())
}

/// `muya --scheduler`: the background schedules service, no window
/// (docs/prd-schedules-background.md).
pub fn run_scheduler() {
    std::panic::set_hook(Box::new(|info| {
        eprintln!("PANIC: {info}");
    }));
    bg_service::run()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Route panics to the log (and stderr) instead of silently losing them.
    std::panic::set_hook(Box::new(|info| {
        log::error!("PANIC: {info}");
        eprintln!("PANIC: {info}");
    }));
    tauri::Builder::default()
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(log::LevelFilter::Info)
                .targets([
                    tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::LogDir {
                        file_name: Some("muya".into()),
                    }),
                    tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Stdout),
                ])
                .build(),
        )
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .setup(|app| {
            // Must run before anything else: an updated bundle can come back
            // quarantined, and a quarantined app outside /Applications is
            // translocated on its next launch — which resets the user's file
            // permission all over again. See fs::strip_own_quarantine.
            crate::fs::strip_own_quarantine();

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
            // ⌘O: macOS open dialog; the chosen files open in Muya. Emits "menu:open-file".
            let open_file = MenuItemBuilder::with_id("open_file", "Open…")
                .accelerator("CmdOrCtrl+O")
                .build(app)?;
            // ⌘⇧T: bring back the last closed session / terminal / file (newest first).
            let reopen_tab = MenuItemBuilder::with_id("reopen_tab", "Reopen Closed Tab")
                .accelerator("CmdOrCtrl+Shift+T")
                .build(app)?;
            // Custom quit item so we can intercept ⌘Q for double-press guard.
            // The built-in .quit() calls NSApplication.terminate() directly,
            // bypassing RunEvent::ExitRequested, so we must own it here.
            let quit_item = MenuItemBuilder::with_id("quit", "Quit Muya")
                .accelerator("CmdOrCtrl+Q")
                .build(app)?;
            let check_update =
                MenuItemBuilder::with_id("check_update", "Check for Updates...").build(app)?;
            // Settings… (⌘, macOS convention) — opens the in-app Settings modal
            // (debug logging toggle + log path). Emits "menu:settings".
            let settings_item = MenuItemBuilder::with_id("settings", "Settings…")
                .accelerator("CmdOrCtrl+,")
                .build(app)?;
            let app_menu = SubmenuBuilder::new(app, "Muya")
                .about(None)
                .separator()
                .item(&check_update)
                .item(&settings_item)
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
                .item(&open_file)
                .separator()
                .item(&close_tab)
                .item(&reopen_tab)
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
            if let Err(e) = build_tray(app) {
                log::warn!("[tray] menu bar icon failed: {e}");
            }
            // Apply persisted debug-logging settings (~/.claude/muya-settings.json)
            // so CyberArk/SSH step logs start flowing immediately if enabled.
            debuglog::load_and_apply();
            app_prefs::load();
            // AC-1-7: Spawn vault MCP subprocess + warmup at startup.
            // warmup_vault runs asynchronously so it never blocks the setup hook.
            let vault_arc = app.state::<vault::VaultMcpManager>().0.clone();
            tauri::async_runtime::spawn(async move {
                vault::warmup_vault(vault_arc).await;
            });

            // Headless auto-listen for dev/test instances: bind the local bridge
            // socket at startup without a UI toggle. Gated by env (inert in prod).
            // Pair with MUYA_BRIDGE_SOCK to isolate from the primary instance.
            if std::env::var("MUYA_BRIDGE_AUTOLISTEN").is_ok() {
                let bridge_state = app.state::<bridge::BridgeState>();
                let handle = app.handle().clone();
                if let Err(e) = tauri::async_runtime::block_on(bridge::enable_local_listener(
                    &bridge_state,
                    handle,
                )) {
                    eprintln!("[bridge] auto-listen failed: {e}");
                }
            }

            // Remote bridge (PRD bridge-mcp): resume polling the peers we dialed, so
            // messages they queued for us arrive without an agent call first.
            bridge_mcp::start_pollers(app.handle().clone());
            login_item::refresh();

            // SSH agent broker (PRD ssh-agent-broker, Faz 1): start the owner-only
            // UDS listener (0600 + getpeereid uid check) and register the muya-ssh
            // MCP proxy in ~/.claude/.mcp.json. Both are idempotent + secret-free.
            {
                let broker_state = app.state::<broker::BrokerState>();
                let handle = app.handle().clone();
                let owned_elsewhere = match tauri::async_runtime::block_on(
                    broker::enable_broker_listener(&broker_state, handle),
                ) {
                    Ok(()) => false,
                    Err(e) => {
                        log::warn!("[ssh-broker] listener start failed: {e}");
                        e == broker::BROKER_OWNED_ELSEWHERE
                    }
                };
                // The instance that serves the broker owns the MCP registration too. A
                // second instance re-registering would point every Claude/opencode
                // session at ITS helper build while the running one keeps the socket.
                if !owned_elsewhere {
                    if let Err(e) = broker::register_mcp() {
                        log::warn!("[ssh-broker] mcp registration failed: {e}");
                    }
                }
                // ControlMaster socket dir (0700) — ssh reuses one connection per host
                // via ControlPath in here, so it must exist before any ssh_run.
                crate::ssh::ensure_control_master_dir();
                // Sweep stale masters from a previous run: ControlPersist doesn't reap
                // PSMP masters (not idle), so a dead-for-reuse socket would lock the alias.
                crate::ssh::sweep_control_master_sockets();
                // Claude status-line capture dir for the footer (PRD statusline-footer).
                crate::statusline::init();

                // Idle-session reaper (PRD ssh-session): agent_ssh sessions have no other
                // garbage collector — an agent that opens one and never closes it (crash,
                // context reset) would otherwise leak the PTY/PSMP connection for the life
                // of the app. Sweep on a cadence well under IDLE_TIMEOUT so a leaked
                // session is caught reasonably soon after going idle, not near-immediately.
                let agent_ssh_store = app.state::<agent_ssh::AgentSshStore>().inner().clone();
                tauri::async_runtime::spawn(async move {
                    loop {
                        tokio::time::sleep(std::time::Duration::from_secs(5 * 60)).await;
                        let store = agent_ssh_store.clone();
                        let closed = tokio::task::spawn_blocking(move || {
                            agent_ssh::reap_idle(&store, agent_ssh::IDLE_TIMEOUT)
                        })
                        .await
                        .unwrap_or_default();
                        for id in closed {
                            log::info!("[agent-ssh] reaped idle session {id}");
                        }
                    }
                });
            }

            // Scheduled headless Claude prompts (docs/prd-schedules.md).
            schedules::start(app.handle());

            Ok(())
        })
        .on_menu_event(|app, event| match event.id().as_ref() {
            "new_file" => {
                let _ = app.emit("menu:new-file", ());
            }
            "close_tab" => {
                let _ = app.emit("menu:close-tab", ());
            }
            "open_file" => {
                let _ = app.emit("menu:open-file", ());
            }
            "reopen_tab" => {
                let _ = app.emit("menu:reopen-closed-tab", ());
            }
            "check_update" => {
                let _ = app.emit("menu:check-update", ());
            }
            "settings" => {
                let _ = app.emit("menu:settings", ());
            }
            "tray_open" => show_main(app),
            "tray_settings" => {
                show_main(app);
                let _ = app.emit("menu:settings", ());
            }
            // A deliberate menu click, and the window may be hidden so the ⌘Q
            // "press again" hint would never be seen: quit at once.
            "tray_quit" => quit_now(app),
            "quit" => {
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64;
                let last = LAST_QUIT_MS.load(Ordering::Relaxed);
                if now.saturating_sub(last) < QUIT_DOUBLE_PRESS_MS {
                    quit_now(app);
                } else {
                    LAST_QUIT_MS.store(now, Ordering::Relaxed);
                    // First press — tell the UI to show a transient "press ⌘Q again
                    // to quit" hint (VS Code style), so an accidental ⌘Q doesn't
                    // silently do nothing and a real quit is a deliberate double-press.
                    let _ = app.emit("menu:quit-hint", ());
                }
            }
            _ => {}
        })
        .manage(pty::PtyManager::default())
        .manage(metrics::Metrics::default())
        .manage(watcher::WatchState::default())
        .manage(vault::VaultMcpManager::default())
        .manage(bridge::BridgeState::default())
        .manage(bridge_remote::RemoteBridgeState::default())
        .manage(bridge_exec::ExecState::default())
        .manage(broker::BrokerState::default())
        .manage(agent_ssh::AgentSshStore::default())
        .manage(schedules::ScheduleState::default())
        .manage(credstore::CredStore::default())
        .manage(cyberark::CyberarkState::default())
        .invoke_handler(tauri::generate_handler![
            agents::list_agent_sessions,
            schedules::schedules_list,
            schedules::schedule_save,
            schedules::schedule_set_enabled,
            schedules::schedule_delete,
            schedules::schedule_run_now,
            schedules::schedule_runs,
            agents::claude_channels_supported,
            agents::stop_agent,
            agents::kill_session,
            history::list_session_history,
            history::read_session_transcript,
            agent_files::session_touched_files,
            fs::list_dir,
            fs::read_file,
            fs::write_file,
            fs::create_file,
            fs::create_dir,
            fs::path_kind,
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
            watcher::set_watched_files,
            pty::pty_spawn,
            term_history::term_history_delete,
            term_history::term_history_entries,
            term_history::term_history_full,
            term_history::term_history_export,
            pty::pty_write,
            pty::pty_resize,
            pty::pty_kill,
            pty::pty_cwds,
            pty::pty_session_ids,
            fs::list_claude_resources,
            slash_commands::list_slash_commands,
            statusline::statusline_settings_path,
            statusline::statusline_get,
            fs::fetch_skill_marketplace,
            fs::fetch_mcp_marketplace,
            fs::install_skill,
            fs::install_mcp,
            fs::install_muya_plugin,
            fs::git_status,
            fs::reveal_in_finder,
            fs::open_privacy_settings,
            fs::file_access_status,
            fs::relaunch_in_place,
            fs::allow_asset_path,
            fs::read_file_bytes,
            titlebar::title_bar_double_click,
            titlebar::open_third_party_licenses,
            fs::resolve_path_kind,
            fs::local_ip,
            fs::rename_entry,
            fs::delete_entry,
            get_startup_files,
            ssh_release_session,
            release_agent_session,
            vault::vault_search,
            vault::vault_get_status,
            vault::vault_detect_candidates,
            vault::vault_set_path,
            vault::vault_restart,
            fs::scan_prd_docs,
            sessions::search_session_contents,
            sessions::export_session_markdown,
            bridge::bridge_local_listen,
            bridge::bridge_poll_inbound,
            bridge::bridge_send,
            bridge::bridge_approve,
            bridge_remote::bridge_remote_listen,
            bridge_remote::bridge_pair_invite,
            bridge_remote::bridge_pair_start_listener,
            bridge_remote::bridge_pair_stop_listener,
            bridge_remote::bridge_check_port,
            bridge_remote::bridge_pair_connect,
            bridge_remote::bridge_pair_confirm_sas,
            bridge_remote::bridge_list_peers,
            bridge_remote::bridge_revoke_peer,
            bridge_remote::bridge_remote_send,
            bridge_exec::bridge_set_capability,
            bridge_exec::bridge_set_auto_run,
            bridge_exec::bridge_audit_log,
            bridge_exec::bridge_execute_task,
            bridge_exec::bridge_fan_out,
            bridge_exec::bridge_run_claude,
            credstore::credstore_status,
            credstore::credstore_init,
            credstore::credstore_unlock,
            credstore::credstore_lock,
            credstore::credstore_biometric_available,
            credstore::credstore_enable_biometric_unlock,
            credstore::credstore_disable_biometric_unlock,
            credstore::credstore_unlock_biometric,
            credstore::credstore_cred_list,
            credstore::credstore_cred_upsert,
            credstore::credstore_cred_remove,
            credstore::credstore_rekey,
            credstore::credstore_export,
            credstore::credstore_export_master,
            credstore::credstore_import_key,
            credstore::credstore_import_secret,
            credstore::credstore_export_cred,
            credstore::credstore_reveal_cred,
            ssh::ssh_get_config,
            ssh::ssh_list_servers,
            ssh::ssh_upsert_server,
            ssh::ssh_remove_server,
            ssh::ssh_upsert_psmp_profile,
            ssh::ssh_remove_psmp_profile,
            ssh::ssh_set_cyberark_config,
            ssh::ssh_build_connect_cmd,
            ssh::ssh_pty_connect,
            cyberark::cyberark_logon,
            cyberark::cyberark_test_connection,
            cyberark::cyberark_list_accounts,
            cyberark::cyberark_logoff,
            cyberark::cyberark_status,
            agent_ops::agent_ops_list,
            agent_ops::agent_ops_upsert,
            workspace_roots::set_workspace_roots,
            debuglog::debug_log_set,
            login_item::login_item_get,
            login_item::login_item_set,
            app_prefs::app_prefs_get,
            app_prefs::app_prefs_set,
            bg_service::bg_service_status,
            bg_service::bg_service_set,
            bg_service::bg_service_open_settings,
            spotlight::spotlight_search,
            debuglog::debug_log_get,
            frontend_log
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            hide_on_close(app_handle, &event);
            // Dock click while the window is hidden: bring it back.
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen {
                has_visible_windows: false,
                ..
            } = &event
            {
                show_main(app_handle);
            }
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
                // A file opened from Finder while the window is hidden shows it again.
                show_main(app_handle);
                // Also emit for the already-running case.
                for path in paths {
                    let _ = app_handle.emit("apex://open-file", path);
                }
            }
        });
}

#[cfg(test)]
mod window_close_tests {
    use tauri::Manager;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    /// The red close button sends CloseRequested. The mock runtime then removes the
    /// window and, with none left, stops the app — unless the handler prevented the
    /// close. Queue a close, a marker task, then a destroy (so the test ends either
    /// way): the marker only runs if the app survived the close.
    fn survives_close(keep: bool) -> bool {
        crate::app_prefs::set_keep_running_for_test(keep);
        let app = tauri::test::mock_builder()
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .unwrap();
        tauri::WebviewWindowBuilder::new(&app, "main", Default::default())
            .build()
            .unwrap();
        let survived = Arc::new(AtomicBool::new(false));
        let s = survived.clone();
        // The mock only routes these through the event loop once it runs.
        app.run(move |h, e| {
            super::hide_on_close(h, &e);
            if matches!(e, tauri::RunEvent::Ready) {
                let w = h.get_webview_window("main").unwrap();
                w.close().unwrap();
                let s = s.clone();
                h.run_on_main_thread(move || s.store(true, Ordering::SeqCst))
                    .unwrap();
                w.destroy().unwrap();
            }
        });
        survived.load(Ordering::SeqCst)
    }

    #[test]
    fn close_hides_while_keep_running_is_on_and_quits_when_off() {
        assert!(survives_close(true), "on: the window hides, Muya keeps running");
        assert!(!survives_close(false), "off: closing the window quits, as before");
        crate::app_prefs::set_keep_running_for_test(true);
    }
}

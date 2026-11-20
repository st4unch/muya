//! Tauri-free Muya logic (PRD §5 code layout, AC1). Modules move here from `src-tauri` without
//! behaviour changes; the Tauri app re-exports them under their old paths, so both the current
//! app and the native daemons run the same code.

pub mod agent_files;
pub mod agent_ops;
pub mod agent_ssh;
pub mod agents;
pub mod app_location;
pub mod app_prefs;
pub mod askpass;
pub mod bg_service;
pub mod bridge;
pub mod bridge_exec;
pub mod bridge_host;
pub mod bridge_mcp;
pub mod bridge_remote;
pub mod broker;
pub mod claude_settings;
pub mod credstore;
pub mod cyberark;
pub mod debuglog;
pub mod delivery_keys;
pub mod file_history;
pub mod fs;
pub mod fsutil;
pub mod history;
pub mod inject;
pub mod local_guard;
pub mod login_item;
pub mod metrics;
pub mod migrate;
pub mod opencode;
pub mod pm;
pub mod pty_state;
pub mod schedules;
pub mod screen;
pub mod secret_refs;
pub mod sessions;
pub mod slash_commands;
pub mod spawn;
pub mod spotlight;
pub mod ssh;
pub mod statusline;
pub mod term_history;
#[cfg(test)]
pub mod testutil;
pub mod trash;
pub mod validate;
pub mod vault;
pub mod watcher;
pub mod workspace_roots;

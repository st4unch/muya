//! P12 Rpc methods: `notes_vault.*` — the OBSIDIAN notes vault (semantic search over the user's own notes),
//! not the password store (`vault.*`). One method per old Tauri command:
//!
//! | method                          | Tauri command            |
//! |---------------------------------|--------------------------|
//! | `notes_vault.status`            | `vault_get_status`       |
//! | `notes_vault.detect_candidates` | `vault_detect_candidates`|
//! | `notes_vault.set_path`          | `vault_set_path`         |
//! | `notes_vault.restart`           | `vault_restart`          |
//! | `notes_vault.search`            | `vault_search`           |
//!
//! The helper process (smart-connections MCP) is owned by the daemon, so it survives the window. Nothing here
//! scans iCloud / CloudStorage: candidates come from muya-core's depth-limited scan of ordinary folders, and
//! any other vault is only ever a path the user typed or picked.

use muya_core::vault::{self, VaultMcpManager};
use serde::Deserialize;
use serde_json::Value;
use std::sync::OnceLock;

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("notes-vault")
            .enable_all()
            .build()
            .expect("notes_vault runtime")
    })
}

fn manager() -> &'static VaultMcpManager {
    static M: OnceLock<VaultMcpManager> = OnceLock::new();
    M.get_or_init(VaultMcpManager::default)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetPath {
    path: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Search {
    query: String,
    max_blocks: Option<u32>,
    timeout_ms: Option<u64>,
}

fn p<T: serde::de::DeserializeOwned>(params: &str) -> Result<T, String> {
    serde_json::from_str(if params.trim().is_empty() { "{}" } else { params }).map_err(|e| format!("bad parameters: {e}"))
}

fn enc<T: serde::Serialize>(v: &T) -> Result<Value, String> {
    serde_json::to_value(v).map_err(|e| format!("encode: {e}"))
}

/// `None` = not ours.
pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    let r = match method {
        "notes_vault.status" => enc(&vault::vault_get_status()),
        "notes_vault.detect_candidates" => enc(&vault::vault_detect_candidates()),
        "notes_vault.set_path" => p::<SetPath>(params).and_then(|a| vault::vault_set_path(a.path)).map(|()| Value::Null),
        "notes_vault.restart" => runtime().block_on(vault::restart(manager())).map(|()| Value::Null),
        "notes_vault.search" => p::<Search>(params)
            .and_then(|a| runtime().block_on(vault::search(manager(), a.query, a.max_blocks, a.timeout_ms)))
            .and_then(|b| enc(&b)),
        _ => return None,
    };
    Some(r)
}

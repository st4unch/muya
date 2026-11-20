//! SSH/session broker — the logic lives in `muya_core::broker` (Tauri-free, hostable by
//! `muyad`). This shim re-exports it under the old path and supplies the Tauri host:
//! vault, CyberArk, schedules, bridge and UI events all go through `TauriBrokerHost`.
//! The `muya-mcp` registration also stays here (it needs `app_location` / `fs`).

use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager};
use zeroize::Zeroizing;

pub use muya_core::broker::*;
use muya_core::agent_ssh::AgentSshStore;

/// Name of the MCP entry written to `~/.claude/.mcp.json` and of the proxy binary.
const MCP_ENTRY_NAME: &str = "muya-mcp";
/// Prior name of this MCP server; removed from `~/.claude.json` on register so the
/// rename doesn't leave a stale duplicate pointing at the same binary.
const MCP_LEGACY_ENTRY_NAME: &str = "muya-ssh";

/// The Tauri app as broker host.
#[derive(Clone)]
pub struct TauriBrokerHost(pub AppHandle);

fn secret_meta(m: crate::credstore::CredMeta) -> SecretMeta {
    SecretMeta {
        label: m.label,
        description: m.description,
        secret_kind: m.secret_kind,
        group: m.group,
    }
}

impl BrokerHost for TauriBrokerHost {
    fn broker(&self) -> &BrokerState {
        self.0.state::<BrokerState>().inner()
    }

    fn agent_ssh(&self) -> &AgentSshStore {
        self.0.state::<AgentSshStore>().inner()
    }

    fn emit(&self, event: &str, payload: Value) -> Result<(), String> {
        self.0.emit(event, payload).map_err(|e| e.to_string())
    }

    fn vault_is_unlocked(&self) -> bool {
        crate::credstore::is_unlocked(&self.0.state::<crate::credstore::CredStore>())
    }

    fn vault_list_meta(&self) -> Result<Vec<SecretMeta>, String> {
        crate::credstore::list_meta(&self.0.state::<crate::credstore::CredStore>())
            .map(|v| v.into_iter().map(secret_meta).collect())
    }

    fn vault_add_credential(
        &self,
        name: String,
        description: String,
        kind: String,
        value: String,
    ) -> Result<SecretMeta, String> {
        crate::credstore::add_credential(
            &self.0.state::<crate::credstore::CredStore>(),
            name,
            description,
            kind,
            value,
        )
        .map(secret_meta)
    }

    fn vault_secret_for_ref(&self, reference: &str) -> Result<Zeroizing<String>, String> {
        crate::credstore::secret_for_ref(&self.0.state::<crate::credstore::CredStore>(), reference)
    }

    fn vault_secret_for(&self, id: &str) -> Result<Zeroizing<String>, String> {
        crate::credstore::secret_for(&self.0.state::<crate::credstore::CredStore>(), id)
    }

    fn vault_edit_credential(
        &self,
        reference: &str,
        e: muya_core::broker::SecretEdit,
    ) -> Result<SecretMeta, String> {
        let edit = crate::credstore::CredEdit {
            value: e.value,
            new_name: e.new_name,
            description: e.description,
            kind: e.kind,
            group: e.group,
        };
        crate::credstore::edit_credential(&self.0.state::<crate::credstore::CredStore>(), reference, edit)
            .map(secret_meta)
    }

    async fn cyberark_password(&self, account_id: &str) -> Result<Zeroizing<String>, String> {
        let cyber = self.0.state::<crate::cyberark::CyberarkState>();
        crate::cyberark::fetch_password(&cyber, account_id).await
    }

    async fn schedule_op(
        &self,
        op: String,
        key: Option<String>,
        fields: Option<Value>,
        enabled: Option<bool>,
        limit: Option<usize>,
    ) -> Result<Value, String> {
        let app = self.0.clone();
        tauri::async_runtime::spawn_blocking(move || {
            crate::schedules::agent_op(&app, &op, key.as_deref(), fields.as_ref(), enabled, limit)
        })
        .await
        .unwrap_or_else(|e| Err(e.to_string()))
    }

    async fn bridge_handle(&self, op: &str, args: &Value, caller: &str) -> Value {
        crate::bridge_mcp::handle(&self.0, op, args, caller).await
    }

    fn list_agent_sessions_fresh(include_all: Option<bool>) -> Result<Vec<AgentSession>, String> {
        muya_core::broker::default_list_agent_sessions_fresh(include_all)
    }

    fn read_transcript_tail(
        cwd: &str,
        session_id: &str,
        limit: usize,
        query: Option<&str>,
    ) -> Result<String, String> {
        muya_core::broker::default_read_transcript_tail(cwd, session_id, limit, query)
    }
}

/// Running sessions (non-stopped), for `bridge_mcp`'s name resolution.
pub(crate) fn running_sessions() -> Result<Vec<AgentSession>, String> {
    muya_core::broker::running_sessions::<TauriBrokerHost>()
}


/// Absolute path to register for the `muya-ssh-mcp` proxy binary.
///
/// Never a path inside the app bundle when running from one: a translocated launch
/// runs from a mount macOS deletes on quit, and the registered path died with it
/// (`ENOENT .../AppTranslocation/.../muya-ssh-mcp`, no SSH tools). The helper is
/// copied to a fixed per-user location instead — see `app_location`.
/// Dev (`target/debug`) registers the freshly built binary beside the exe.
pub(crate) fn mcp_binary_path() -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| format!("current_exe: {e}"))?;
    Ok(crate::app_location::stable_mcp_binary(&exe)?
        .to_string_lossy()
        .into_owned())
}

/// Register (or refresh) the `muya-mcp` stdio entry in `~/.claude.json`.
/// Idempotent — `install_mcp` merges by key, so running twice never duplicates.
/// Also drops the legacy `muya-ssh` entry so the rename doesn't leave a stale twin.
pub(crate) fn register_mcp() -> Result<(), String> {
    let command = mcp_binary_path()?;
    let _ = crate::fs::remove_legacy_muya_mcp(MCP_LEGACY_ENTRY_NAME);
    // opencode reads a different file in a different shape. Best-effort: a machine
    // without opencode should not fail Claude's registration, which is the one that
    // must always work. Logged so a genuine failure is still findable.
    if let Err(e) =
        crate::fs::install_opencode_mcp(MCP_ENTRY_NAME.to_string(), command.clone(), vec![])
    {
        crate::debuglog::log(&format!("[mcp] opencode registration skipped: {e}"));
    }
    crate::fs::install_mcp(MCP_ENTRY_NAME.to_string(), command, vec![])
}

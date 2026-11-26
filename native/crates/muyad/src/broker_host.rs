//! The MCP broker hosted inside muyad (PRD AC4): `muya_core::broker` over [`MuyadBrokerHost`].
//!
//! The password store is the one the daemon's `vault.*` RPCs unlock (`with_vault`): locked until the operator
//! unlocks it, then the same secrets classic Muya's broker serves. CyberArk and bridge ops say they are not
//! available in the native daemon yet.

use crate::Muyad;
use crate::bridge_host::MuyadBridgeHost;
use muya_core::bridge_host::BridgeHost;
use muya_core::agent_ssh::AgentSshStore;
use muya_core::delivery_keys::{self, DeliveryKeys};
use muya_core::broker::{self, AgentSession, BrokerHost, BrokerState, SecretMeta, TerminalInfo};
use muya_core::credstore::{self, CredStore};
use muya_core::schedules::ScheduleState;
use serde_json::{Value, json};
use std::sync::Arc;
use zeroize::Zeroizing;

const LOCKED: &str = "password store is locked — unlock it in the Password Store tab";
const NOT_YET: &str = "not available in the native daemon yet";

fn secret_meta(m: credstore::CredMeta) -> SecretMeta {
    SecretMeta { label: m.label, description: m.description, secret_kind: m.secret_kind, group: m.group }
}

/// A store error that only means "not unlocked" becomes the standard locked text; anything else is shown as it is.
fn locked_or(e: String) -> String {
    if e.to_lowercase().contains("locked") { LOCKED.to_string() } else { e }
}

struct Inner {
    muyad: Arc<Muyad>,
    broker: BrokerState,
    agent_ssh: AgentSshStore,
    schedules: ScheduleState,
    /// Persisted `send_to_session` idempotency keys (PRD AC25); survives a daemon kill.
    delivery_keys: DeliveryKeys,
    /// The bridge behind the `bridge_*` agent tools; None = they answer "not available".
    bridge: Option<MuyadBridgeHost>,
    /// The password store (locked until `vault.unlock`); the Rpc serves the same one.
    vault: Arc<CredStore>,
    /// The CyberArk logon the Rpc serves (`cyberark.logon`); `ssh_open` fetches passwords with it.
    cyberark: Arc<muya_core::cyberark::CyberarkState>,
    /// `ssh_open` session id -> the terminal session it opened (for `ssh_send`).
    ssh_tabs: std::sync::Mutex<std::collections::HashMap<String, u64>>,
}

/// How often the idle reaper looks (classic `lib.rs`: every 5 minutes; sessions go after `IDLE_TIMEOUT`, 30 minutes).
pub const REAP_EVERY: std::time::Duration = std::time::Duration::from_secs(5 * 60);

/// The reaper loop: every `every`, close the sessions idle for `idle`. `rounds` limits it (tests); None = for ever.
pub fn run_idle_reaper(store: &muya_core::agent_ssh::AgentSshStore, every: std::time::Duration, idle: std::time::Duration, rounds: Option<usize>) {
    let mut n = 0;
    while rounds.map_or(true, |r| n < r) {
        std::thread::sleep(every);
        for id in muya_core::agent_ssh::reap_idle(store, idle) {
            muya_core::debuglog::log(&format!("[agent-ssh] reaped idle session {id}"));
        }
        n += 1;
    }
}

#[derive(Clone)]
pub struct MuyadBrokerHost(Arc<Inner>);

impl MuyadBrokerHost {
    /// `schedules`: the daemon's timers (`--scheduler`) or a store-only client.
    pub fn new(muyad: Arc<Muyad>, schedules: ScheduleState) -> Self {
        let delivery_keys = DeliveryKeys::in_claude_dir(&muya_core::schedules::claude_dir());
        Self(Arc::new(Inner { muyad, broker: BrokerState::default(), agent_ssh: AgentSshStore::default(), schedules, delivery_keys, bridge: None, vault: Arc::new(CredStore::default()), cyberark: Arc::default(), ssh_tabs: Default::default() }))
    }

    /// Agent SSH sessions (`ssh_session_open`) have no other garbage collector: one the agent never closes (crash, context
    /// reset) would keep its PTY and connection for as long as muyad runs. Same cadence and timeout as classic.
    pub fn start_idle_reaper(&self, every: std::time::Duration, idle: std::time::Duration) {
        let store = self.0.agent_ssh.clone();
        let _ = std::thread::Builder::new().name("agent-ssh-reaper".into()).spawn(move || run_idle_reaper(&store, every, idle, None));
    }

    /// Fetch CyberArk passwords with the logon `c` (the store the Rpc logs on); call before `spawn`.
    pub fn with_cyberark(self, cyberark: Arc<muya_core::cyberark::CyberarkState>) -> Self {
        let inner = Arc::try_unwrap(self.0).unwrap_or_else(|_| unreachable!("with_cyberark is called before the host is shared"));
        Self(Arc::new(Inner { cyberark, ..inner }))
    }

    /// Read secrets from `vault` (the store the Rpc unlocks); call before `spawn`.
    pub fn with_vault(self, vault: Arc<CredStore>) -> Self {
        let inner = Arc::try_unwrap(self.0).unwrap_or_else(|_| unreachable!("with_vault is called before the host is shared"));
        Self(Arc::new(Inner { vault, ..inner }))
    }

    /// Serve the `bridge_*` agent tools from `bridge` (call before `spawn`).
    pub fn with_bridge(self, bridge: MuyadBridgeHost) -> Self {
        let inner = Arc::try_unwrap(self.0).unwrap_or_else(|_| unreachable!("with_bridge is called before the host is shared"));
        Self(Arc::new(Inner { bridge: Some(bridge), ..inner }))
    }

    /// Binds the broker socket and serves it on a dedicated tokio runtime thread. Fails (and
    /// leaves the socket alone) when a live broker already owns it, e.g. the Tauri app.
    pub fn spawn(self) -> Result<(), String> {
        self.start_idle_reaper(REAP_EVERY, muya_core::agent_ssh::IDLE_TIMEOUT);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("broker".into())
            .spawn(move || {
                let rt = match tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() {
                    Ok(rt) => rt,
                    Err(e) => return drop(tx.send(Err(format!("tokio runtime: {e}")))),
                };
                rt.block_on(async move {
                    let host = self.clone();
                    let started = broker::enable_broker_listener(&self.0.broker, host).await;
                    let ok = started.is_ok();
                    let _ = tx.send(started);
                    if ok {
                        std::future::pending::<()>().await;
                    }
                });
            })
            .map_err(|e| e.to_string())?;
        rx.recv().map_err(|_| "broker thread died".to_string())?
    }
}

impl BrokerHost for MuyadBrokerHost {
    fn broker(&self) -> &BrokerState {
        &self.0.broker
    }

    fn agent_ssh(&self) -> &AgentSshStore {
        &self.0.agent_ssh
    }

    fn emit(&self, event: &str, payload: Value) -> Result<(), String> {
        match event {
            // The agent's `ssh_open` / `ssh_send`: the daemon owns the terminal, so it opens it (with the password
            // injected) and types into it; there is no app-side handler to wait for.
            "ssh-broker-open" => {
                let server_id = payload["serverId"].as_str().ok_or("serverId missing")?.to_string();
                let session = payload["sessionId"].as_str().ok_or("sessionId missing")?.to_string();
                let cfg = muya_core::ssh::load_config()?;
                let server = cfg.servers.iter().find(|s| s.id == server_id).ok_or("server not found")?.clone();
                // `emit` is sync but runs inside the broker's async task: resolve the (async) secret on a thread of its own
                // so a nested runtime is never started on this one.
                let host = self.clone();
                let srv = server.clone();
                let secret = std::thread::spawn(move || {
                    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
                    rt.block_on(crate::ssh_connect::resolve_secret(&host.0.vault, &host.0.cyberark, &srv)).map_err(locked_or)
                })
                .join()
                .map_err(|_| "secret lookup panicked".to_string())??;
                let id = self.0.muyad.ssh_connect(&server_id, secret, None, None)?;
                self.0.ssh_tabs.lock().unwrap().insert(session, id);
                Ok(())
            }
            "ssh-broker-send" => {
                let session = payload["sessionId"].as_str().unwrap_or_default();
                let text = payload["text"].as_str().unwrap_or_default();
                let id = self.0.ssh_tabs.lock().unwrap().get(session).copied().ok_or("no such ssh tab")?;
                self.0.muyad.type_raw(id, text)
            }
            _ => self.0.muyad.emit_event(event, &payload),
        }
    }

    fn claim_delivery(&self, key: &str) -> Result<bool, String> {
        self.0.delivery_keys.claim(key, delivery_keys::now_ms())
    }

    fn release_delivery(&self, key: &str) {
        self.0.delivery_keys.release(key);
    }

    fn vault_is_unlocked(&self) -> bool {
        credstore::is_unlocked(&self.0.vault)
    }

    fn vault_list_meta(&self) -> Result<Vec<SecretMeta>, String> {
        credstore::list_meta(&self.0.vault).map(|v| v.into_iter().map(secret_meta).collect()).map_err(locked_or)
    }

    fn vault_add_credential(&self, name: String, description: String, kind: String, value: String) -> Result<SecretMeta, String> {
        credstore::add_credential(&self.0.vault, name, description, kind, value).map(secret_meta).map_err(locked_or)
    }

    fn vault_secret_for_ref(&self, reference: &str) -> Result<Zeroizing<String>, String> {
        credstore::secret_for_ref(&self.0.vault, reference).map_err(locked_or)
    }

    fn vault_secret_for(&self, id: &str) -> Result<Zeroizing<String>, String> {
        credstore::secret_for(&self.0.vault, id).map_err(locked_or)
    }

    fn vault_edit_credential(&self, reference: &str, e: muya_core::broker::SecretEdit) -> Result<SecretMeta, String> {
        let edit = credstore::CredEdit { value: e.value, new_name: e.new_name, description: e.description, kind: e.kind, group: e.group };
        credstore::edit_credential(&self.0.vault, reference, edit).map(secret_meta).map_err(locked_or)
    }

    async fn cyberark_password(&self, account_id: &str) -> Result<Zeroizing<String>, String> {
        muya_core::cyberark::fetch_password(&self.0.cyberark, account_id).await.map_err(|e| if e.contains("not logged on") { "log on to CyberArk first (SSH > CyberArk tab)".to_string() } else { e })
    }

    async fn schedule_op(&self, op: String, key: Option<String>, fields: Option<Value>, enabled: Option<bool>, limit: Option<usize>) -> Result<Value, String> {
        let state = self.0.schedules.clone();
        // File I/O and a std mutex: keep them off the broker's async threads.
        tokio::task::spawn_blocking(move || state.agent_op(&op, key.as_deref(), fields.as_ref(), enabled, limit))
            .await
            .map_err(|e| e.to_string())?
    }

    async fn bridge_handle(&self, op: &str, args: &Value, caller: &str) -> Value {
        match &self.0.bridge {
            // The bridge runs on its own runtime; this call is already inside the broker's.
            Some(b) => {
                let (b, op, args, caller) = (b.clone(), op.to_string(), args.clone(), caller.to_string());
                let rt = b.runtime();
                match rt.spawn(async move { muya_core::bridge_mcp::handle(&b, &op, &args, &caller).await }).await {
                    Ok(v) => v,
                    Err(e) => json!({ "ok": false, "error": format!("bridge task failed: {e}") }),
                }
            }
            None => json!({ "ok": false, "error": format!("the bridge is {NOT_YET}") }),
        }
    }

    fn terminal_list(&self) -> Result<Vec<TerminalInfo>, String> {
        self.0.muyad.terminals()
    }

    fn terminal_open(&self, name: &str, cwd: Option<&str>, command: Option<&str>) -> Result<u64, String> {
        self.0.muyad.open_terminal(name, cwd, command)
    }

    fn terminal_type(&self, id: u64, text: &str, enter: bool, agent: bool) -> Result<(), String> {
        self.0.muyad.type_text(id, text, enter, agent)
    }

    fn terminal_lines(&self, id: u64) -> Option<Vec<String>> {
        self.0.muyad.screen_lines(id)
    }

    fn terminal_close(&self, id: u64) -> Result<(), String> {
        self.0.muyad.close_terminal(id)
    }

    fn terminal_text(&self, id: u64) -> Option<String> {
        self.0.muyad.screen_text(id)
    }

    fn terminal_echo(&self, id: u64) -> Option<bool> {
        self.0.muyad.pty_echo(id)
    }

    fn terminal_raw(&self, id: u64, text: &str) -> Result<(), String> {
        self.0.muyad.type_raw(id, text)
    }

    /// muyad owns the terminals: `open_session` / `send_to_session` confirm what they did.
    /// `MUYA_BROKER_TRACKING=off` restores fire-and-forget (tests that run without a Claude).
    fn tracking(&self) -> Option<muya_core::broker::Tracking> {
        let mut t = muya_core::broker::Tracking::default();
        match std::env::var("MUYA_BROKER_TRACKING").as_deref() {
            Ok("off") => return None,
            // "fast": short waits, for tests that expect a failure
            Ok("fast") => {
                t.open_wait = std::time::Duration::from_secs(3);
                t.submit_wait = std::time::Duration::from_secs(3);
                t.poll = std::time::Duration::from_millis(100);
            }
            _ => {}
        }
        Some(t)
    }

    fn list_agent_sessions_fresh(include_all: Option<bool>) -> Result<Vec<AgentSession>, String> {
        broker::default_list_agent_sessions_fresh(include_all)
    }

    fn read_transcript_tail(cwd: &str, session_id: &str, limit: usize, query: Option<&str>) -> Result<String, String> {
        broker::default_read_transcript_tail(cwd, session_id, limit, query)
    }
}

#[cfg(test)]
mod reaper_tests {
    use super::*;
    use muya_core::agent_ssh;
    use std::time::Duration;

    fn alive(pid: u32) -> bool {
        unsafe { libc::kill(pid as i32, 0) == 0 }
    }

    /// The daemon's loop (the thread `start_idle_reaper` runs) reaps an idle session by itself: with a short injected timeout the
    /// session is gone from the store and its child process is dead, with nobody calling `close`.
    #[test]
    fn the_reaper_loop_closes_an_idle_session_and_reaps_its_child() {
        let store = agent_ssh::AgentSshStore::default();
        let (_id, pid) = agent_ssh::spawn_unprobed(&store, "/bin/sleep", &["600".into()]).expect("child");
        let pid = pid.unwrap();
        assert!(alive(pid));
        run_idle_reaper(&store, Duration::from_millis(250), Duration::from_millis(100), Some(2));
        assert_eq!(agent_ssh::session_count(&store), 0, "the idle session was closed by the loop");
        assert!(!alive(pid), "its child was killed and reaped");
    }

    #[test]
    fn reaper_cadence_matches_classic() {
        assert_eq!(REAP_EVERY, Duration::from_secs(300));
        assert_eq!(agent_ssh::IDLE_TIMEOUT, Duration::from_secs(1800));
    }
}

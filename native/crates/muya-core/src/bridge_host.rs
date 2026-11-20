//! What the bridge modules (`bridge`, `bridge_exec`, `bridge_mcp`, `bridge_remote`) need from
//! whoever hosts them. The Tauri app implements it in `src-tauri/src/bridge.rs`
//! (`TauriBridgeHost`); `muyad` will supply its own. Derived from the call sites, nothing more:
//! UI events, the async runtime, the shared remote-bridge state and the running-session list.

use crate::broker::AgentSession;
use crate::bridge_remote::RemoteBridgeState;

/// Generic (never `dyn`) like [`crate::broker::BrokerHost`]; `Clone` because the accept loops
/// and pollers hand a copy to every spawned task.
pub trait BridgeHost: Clone + Send + Sync + 'static {
    /// Deliver a `bridge://…` event to the UI. Same shape as Tauri's `Emitter::emit`, so the
    /// call sites are unchanged; callers treat a failure as best effort.
    fn emit<P: serde::Serialize + Clone>(&self, event: &str, payload: P) -> Result<(), String>;

    /// The tokio runtime that long-lived bridge tasks are spawned onto. Needed (instead of a
    /// bare `tokio::spawn`) because `bridge_mcp::start_pollers` runs from Tauri's synchronous
    /// `setup`, outside any runtime context. Tauri's `async_runtime` is a tokio runtime.
    fn runtime(&self) -> tokio::runtime::Handle;

    /// The app-wide remote bridge state (peers, chat queues, listeners).
    fn remote_state(&self) -> &RemoteBridgeState;

    /// Ids/names of the Claude sessions running right now (for `bridge_send` target resolution).
    fn running_sessions(&self) -> Result<Vec<AgentSession>, String>;
}

//! The bridge (local socket + mTLS/SPAKE2 remote pairing) hosted inside muyad (parity package P10):
//! `muya_core::bridge*` over [`MuyadBridgeHost`]. One instance is shared by the Rpc methods
//! (`bridge.*`, see `rpc_bridge`) and the MCP broker (`bridge_*` agent tools), so both see the same
//! listeners, peers and held messages. The bridge's UI events leave as `Control::Event`s with the
//! names and payloads the Tauri app emits (`bridge://…`).

use crate::Muyad;
use muya_core::bridge::BridgeState;
use muya_core::bridge_exec::ExecState;
use muya_core::bridge_host::BridgeHost;
use muya_core::bridge_remote::RemoteBridgeState;
use muya_core::broker::AgentSession;
use std::sync::{Arc, Weak};

struct Inner {
    muyad: Weak<Muyad>,
    remote: RemoteBridgeState,
    local: BridgeState,
    /// Auto-run grants + the memory-only audit log (P11); never written to disk.
    exec: ExecState,
    /// The listeners and pollers live on their own runtime thread pool, like the broker's.
    rt: tokio::runtime::Runtime,
}

#[derive(Clone)]
pub struct MuyadBridgeHost(Arc<Inner>);

impl MuyadBridgeHost {
    pub fn new(muyad: Weak<Muyad>) -> Result<Self, String> {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("bridge")
            .enable_all()
            .build()
            .map_err(|e| format!("tokio runtime: {e}"))?;
        Ok(Self(Arc::new(Inner {
            muyad,
            remote: RemoteBridgeState::default(),
            local: BridgeState::default(),
            exec: ExecState::default(),
            rt,
        })))
    }

    pub fn local(&self) -> &BridgeState {
        &self.0.local
    }

    pub fn exec(&self) -> &ExecState {
        &self.0.exec
    }

    /// Runs a bridge future to completion from a plain (non-async) thread — an Rpc call.
    pub fn block_on<F: std::future::Future>(&self, f: F) -> F::Output {
        self.0.rt.block_on(f)
    }

    /// Resume polling every peer we dialed (their queued messages reach us without an agent
    /// touching a bridge tool first). Cheap when there are no peers.
    pub fn start_pollers(&self) {
        muya_core::bridge_mcp::start_pollers(self.clone());
    }
}

impl BridgeHost for MuyadBridgeHost {
    fn emit<P: serde::Serialize + Clone>(&self, event: &str, payload: P) -> Result<(), String> {
        let value = serde_json::to_value(payload).map_err(|e| format!("encode: {e}"))?;
        match self.0.muyad.upgrade() {
            Some(m) => m.emit_event(event, &value),
            None => Err("muyad is gone".into()),
        }
    }

    fn runtime(&self) -> tokio::runtime::Handle {
        self.0.rt.handle().clone()
    }

    fn remote_state(&self) -> &RemoteBridgeState {
        &self.0.remote
    }

    fn running_sessions(&self) -> Result<Vec<AgentSession>, String> {
        muya_core::broker::running_sessions::<crate::broker_host::MuyadBrokerHost>()
    }
}

//! Bridge chat/MCP ops — logic in `muya_core::bridge_mcp`; this shim binds it to the Tauri host.

use serde_json::Value;
use tauri::AppHandle;

use crate::bridge::TauriBridgeHost;


/// App start: resume polling every peer we dialed.
pub fn start_pollers(app: AppHandle) {
    muya_core::bridge_mcp::start_pollers(TauriBridgeHost(app))
}

/// One `bridge_*` MCP tool call from the broker.
pub async fn handle(app: &AppHandle, op: &str, args: &Value, caller: &str) -> Value {
    muya_core::bridge_mcp::handle(&TauriBridgeHost(app.clone()), op, args, caller).await
}

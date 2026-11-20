//! P10 Rpc methods: the local bridge socket (`bridge.local_*`, `bridge.poll_inbound`, `bridge.send`,
//! `bridge.approve`) and the remote pairing / mTLS peers (`bridge.remote_*`, `bridge.pair_*`,
//! `bridge.*_peer*`, `bridge.check_port`). Same behaviour as the Tauri commands of the same names;
//! parameters are camelCase like Tauri's arguments.
//!
//! SECURITY: inbound messages are untrusted data and are never executed here — a staged local
//! request still needs `bridge.approve`, and the remote path only queues/delivers text (muya_core
//! does the sanitising). Nothing in this file logs a pairing PIN or the SAS.

use crate::bridge_host::MuyadBridgeHost;
use muya_core::bridge;
use muya_core::bridge_exec as exec;
use muya_core::bridge_host::BridgeHost;
use muya_core::bridge_remote as remote;
use serde::Deserialize;
use serde_json::Value;

#[derive(Deserialize)]
struct EnableParams {
    enable: bool,
    #[serde(default)]
    iface: String,
}

#[derive(Deserialize)]
struct SendParams {
    peer: String,
    kind: String,
    #[serde(default)]
    payload: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ApproveParams {
    req_id: String,
    decision: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairListenerParams {
    pairing_iface: String,
}

#[derive(Deserialize)]
struct AddrParams {
    addr: String,
}

#[derive(Deserialize)]
struct ConnectParams {
    addr: String,
    pin: String,
    #[serde(default)]
    label: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfirmParams {
    peer_spki: String,
    sas_ok: bool,
    #[serde(default)]
    label: String,
    /// The code the other machine shows. When given it must equal ours, or nothing is pinned
    /// (a wrong PIN shows up as two different codes).
    #[serde(default)]
    their_sas: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RevokeParams {
    spki_hash: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CapabilityParams {
    peer_spki: String,
    capability: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AutoRunParams {
    peer_spki: String,
    #[serde(default)]
    capabilities: Vec<String>,
    #[serde(default)]
    shell_auto_run_override: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExecuteParams {
    req_id: String,
    peer_spki: String,
}

#[derive(Deserialize)]
struct FanOutParams {
    #[serde(default)]
    payload: Value,
    #[serde(default)]
    targets: Vec<Value>,
}

#[derive(Deserialize)]
struct RunClaudeParams {
    question: String,
}

fn to_value<T: serde::Serialize>(v: &T) -> Result<Value, String> {
    serde_json::to_value(v).map_err(|e| format!("encode: {e}"))
}

fn arg<T: serde::de::DeserializeOwned>(v: Value) -> Result<T, String> {
    serde_json::from_value(v).map_err(|e| format!("bad parameters: {e}"))
}

/// Who is behind an Rpc call. Only the app's own connection (`Operator`) may widen what a paired Mac
/// can do. Agents never reach the Rpc socket (they talk to the MCP broker, which has no such op), but the
/// gate is explicit so a future path that forwards agent calls here cannot change a peer's scope.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Caller {
    Operator,
    Agent,
}

/// Methods that change what a paired Mac may do: operator only.
fn is_scope_change(name: &str) -> bool {
    matches!(name, "set_peer_capability" | "set_capability" | "set_auto_run")
}

/// `None` = not a bridge method.
pub fn call(
    host: &MuyadBridgeHost,
    method: &str,
    caller: Caller,
    params: impl FnOnce() -> Result<Value, String>,
) -> Option<Result<Value, String>> {
    let name = method.strip_prefix("bridge.")?;
    let known = matches!(
        name,
        "local_listen"
            | "poll_inbound"
            | "send"
            | "approve"
            | "remote_listen"
            | "pair_invite"
            | "pair_start_listener"
            | "pair_stop_listener"
            | "check_port"
            | "pair_connect"
            | "pair_confirm_sas"
            | "list_peers"
            | "revoke_peer"
            | "remote_send"
            | "set_capability"
            | "set_peer_capability"
            | "set_auto_run"
            | "audit_log"
            | "execute_task"
            | "fan_out"
            | "run_claude"
    );
    if !known {
        return None;
    }
    if is_scope_change(name) && caller != Caller::Operator {
        return Some(Err("changing a paired Mac's scope is operator-only: do it in Muya Settings".into()));
    }
    Some(params().and_then(|v| run(host, name, v)))
}

fn run(host: &MuyadBridgeHost, name: &str, v: Value) -> Result<Value, String> {
    let state = host.remote_state();
    match name {
        "local_listen" => {
            let p: EnableParams = arg(v)?;
            host.block_on(bridge::bridge_local_listen(
                p.enable,
                host.local(),
                host.clone(),
            ))?;
            Ok(Value::Null)
        }
        "poll_inbound" => to_value(&host.block_on(bridge::bridge_poll_inbound(host.local()))?),
        "send" => {
            let p: SendParams = arg(v)?;
            Ok(Value::String(host.block_on(bridge::bridge_send(
                p.peer,
                p.kind,
                p.payload,
                host.local(),
            ))?))
        }
        "approve" => {
            let p: ApproveParams = arg(v)?;
            host.block_on(bridge::bridge_approve(p.req_id, p.decision, host.local()))?;
            Ok(Value::Null)
        }
        "remote_listen" => {
            let p: EnableParams = arg(v)?;
            host.block_on(remote::remote_listen_impl(state, p.enable, &p.iface, host))?;
            Ok(Value::Null)
        }
        "pair_invite" => host.block_on(remote::pair_invite_impl(state)),
        "pair_start_listener" => {
            let p: PairListenerParams = arg(v)?;
            host.block_on(remote::pair_start_listener_impl(
                state,
                p.pairing_iface,
                host.clone(),
            ))?;
            Ok(Value::Null)
        }
        "pair_stop_listener" => {
            host.block_on(remote::bridge_pair_stop_listener(state))?;
            Ok(Value::Null)
        }
        "check_port" => {
            let p: AddrParams = arg(v)?;
            to_value(&host.block_on(remote::bridge_check_port(p.addr, state))?)
        }
        "pair_connect" => {
            let p: ConnectParams = arg(v)?;
            // The pairing window is one port above the data listener (bridge_invite's convention):
            // remember the data address, the one-shot window is closed after this pairing.
            let data_addr = muya_core::bridge_mcp::data_addr_for(&p.addr)?;
            let out = host.block_on(async {
                let out = remote::pair_connect_impl(state, p.addr, p.pin, p.label).await?;
                if let Some(pending) = state.active_pin.lock().await.as_mut().and_then(|a| a.pending_sas.as_mut()) {
                    pending.peer_addr = data_addr;
                }
                Ok::<_, String>(out)
            })?;
            Ok(out)
        }
        "pair_confirm_sas" => {
            let p: ConfirmParams = arg(v)?;
            match p.their_sas.as_deref().filter(|s| !s.trim().is_empty()) {
                None => host.block_on(remote::bridge_pair_confirm_sas(
                    p.peer_spki,
                    p.sas_ok,
                    p.label,
                    state,
                ))?,
                Some(theirs) => host.block_on(async {
                    // Same SPKI check as the plain confirm, then the SAS comparison.
                    if let Some(pending) = state
                        .active_pin
                        .lock()
                        .await
                        .as_ref()
                        .and_then(|a| a.pending_sas.as_ref())
                    {
                        if p.sas_ok && pending.peer_spki != p.peer_spki {
                            return Err(format!(
                                "SPKI mismatch: expected {}, got {}",
                                pending.peer_spki, p.peer_spki
                            ));
                        }
                    }
                    let label = Some(p.label.clone());
                    remote::pair_confirm_impl(state, p.sas_ok, Some(theirs), label)
                        .await
                        .map(|_| ())
                })?,
            }
            Ok(Value::Null)
        }
        "list_peers" => to_value(&host.block_on(remote::bridge_list_peers(state))?),
        "revoke_peer" => {
            let p: RevokeParams = arg(v)?;
            host.block_on(remote::revoke_impl(state, &p.spki_hash))?;
            Ok(Value::Null)
        }
        "remote_send" => {
            let p: SendParams = arg(v)?;
            Ok(Value::String(host.block_on(remote::remote_send_impl(
                p.peer, p.kind, p.payload, state,
            ))?))
        }
        // --- P11: capability scope, auto-run, audit, gated execution, fan-out, headless Claude ---
        "set_capability" => {
            let p: CapabilityParams = arg(v)?;
            host.block_on(exec::bridge_set_capability(p.peer_spki, p.capability, state))?;
            Ok(Value::Null)
        }
        // The Settings row: Messaging (agent-paired default) or Full. Stored as "messaging" / "research".
        "set_peer_capability" => {
            let p: CapabilityParams = arg(v)?;
            host.block_on(remote::set_peer_capability(state, &p.peer_spki, &p.capability))?;
            Ok(Value::Null)
        }
        "set_auto_run" => {
            let p: AutoRunParams = arg(v)?;
            host.block_on(exec::bridge_set_auto_run(
                p.peer_spki,
                p.capabilities,
                p.shell_auto_run_override,
                host.exec(),
            ))?;
            Ok(Value::Null)
        }
        "audit_log" => to_value(&host.block_on(exec::bridge_audit_log(host.exec()))?),
        "execute_task" => {
            let p: ExecuteParams = arg(v)?;
            // The gate (capability scope, auto-run or an explicit approval) is re-checked inside.
            Ok(Value::String(host.block_on(exec::bridge_execute_task(
                p.req_id,
                p.peer_spki,
                state,
                host.exec(),
                host.local(),
                host.clone(),
            ))?))
        }
        "fan_out" => {
            let p: FanOutParams = arg(v)?;
            to_value(&host.block_on(exec::bridge_fan_out(
                p.payload,
                p.targets,
                state,
                host.exec(),
                host.local(),
                host.clone(),
            ))?)
        }
        "run_claude" => {
            let p: RunClaudeParams = arg(v)?;
            Ok(Value::String(host.block_on(exec::run_claude_headless(&p.question))?))
        }
        _ => unreachable!("filtered in call()"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host() -> MuyadBridgeHost {
        MuyadBridgeHost::new(std::sync::Weak::new()).unwrap()
    }

    #[test]
    fn agent_callers_cannot_change_a_peers_scope() {
        let h = host();
        for m in ["bridge.set_peer_capability", "bridge.set_capability", "bridge.set_auto_run"] {
            let r = call(&h, m, Caller::Agent, || Ok(serde_json::json!({ "spkiHash": "aa", "peerSpki": "aa", "capability": "full" })));
            let e = r.expect("a bridge method").unwrap_err();
            assert!(e.contains("operator-only"), "{m}: {e}");
        }
    }

    #[test]
    fn reads_are_not_scope_changes_and_unknown_methods_pass_through() {
        assert!(!is_scope_change("list_peers") && is_scope_change("set_peer_capability"));
        assert!(call(&host(), "sessions.history", Caller::Agent, || Ok(Value::Null)).is_none());
    }
}

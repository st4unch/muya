//! P2 Rpc methods: agent control (`agents.*`), operator-pinned operations (`agent_ops.*`), the
//! header CPU/RAM readout (`metrics.get`) and `vault.lock` (the `muya://vault-locked` event).
//! Same behaviour as the Tauri commands of the same names; the app is the only caller (the agents'
//! own broker socket has no path here, so `agent_ops.upsert` stays operator-only).

use crate::Muyad;
use muya_core::{agent_files, agent_ops, agents, metrics};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Executable name of the PTY daemon — counted in the readout next to muyad and the sessions.
const PTYD_NAME: &str = "muya-ptyd";
/// How long a ptyd lookup (a scan of the process table) is reused.
const PTYD_RESCAN: Duration = Duration::from_secs(30);

/// State of `metrics.get`: the persistent sampler (CPU% needs two polls) and the cached ptyd pids.
#[derive(Default)]
pub struct MetricsState {
    sampler: metrics::Metrics,
    ptyd: Mutex<Option<(Instant, Vec<u32>)>>,
}

impl MetricsState {
    fn ptyd_pids(&self) -> Vec<u32> {
        let Ok(mut cache) = self.ptyd.lock() else {
            return Vec::new();
        };
        let stale = cache
            .as_ref()
            .is_none_or(|(at, pids)| pids.is_empty() || at.elapsed() > PTYD_RESCAN);
        if stale {
            *cache = Some((
                Instant::now(),
                metrics::pids_named(&self.sampler, PTYD_NAME),
            ));
        }
        cache.as_ref().map(|(_, p)| p.clone()).unwrap_or_default()
    }

    /// `{cpu, memMb, processes:[{name,pid,cpu,memMb}]}` — muyad itself, ptyd and every live session's
    /// shell. `cpu`/`memMb` are the sums, so the header shows one number like the Tauri readout.
    pub fn get(&self, session_pids: &[i32]) -> Value {
        let ptyd = self.ptyd_pids();
        let mut procs: Vec<(String, u32)> = vec![("muyad".into(), std::process::id())];
        // A session's shell is `muya-ptyd --exec-with-ctty` for a moment before it execs into the shell, so
        // a ptyd scan landing in that window caches the session pid as a daemon (and keeps it 30 s). Sessions win.
        procs.extend(
            ptyd.iter()
                .filter(|p| !session_pids.contains(&(**p as i32)))
                .map(|p| (PTYD_NAME.to_string(), *p)),
        );
        procs.extend(
            session_pids
                .iter()
                .filter(|p| **p > 1)
                .map(|p| ("session".to_string(), *p as u32)),
        );
        let refs: Vec<(&str, u32)> = procs.iter().map(|(n, p)| (n.as_str(), *p)).collect();
        let (total, rows) = metrics::sample_many(&self.sampler, &refs);
        json!({ "cpu": total.cpu, "memMb": total.mem_mb, "processes": rows })
    }
}

#[derive(Deserialize)]
struct StopParams {
    id: String,
}

#[derive(Deserialize)]
struct KillParams {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    pid: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TouchedParams {
    cwd: String,
    session_id: String,
}

#[derive(Deserialize)]
struct OpParams {
    op: agent_ops::OpDefinition,
}

fn to_value<T: serde::Serialize>(v: &T) -> Result<Value, String> {
    serde_json::to_value(v).map_err(|e| format!("encode: {e}"))
}

/// Methods that need nothing but their parameters. `None` = not ours.
pub fn call(
    method: &str,
    params: &str,
    parse: impl Fn(&str) -> Result<Value, String>,
) -> Option<Result<Value, String>> {
    let from = |f: &dyn Fn(Value) -> Result<Value, String>| Some(parse(params).and_then(f));
    match method {
        "agents.channels_supported" => Some(Ok(json!(agents::claude_channels_supported()))),
        "agents.bins" => Some(Ok(json!({
            "claude": agents::claude_usable(),
            "opencode": muya_core::opencode::opencode_usable(),
        }))),
        "agents.stop" => from(&|v| {
            let p: StopParams =
                serde_json::from_value(v).map_err(|e| format!("bad parameters: {e}"))?;
            if p.id.trim().is_empty() || p.id.starts_with('-') {
                return Err("bad agent id".into());
            }
            Ok(json!(agents::stop_agent(p.id)?))
        }),
        "agents.kill" => from(&|v| {
            let p: KillParams =
                serde_json::from_value(v).map_err(|e| format!("bad parameters: {e}"))?;
            if let Some(id) = p.id.as_deref().filter(|s| !s.is_empty()) {
                if id.starts_with('-') {
                    return Err("bad agent id".into());
                }
            } else {
                // `kill 0` / `kill -1` would signal whole process groups, and the daemon must not
                // be able to be asked to terminate itself.
                match p.pid {
                    Some(pid)
                        if pid > 1
                            && pid != i64::from(std::process::id())
                            && pid <= i64::from(i32::MAX) => {}
                    Some(_) => return Err("refusing to signal that pid".into()),
                    None => return Err("no background id and no pid to kill".into()),
                }
            }
            Ok(json!(agents::kill_session(p.id, p.pid)?))
        }),
        "agents.touched_files" => from(&|v| {
            let p: TouchedParams =
                serde_json::from_value(v).map_err(|e| format!("bad parameters: {e}"))?;
            if !p.cwd.starts_with('/') {
                return Err("cwd must be an absolute folder path".into());
            }
            to_value(&agent_files::session_touched_files(p.cwd, p.session_id)?)
        }),
        "agent_ops.list" => Some(agent_ops::agent_ops_list().and_then(|l| to_value(&l))),
        "agent_ops.upsert" => from(&|v| {
            let p: OpParams =
                serde_json::from_value(v).map_err(|e| format!("bad parameters: {e}"))?;
            if !p.op.program.starts_with('/') {
                return Err("an operation's program must be an absolute path".into());
            }
            agent_ops::agent_ops_upsert(p.op)?;
            Ok(Value::Null)
        }),
        _ => None,
    }
}

/// `vault.lock`: forget the key and tell every attached app (same event as the Tauri app).
pub fn vault_lock(
    muyad: Option<std::sync::Arc<Muyad>>,
    vault: &muya_core::credstore::CredStore,
) -> Result<Value, String> {
    muya_core::credstore::lock_store(vault)?;
    if let Some(m) = muyad {
        m.emit_event("muya://vault-locked", &Value::Null)?;
    }
    Ok(Value::Null)
}

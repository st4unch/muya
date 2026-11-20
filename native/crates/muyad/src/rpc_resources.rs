//! P7 Rpc methods: slash commands (`slash.list`), the Claude status line (`statusline.*`) and the
//! Resources page (`resources.*`: what is installed, the two marketplaces, the three installers).
//! Same behaviour and payload shapes as the Tauri commands of the same names; the logic is
//! `muya_core::{slash_commands, statusline, fs}`.

use muya_core::{fs as core_fs, slash_commands, statusline};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::OnceLock;

/// The marketplace calls and the plugin installer are `async` in muya-core (reqwest / the blocking
/// pool); an Rpc call runs on its own plain thread, so they get a small shared runtime here.
fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("muyad-resources")
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

pub(crate) fn block_on<F: std::future::Future>(f: F) -> F::Output {
    runtime().block_on(f)
}

fn p<T: serde::de::DeserializeOwned>(params: &str) -> Result<T, String> {
    serde_json::from_str(if params.trim().is_empty() {
        "{}"
    } else {
        params
    })
    .map_err(|e| format!("bad parameters: {e}"))
}

fn enc<T: serde::Serialize>(v: &T) -> Result<Value, String> {
    serde_json::to_value(v).map_err(|e| format!("encode: {e}"))
}

#[derive(Deserialize)]
struct SlashParams {
    agent: String,
    #[serde(default)]
    cwd: Option<String>,
}

#[derive(Deserialize)]
struct PtyParams {
    #[serde(rename = "ptyId", alias = "pty_id")]
    pty_id: String,
}

#[derive(Deserialize)]
struct QueryParams {
    #[serde(default)]
    query: String,
}

#[derive(Deserialize)]
struct SkillParams {
    name: String,
    #[serde(rename = "githubUrl", alias = "github_url")]
    github_url: String,
}

#[derive(Deserialize)]
struct McpParams {
    name: String,
    command: String,
    #[serde(default)]
    args: Vec<String>,
}

/// `None` = not ours. `guard` accepts a folder only inside Muya's roots (the slash scan reads
/// `<cwd>/.claude/commands`, so a caller must not point it anywhere on disk).
pub fn call(
    method: &str,
    params: &str,
    guard: &dyn Fn(&str) -> Result<PathBuf, String>,
) -> Option<Result<Value, String>> {
    let r = match method {
        "slash.list" => (|| {
            let a: SlashParams = p(params)?;
            let cwd = match a.cwd.as_deref().filter(|c| !c.is_empty()) {
                Some(c) => Some(guard(c)?.to_string_lossy().into_owned()),
                None => None,
            };
            enc(&slash_commands::list_slash_commands(a.agent, cwd))
        })(),
        "statusline.path" => Ok(json!(statusline_settings_path())),
        "statusline.get" => (|| {
            let a: PtyParams = p(params)?;
            // The status file name comes from the id: refuse anything that is not a plain name.
            if a.pty_id.is_empty()
                || !a
                    .pty_id
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
            {
                return Err("invalid pty id".into());
            }
            ensure_statusline();
            Ok(statusline::statusline_get(a.pty_id).unwrap_or(Value::Null))
        })(),
        "resources.list" => core_fs::list_claude_resources().and_then(|r| enc(&r)),
        "resources.skills_market" => p::<QueryParams>(params)
            .and_then(|a| block_on(core_fs::fetch_skill_marketplace(a.query)))
            .and_then(|r| enc(&r)),
        "resources.mcp_market" => p::<QueryParams>(params)
            .and_then(|a| block_on(core_fs::fetch_mcp_marketplace(a.query)))
            .and_then(|r| enc(&r)),
        "resources.install_skill" => p::<SkillParams>(params)
            .and_then(|a| core_fs::install_skill(a.name, a.github_url))
            .map(|()| Value::Null),
        "resources.install_mcp" => p::<McpParams>(params)
            .and_then(|a| core_fs::install_mcp(a.name, a.command, a.args))
            .map(|()| Value::Null),
        "resources.install_muya_plugin" => {
            block_on(core_fs::install_muya_plugin()).map(Value::String)
        }
        _ => return None,
    };
    Some(r)
}

/// Sets up the status-line capture folder once per daemon (what the Tauri app does at startup).
pub(crate) fn ensure_statusline() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(statusline::init);
}

fn statusline_settings_path() -> Option<String> {
    ensure_statusline();
    statusline::statusline_settings_path()
}

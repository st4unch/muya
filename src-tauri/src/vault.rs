// Vault MCP integration — smart-connections subprocess manager.
// Spawns a persistent Python MCP server process and routes vault_search
// commands through JSON-RPC over stdin/stdout.
//
// The vault path used to be a single hardcoded OneDrive path (this developer's
// machine only) — it silently did nothing on any other machine. It's now
// resolved in priority order: user-configured path (persisted to disk) →
// OBSIDIAN_VAULT_PATH env var → auto-detected `.obsidian` folder under common
// locations. If none resolve, the feature is cleanly disabled (no subprocess
// spawn attempt, no repeated failures).

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use tauri::State;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin};
use tokio::sync::Mutex;
use tokio::time::{timeout, Duration};

// ---------------------------------------------------------------------------
// Process handle
// ---------------------------------------------------------------------------

pub struct VaultMcpProcess {
    _child: Child,
    stdin: ChildStdin,
    stdout: BufReader<tokio::process::ChildStdout>,
    next_id: u64,
}

// ---------------------------------------------------------------------------
// Tauri managed state
// ---------------------------------------------------------------------------

pub struct VaultMcpManager(pub Arc<Mutex<Option<VaultMcpProcess>>>);

impl Default for VaultMcpManager {
    fn default() -> Self {
        VaultMcpManager(Arc::new(Mutex::new(None)))
    }
}

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VaultBlock {
    pub path: String,
    pub similarity: f32,
    pub text: String,
    pub lines: Option<String>,
}

// ---------------------------------------------------------------------------
// User-configurable vault path (persisted; no more hardcoded machine path)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VaultConfig {
    /// Absolute path to an Obsidian vault (a folder containing `.obsidian/`).
    pub vault_path: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VaultStatus {
    pub configured_path: Option<String>,
    /// True if `configured_path` (or a resolved fallback) points at a real vault.
    pub resolved_path: Option<String>,
    /// False if `~/smart-connections-mcp/server.py` isn't present — the whole
    /// feature is unavailable regardless of vault path in that case.
    pub server_installed: bool,
}

fn config_file_path_under(home: &str) -> PathBuf {
    Path::new(home).join(".claude/muya-vault-config.json")
}

fn config_file_path() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    Some(config_file_path_under(&home))
}

fn load_config_from(path: &Path) -> VaultConfig {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn load_config() -> VaultConfig {
    config_file_path()
        .map(|p| load_config_from(&p))
        .unwrap_or_default()
}

fn save_config_to(path: &Path, cfg: &VaultConfig) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_string_pretty(cfg).map_err(|e| e.to_string())?;
    std::fs::write(path, json).map_err(|e| e.to_string())
}

fn save_config(cfg: &VaultConfig) -> Result<(), String> {
    let path = config_file_path().ok_or("HOME not set")?;
    save_config_to(&path, cfg)
}

/// A folder "is a vault" if it directly contains an `.obsidian` subdirectory.
fn is_obsidian_vault(dir: &Path) -> bool {
    dir.join(".obsidian").is_dir()
}

/// Scan common vault parent locations for `.obsidian` folders, depth-limited.
/// Returns absolute paths, most-recently-modified first.
fn detect_vaults() -> Vec<String> {
    let home = match std::env::var("HOME") {
        Ok(h) => h,
        Err(_) => return vec![],
    };
    let roots = vec![
        format!("{home}/Documents"),
        format!("{home}/Obsidian"),
        format!("{home}/Library/Mobile Documents/iCloud~md~obsidian/Documents"),
        format!("{home}/Library/CloudStorage"),
        home.clone(),
    ];
    scan_roots_for_vaults(roots)
}

/// Depth-limited (root, root/*, root/*/*) `.obsidian` scan over explicit
/// root directories — split out from `detect_vaults` so tests can scan a
/// temp dir instead of the real HOME.
fn scan_roots_for_vaults(roots: Vec<String>) -> Vec<String> {
    let mut found: Vec<(std::time::SystemTime, String)> = Vec::new();
    for root in roots {
        let root_path = Path::new(&root);
        if !root_path.is_dir() {
            continue;
        }
        if is_obsidian_vault(root_path) {
            let mtime = root_path
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            found.push((mtime, root.clone()));
        }
        // One level deep (covers CloudStorage/<provider>/<vault>, Documents/<vault>).
        let Ok(entries) = std::fs::read_dir(root_path) else {
            continue;
        };
        for entry in entries.flatten() {
            let p = entry.path();
            if !p.is_dir() {
                continue;
            }
            if is_obsidian_vault(&p) {
                let mtime = p
                    .metadata()
                    .and_then(|m| m.modified())
                    .unwrap_or(std::time::UNIX_EPOCH);
                found.push((mtime, p.to_string_lossy().into_owned()));
                continue;
            }
            // Two levels deep for CloudStorage/<provider>/<subfolders>/<vault>.
            let Ok(sub_entries) = std::fs::read_dir(&p) else {
                continue;
            };
            for sub in sub_entries.flatten() {
                let sp = sub.path();
                if sp.is_dir() && is_obsidian_vault(&sp) {
                    let mtime = sp
                        .metadata()
                        .and_then(|m| m.modified())
                        .unwrap_or(std::time::UNIX_EPOCH);
                    found.push((mtime, sp.to_string_lossy().into_owned()));
                }
            }
        }
    }
    found.sort_by(|a, b| b.0.cmp(&a.0));
    found.dedup_by(|a, b| a.1 == b.1);
    found.into_iter().map(|(_, p)| p).take(10).collect()
}

/// Resolve the vault path to use, in priority order. No hardcoded fallback —
/// if nothing resolves, the feature is simply unavailable on this machine.
fn resolve_vault_path() -> Option<String> {
    if let Some(p) = load_config().vault_path {
        if is_obsidian_vault(Path::new(&p)) {
            return Some(p);
        }
    }
    if let Ok(p) = std::env::var("OBSIDIAN_VAULT_PATH") {
        if is_obsidian_vault(Path::new(&p)) {
            return Some(p);
        }
    }
    detect_vaults().into_iter().next()
}

/// Directory where the smart-connections MCP server lives. Overridable with
/// `VAULT_MCP_DIR` so the app doesn't hard-require exactly `~/smart-connections-mcp`.
fn mcp_dir() -> Option<PathBuf> {
    if let Ok(d) = std::env::var("VAULT_MCP_DIR") {
        let p = PathBuf::from(d);
        if p.is_dir() {
            return Some(p);
        }
    }
    let home = std::env::var("HOME").ok()?;
    let p = Path::new(&home).join("smart-connections-mcp");
    p.is_dir().then_some(p)
}

fn server_script_path() -> Option<PathBuf> {
    let p = mcp_dir()?.join("server.py");
    p.is_file().then_some(p)
}

/// Does this venv have `sentence_transformers` installed? Fast filesystem check
/// (`<venv>/lib/python*/site-packages/sentence_transformers`) — no subprocess,
/// no heavy import. Guards against selecting an empty/broken venv.
fn venv_has_deps(venv_dir: &Path) -> bool {
    let lib = venv_dir.join("lib");
    let Ok(entries) = std::fs::read_dir(&lib) else {
        return false;
    };
    for e in entries.flatten() {
        // e = lib/python3.X
        if e.path()
            .join("site-packages/sentence_transformers")
            .is_dir()
        {
            return true;
        }
    }
    false
}

/// Resolve the Python interpreter to run the MCP server, in priority order:
///   1. `VAULT_PYTHON` env — explicit override (always wins, trusted as-is).
///   2. `<mcp_dir>/.venv/bin/python` — the venv `install.sh` creates, but ONLY
///      if it actually has the deps (guards a broken/empty venv from shadowing
///      a working global install). This is the portable path: clone + install.sh.
///   3. `/opt/homebrew/bin/python3.11` — legacy fallback (works when the heavy
///      deps are installed globally there, as on the original dev machine).
///   4. `python3` on PATH — last resort.
fn resolve_python() -> String {
    if let Ok(p) = std::env::var("VAULT_PYTHON") {
        if !p.trim().is_empty() {
            return p;
        }
    }
    if let Some(dir) = mcp_dir() {
        let venv_py = dir.join(".venv/bin/python");
        if venv_py.is_file() && venv_has_deps(&dir.join(".venv")) {
            return venv_py.to_string_lossy().into_owned();
        }
    }
    if Path::new("/opt/homebrew/bin/python3.11").is_file() {
        return "/opt/homebrew/bin/python3.11".to_string();
    }
    "python3".to_string()
}

/// Tauri command: current config + resolution state, for a Settings UI.
#[tauri::command]
pub fn vault_get_status() -> VaultStatus {
    let cfg = load_config();
    VaultStatus {
        configured_path: cfg.vault_path,
        resolved_path: resolve_vault_path(),
        server_installed: server_script_path().is_some(),
    }
}

/// Tauri command: list auto-detected vault candidates for a picker UI.
#[tauri::command]
pub fn vault_detect_candidates() -> Vec<String> {
    detect_vaults()
}

/// Tauri command: persist a user-chosen vault path. Validates it's a real
/// vault (contains `.obsidian/`) before saving.
#[tauri::command]
pub fn vault_set_path(path: String) -> Result<(), String> {
    let p = path.trim();
    if p.is_empty() {
        return Err("path is required".into());
    }
    if !is_obsidian_vault(Path::new(p)) {
        return Err("not an Obsidian vault (no .obsidian folder found)".into());
    }
    save_config(&VaultConfig {
        vault_path: Some(p.to_string()),
    })
}

/// Tauri command: kill the current MCP subprocess (if any) and respawn +
/// warm up with the current resolved config. Used after the user changes the
/// vault path, so the new path takes effect without an app restart.
#[tauri::command]
pub async fn vault_restart(state: State<'_, VaultMcpManager>) -> Result<(), String> {
    let manager = state.0.clone();
    {
        let mut lock = manager.lock().await;
        *lock = None; // drop = kill_on_drop kills the old subprocess
    }
    warmup_vault(manager).await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Low-level I/O helpers
// ---------------------------------------------------------------------------

async fn send_json(stdin: &mut ChildStdin, value: &serde_json::Value) -> Result<(), String> {
    let mut s = serde_json::to_string(value).map_err(|e| e.to_string())?;
    s.push('\n');
    stdin
        .write_all(s.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    stdin.flush().await.map_err(|e| e.to_string())?;
    Ok(())
}

async fn read_json_line(
    stdout: &mut BufReader<tokio::process::ChildStdout>,
) -> Result<serde_json::Value, String> {
    let mut line = String::new();
    stdout
        .read_line(&mut line)
        .await
        .map_err(|e| e.to_string())?;
    if line.is_empty() {
        return Err("subprocess_closed".to_string());
    }
    serde_json::from_str(line.trim()).map_err(|e| format!("json_parse: {}: {}", e, line.trim()))
}

// ---------------------------------------------------------------------------
// JSON-RPC response parser → Vec<VaultBlock>
// ---------------------------------------------------------------------------

fn parse_mcp_response(v: serde_json::Value) -> Result<Vec<VaultBlock>, String> {
    if let Some(err) = v.get("error") {
        return Err(format!("mcp_error: {}", err));
    }

    let content = v
        .get("result")
        .and_then(|r| r.get("content"))
        .and_then(|c| c.as_array())
        .ok_or_else(|| "no_results".to_string())?;

    if content.is_empty() {
        return Err("no_results".to_string());
    }

    let mut blocks: Vec<VaultBlock> = Vec::new();

    for item in content {
        if item.get("type").and_then(|t| t.as_str()) != Some("text") {
            continue;
        }
        let text = item.get("text").and_then(|t| t.as_str()).unwrap_or("");

        // Try parsing as JSON — could be {blocks:[...]} wrapper or a raw array.
        let json_blocks: Vec<serde_json::Value> =
            if let Ok(wrapper) = serde_json::from_str::<serde_json::Value>(text) {
                if let Some(arr) = wrapper.get("blocks").and_then(|b| b.as_array()) {
                    arr.clone()
                } else if let Some(arr) = wrapper.as_array() {
                    arr.clone()
                } else {
                    vec![wrapper]
                }
            } else {
                vec![]
            };

        if !json_blocks.is_empty() {
            for block in &json_blocks {
                let path = block
                    .get("path")
                    .and_then(|p| p.as_str())
                    .unwrap_or("vault")
                    .to_string();
                let similarity = block
                    .get("similarity")
                    .or_else(|| block.get("score"))
                    .and_then(|s| s.as_f64())
                    .unwrap_or(0.0) as f32;
                let block_text = block
                    .get("text")
                    .or_else(|| block.get("content"))
                    .and_then(|t| t.as_str())
                    .unwrap_or("")
                    .to_string();
                let lines = block
                    .get("lines")
                    .and_then(|l| l.as_str())
                    .map(|s| s.to_string());
                blocks.push(VaultBlock {
                    path,
                    similarity,
                    text: block_text,
                    lines,
                });
            }
        } else if !text.is_empty() {
            blocks.push(VaultBlock {
                path: "vault".to_string(),
                similarity: 1.0,
                text: text.to_string(),
                lines: None,
            });
        }
    }

    if blocks.is_empty() {
        Err("no_results".to_string())
    } else {
        Ok(blocks)
    }
}

// ---------------------------------------------------------------------------
// MCP call
// ---------------------------------------------------------------------------

async fn call_mcp(
    proc: &mut VaultMcpProcess,
    query: &str,
    max_blocks: u32,
) -> Result<Vec<VaultBlock>, String> {
    let id = proc.next_id;
    proc.next_id += 1;

    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": {
            "name": "get_context_blocks",
            "arguments": {
                "query": query,
                "max_blocks": max_blocks
            }
        }
    });

    send_json(&mut proc.stdin, &request).await?;
    let response = read_json_line(&mut proc.stdout).await?;
    parse_mcp_response(response)
}

// ---------------------------------------------------------------------------
// Subprocess spawn + MCP initialize handshake
// ---------------------------------------------------------------------------

async fn spawn_vault_mcp() -> Option<VaultMcpProcess> {
    // No vault resolvable (not configured, no env var, nothing auto-detected)
    // or the MCP server script isn't installed on this machine — disable
    // cleanly instead of spawning a process that can only fail.
    let server_path = server_script_path()?;
    let vault_path = resolve_vault_path()?;

    let python = resolve_python();

    let mut child = tokio::process::Command::new(&python)
        .arg(&server_path)
        .env("OBSIDIAN_VAULT_PATH", &vault_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;

    let stdin = child.stdin.take()?;
    let stdout_raw = child.stdout.take()?;

    Some(VaultMcpProcess {
        _child: child,
        stdin,
        stdout: BufReader::new(stdout_raw),
        next_id: 1,
    })
}

async fn do_initialize(proc: &mut VaultMcpProcess) -> Result<(), String> {
    // 1. Send initialize request.
    let init_req = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 0,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": { "name": "muya", "version": "0.1" }
        }
    });
    send_json(&mut proc.stdin, &init_req).await?;

    // 2. Read server capabilities response.
    let _caps = read_json_line(&mut proc.stdout).await?;

    // 3. Send notifications/initialized (fire-and-forget, no response expected).
    let notif = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "notifications/initialized"
    });
    send_json(&mut proc.stdin, &notif).await?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Public: warmup called at app startup (AC-1-7)
// ---------------------------------------------------------------------------

pub async fn warmup_vault(manager: Arc<Mutex<Option<VaultMcpProcess>>>) {
    let mut proc = match spawn_vault_mcp().await {
        Some(p) => p,
        None => {
            eprintln!(
                "[vault] not available: no vault configured/detected, or smart-connections-mcp \
                 not installed at ~/smart-connections-mcp — set a path via vault_set_path"
            );
            return;
        }
    };

    if let Err(e) = do_initialize(&mut proc).await {
        eprintln!("[vault] warmup: initialize failed: {}", e);
        return;
    }

    // Warm up embeddings so first real query hits the cache.
    let _ = call_mcp(&mut proc, "warmup initialization", 1).await;

    let mut lock = manager.lock().await;
    *lock = Some(proc);
    eprintln!("[vault] warmup: ready");
}

// ---------------------------------------------------------------------------
// Tauri command: vault_search (AC-1-1 … AC-1-6)
// ---------------------------------------------------------------------------

/// Search the Obsidian vault via the smart-connections MCP subprocess.
///
/// Error strings:
///   "mcp_unavailable" — subprocess not running / crashed (AC-1-6)
///   "timeout"         — no response within timeout_ms (AC-1-3)
///   "no_results"      — no blocks above the similarity threshold (AC-1-4)
#[tauri::command]
pub async fn vault_search(
    state: State<'_, VaultMcpManager>,
    query: String,
    max_blocks: Option<u32>,
    timeout_ms: Option<u64>,
) -> Result<Vec<VaultBlock>, String> {
    let max_b = max_blocks.unwrap_or(3).min(10);
    let timeout_dur = Duration::from_millis(timeout_ms.unwrap_or(300));

    let manager = &state.0;
    let mut lock = manager.lock().await;

    let proc = match lock.as_mut() {
        Some(p) => p,
        None => return Err("mcp_unavailable".to_string()), // AC-1-6
    };

    match timeout(timeout_dur, call_mcp(proc, &query, max_b)).await {
        Ok(Ok(mut blocks)) => {
            // AC-1-4: filter out blocks below the similarity threshold.
            blocks.retain(|b| b.similarity >= 0.35);
            if blocks.is_empty() {
                Err("no_results".to_string())
            } else {
                // Enforce max_blocks after filtering.
                blocks.truncate(max_b as usize);
                Ok(blocks)
            }
        }
        Ok(Err(e)) if e == "no_results" => Err("no_results".to_string()),
        Ok(Err(_)) => {
            // Subprocess returned an error — assume crash, mark unavailable. (AC-1-6)
            *lock = None;
            Err("mcp_unavailable".to_string())
        }
        Err(_elapsed) => {
            // Timeout — drop the subprocess (kill_on_drop) and return timeout. (AC-1-3)
            *lock = None;
            Err("timeout".to_string())
        }
    }
}

#[cfg(test)]
mod vault_config_tests {
    use super::*;

    fn make_vault(root: &Path, name: &str) -> PathBuf {
        let v = root.join(name);
        std::fs::create_dir_all(v.join(".obsidian")).unwrap();
        v
    }

    #[test]
    fn venv_has_deps_detects_installed_and_missing() {
        let dir = tempfile::tempdir().unwrap();
        let venv = dir.path().join(".venv");
        // Empty venv → no deps.
        std::fs::create_dir_all(venv.join("lib/python3.11/site-packages")).unwrap();
        assert!(!venv_has_deps(&venv), "empty venv must report no deps");
        // Install the marker package dir → detected.
        std::fs::create_dir_all(venv.join("lib/python3.11/site-packages/sentence_transformers"))
            .unwrap();
        assert!(
            venv_has_deps(&venv),
            "venv with the package dir must be detected"
        );
    }

    #[test]
    fn resolve_python_skips_broken_venv() {
        // A venv without deps must NOT be selected — resolution falls through to
        // the global fallback (regression guard for the working dev machine).
        let dir = tempfile::tempdir().unwrap();
        let mcp = dir.path().join("smart-connections-mcp");
        std::fs::create_dir_all(mcp.join(".venv/bin")).unwrap();
        std::fs::write(mcp.join(".venv/bin/python"), "#!/bin/sh\n").unwrap();
        std::fs::create_dir_all(mcp.join(".venv/lib/python3.11/site-packages")).unwrap();
        // Point VAULT_MCP_DIR at our fixture; ensure VAULT_PYTHON is unset.
        std::env::set_var("VAULT_MCP_DIR", &mcp);
        std::env::remove_var("VAULT_PYTHON");
        let py = resolve_python();
        assert!(
            !py.contains(".venv"),
            "broken venv (no deps) must be skipped, got: {py}"
        );
        std::env::remove_var("VAULT_MCP_DIR");
    }

    #[test]
    fn is_obsidian_vault_requires_dot_obsidian_dir() {
        let dir = tempfile::tempdir().unwrap();
        assert!(!is_obsidian_vault(dir.path()));
        make_vault(dir.path(), "my-vault");
        assert!(is_obsidian_vault(&dir.path().join("my-vault")));
        // A plain file named .obsidian doesn't count — must be a directory.
        let fake = dir.path().join("fake-vault");
        std::fs::create_dir_all(&fake).unwrap();
        std::fs::write(fake.join(".obsidian"), "not a dir").unwrap();
        assert!(!is_obsidian_vault(&fake));
    }

    #[test]
    fn scan_finds_vault_at_root_and_one_and_two_levels_deep() {
        let dir = tempfile::tempdir().unwrap();
        let root_vault = make_vault(dir.path(), "at-root");
        // One level deep, e.g. ~/Documents/my-notes.
        let one_deep_parent = dir.path().join("Documents");
        std::fs::create_dir_all(&one_deep_parent).unwrap();
        let one_deep = make_vault(&one_deep_parent, "my-notes");
        // Two levels deep, e.g. ~/Library/CloudStorage/OneDrive/obsidian.
        let two_deep_parent = dir.path().join("CloudStorage").join("OneDrive");
        std::fs::create_dir_all(&two_deep_parent).unwrap();
        let two_deep = make_vault(&two_deep_parent, "obsidian");
        // A non-vault dir mixed in should be ignored, not error out the scan.
        std::fs::create_dir_all(dir.path().join("Downloads")).unwrap();

        let roots = vec![
            dir.path().to_string_lossy().into_owned(),
            one_deep_parent.to_string_lossy().into_owned(),
            two_deep_parent
                .parent()
                .unwrap()
                .to_string_lossy()
                .into_owned(),
        ];
        let found = scan_roots_for_vaults(roots);

        let found_set: std::collections::HashSet<_> = found.iter().cloned().collect();
        assert!(found_set.contains(&root_vault.to_string_lossy().into_owned()));
        assert!(found_set.contains(&one_deep.to_string_lossy().into_owned()));
        assert!(found_set.contains(&two_deep.to_string_lossy().into_owned()));
    }

    #[test]
    fn scan_missing_root_does_not_panic() {
        let found = scan_roots_for_vaults(vec!["/definitely/does/not/exist/xyz".to_string()]);
        assert!(found.is_empty());
    }

    #[test]
    fn set_and_get_vault_path_roundtrip() {
        // Uses injected paths (config_file_path_under / save_config_to /
        // load_config_from) instead of the real vault_set_path command, which
        // reads process-global HOME — mutating that would race with other
        // tests in this crate that also read HOME concurrently.
        let fake_home = tempfile::tempdir().unwrap();
        let vault_dir = make_vault(fake_home.path(), "test-vault");
        let vault_str = vault_dir.to_string_lossy().into_owned();
        let cfg_path = config_file_path_under(&fake_home.path().to_string_lossy());

        // No config saved yet → empty.
        assert!(load_config_from(&cfg_path).vault_path.is_none());

        // Save + reload round-trips.
        save_config_to(
            &cfg_path,
            &VaultConfig {
                vault_path: Some(vault_str.clone()),
            },
        )
        .expect("save should succeed");
        let loaded = load_config_from(&cfg_path);
        assert_eq!(loaded.vault_path.as_deref(), Some(vault_str.as_str()));
    }

    #[test]
    fn vault_set_path_rejects_non_vault_dir() {
        let dir = tempfile::tempdir().unwrap();
        // No .obsidian folder inside — must be rejected.
        let err = vault_set_path(dir.path().to_string_lossy().into_owned());
        assert!(err.is_err());
    }

    #[test]
    fn vault_set_path_rejects_empty_path() {
        assert!(vault_set_path(String::new()).is_err());
        assert!(vault_set_path("   ".to_string()).is_err());
    }
}

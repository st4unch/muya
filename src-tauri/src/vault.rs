// Vault MCP integration — smart-connections subprocess manager.
// Spawns a persistent Python MCP server process and routes vault_search
// commands through JSON-RPC over stdin/stdout.

use serde::{Deserialize, Serialize};
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
    let home = std::env::var("HOME").unwrap_or_default();
    let server_path = format!("{}/smart-connections-mcp/server.py", home);

    let vault_path = std::env::var("OBSIDIAN_VAULT_PATH").unwrap_or_else(|_| {
        format!(
            "{}/Library/CloudStorage/OneDrive-Kişisel/obsidian/murat_self",
            home
        )
    });

    let python = std::env::var("VAULT_PYTHON")
        .unwrap_or_else(|_| "/opt/homebrew/bin/python3.11".to_string());

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
            eprintln!("[vault] warmup: failed to spawn MCP subprocess");
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

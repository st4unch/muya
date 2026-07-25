//! `muya-ssh` — thin stdio MCP proxy (PRD `ssh-agent-broker`, Faz 1).
//!
//! Claude Code spawns THIS binary as an MCP server. It speaks MCP (JSON-RPC 2.0
//! over stdio, newline-delimited per the MCP stdio transport spec — one message
//! per line, no embedded newlines; messages on stdout, diagnostics on stderr) to
//! the agent, and forwards tool calls to the running Muya app over the owner-only
//! broker Unix-domain socket (see `src/broker.rs`).
//!
//! It holds NO secrets and does NO ssh: `ssh_open` merely asks the app to open a
//! terminal (the app injects the password Rust-side). If the app is not running,
//! tool calls degrade gracefully with a JSON-RPC error "Muya app not running".
//!
//! Tools exposed (Faz 1): `ssh_list_servers`, `ssh_open`. `ssh_run` is Faz 2.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use serde_json::{json, Value};

const PROTOCOL_VERSION: &str = "2025-06-18";
const SERVER_NAME: &str = "muya-ssh";
const SERVER_VERSION: &str = "0.1.0";

fn app_socket_path() -> PathBuf {
    if let Ok(p) = std::env::var("MUYA_SSH_BROKER_SOCK") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(home).join(".claude/muya-ssh-broker.sock")
}

/// Send one request line to the app broker socket and read one response line.
/// Connection failure (app not running) is a hard `Err` → JSON-RPC error.
fn app_call(req: &Value) -> Result<Value, String> {
    let path = app_socket_path();
    let mut stream = UnixStream::connect(&path).map_err(|_| "Muya app not running".to_string())?;
    let mut line = serde_json::to_string(req).map_err(|e| e.to_string())?;
    line.push('\n');
    stream
        .write_all(line.as_bytes())
        .map_err(|e| format!("write to Muya app: {e}"))?;
    stream.flush().ok();
    let mut reader = BufReader::new(stream);
    let mut resp = String::new();
    reader
        .read_line(&mut resp)
        .map_err(|e| format!("read from Muya app: {e}"))?;
    if resp.trim().is_empty() {
        return Err("empty response from Muya app".to_string());
    }
    serde_json::from_str(resp.trim()).map_err(|e| format!("bad response from Muya app: {e}"))
}

/// A `tools/call` result marked as a tool-level error (model self-corrects).
fn tool_error(msg: impl Into<String>) -> Value {
    json!({
        "content": [{ "type": "text", "text": msg.into() }],
        "isError": true
    })
}

fn tool_ok(text: String, structured: Option<Value>) -> Value {
    let mut v = json!({
        "content": [{ "type": "text", "text": text }],
        "isError": false
    });
    if let Some(s) = structured {
        v["structuredContent"] = s;
    }
    v
}

fn tools_list() -> Value {
    json!({
        "tools": [
            {
                "name": "ssh_list_servers",
                "description": "List the SSH servers the operator has allowed agents to use. Returns each server's alias plus host/username/port/connectionType. No passwords or credentials are ever returned. Use the returned alias with ssh_open.",
                "inputSchema": { "type": "object", "additionalProperties": false }
            },
            {
                "name": "ssh_open",
                "description": "Open an interactive SSH terminal in Muya for the server with the given alias (from ssh_list_servers). Muya resolves and injects the password itself; the password is never exposed to you. Fails if the alias is not agent-accessible or the credential store is locked.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "alias": { "type": "string", "description": "Server alias from ssh_list_servers." }
                    },
                    "required": ["alias"],
                    "additionalProperties": false
                }
            }
        ]
    })
}

/// Dispatch a `tools/call`. Connection failures bubble up as `Err` (JSON-RPC
/// error); business failures (locked store, unknown alias) return a tool result
/// with `isError:true` so the model can react.
fn handle_tools_call(params: &Value) -> Result<Value, (i64, String)> {
    let name = params.get("name").and_then(Value::as_str).unwrap_or("");
    let args = params
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));

    match name {
        "ssh_list_servers" => {
            let resp = app_call(&json!({ "op": "list_servers" })).map_err(|e| (-32000, e))?;
            if resp.get("ok").and_then(Value::as_bool) == Some(true) {
                let servers = resp.get("servers").cloned().unwrap_or_else(|| json!([]));
                let text = serde_json::to_string_pretty(&servers).unwrap_or_else(|_| "[]".into());
                Ok(tool_ok(text, Some(json!({ "servers": servers }))))
            } else {
                Ok(tool_error(
                    resp.get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("list failed")
                        .to_string(),
                ))
            }
        }
        "ssh_open" => {
            let alias = match args.get("alias").and_then(Value::as_str) {
                Some(a) if !a.trim().is_empty() => a.to_string(),
                _ => return Ok(tool_error("missing required argument 'alias'")),
            };
            let resp =
                app_call(&json!({ "op": "open", "alias": alias })).map_err(|e| (-32000, e))?;
            if resp.get("ok").and_then(Value::as_bool) == Some(true) {
                Ok(tool_ok(
                    format!("Opening '{alias}' in a new Muya terminal."),
                    None,
                ))
            } else {
                Ok(tool_error(
                    resp.get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("open failed")
                        .to_string(),
                ))
            }
        }
        other => Ok(tool_error(format!("unknown tool: {other}"))),
    }
}

/// Route a single JSON-RPC request method → result (or JSON-RPC error).
fn handle_method(method: &str, params: &Value) -> Result<Value, (i64, String)> {
    match method {
        "initialize" => {
            // Echo the client's protocol version when supplied, else our default.
            let pv = params
                .get("protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or(PROTOCOL_VERSION)
                .to_string();
            Ok(json!({
                "protocolVersion": pv,
                "capabilities": { "tools": {} },
                "serverInfo": { "name": SERVER_NAME, "version": SERVER_VERSION }
            }))
        }
        "ping" => Ok(json!({})),
        "tools/list" => Ok(tools_list()),
        "tools/call" => handle_tools_call(params),
        other => Err((-32601, format!("method not found: {other}"))),
    }
}

fn main() {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                // Parse error — respond only if we can't even find an id (null id).
                let out = json!({
                    "jsonrpc": "2.0",
                    "id": Value::Null,
                    "error": { "code": -32700, "message": format!("parse error: {e}") }
                });
                write_line(&mut stdout, &out);
                continue;
            }
        };

        let id = msg.get("id").cloned();
        let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
        let params = msg.get("params").cloned().unwrap_or_else(|| json!({}));

        // Notifications (no id) — e.g. notifications/initialized — get no reply.
        let id = match id {
            Some(id) if !id.is_null() => id,
            _ => continue,
        };

        let out = match handle_method(method, &params) {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err((code, message)) => {
                json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
            }
        };
        write_line(&mut stdout, &out);
    }
}

fn write_line<W: Write>(out: &mut W, value: &Value) {
    // serde_json::to_string never emits embedded newlines → one message per line.
    if let Ok(mut s) = serde_json::to_string(value) {
        s.push('\n');
        let _ = out.write_all(s.as_bytes());
        let _ = out.flush();
    }
}

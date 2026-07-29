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
//! Tools exposed: `ssh_list_servers`, `ssh_open` (Faz 1) and `ssh_run` (Faz 2 —
//! one remote command, stdout captured, password injected app-side).

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
            },
            {
                "name": "ssh_run",
                "description": "Run ONE command on the SSH server with the given alias (from ssh_list_servers) and return its stdout. Muya connects, injects the password server-side (never exposed to you), runs the single command remotely, and returns the captured output plus the exit code. The command is passed to the remote shell as a single string, so you may use pipes/redirection inside it. Fails if the alias is not agent-accessible, if the credential store is locked, or if the server uses a 'prompt' credential (no stored password to inject non-interactively) — in that case use a stored or CyberArk credential.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "alias": { "type": "string", "description": "Server alias from ssh_list_servers." },
                        "command": { "type": "string", "description": "The command to run on the remote server, e.g. 'uname -a' or 'df -h | head'." }
                    },
                    "required": ["alias", "command"],
                    "additionalProperties": false
                }
            },
            {
                "name": "list_secrets",
                "description": "List the names of stored secrets the operator has saved (name, description, kind). The secret VALUES are never returned — you reference a secret only BY NAME when running an operation. Use this to discover which credential to pick for a run_operation call.",
                "inputSchema": { "type": "object", "additionalProperties": false }
            },
            {
                "name": "add_secret",
                "description": "Store a NEW secret (e.g. a token your workflow just generated) under a name for later use by run_operation. Fails if the name already exists or the credential store is locked. The value is write-only — it is never returned to you afterwards; you reference the secret only BY NAME. Pick a descriptive name and (optionally) a description so the operator can identify it.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string", "description": "Unique name for the secret (must not already exist)." },
                        "value": { "type": "string", "description": "The secret value to store. Write-only — never returned." },
                        "kind": {
                            "type": "string",
                            "enum": ["password", "key", "token", "api_key"],
                            "description": "The kind of secret. Use 'api_key' for API keys/tokens; defaults to 'api_key' if omitted."
                        },
                        "description": { "type": "string", "description": "Optional operator-facing note describing the secret." }
                    },
                    "required": ["name", "value"],
                    "additionalProperties": false
                }
            },
            {
                "name": "get_secret",
                "description": "Read a stored secret's VALUE by name — use when you must place a stored password/API key into a system you are configuring (a config file, an env var you set, another service). Requires the operator to have unlocked the Password Store. Prefer run_operation when you only need to USE a secret (it never exposes the value); use get_secret only when you genuinely need the value itself.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string", "description": "The secret's name (from list_secrets)." }
                    },
                    "required": ["name"],
                    "additionalProperties": false
                }
            },
            {
                "name": "update_secret",
                "description": "Replace an EXISTING secret's value by name (e.g. after rotating a credential or reconfiguring a system). Fails if the name does not exist (use add_secret to create) or the store is locked. The new value is write-only — never returned.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string", "description": "Name of the existing secret to update." },
                        "value": { "type": "string", "description": "The new secret value. Write-only — never returned." }
                    },
                    "required": ["name", "value"],
                    "additionalProperties": false
                }
            },
            {
                "name": "list_operations",
                "description": "List the fixed operations the operator has defined that agents may run (name + description only). Each operation is a pinned program+subcommand (e.g. an aws/kubectl/git command) that uses a stored secret WITHOUT revealing it. Use the returned name with run_operation.",
                "inputSchema": { "type": "object", "additionalProperties": false }
            },
            {
                "name": "run_operation",
                "description": "Run one operator-defined operation by name (from list_operations). Muya injects the associated secret into the program's environment (never exposed to you), runs the fixed program with your (policed) arguments, and returns stdout/stderr/exit code. Arguments are restricted by a fail-closed policy: only allow-listed flags and operand values are accepted — pass flag values as --flag=value. The subcommand is fixed by the operator and cannot be changed.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "operation": { "type": "string", "description": "Operation name from list_operations." },
                        "args": {
                            "type": "array",
                            "items": { "type": "string" },
                            "description": "Additional arguments appended after the operation's pinned command, e.g. [\"--region=us-east-1\", \"s3://bucket/key\"]. Subject to the operation's allow-list."
                        }
                    },
                    "required": ["operation"],
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
        "ssh_run" => {
            let alias = match args.get("alias").and_then(Value::as_str) {
                Some(a) if !a.trim().is_empty() => a.to_string(),
                _ => return Ok(tool_error("missing required argument 'alias'")),
            };
            let command = match args.get("command").and_then(Value::as_str) {
                Some(c) if !c.trim().is_empty() => c.to_string(),
                _ => return Ok(tool_error("missing required argument 'command'")),
            };
            let resp = app_call(&json!({ "op": "run", "alias": alias, "command": command }))
                .map_err(|e| (-32000, e))?;
            if resp.get("ok").and_then(Value::as_bool) == Some(true) {
                let stdout = resp.get("stdout").and_then(Value::as_str).unwrap_or("");
                let timed_out = resp.get("timedOut").and_then(Value::as_bool) == Some(true);
                let exit_note = match resp.get("exitCode").and_then(Value::as_i64) {
                    Some(code) => format!("[exit code: {code}]"),
                    None => "[exit code: unknown]".to_string(),
                };
                let mut text = stdout.to_string();
                if !text.is_empty() && !text.ends_with('\n') {
                    text.push('\n');
                }
                if timed_out {
                    text.push_str("[command timed out and was terminated]\n");
                }
                text.push_str(&exit_note);
                Ok(tool_ok(
                    text,
                    Some(json!({
                        "stdout": stdout,
                        "exitCode": resp.get("exitCode").cloned().unwrap_or(Value::Null),
                        "timedOut": timed_out,
                    })),
                ))
            } else {
                Ok(tool_error(
                    resp.get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("run failed")
                        .to_string(),
                ))
            }
        }
        "list_secrets" => {
            let resp = app_call(&json!({ "op": "list_secrets" })).map_err(|e| (-32000, e))?;
            if resp.get("ok").and_then(Value::as_bool) == Some(true) {
                let secrets = resp.get("secrets").cloned().unwrap_or_else(|| json!([]));
                let text = serde_json::to_string_pretty(&secrets).unwrap_or_else(|_| "[]".into());
                Ok(tool_ok(text, Some(json!({ "secrets": secrets }))))
            } else {
                Ok(tool_error(
                    resp.get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("list_secrets failed")
                        .to_string(),
                ))
            }
        }
        "add_secret" => {
            let secret_name = match args.get("name").and_then(Value::as_str) {
                Some(n) if !n.trim().is_empty() => n.to_string(),
                _ => return Ok(tool_error("missing required argument 'name'")),
            };
            let value = match args.get("value").and_then(Value::as_str) {
                Some(v) if !v.is_empty() => v.to_string(),
                _ => return Ok(tool_error("missing required argument 'value'")),
            };
            let kind = args
                .get("kind")
                .and_then(Value::as_str)
                .filter(|k| !k.trim().is_empty())
                .unwrap_or("api_key")
                .to_string();
            let description = args
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let resp = app_call(&json!({
                "op": "add_secret",
                "name": secret_name,
                "value": value,
                "kind": kind,
                "description": description,
            }))
            .map_err(|e| (-32000, e))?;
            if resp.get("ok").and_then(Value::as_bool) == Some(true) {
                let secret = resp.get("secret").cloned().unwrap_or_else(|| json!({}));
                let name = secret.get("name").and_then(Value::as_str).unwrap_or("");
                let stored_kind = secret.get("kind").and_then(Value::as_str).unwrap_or("");
                Ok(tool_ok(
                    format!(
                        "Stored secret '{name}' (kind: {stored_kind}). The value is write-only \
                         and cannot be read back; reference it by name in run_operation."
                    ),
                    Some(json!({ "secret": secret })),
                ))
            } else {
                Ok(tool_error(
                    resp.get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("add_secret failed")
                        .to_string(),
                ))
            }
        }
        "get_secret" => {
            let name = match args.get("name").and_then(Value::as_str) {
                Some(n) if !n.trim().is_empty() => n.to_string(),
                _ => return Ok(tool_error("missing required argument 'name'")),
            };
            let resp =
                app_call(&json!({ "op": "get_secret", "name": name })).map_err(|e| (-32000, e))?;
            if resp.get("ok").and_then(Value::as_bool) == Some(true) {
                let value = resp.get("value").and_then(Value::as_str).unwrap_or("");
                // The value is returned to the agent by explicit operator design.
                Ok(tool_ok(value.to_string(), Some(json!({ "value": value }))))
            } else {
                Ok(tool_error(
                    resp.get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("get_secret failed")
                        .to_string(),
                ))
            }
        }
        "update_secret" => {
            let name = match args.get("name").and_then(Value::as_str) {
                Some(n) if !n.trim().is_empty() => n.to_string(),
                _ => return Ok(tool_error("missing required argument 'name'")),
            };
            let value = match args.get("value").and_then(Value::as_str) {
                Some(v) if !v.is_empty() => v.to_string(),
                _ => return Ok(tool_error("missing required argument 'value'")),
            };
            let resp = app_call(&json!({ "op": "update_secret", "name": name, "value": value }))
                .map_err(|e| (-32000, e))?;
            if resp.get("ok").and_then(Value::as_bool) == Some(true) {
                let secret = resp.get("secret").cloned().unwrap_or_else(|| json!({}));
                let n = secret.get("name").and_then(Value::as_str).unwrap_or("");
                Ok(tool_ok(
                    format!("Updated secret '{n}'. The new value is write-only and cannot be read back here."),
                    Some(json!({ "secret": secret })),
                ))
            } else {
                Ok(tool_error(
                    resp.get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("update_secret failed")
                        .to_string(),
                ))
            }
        }
        "list_operations" => {
            let resp = app_call(&json!({ "op": "list_operations" })).map_err(|e| (-32000, e))?;
            if resp.get("ok").and_then(Value::as_bool) == Some(true) {
                let ops = resp.get("operations").cloned().unwrap_or_else(|| json!([]));
                let text = serde_json::to_string_pretty(&ops).unwrap_or_else(|_| "[]".into());
                Ok(tool_ok(text, Some(json!({ "operations": ops }))))
            } else {
                Ok(tool_error(
                    resp.get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("list_operations failed")
                        .to_string(),
                ))
            }
        }
        "run_operation" => {
            let operation = match args.get("operation").and_then(Value::as_str) {
                Some(o) if !o.trim().is_empty() => o.to_string(),
                _ => return Ok(tool_error("missing required argument 'operation'")),
            };
            // Optional string array; anything non-string is rejected up-front.
            let op_args: Vec<String> = match args.get("args") {
                None | Some(Value::Null) => vec![],
                Some(Value::Array(items)) => {
                    let mut out = Vec::with_capacity(items.len());
                    for it in items {
                        match it.as_str() {
                            Some(s) => out.push(s.to_string()),
                            None => return Ok(tool_error("'args' must be an array of strings")),
                        }
                    }
                    out
                }
                Some(_) => return Ok(tool_error("'args' must be an array of strings")),
            };
            let resp = app_call(&json!({
                "op": "run_operation",
                "operation": operation,
                "args": op_args,
            }))
            .map_err(|e| (-32000, e))?;
            if resp.get("ok").and_then(Value::as_bool) == Some(true) {
                let stdout = resp.get("stdout").and_then(Value::as_str).unwrap_or("");
                let stderr = resp.get("stderr").and_then(Value::as_str).unwrap_or("");
                let exit_note = match resp.get("exitCode").and_then(Value::as_i64) {
                    Some(code) => format!("[exit code: {code}]"),
                    None => "[exit code: unknown]".to_string(),
                };
                let mut text = stdout.to_string();
                if !text.is_empty() && !text.ends_with('\n') {
                    text.push('\n');
                }
                if !stderr.is_empty() {
                    text.push_str("[stderr]\n");
                    text.push_str(stderr);
                    if !text.ends_with('\n') {
                        text.push('\n');
                    }
                }
                text.push_str(&exit_note);
                Ok(tool_ok(
                    text,
                    Some(json!({
                        "stdout": stdout,
                        "stderr": stderr,
                        "exitCode": resp.get("exitCode").cloned().unwrap_or(Value::Null),
                    })),
                ))
            } else {
                Ok(tool_error(
                    resp.get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("run_operation failed")
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

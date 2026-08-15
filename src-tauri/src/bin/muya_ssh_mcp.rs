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

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use serde_json::{json, Value};

const PROTOCOL_VERSION: &str = "2025-06-18";
const SERVER_NAME: &str = "muya-mcp";
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

/// Turn a plan title into a filename-safe slug: alphanumerics kept (Unicode letters
/// too, so Turkish titles survive), everything else collapses to single dashes, and
/// leading/trailing dashes are trimmed. Empty result → caller rejects.
fn slugify(title: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = false;
    for c in title.chars() {
        if c.is_alphanumeric() {
            out.extend(c.to_lowercase());
            prev_dash = false;
        } else if !prev_dash && !out.is_empty() {
            out.push('-');
            prev_dash = true;
        }
    }
    out.trim_matches('-').to_string()
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
                "description": "Open a live, INTERACTIVE SSH terminal TAB in Muya's window (a human watches it) and return a `sessionId`. You do NOT receive the command output on-screen — this is for interactive work: an interactive login, a 2FA/OTP/RADIUS challenge PSMP requires, or a multi-step/TUI flow. Keep the returned `sessionId` and use ssh_send(sessionId, text) to type into that same terminal afterwards. To run a single command and get its stdout back to you, use ssh_run instead. Muya resolves and injects the password itself; the password is never exposed to you. Fails if the alias is not agent-accessible or the credential store is locked.",
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
                "name": "ssh_send",
                "description": "Type text into a terminal you previously opened with ssh_open (Playwright-style). Pass the `sessionId` that ssh_open returned and the literal `text` to send — include a trailing newline (\\n) to actually run a command. Use this for interactive follow-ups ssh_run can't do: answering a prompt, driving a TUI/REPL, a sudo password the human just cleared, or a multi-step flow. Fire-and-forget: the output appears in the human's terminal, NOT back to you — if you need the output, use ssh_run instead. You may only write to a session YOU opened, and only while its tab is still open; a closed or unknown sessionId is refused. The text is delivered as keystrokes and is never logged.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "sessionId": { "type": "string", "description": "The session id returned by ssh_open for the terminal to type into." },
                        "text": { "type": "string", "description": "Literal text to type. Add a trailing '\\n' to submit a command line." }
                    },
                    "required": ["sessionId", "text"],
                    "additionalProperties": false
                }
            },
            {
                "name": "ssh_run",
                "description": "THIS is how you (the agent) execute a command on a remote server and get the result back — your primary tool for remote command execution (no human needed). Runs ONE command on the SSH server with the given alias (from ssh_list_servers) and returns its stdout. Muya connects, injects the password server-side (never exposed to you), runs the single command remotely, and returns the captured stdout plus the exit code (and `stderr` — the real error message on a non-zero exit). The command is passed to the remote shell as a single string, so you may use pipes/redirection inside it. Fails if the alias is not agent-accessible, if the credential store is locked, or if the server uses a 'prompt' credential (no stored password to inject non-interactively) — in that case use a stored or CyberArk credential. LIMITATION — PSMP + 2FA: for servers behind a CyberArk PSMP proxy, ssh_run only supports a plain password prompt. If PSMP shows a 2FA/OTP/passcode/RADIUS challenge, ssh_run refuses to guess (it will NOT type the stored password into a 2FA field) and returns an error telling you to use ssh_open instead, which lets a human complete the interactive challenge. A timeout with no prompt at all on a PSMP server likely means a RADIUS push notification is awaiting out-of-band approval — again, use ssh_open.",
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
                "name": "track_plan",
                "description": "Publish a PRD or plan onto Muya's Kanban board so the human can watch its status. Writes docs/prd-<slug>.md (+ a progress file carrying the status) inside YOUR CURRENT PROJECT directory — the same folder you're working in — and Muya's Kanban picks it up automatically. Use it when you create or finish a plan/PRD and want it visible: call once with status 'active' when you start, and again (same title) with status 'done' when finished. `title` becomes the card name; `status` is one of active|draft|blocked|done (defaults to active); optional `body` is the Markdown plan contents. Re-calling with the same title updates that card.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "title": { "type": "string", "description": "Human-readable plan/PRD title. Becomes the Kanban card name and the doc's slug." },
                        "status": { "type": "string", "enum": ["active", "draft", "blocked", "done"], "description": "Board column. Defaults to 'active'." },
                        "body": { "type": "string", "description": "Optional Markdown body of the plan/PRD (phases, acceptance criteria, notes)." }
                    },
                    "required": ["title"],
                    "additionalProperties": false
                }
            },
            {
                "name": "ssh_add_server",
                "description": "Register a NEW SSH server that you can then use with ssh_open / ssh_run. Provide host and login username (and optionally a label and port; port defaults to 22). Optionally attach a stored credential BY NAME (from list_secrets) so ssh_run can authenticate non-interactively — Muya resolves and injects that secret itself; you never see its value. Omit 'credential' for a server whose password is typed by the operator each time ('prompt'). You CANNOT set raw ssh options, a jump host, or a PSMP profile. The connection is always a direct ssh. Fails if a server for that host+username already exists (it will not overwrite an existing server), or if host/username contain spaces, control characters, or '@'.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "label": { "type": "string", "description": "Optional friendly name / alias for the server. Defaults to the server id if omitted." },
                        "host": { "type": "string", "description": "Hostname or IP of the SSH server. No spaces, control characters, or '@'." },
                        "username": { "type": "string", "description": "SSH login username. No spaces, control characters, or '@'." },
                        "port": { "type": "integer", "description": "SSH port. Defaults to 22.", "minimum": 1, "maximum": 65535 },
                        "credential": { "type": "string", "description": "Optional name of a stored secret (from list_secrets) to attach as this server's password. Muya injects it at connect time; you never see the value. Omit to have the operator type the password each time." }
                    },
                    "required": ["host", "username"],
                    "additionalProperties": false
                }
            },
            {
                "name": "ssh_scp",
                "description": "Copy a file to/from the SSH server with the given alias (from ssh_list_servers), including servers behind a CyberArk PSMP proxy. Muya resolves and injects the credential server-side (never exposed to you) and assembles all ssh/scp options itself. SECURITY: localPath is confined to Muya's configured workspace roots (the folders open in the app) — any path outside them (e.g. ~/.ssh/id_rsa, /etc/passwd, a '..' escape, or a symlink pointing outside) is refused before scp ever runs, and nothing is read/written on your local disk in that case. extraArgs accepts ONLY scp flags -r/-p/-C/-l (never a path) — -o/-F/-i/-S/-P are always rejected, Muya sets those itself. direction is required and explicit ('upload' or 'download') — it is never inferred. Same PSMP 2FA/OTP limitation as ssh_run: a challenge prompt is refused (use ssh_open instead) rather than guessed. On a non-zero exitCode the response includes `stderr` — scp's actual error (e.g. a CyberArk PSMP policy/DLP message when a download is blocked); read it to tell a server-side policy block from a transfer error.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "alias": { "type": "string", "description": "Server alias from ssh_list_servers." },
                        "direction": {
                            "type": "string",
                            "enum": ["upload", "download"],
                            "description": "Transfer direction. 'upload' copies localPath -> remotePath; 'download' copies remotePath -> localPath. Always explicit, never inferred."
                        },
                        "localPath": { "type": "string", "description": "Absolute local path. Must resolve inside one of Muya's configured workspace roots; anything outside is refused before any transfer or filesystem access." },
                        "remotePath": { "type": "string", "description": "Absolute or relative path on the remote server." },
                        "recursive": { "type": "boolean", "default": false, "description": "Copy a directory recursively (adds scp -r)." },
                        "extraArgs": {
                            "type": "array",
                            "items": { "type": "string" },
                            "description": "Optional extra scp FLAGS only (no paths): -r, -p, -C, -l[<limit>]. -o/-F/-i/-S/-P are always rejected."
                        }
                    },
                    "required": ["alias", "direction", "localPath", "remotePath"],
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
                let session_id = resp
                    .get("sessionId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                Ok(tool_ok(
                    format!(
                        "Opening '{alias}' in a new Muya terminal. sessionId={session_id} — pass \
                         this to ssh_send to type into that terminal."
                    ),
                    Some(json!({ "sessionId": session_id })),
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
        "ssh_send" => {
            let session_id = match args.get("sessionId").and_then(Value::as_str) {
                Some(s) if !s.trim().is_empty() => s.to_string(),
                _ => return Ok(tool_error("missing required argument 'sessionId'")),
            };
            let text = match args.get("text").and_then(Value::as_str) {
                Some(t) => t.to_string(),
                _ => return Ok(tool_error("missing required argument 'text'")),
            };
            let resp = app_call(&json!({ "op": "send", "sessionId": session_id, "text": text }))
                .map_err(|e| (-32000, e))?;
            if resp.get("ok").and_then(Value::as_bool) == Some(true) {
                Ok(tool_ok(
                    format!("Sent {} bytes to session {session_id}.", text.len()),
                    None,
                ))
            } else {
                Ok(tool_error(
                    resp.get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("send failed")
                        .to_string(),
                ))
            }
        }
        "track_plan" => {
            let title = match args.get("title").and_then(Value::as_str) {
                Some(t) if !t.trim().is_empty() => t.trim().to_string(),
                _ => return Ok(tool_error("missing required argument 'title'")),
            };
            let status = {
                let s = args
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("active")
                    .trim();
                if s.is_empty() { "active" } else { s }.to_string()
            };
            let body = args
                .get("body")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let slug = slugify(&title);
            if slug.is_empty() {
                return Ok(tool_error(
                    "title has no usable characters to form a filename",
                ));
            }
            // Write into the CURRENT project's docs/ — the folder Claude Code spawned
            // this MCP server in, i.e. the agent's own project/worktree. Muya's Kanban
            // scans that dir, so the card appears with no extra wiring.
            let cwd = std::env::current_dir()
                .map_err(|e| (-32000i64, format!("cannot resolve current dir: {e}")))?;
            let docs = cwd.join("docs");
            if let Err(e) = fs::create_dir_all(&docs) {
                return Ok(tool_error(format!("cannot create docs/: {e}")));
            }
            let prd_path = docs.join(format!("prd-{slug}.md"));
            let progress_path = docs.join(format!("prd-{slug}.progress.md"));
            let prd_md = format!("# {title}\n\n{body}\n");
            let progress_md =
                format!("---\nstatus: {status}\nprd: docs/prd-{slug}.md\n---\n\n## Progress\n");
            if let Err(e) = fs::write(&prd_path, prd_md) {
                return Ok(tool_error(format!("failed to write PRD: {e}")));
            }
            if let Err(e) = fs::write(&progress_path, progress_md) {
                return Ok(tool_error(format!("failed to write progress: {e}")));
            }
            Ok(tool_ok(
                format!(
                    "Tracked '{title}' ({status}) on the Kanban → {}",
                    prd_path.display()
                ),
                Some(json!({ "prdPath": prd_path.to_string_lossy(), "status": status })),
            ))
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
                let stderr = resp.get("stderr").and_then(Value::as_str).unwrap_or("");
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
                if !stderr.trim().is_empty() {
                    text.push_str(&format!("[stderr]\n{}\n", stderr.trim_end()));
                }
                text.push_str(&exit_note);
                Ok(tool_ok(
                    text,
                    Some(json!({
                        "stdout": stdout,
                        "stderr": stderr,
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
        "ssh_scp" => {
            let alias = match args.get("alias").and_then(Value::as_str) {
                Some(a) if !a.trim().is_empty() => a.to_string(),
                _ => return Ok(tool_error("missing required argument 'alias'")),
            };
            let direction = match args.get("direction").and_then(Value::as_str) {
                Some(d) if d == "upload" || d == "download" => d.to_string(),
                Some(other) => {
                    return Ok(tool_error(format!(
                        "'direction' must be 'upload' or 'download', got '{other}'"
                    )))
                }
                None => return Ok(tool_error("missing required argument 'direction'")),
            };
            let local_path = match args.get("localPath").and_then(Value::as_str) {
                Some(p) if !p.trim().is_empty() => p.to_string(),
                _ => return Ok(tool_error("missing required argument 'localPath'")),
            };
            let remote_path = match args.get("remotePath").and_then(Value::as_str) {
                Some(p) if !p.trim().is_empty() => p.to_string(),
                _ => return Ok(tool_error("missing required argument 'remotePath'")),
            };
            let recursive = args
                .get("recursive")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let extra_args: Vec<String> = match args.get("extraArgs") {
                None | Some(Value::Null) => vec![],
                Some(Value::Array(items)) => {
                    let mut out = Vec::with_capacity(items.len());
                    for it in items {
                        match it.as_str() {
                            Some(s) => out.push(s.to_string()),
                            None => {
                                return Ok(tool_error("'extraArgs' must be an array of strings"))
                            }
                        }
                    }
                    out
                }
                Some(_) => return Ok(tool_error("'extraArgs' must be an array of strings")),
            };
            let resp = app_call(&json!({
                "op": "scp",
                "alias": alias,
                "direction": direction,
                "localPath": local_path,
                "remotePath": remote_path,
                "recursive": recursive,
                "extraArgs": extra_args,
            }))
            .map_err(|e| (-32000, e))?;
            if resp.get("ok").and_then(Value::as_bool) == Some(true) {
                let resolved_local = resp
                    .get("localPath")
                    .and_then(Value::as_str)
                    .unwrap_or(&local_path);
                let stderr = resp.get("stderr").and_then(Value::as_str).unwrap_or("");
                let timed_out = resp.get("timedOut").and_then(Value::as_bool) == Some(true);
                let exit_note = match resp.get("exitCode").and_then(Value::as_i64) {
                    Some(code) => format!("[exit code: {code}]"),
                    None => "[exit code: unknown]".to_string(),
                };
                let mut text = format!(
                    "{direction} '{resolved_local}' <-> '{remote_path}' on '{alias}' complete.\n"
                );
                if timed_out {
                    text.push_str("[transfer timed out and was terminated]\n");
                }
                if let Some(msg) = resp.get("message").and_then(Value::as_str) {
                    text.push_str(msg);
                    text.push('\n');
                }
                if !stderr.trim().is_empty() {
                    text.push_str(&format!("[stderr]\n{}\n", stderr.trim_end()));
                }
                text.push_str(&exit_note);
                Ok(tool_ok(
                    text,
                    Some(json!({
                        "direction": direction,
                        "localPath": resolved_local,
                        "remotePath": remote_path,
                        "stderr": stderr,
                        "exitCode": resp.get("exitCode").cloned().unwrap_or(Value::Null),
                        "timedOut": timed_out,
                    })),
                ))
            } else {
                Ok(tool_error(
                    resp.get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("scp failed")
                        .to_string(),
                ))
            }
        }
        "ssh_add_server" => {
            let host = match args.get("host").and_then(Value::as_str) {
                Some(h) if !h.trim().is_empty() => h.to_string(),
                _ => return Ok(tool_error("missing required argument 'host'")),
            };
            let username = match args.get("username").and_then(Value::as_str) {
                Some(u) if !u.trim().is_empty() => u.to_string(),
                _ => return Ok(tool_error("missing required argument 'username'")),
            };
            let mut call = json!({ "op": "add_server", "host": host, "username": username });
            if let Some(label) = args.get("label").and_then(Value::as_str) {
                if !label.trim().is_empty() {
                    call["label"] = json!(label);
                }
            }
            if let Some(port) = args.get("port").and_then(Value::as_u64) {
                call["port"] = json!(port);
            }
            if let Some(cred) = args.get("credential").and_then(Value::as_str) {
                if !cred.trim().is_empty() {
                    call["credential"] = json!(cred);
                }
            }
            let resp = app_call(&call).map_err(|e| (-32000, e))?;
            if resp.get("ok").and_then(Value::as_bool) == Some(true) {
                let alias = resp.get("alias").and_then(Value::as_str).unwrap_or("");
                Ok(tool_ok(
                    format!(
                        "Registered SSH server '{alias}'. Use it with ssh_open or ssh_run \
                         by this alias."
                    ),
                    Some(json!({ "alias": alias })),
                ))
            } else {
                Ok(tool_error(
                    resp.get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("add_server failed")
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

#[cfg(test)]
mod tests {
    use super::slugify;

    #[test]
    fn slugify_makes_filename_safe_slugs() {
        assert_eq!(slugify("Vault RAG Pipeline"), "vault-rag-pipeline");
        assert_eq!(slugify("  spaced  out  "), "spaced-out");
        assert_eq!(slugify("weird!!!chars@@@here"), "weird-chars-here");
        assert_eq!(slugify("--leading-trailing--"), "leading-trailing");
        assert_eq!(slugify("!!!"), ""); // no usable chars → caller rejects
    }
}

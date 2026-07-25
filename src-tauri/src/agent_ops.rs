//! Secret-operation broker ENGINE (PRD `ssh-agent-broker`, Faz 3.1 — AC13–AC15).
//!
//! Lets Claude agents (via the `muya-ssh` MCP proxy) USE a stored secret to run an
//! operator-defined, fixed-program operation (aws / kubectl / git / …) WITHOUT ever
//! seeing the raw secret. The agent references an operation BY NAME; Muya resolves
//! the secret in Rust, injects it into the CHILD process env (never the agent's env,
//! never the argv, never the response), runs the program, and returns only
//! stdout/stderr/exitCode.
//!
//! Phase 3.1 ships the ENGINE + an EMPTY registry: no real operations are defined
//! here. Operations live ONLY in `~/.claude/muya-agent-ops.json`, which is
//! operator-authored (an agent CANNOT register an op). An absent/empty file ⇒ zero
//! operations, so nothing is runnable until the operator opts in.
//!
//! ── THE SECURITY CRUX (load-bearing) ─────────────────────────────────────────
//! A "fixed program" still executes arbitrary code if its ARGUMENTS aren't policed:
//!   * `git -c core.sshCommand=<attacker>` — arbitrary command via config
//!   * `aws --endpoint-url=<attacker>`     — exfiltrate creds to a rogue endpoint
//!   * `kubectl --kubeconfig=<attacker>`   — target an attacker cluster
//!   * `… -o/--output <path>`              — write attacker-controlled files
//! Therefore `enforce_arg_policy` is FAIL-CLOSED and enforced in Rust:
//!   * a positional arg starting with `-` (a flag in an operand slot) → REJECT
//!   * a hard-denied flag (`-c --endpoint-url --kubeconfig --output -o --query`)
//!     or an op-specific denied flag → REJECT
//!   * a flag NOT on the op's `allowed_flags` allowlist → REJECT (unknown ⇒ reject)
//!   * a bare word-shaped positional (a would-be subcommand not pinned by the op)
//!     → REJECT
//! The operator pins the subcommand via `pinned_argv`; the agent may only supply
//! operand VALUES and explicitly-allowed flags. Flag values MUST use `--flag=value`
//! form so a bare word can never smuggle in a subcommand. If in doubt: REJECT.

use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};

/// Cap on captured stdout/stderr (each) before truncation, mirroring the SSH
/// broker's 256 KiB PTY buffer. Prevents a runaway op from exhausting memory.
const OUTPUT_CAP: usize = 256 * 1024;

/// Flags that can turn a "fixed program" into arbitrary code / exfiltration, no
/// matter the program. Denied for EVERY op regardless of its allowlist.
const HARD_DENIED_FLAGS: &[&str] = &[
    "-c",             // git -c core.sshCommand=… / arbitrary config
    "--endpoint-url", // aws → rogue endpoint
    "--kubeconfig",   // kubectl → attacker cluster
    "--output",       // write arbitrary files
    "-o",             // short --output
    "--query",        // jmespath side effects / large dumps
];

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

/// One operator-defined operation. Authored ONLY in `~/.claude/muya-agent-ops.json`.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct OpDefinition {
    /// The handle the agent calls by (e.g. "aws-s3-ls").
    pub name: String,
    /// Human/agent-facing note surfaced by `list_operations`.
    #[serde(default)]
    pub description: String,
    /// Absolute path to the program (e.g. "/usr/bin/aws"). Absolute-only so the
    /// executed binary can never be shadowed via PATH.
    pub program: String,
    /// Operator-pinned leading argv (subcommand + fixed flags), always prepended;
    /// the agent CANNOT alter it.
    #[serde(rename = "pinnedArgv", default)]
    pub pinned_argv: Vec<String>,
    /// Flags the agent is permitted to pass (exact match; use `--flag=value`).
    #[serde(rename = "allowedFlags", default)]
    pub allowed_flags: Vec<String>,
    /// Extra op-specific denied flags, merged with the global hard denylist.
    #[serde(rename = "deniedFlags", default)]
    pub denied_flags: Vec<String>,
    /// Credential id (in the encrypted store) whose secret feeds `env_map`.
    /// `None` ⇒ the op needs no secret (env from literal values only).
    #[serde(rename = "secretId", default)]
    pub secret_id: Option<String>,
    /// Child-process env to build. Each value is a template:
    ///   * `"{{secret}}"`               → the whole resolved secret
    ///   * `"{{secret.json:FIELD}}"`    → `FIELD` from a compact-JSON secret
    ///   * anything else                → a literal (non-secret) value
    #[serde(rename = "envMap", default)]
    pub env_map: HashMap<String, String>,
}

/// Non-secret op metadata for `list_operations`. Deliberately omits `program`,
/// `pinned_argv`, `secret_id`, and `env_map` — the agent gets name + description only.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct OpMeta {
    pub name: String,
    pub description: String,
}

/// Captured result of one operation run. Carries NO secret.
#[derive(Serialize, Clone, Debug)]
pub struct OpOutput {
    pub stdout: String,
    pub stderr: String,
    #[serde(rename = "exitCode")]
    pub exit_code: i32,
}

#[derive(Serialize, Deserialize, Default)]
struct OpsRegistry {
    #[serde(default)]
    operations: Vec<OpDefinition>,
}

// ---------------------------------------------------------------------------
// Registry persistence (file-based; operator-authored)
// ---------------------------------------------------------------------------

fn ops_path() -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    Ok(Path::new(&home).join(".claude/muya-agent-ops.json"))
}

/// Load operations from `path`. Absent OR empty file ⇒ empty list (Phase 3.1
/// default). A present-but-malformed file is a hard error (fail-closed: we do NOT
/// silently run with a partial/empty registry when the operator meant otherwise).
pub(crate) fn load_ops_from(path: &Path) -> Result<Vec<OpDefinition>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(format!("read agent-ops registry: {e}")),
    };
    if text.trim().is_empty() {
        return Ok(vec![]);
    }
    let reg: OpsRegistry =
        serde_json::from_str(&text).map_err(|e| format!("agent-ops registry parse: {e}"))?;
    Ok(reg.operations)
}

pub(crate) fn load_ops() -> Result<Vec<OpDefinition>, String> {
    load_ops_from(&ops_path()?)
}

/// Persist the registry atomically (temp + rename), reusing the credstore writer.
pub(crate) fn save_ops(ops: &[OpDefinition]) -> Result<(), String> {
    let reg = OpsRegistry {
        operations: ops.to_vec(),
    };
    let bytes = serde_json::to_vec_pretty(&reg).map_err(|e| e.to_string())?;
    crate::credstore::atomic_write(&ops_path()?, &bytes)
}

/// AC13 — resolve an op by name. Unknown name ⇒ the exact error string the spec
/// requires so the agent gets an unambiguous, self-correcting message.
pub(crate) fn resolve_op<'a>(
    ops: &'a [OpDefinition],
    name: &str,
) -> Result<&'a OpDefinition, String> {
    ops.iter()
        .find(|o| o.name == name)
        .ok_or_else(|| "no such operation".to_string())
}

pub(crate) fn op_metas(ops: &[OpDefinition]) -> Vec<OpMeta> {
    ops.iter()
        .map(|o| OpMeta {
            name: o.name.clone(),
            description: o.description.clone(),
        })
        .collect()
}

// ---------------------------------------------------------------------------
// AC14 — fail-closed argument policy (PURE)
// ---------------------------------------------------------------------------

/// A bare word-shaped token: `[A-Za-z0-9][A-Za-z0-9-]*` with no `/ . : @ _ = ~`.
/// Such tokens are exactly what CLIs treat as SUBCOMMANDS (e.g. `ec2`, `s3api`,
/// `describe-instances`), so an agent must not be able to slip one past the pinned
/// subcommand. Operand VALUES (paths, URIs, `key=value`) contain other characters
/// and are permitted; word-shaped flag values must be passed as `--flag=value`.
fn is_subcommand_shaped(tok: &str) -> bool {
    let mut chars = tok.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphanumeric() => {}
        _ => return false,
    }
    tok.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// Validate agent-supplied args against `op`, returning the policed args to append
/// AFTER `op.pinned_argv`. FAIL-CLOSED: anything not explicitly permitted is rejected.
pub(crate) fn enforce_arg_policy(
    op: &OpDefinition,
    args: &[String],
) -> Result<Vec<String>, String> {
    let mut out = Vec::with_capacity(args.len());
    for arg in args {
        if arg.contains('\0') {
            return Err("argument contains a NUL byte".to_string());
        }
        if let Some(stripped) = arg.strip_prefix('-') {
            // A flag (or a leading-`-` positional trying to look like an operand).
            // Empty ("-") and "--" are not real, whitelistable flags → reject.
            if stripped.is_empty() || stripped == "-" {
                return Err(format!("bare '{arg}' is not an allowed argument"));
            }
            // Compare on the flag NAME only (`--flag=value` → `--flag`).
            let flag = arg.split('=').next().unwrap_or(arg);
            if HARD_DENIED_FLAGS.contains(&flag) || op.denied_flags.iter().any(|d| d == flag) {
                return Err(format!(
                    "flag '{flag}' is denied for this operation (argument-injection risk)"
                ));
            }
            if !op.allowed_flags.iter().any(|a| a == flag) {
                return Err(format!(
                    "flag '{flag}' is not on this operation's allow-list (unknown flags are rejected)"
                ));
            }
            out.push(arg.clone());
        } else {
            // A positional operand. Reject word-shaped tokens that could be an
            // unpinned subcommand; permit path/URI/key=value operands.
            if is_subcommand_shaped(arg) {
                return Err(format!(
                    "positional '{arg}' looks like a subcommand; the operation's subcommand is fixed \
                     (pass flag values as --flag=value)"
                ));
            }
            out.push(arg.clone());
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// AC15 — secret → env building (PURE) and the run engine
// ---------------------------------------------------------------------------

/// Build the child-process env from `op.env_map`, expanding secret templates from
/// `secret`. PURE + secret-safe: it never logs and returns values only inside the
/// map that goes straight into the child's env. A template referencing the secret
/// while `secret` is `None`, or a JSON-field template against a non-object/missing
/// field, is a hard error (fail-closed — we never run with a half-built env).
pub(crate) fn build_op_env(
    op: &OpDefinition,
    secret: Option<&str>,
) -> Result<HashMap<String, String>, String> {
    // Parse the secret as JSON lazily, once, only if a json-field template is used.
    let mut json_cache: Option<serde_json::Value> = None;
    let mut env = HashMap::with_capacity(op.env_map.len());

    for (key, template) in &op.env_map {
        let value = if template == "{{secret}}" {
            secret
                .ok_or_else(|| {
                    format!("env '{key}' references the secret but the operation has no secretId")
                })?
                .to_string()
        } else if let Some(field) = template
            .strip_prefix("{{secret.json:")
            .and_then(|s| s.strip_suffix("}}"))
        {
            let s = secret.ok_or_else(|| {
                format!("env '{key}' references a secret field but the operation has no secretId")
            })?;
            if json_cache.is_none() {
                let parsed: serde_json::Value = serde_json::from_str(s).map_err(|_| {
                    "secret is not valid JSON but a json-field env template was used".to_string()
                })?;
                json_cache = Some(parsed);
            }
            let field = field.trim();
            let v = json_cache
                .as_ref()
                .and_then(|j| j.get(field))
                .ok_or_else(|| format!("secret JSON has no field '{field}' for env '{key}'"))?;
            match v {
                serde_json::Value::String(s) => s.clone(),
                other => other.to_string(),
            }
        } else {
            // Literal, non-secret value (e.g. AWS_DEFAULT_REGION=us-east-1).
            template.clone()
        };
        env.insert(key.clone(), value);
    }
    Ok(env)
}

/// Read up to `OUTPUT_CAP` bytes, then keep draining (so the child never blocks on
/// a full pipe) while discarding the overflow and appending a truncation marker.
fn read_capped<R: Read>(mut r: R) -> Vec<u8> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    let mut truncated = false;
    loop {
        match r.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                if buf.len() < OUTPUT_CAP {
                    let room = OUTPUT_CAP - buf.len();
                    buf.extend_from_slice(&chunk[..n.min(room)]);
                    if n > room {
                        truncated = true;
                    }
                } else {
                    truncated = true; // keep draining, drop the bytes
                }
            }
            Err(_) => break,
        }
    }
    if truncated {
        buf.extend_from_slice(b"\n[output truncated at 256 KiB]");
    }
    buf
}

/// AC15 core (PURE of Tauri/secret-resolution): policy → env → spawn the fixed
/// program with `env_clear().envs(env)`, NO shell, argv-only, bounded capture.
/// NEVER returns the secret — only stdout/stderr/exitCode.
pub(crate) fn execute_op(
    op: &OpDefinition,
    args: &[String],
    secret: Option<&str>,
) -> Result<OpOutput, String> {
    if op.program.trim().is_empty() {
        return Err("operation has no program".to_string());
    }
    if !Path::new(&op.program).is_absolute() {
        return Err("operation program must be an absolute path".to_string());
    }
    let policed = enforce_arg_policy(op, args)?;
    let env = build_op_env(op, secret)?;

    let mut argv = op.pinned_argv.clone();
    argv.extend(policed);

    // std::process::Command (NOT a PTY): aws/kubectl/git read creds from env, not a
    // TTY. env_clear() + envs(env) means ONLY the declared vars reach the child; the
    // agent's/app's environment (and the raw secret) never leak in.
    let mut child = Command::new(&op.program)
        .args(&argv)
        .env_clear()
        .envs(&env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn '{}': {e}", op.program))?;

    // Drain stdout + stderr concurrently so a full pipe can never deadlock the child.
    let out_pipe = child.stdout.take().ok_or("child stdout not captured")?;
    let err_pipe = child.stderr.take().ok_or("child stderr not captured")?;
    let out_handle = std::thread::spawn(move || read_capped(out_pipe));
    let err_handle = std::thread::spawn(move || read_capped(err_pipe));

    let status = child
        .wait()
        .map_err(|e| format!("wait '{}': {e}", op.program))?;
    let stdout = out_handle.join().map_err(|_| "stdout reader panicked")?;
    let stderr = err_handle.join().map_err(|_| "stderr reader panicked")?;

    Ok(OpOutput {
        stdout: String::from_utf8_lossy(&stdout).into_owned(),
        stderr: String::from_utf8_lossy(&stderr).into_owned(),
        exit_code: status.code().unwrap_or(-1),
    })
}

// ---------------------------------------------------------------------------
// Minimal Tauri commands (for a future ops-management UI). The broker itself
// reads the registry directly via `load_ops`, so these are optional conveniences.
// ---------------------------------------------------------------------------

/// List operation metadata (name + description only — no program/secret). Safe to
/// surface in the UI; identical projection to the agent's `list_operations`.
#[tauri::command]
pub fn agent_ops_list() -> Result<Vec<OpMeta>, String> {
    Ok(op_metas(&load_ops()?))
}

/// Create/replace an operation by name (operator-only, from the app UI). Agents
/// have NO path to this — it is a Tauri command, not a broker op.
#[tauri::command]
pub fn agent_ops_upsert(op: OpDefinition) -> Result<(), String> {
    if op.name.trim().is_empty() {
        return Err("operation name is required".into());
    }
    let mut ops = load_ops()?;
    match ops.iter_mut().find(|o| o.name == op.name) {
        Some(slot) => *slot = op,
        None => ops.push(op),
    }
    save_ops(&ops)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn op(allowed: &[&str], denied: &[&str], pinned: &[&str]) -> OpDefinition {
        OpDefinition {
            name: "test".into(),
            description: "t".into(),
            program: "/usr/bin/aws".into(),
            pinned_argv: pinned.iter().map(|s| s.to_string()).collect(),
            allowed_flags: allowed.iter().map(|s| s.to_string()).collect(),
            denied_flags: denied.iter().map(|s| s.to_string()).collect(),
            secret_id: None,
            env_map: HashMap::new(),
        }
    }
    fn a(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|s| s.to_string()).collect()
    }

    // AC13 — an unknown operation name yields the exact "no such operation" error.
    #[test]
    fn ac13_unknown_op_errors() {
        assert_eq!(resolve_op(&[], "ghost").unwrap_err(), "no such operation");
        let ops = vec![op(&[], &[], &[])];
        assert!(resolve_op(&ops, "test").is_ok());
        assert_eq!(resolve_op(&ops, "other").unwrap_err(), "no such operation");
    }

    // AC13 — an absent registry file loads as an empty list (Phase 3.1 default).
    #[test]
    fn ac13_absent_registry_is_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("muya-agent-ops.json");
        assert!(load_ops_from(&path).unwrap().is_empty());
        // An empty file is also treated as zero ops.
        std::fs::write(&path, "   ").unwrap();
        assert!(load_ops_from(&path).unwrap().is_empty());
    }

    // AC13 — save then load round-trips an operation.
    #[test]
    fn ac13_registry_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("muya-agent-ops.json");
        let reg = OpsRegistry {
            operations: vec![op(&["--region"], &[], &["s3", "ls"])],
        };
        let bytes = serde_json::to_vec_pretty(&reg).unwrap();
        crate::credstore::atomic_write(&path, &bytes).unwrap();
        let loaded = load_ops_from(&path).unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].pinned_argv, a(&["s3", "ls"]));
    }

    // AC14 — clean args (an allowed --flag=value + a URI operand) pass.
    #[test]
    fn ac14_clean_args_pass() {
        let o = op(&["--region"], &[], &["s3", "ls"]);
        let policed =
            enforce_arg_policy(&o, &a(&["--region=us-east-1", "s3://bucket/key"])).unwrap();
        assert_eq!(policed, a(&["--region=us-east-1", "s3://bucket/key"]));
    }

    // AC14 — `-c` (git arbitrary-config escape hatch) is rejected even if someone
    // mistakenly allow-lists it: the hard denylist wins.
    #[test]
    fn ac14_dash_c_rejected() {
        let o = op(&["-c"], &[], &["log"]);
        assert!(enforce_arg_policy(&o, &a(&["-c", "core.sshCommand=x"])).is_err());
    }

    // AC14 — `--endpoint-url` (aws exfiltration) is rejected.
    #[test]
    fn ac14_endpoint_url_rejected() {
        let o = op(&["--endpoint-url"], &[], &["s3", "ls"]);
        assert!(enforce_arg_policy(&o, &a(&["--endpoint-url=http://evil"])).is_err());
    }

    // AC14 — a leading-`-` positional (a flag smuggled into an operand slot) is rejected.
    #[test]
    fn ac14_leading_dash_positional_rejected() {
        let o = op(&["--region"], &[], &["s3", "ls"]);
        assert!(enforce_arg_policy(&o, &a(&["-rf"])).is_err());
    }

    // AC14 — a non-pinned subcommand (bare word) is rejected.
    #[test]
    fn ac14_non_pinned_subcommand_rejected() {
        let o = op(&["--region"], &[], &["s3", "ls"]);
        assert!(enforce_arg_policy(&o, &a(&["ec2"])).is_err());
        assert!(enforce_arg_policy(&o, &a(&["describe-instances"])).is_err());
    }

    // AC14 — an unknown flag (not on the allowlist) is rejected (fail-closed).
    #[test]
    fn ac14_unknown_flag_rejected() {
        let o = op(&["--region"], &[], &["s3", "ls"]);
        assert!(enforce_arg_policy(&o, &a(&["--profile=prod"])).is_err());
    }

    // AC15 — build_op_env maps a whole secret, a literal, and a JSON field.
    #[test]
    fn ac15_build_op_env_maps_secret_into_vars() {
        let mut o = op(&[], &[], &[]);
        o.env_map.insert("GITHUB_TOKEN".into(), "{{secret}}".into());
        o.env_map
            .insert("AWS_DEFAULT_REGION".into(), "us-east-1".into());
        let env = build_op_env(&o, Some("ghp_TOPSECRET")).unwrap();
        assert_eq!(env.get("GITHUB_TOKEN").unwrap(), "ghp_TOPSECRET");
        assert_eq!(env.get("AWS_DEFAULT_REGION").unwrap(), "us-east-1");

        // A compact-JSON token expands into multiple env vars.
        let mut o2 = op(&[], &[], &[]);
        o2.env_map
            .insert("AWS_ACCESS_KEY_ID".into(), "{{secret.json:ak}}".into());
        o2.env_map
            .insert("AWS_SECRET_ACCESS_KEY".into(), "{{secret.json:sk}}".into());
        let env2 = build_op_env(&o2, Some(r#"{"ak":"AKIA123","sk":"s3cr3t"}"#)).unwrap();
        assert_eq!(env2.get("AWS_ACCESS_KEY_ID").unwrap(), "AKIA123");
        assert_eq!(env2.get("AWS_SECRET_ACCESS_KEY").unwrap(), "s3cr3t");
    }

    // AC15 — a secret template with no secret available is a hard error (fail-closed).
    #[test]
    fn ac15_missing_secret_errors() {
        let mut o = op(&[], &[], &[]);
        o.env_map.insert("TOK".into(), "{{secret}}".into());
        assert!(build_op_env(&o, None).is_err());
    }

    // AC15 — the engine runs a fixed program and captures its stdout; the response
    // struct carries no secret value.
    #[test]
    fn ac15_execute_op_captures_stdout() {
        let mut o = op(&[], &[], &["hi"]);
        o.program = "/bin/echo".into();
        o.secret_id = Some("cred1".into());
        o.env_map.insert("TOK".into(), "{{secret}}".into());
        let out = execute_op(&o, &[], Some("NEVER_LEAK_ME")).unwrap();
        assert_eq!(out.stdout.trim(), "hi");
        assert_eq!(out.exit_code, 0);
        // The captured result must never echo the injected secret.
        let json = serde_json::to_string(&out).unwrap();
        assert!(
            !json.contains("NEVER_LEAK_ME"),
            "operation output leaked the secret: {json}"
        );
    }

    // OpMeta (list_operations projection) exposes no program path or secret.
    #[test]
    fn op_meta_hides_program_and_secret() {
        let o = op(&["--region"], &[], &["s3", "ls"]);
        let metas = op_metas(std::slice::from_ref(&o));
        let json = serde_json::to_string(&metas).unwrap();
        for banned in ["program", "aws", "secretId", "pinnedArgv", "envMap"] {
            assert!(!json.contains(banned), "OpMeta leaked `{banned}`: {json}");
        }
    }
}

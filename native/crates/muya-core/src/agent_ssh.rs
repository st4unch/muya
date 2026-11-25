//! Persistent, headless agent-owned SSH sessions (PRD `ssh-session`, Faz 2).
//!
//! ControlMaster multiplexing is rejected by CyberArk PSMP (L41), so "one connection,
//! many commands" cannot be done by reusing channels. Instead we keep ONE interactive
//! SSH session (one PTY, one PSMP audited session → ONE OTP/push) alive and run many
//! commands INSIDE it, framing each with a nonce'd begin/end sentinel so we can read its
//! output + exit code back. Shell state (cd/env/sudo) is preserved between commands.
//!
//! The session is headless (no visible tab): the broker owns it end to end. The password
//! is injected into the PTY exactly like `pty::run_with_injection` and never crosses to
//! the agent. A typed 2FA/OTP challenge is withheld (session can't proceed
//! non-interactively); a RADIUS push is out-of-band (the human approves once, at open).

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use zeroize::Zeroizing;

const BUFFER_CAP: usize = 512 * 1024;
/// Auth (incl. a RADIUS push the human must approve) can take a while.
const READY_TIMEOUT: Duration = Duration::from_secs(90);
const DEFAULT_EXEC_TIMEOUT: Duration = Duration::from_secs(120);
const POLL: Duration = Duration::from_millis(60);

struct Session {
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    buffer: Arc<Mutex<String>>,
    child: Box<dyn Child + Send + Sync>,
    _master: Box<dyn MasterPty + Send>,
    /// Updated at the start of every `exec`. The idle reaper closes a session that
    /// hasn't been used in `IDLE_TIMEOUT` — an agent that opens a session and then
    /// forgets to `close` it (crashes, context reset) would otherwise leak the PTY
    /// process and its PSMP-audited connection for the life of the app.
    last_used: Mutex<Instant>,
}

/// A session idle this long is closed by the background reaper (see `reap_idle` /
/// `lib.rs`'s periodic sweep). Generous — a real back-and-forth shouldn't trip it —
/// but bounded, so a forgotten session doesn't run forever.
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(30 * 60);

/// Cloneable (Arc inside) so a broker handler can move a handle into `spawn_blocking`
/// for the blocking open/exec while the session map stays shared.
#[derive(Default, Clone)]
pub struct AgentSshStore(Arc<Mutex<HashMap<String, Session>>>);

pub struct ExecOutput {
    pub stdout: String,
    pub exit_code: i32,
    pub timed_out: bool,
}

fn nonce() -> String {
    format!(
        "{:x}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    )
}

/// Extract the output framed between `__MUYA<nonce>B__` and `__MUYA<nonce>E:<rc>__` in
/// `text`, returning `(output, exit_code)`. Pure/testable. The full markers are assembled
/// on the remote from a shell variable (`printf '%sB__' "$M"`), so the command the PTY
/// echoes back never contains a full marker — `find` only ever hits the real output.
fn extract_framed(text: &str, nonce: &str) -> Option<(String, i32)> {
    let begin = format!("__MUYA{nonce}B__");
    let end_prefix = format!("__MUYA{nonce}E:");
    let b = text.find(&begin)? + begin.len();
    let after = &text[b..];
    let e = after.find(&end_prefix)?;
    let out = &after[..e];
    let rest = &after[e + end_prefix.len()..];
    let rc = rest
        .split("__")
        .next()
        .and_then(|s| s.trim().parse::<i32>().ok())
        .unwrap_or(-1);
    // Trim the framing newlines the printf added around the markers.
    Some((out.trim_matches(['\r', '\n']).to_string(), rc))
}

fn spawn_reader(
    mut reader: Box<dyn Read + Send>,
    buffer: Arc<Mutex<String>>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    secret: Option<Zeroizing<String>>,
    is_psmp: bool,
    injected: Arc<AtomicBool>,
    challenge: Arc<AtomicBool>,
) {
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        let mut done_inject = false;
        let mut tail = String::new();
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let chunk = String::from_utf8_lossy(&buf[..n]);
                    // Password injection (same policy as pty::run_with_injection): a PSMP
                    // typed-challenge is withheld; an ordinary password prompt is answered.
                    if let (false, Some(sec)) = (done_inject, secret.as_ref()) {
                        tail.push_str(&chunk);
                        crate::inject::trim_prompt_tail(&mut tail, 512);
                        if is_psmp && crate::inject::looks_like_challenge_prompt(&tail) {
                            done_inject = true;
                            challenge.store(true, Ordering::Relaxed);
                        } else if crate::inject::looks_like_password_prompt(&tail) {
                            if let Ok(mut w) = writer.lock() {
                                let _ = w.write_all(sec.as_bytes());
                                let _ = w.write_all(b"\n");
                                let _ = w.flush();
                            }
                            done_inject = true;
                            injected.store(true, Ordering::Relaxed);
                        }
                    }
                    // Poison-tolerant: a panic elsewhere must not wedge every later exec.
                    let mut b = buffer.lock().unwrap_or_else(|e| e.into_inner());
                    b.push_str(&chunk);
                    crate::inject::trim_prompt_tail(&mut b, BUFFER_CAP);
                    drop(b);
                }
                Err(_) => break,
            }
        }
    });
}

/// Open a persistent session: spawn the ssh PTY, inject the password on prompt, and wait
/// until the shell is interactive (a ready-probe echoes back). Returns the session id.
pub fn open(
    store: &AgentSshStore,
    program: &str,
    args: &[String],
    secret: Option<Zeroizing<String>>,
    is_psmp: bool,
) -> Result<String, String> {
    open_with(store, program, args, secret, is_psmp, READY_TIMEOUT)
}

/// How long the output must stay quiet before a login that never asked for the password (key auth, a reused ControlMaster)
/// is treated as "no prompt is coming" and the shell-ready probe may be sent.
const QUIET_BEFORE_PROBE: Duration = Duration::from_millis(2500);

/// May the shell-ready probe be written now? The password path is unchanged: with a secret armed, the probe waits until it was
/// injected. The ADDITION: a login that produced output, is not at a password / challenge prompt and has been quiet for
/// `QUIET_BEFORE_PROBE` is already past authentication (key login, multiplexed connection), so the probe may go. Nothing the
/// probe does can send the password: injection only ever happens on a seen prompt (see `spawn_reader`).
fn may_probe(need_inject: bool, injected: bool, tail: &str, quiet_for: Duration) -> bool {
    if !need_inject || injected {
        return true;
    }
    !tail.is_empty()
        && quiet_for >= QUIET_BEFORE_PROBE
        && !crate::inject::looks_like_password_prompt(tail)
        && !crate::inject::looks_like_challenge_prompt(tail)
}

pub fn open_with(
    store: &AgentSshStore,
    program: &str,
    args: &[String],
    secret: Option<Zeroizing<String>>,
    is_psmp: bool,
    ready_timeout: Duration,
) -> Result<String, String> {
    let pair = native_pty_system()
        .openpty(PtySize {
            rows: 40,
            cols: 120,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| format!("openpty failed: {e}"))?;

    let mut cmd = CommandBuilder::new(program);
    for a in args {
        cmd.arg(a);
    }
    cmd.env("TERM", "xterm-256color");
    for (k, _) in std::env::vars() {
        if k.starts_with("CLAUDE") || k == "AI_AGENT" {
            cmd.env_remove(&k);
        }
    }

    let child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|e| format!("spawn failed: {e}"))?;
    drop(pair.slave);

    let reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| format!("clone reader failed: {e}"))?;
    let writer = Arc::new(Mutex::new(
        pair.master
            .take_writer()
            .map_err(|e| format!("take writer failed: {e}"))?,
    ));
    let buffer = Arc::new(Mutex::new(String::new()));
    let injected = Arc::new(AtomicBool::new(false));
    let challenge = Arc::new(AtomicBool::new(false));
    let need_inject = secret.is_some();

    spawn_reader(
        reader,
        Arc::clone(&buffer),
        Arc::clone(&writer),
        secret,
        is_psmp,
        Arc::clone(&injected),
        Arc::clone(&challenge),
    );

    // Wait for the shell to become interactive. A typed challenge (OTP) means we can't
    // proceed non-interactively. Once the password is in (or none is needed), probe with
    // a printf and wait for it to echo — that only happens at an interactive shell, so it
    // also waits out a RADIUS push the human is approving.
    let deadline = Instant::now() + ready_timeout;
    let mut seen_len = 0usize;
    let mut changed_at = Instant::now();
    // Built from `$R` on the remote (like exec markers) so the echoed probe command never
    // contains the full token — only the real printf output does.
    let rn = nonce();
    let probe = format!("__MUYAREADY{rn}__");
    let mut probed_at: Option<Instant> = None;
    loop {
        if challenge.load(Ordering::Relaxed) {
            let _ = kill_child(child);
            return Err(
                "PSMP asked for a 2FA/OTP challenge — a persistent session can't answer it \
                 non-interactively; the connection was closed."
                    .into(),
            );
        }
        if Instant::now() > deadline {
            let _ = kill_child(child);
            return Err(
                "timed out waiting for the remote shell (is a login push awaiting approval?)"
                    .into(),
            );
        }
        let ready = buffer.lock().map(|b| b.contains(&probe)).unwrap_or(false);
        if ready {
            break;
        }
        // Only start probing once the password is in (writing during the password prompt
        // would feed the probe into the password field). Re-probe periodically so a probe
        // that lands mid-push still gets retried.
        let (blen, tail) = buffer.lock().map(|b| (b.len(), b.clone())).unwrap_or_default();
        if blen != seen_len {
            seen_len = blen;
            changed_at = Instant::now();
        }
        let can_probe = may_probe(need_inject, injected.load(Ordering::Relaxed), &tail, changed_at.elapsed());
        if can_probe
            && probed_at
                .map(|t| t.elapsed() > Duration::from_secs(2))
                .unwrap_or(true)
        {
            if let Ok(mut w) = writer.lock() {
                // Build the token from $R so the echoed command doesn't contain the full
                // `probe` (echo shows `%s__`, output shows `__MUYAREADY<rn>__`).
                let _ = w.write_all(
                    format!("R=__MUYAREADY{rn}; printf '\\n%s__\\n' \"$R\"\n").as_bytes(),
                );
                let _ = w.flush();
            }
            probed_at = Some(Instant::now());
        }
        std::thread::sleep(POLL);
    }

    // Drop everything up to and including the ready-probe echo so the first exec's buffer
    // scan starts clean.
    if let Ok(mut b) = buffer.lock() {
        if let Some(pos) = b.rfind(&probe) {
            let cut = pos + probe.len();
            b.drain(..cut);
        }
    }

    let session_id = format!("agentssh:{}", nonce());
    store.0.lock().unwrap().insert(
        session_id.clone(),
        Session {
            writer,
            buffer,
            child,
            _master: pair.master,
            last_used: Mutex::new(Instant::now()),
        },
    );
    Ok(session_id)
}

/// A session around `program` on a fresh PTY WITHOUT the shell-ready probe (no password, no echo handshake): the building
/// block of the idle-reaper tests, which need a live child to reap but no remote shell. Returns the id and the child's pid.
pub fn spawn_unprobed(store: &AgentSshStore, program: &str, args: &[String]) -> Result<(String, Option<u32>), String> {
    let pair = native_pty_system()
        .openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
        .map_err(|e| format!("openpty failed: {e}"))?;
    let mut cmd = CommandBuilder::new(program);
    for a in args {
        cmd.arg(a);
    }
    cmd.cwd("/");
    let child = pair.slave.spawn_command(cmd).map_err(|e| format!("spawn failed: {e}"))?;
    drop(pair.slave);
    let pid = child.process_id();
    let writer: Arc<Mutex<Box<dyn Write + Send>>> = Arc::new(Mutex::new(pair.master.take_writer().map_err(|e| e.to_string())?));
    let id = format!("agentssh:{}", nonce());
    store.0.lock().unwrap().insert(
        id.clone(),
        Session { writer, buffer: Arc::new(Mutex::new(String::new())), child, _master: pair.master, last_used: Mutex::new(Instant::now()) },
    );
    Ok((id, pid))
}

/// How many sessions the store holds.
pub fn session_count(store: &AgentSshStore) -> usize {
    store.0.lock().unwrap().len()
}

/// Mark `id` used `age` ago (a clock seam for the reaper tests: no need to wait out a real timeout).
pub fn set_last_used_ago(store: &AgentSshStore, id: &str, age: Duration) {
    if let Some(s) = store.0.lock().unwrap().get(id) {
        *s.last_used.lock().unwrap() = Instant::now().checked_sub(age).unwrap_or_else(Instant::now);
    }
}

/// Run one command inside an open session, framed by begin/end sentinels, and return its
/// output + exit code. Preserves shell state between calls.
pub fn exec(
    store: &AgentSshStore,
    session_id: &str,
    command: &str,
    timeout: Option<Duration>,
) -> Result<ExecOutput, String> {
    let timeout = timeout.unwrap_or(DEFAULT_EXEC_TIMEOUT);
    // Clone the Arc'd handles out and drop the map lock immediately — a command can run
    // for up to `timeout` (minutes), and holding the STORE-WIDE lock for that whole span
    // would block every other session's open/exec/close and the idle reaper behind it.
    let (writer, buffer) = {
        let sessions = store.0.lock().unwrap();
        let s = sessions
            .get(session_id)
            .ok_or_else(|| format!("no open session '{session_id}'"))?;
        *s.last_used.lock().unwrap() = Instant::now();
        (Arc::clone(&s.writer), Arc::clone(&s.buffer))
    };
    let n = nonce();
    // Mark where this exec's output starts, then write the framed command. The marker is
    // built from `$M` on the remote so the echoed input line never contains a FULL marker
    // (echo shows `%sB__`, output shows `__MUYA<n>B__`). One line → no continuation prompt.
    let mark = buffer.lock().map(|b| b.len()).unwrap_or(0);
    let line = format!(
        "M=__MUYA{n}; printf '\\n%sB__\\n' \"$M\"; {command}; printf '\\n%sE:%d__\\n' \"$M\" \"$?\"\n"
    );
    {
        let mut w = writer.lock().map_err(|_| "writer poisoned".to_string())?;
        w.write_all(line.as_bytes())
            .map_err(|e| format!("write failed: {e}"))?;
        w.flush().map_err(|e| format!("flush failed: {e}"))?;
    }
    let end_prefix = format!("__MUYA{n}E:");
    let deadline = Instant::now() + timeout;
    loop {
        {
            let b = buffer.lock().unwrap_or_else(|e| e.into_inner());
            let region = &b[mark.min(b.len())..];
            if region.contains(&end_prefix) {
                if let Some((out, rc)) = extract_framed(region, &n) {
                    return Ok(ExecOutput {
                        stdout: out,
                        exit_code: rc,
                        timed_out: false,
                    });
                }
            }
        }
        if Instant::now() > deadline {
            // Interrupt the stuck command so the session stays usable (Ctrl-C + resync).
            if let Ok(mut w) = writer.lock() {
                let _ = w.write_all(b"\x03");
                let _ = w.flush();
            }
            let partial = buffer
                .lock()
                .map(|b| {
                    let r = &b[mark.min(b.len())..];
                    // best-effort: strip up to the begin marker if present
                    match r.find(&format!("__MUYA{n}B__")) {
                        Some(i) => r[i..].trim_matches(['\r', '\n']).to_string(),
                        None => r.trim_matches(['\r', '\n']).to_string(),
                    }
                })
                .unwrap_or_default();
            return Ok(ExecOutput {
                stdout: partial,
                exit_code: -1,
                timed_out: true,
            });
        }
        std::thread::sleep(POLL);
    }
}

pub fn close(store: &AgentSshStore, session_id: &str) -> Result<(), String> {
    let mut sessions = store.0.lock().unwrap();
    match sessions.remove(session_id) {
        Some(s) => {
            let _ = kill_child(s.child);
            Ok(())
        }
        None => Err(format!("no open session '{session_id}'")),
    }
}

/// Close every session idle longer than `idle_timeout`. Called periodically by a
/// background task (`lib.rs`) so an agent that opens a session and never closes it
/// (crash, context reset, just forgetting) doesn't leak the PTY/PSMP connection for
/// the life of the app. Returns the ids it closed, for logging.
pub fn reap_idle(store: &AgentSshStore, idle_timeout: Duration) -> Vec<String> {
    let stale: Vec<String> = {
        let sessions = store.0.lock().unwrap();
        sessions
            .iter()
            .filter(|(_, s)| {
                s.last_used
                    .lock()
                    .map(|t| t.elapsed() >= idle_timeout)
                    .unwrap_or(false)
            })
            .map(|(id, _)| id.clone())
            .collect()
    };
    for id in &stale {
        let _ = close(store, id);
    }
    stale
}

fn kill_child(mut child: Box<dyn Child + Send + Sync>) -> Result<(), String> {
    let _ = child.kill();
    let _ = child.wait();
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn buffer_trim_is_utf8_safe() {
        // 2-byte chars so any odd cut lands mid-char.
        let mut s = "ü".repeat(BUFFER_CAP);
        crate::inject::trim_prompt_tail(&mut s, BUFFER_CAP);
        assert!(s.len() <= BUFFER_CAP);
        let mut t = "ğ".repeat(400) + "x";
        crate::inject::trim_prompt_tail(&mut t, 511);
        assert!(t.len() <= 511);
    }
    use super::*;

    #[test]
    fn extract_framed_pulls_output_and_rc() {
        // The echoed command line (with `%sB__`) must NOT be mistaken for the real marker.
        let text = "M=__MUYA9f; printf '%sB__' ...\n__MUYA9fB__\nhello world\n__MUYA9fE:0__\n";
        let (out, rc) = extract_framed(text, "9f").unwrap();
        assert_eq!(out, "hello world");
        assert_eq!(rc, 0);
    }

    #[test]
    fn extract_framed_nonzero_exit_and_empty_output() {
        let text = "__MUYA9fB__\n__MUYA9fE:1__";
        let (out, rc) = extract_framed(text, "9f").unwrap();
        assert_eq!(out, "");
        assert_eq!(rc, 1);
    }

    #[test]
    fn extract_framed_none_without_end() {
        assert!(extract_framed("__MUYA9fB__\npartial output no end", "9f").is_none());
    }

    // End-to-end over a LOCAL bash PTY (no ssh/PSMP): proves the session mechanism —
    // ready-probe, framed exec, output capture, and STATE PRESERVATION between commands.
    #[test]
    #[ignore = "spawns a real bash PTY; run explicitly"]
    fn local_bash_session_execs_and_preserves_state() {
        let store = AgentSshStore::default();
        let sid = open(&store, "bash", &[], None, false).expect("open bash session");
        let a = exec(&store, &sid, "echo hello", Some(Duration::from_secs(8))).unwrap();
        assert_eq!(a.stdout, "hello");
        assert_eq!(a.exit_code, 0);
        exec(&store, &sid, "cd /tmp", None).unwrap();
        let b = exec(&store, &sid, "pwd", None).unwrap();
        assert!(b.stdout.contains("/tmp"), "state preserved: {:?}", b.stdout);
        let c = exec(&store, &sid, "false", None).unwrap();
        assert_eq!(c.exit_code, 1);
        close(&store, &sid).unwrap();
        assert!(exec(&store, &sid, "echo x", None).is_err()); // closed
    }

    // Idle reaper: a session untouched past the timeout is closed; one used more
    // recently is left alone. Real bash PTY (same reason as the test above).
    #[test]
    #[ignore = "spawns a real bash PTY; run explicitly"]
    fn reap_idle_closes_only_sessions_past_the_timeout() {
        let store = AgentSshStore::default();
        let stale = open(&store, "bash", &[], None, false).expect("open stale session");
        let fresh = open(&store, "bash", &[], None, false).expect("open fresh session");
        exec(&store, &fresh, "echo hi", Some(Duration::from_secs(8))).unwrap();

        // Backdate the stale session's last_used — same-module test, so the private
        // field is directly reachable (no need to actually wait out a real timeout).
        {
            let sessions = store.0.lock().unwrap();
            let s = sessions.get(&stale).unwrap();
            *s.last_used.lock().unwrap() = Instant::now() - Duration::from_secs(3600);
        }

        let closed = reap_idle(&store, Duration::from_secs(1800));
        assert_eq!(closed, vec![stale.clone()]);
        assert!(
            exec(&store, &stale, "echo x", None).is_err(),
            "stale session reaped"
        );
        assert!(
            exec(&store, &fresh, "echo x", Some(Duration::from_secs(8))).is_ok(),
            "recently-used session must survive"
        );
        close(&store, &fresh).unwrap();
    }

    fn alive(pid: u32) -> bool {
        // signal 0 = "does this process exist" (a reaped child is gone, a zombie would still answer)
        unsafe { libc::kill(pid as i32, 0) == 0 }
    }

    /// The idle reaper closes the session past the timeout and leaves a recently used one; the closed one's child is
    /// killed AND waited for (no zombie), the other keeps running. Real PTY children (`sleep`), no shell, no env needed.
    #[test]
    fn reap_idle_closes_only_idle_sessions_and_reaps_their_child() {
        let store = AgentSshStore::default();
        let (idle, idle_pid) = spawn_unprobed(&store, "/bin/sleep", &["600".into()]).expect("idle child");
        let (busy, busy_pid) = spawn_unprobed(&store, "/bin/sleep", &["600".into()]).expect("busy child");
        let (idle_pid, busy_pid) = (idle_pid.unwrap(), busy_pid.unwrap());
        assert!(alive(idle_pid) && alive(busy_pid));
        set_last_used_ago(&store, &idle, Duration::from_secs(3600));
        set_last_used_ago(&store, &busy, Duration::from_secs(60));

        let closed = reap_idle(&store, IDLE_TIMEOUT);
        assert_eq!(closed, vec![idle.clone()]);
        assert_eq!(session_count(&store), 1, "only the busy session is left");
        assert!(!alive(idle_pid), "the idle session's child is killed and reaped");
        assert!(alive(busy_pid), "the busy session's child still runs");
        assert!(exec(&store, &idle, "echo x", None).is_err(), "the idle session id is gone");

        close(&store, &busy).unwrap();
        assert!(!alive(busy_pid));
        assert_eq!(session_count(&store), 0);
    }

    #[test]
    fn buffer_cap_is_512k_and_idle_timeout_30_minutes() {
        assert_eq!(BUFFER_CAP, 512 * 1024);
        assert_eq!(IDLE_TIMEOUT, Duration::from_secs(30 * 60));
    }

    fn secret(s: &str) -> Option<Zeroizing<String>> {
        Some(Zeroizing::new(s.to_string()))
    }

    #[test]
    fn probe_gate_keeps_the_password_path_and_adds_the_quiet_login() {
        let q = Duration::from_secs(3);
        // password path: with a secret armed and not yet injected, a prompt (or no output) never lets the probe go
        assert!(!may_probe(true, false, "u@h's password: ", q));
        assert!(!may_probe(true, false, "", q), "no output at all: nothing to go on, nothing is written");
        assert!(!may_probe(true, false, "Last login\n$ ", Duration::from_millis(100)), "not quiet long enough");
        assert!(may_probe(true, true, "anything", Duration::ZERO), "after the injection the probe goes at once, as before");
        assert!(may_probe(false, false, "", Duration::ZERO), "no secret: as before");
        // the addition: a quiet shell with output and no prompt (key login, reused connection)
        assert!(may_probe(true, false, "Last login: today\n$ ", q));
        assert!(!may_probe(true, false, "Enter your RADIUS passcode: ", q), "a challenge is never probed over");
    }

    /// A password server still injects and opens (a child that asks for the password and logs what it reads).
    #[test]
    fn a_password_prompt_is_answered_once_and_the_session_opens() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("read.txt");
        let script = format!("printf 'user@host password: '; read -r PW; echo \"$PW\" > '{}'; echo Welcome; exec sh", log.display());
        let store = AgentSshStore::default();
        let id = open_with(&store, "/bin/sh", &["-c".into(), script], secret("Pw-Inject-1"), false, Duration::from_secs(20)).expect("opens");
        assert_eq!(std::fs::read_to_string(&log).unwrap().trim(), "Pw-Inject-1", "the password was injected on the prompt");
        close(&store, &id).unwrap();
    }

    /// A key-only login prints no password prompt: the session opens and the password is NEVER written (the child logs its stdin).
    #[test]
    fn a_login_without_a_prompt_opens_and_never_gets_the_password() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("stdin.txt");
        let script = format!("echo 'Last login: today'; tee '{}' | sh", log.display());
        let store = AgentSshStore::default();
        let id = open_with(&store, "/bin/sh", &["-c".into(), script], secret("Pw-Never-Sent-2"), false, Duration::from_secs(30)).expect("opens without a prompt");
        let seen = std::fs::read_to_string(&log).unwrap_or_default();
        assert!(!seen.contains("Pw-Never-Sent-2"), "the password was written to a login that never asked: {seen:?}");
        close(&store, &id).unwrap();
    }

    /// No output, no prompt: nothing is written at all (no probe, no password) and the open fails at the timeout.
    #[test]
    fn silence_writes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("stdin.txt");
        let script = format!("cat > '{}'", log.display());
        let store = AgentSshStore::default();
        let r = open_with(&store, "/bin/sh", &["-c".into(), script], secret("Pw-Silent-3"), false, Duration::from_secs(4));
        assert!(r.is_err(), "times out");
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(std::fs::read_to_string(&log).unwrap_or_default(), "", "nothing was written to a silent login");
    }
}

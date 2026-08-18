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
                        if tail.len() > 512 {
                            let cut = tail.len() - 512;
                            tail.drain(..cut);
                        }
                        if is_psmp && crate::pty::looks_like_challenge_prompt(&tail) {
                            done_inject = true;
                            challenge.store(true, Ordering::Relaxed);
                        } else if crate::pty::looks_like_password_prompt(&tail) {
                            if let Ok(mut w) = writer.lock() {
                                let _ = w.write_all(sec.as_bytes());
                                let _ = w.write_all(b"\n");
                                let _ = w.flush();
                            }
                            done_inject = true;
                            injected.store(true, Ordering::Relaxed);
                        }
                    }
                    if let Ok(mut b) = buffer.lock() {
                        b.push_str(&chunk);
                        if b.len() > BUFFER_CAP {
                            let cut = b.len() - BUFFER_CAP;
                            b.drain(..cut);
                        }
                    }
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
    let deadline = Instant::now() + READY_TIMEOUT;
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
        let can_probe = !need_inject || injected.load(Ordering::Relaxed);
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
            let b = buffer.lock().unwrap();
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
}

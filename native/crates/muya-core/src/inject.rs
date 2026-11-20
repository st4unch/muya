//! Password/challenge prompt detection and the PTY runner that injects a secret at the prompt
//! (moved from src-tauri pty.rs unchanged; used by ssh, askpass and agent_ssh).

use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use zeroize::Zeroizing;

/// True when the output tail ends in an interactive password/passcode prompt —
/// the trigger for one-shot SSH password injection. Matched case-insensitively on
/// the trailing text (trimmed) so `Password:`, `user@host's password:` and RADIUS
/// `Passcode:` all fire, while incidental mentions mid-line (which have more text
/// after them) do not.
pub fn looks_like_password_prompt(tail: &str) -> bool {
    let t = tail.trim_end().to_lowercase();
    t.ends_with("password:") || t.ends_with("passcode:")
}

/// True when the output tail ends in a 2FA/OTP/RADIUS-passcode CHALLENGE — the
/// PSMP-only gate (PRD `ssh-run-psmp-hardening` AC2). This must NEVER be answered
/// by injecting the stored password: a password typed into an OTP/passcode field
/// burns a failed RADIUS auth attempt and risks locking the account. Only checked
/// for PSMP connections, and checked BEFORE `looks_like_password_prompt` in the
/// injector — direct-SSH connections never consult this function, so the existing
/// `passcode:` → inject behavior there (AC4 regression guard) is untouched.
pub fn looks_like_challenge_prompt(tail: &str) -> bool {
    let t = tail.trim_end().to_lowercase();
    t.ends_with("passcode:")
        || t.ends_with("verification code:")
        || t.ends_with("one-time")
        || t.ends_with("otp:")
}

/// Captured result of a single non-interactive command run in a PTY. Carries NO
/// secret: the injected password answers ssh's prompt *inside* the PTY and the
/// prompt line is stripped from `stdout` before it is returned (AC9).
#[derive(Debug, Clone, serde::Serialize)]
pub struct CommandOutput {
    pub stdout: String,
    pub exit_code: Option<i32>,
    pub timed_out: bool,
    /// AC2 — a PSMP 2FA/OTP/passcode CHALLENGE prompt was seen. The secret was
    /// deliberately NOT injected and the child was killed as soon as this fired.
    pub challenge_detected: bool,
    /// True iff the secret was actually written into the PTY this run. Distinct
    /// from `challenge_detected` (which is always false when this is true, and
    /// vice versa) — callers use this to tell "no prompt ever appeared" (AC3,
    /// possible RADIUS push with no local prompt) from "we injected normally".
    pub injected: bool,
    /// Captured stderr (askpass path only; empty for the PTY path, which merges the
    /// streams). Surfaced so a failed ssh/scp shows its REAL error (e.g. a CyberArk
    /// PSMP DLP "download not permitted" message) instead of a bare exit code. Never
    /// contains the password — ssh/scp never echo it (askpass keeps it off the tty).
    #[serde(default)]
    pub stderr: String,
}

/// Hard cap on captured output (AC8): stop appending past this so a runaway remote
/// command can never grow memory without bound.
pub const CAPTURE_CAP: usize = 256 * 1024;

/// Keep the prompt-watch tail bounded WITHOUT ever slicing through a character.
///
/// `String::len` is bytes and PTY output is arbitrary UTF-8 — server banners,
/// box-drawing TUI frames, Turkish text. Draining to a raw `len - LIMIT` offset
/// panics the moment that offset lands inside a multi-byte character, which kills
/// the reader thread and freezes that session's output for good. Rounding the cut
/// forward to the next boundary keeps the bound and drops at most 3 extra bytes.
pub fn trim_prompt_tail(tail: &mut String, limit: usize) {
    if tail.len() <= limit {
        return;
    }
    let mut cut = tail.len() - limit;
    while cut < tail.len() && !tail.is_char_boundary(cut) {
        cut += 1;
    }
    tail.drain(..cut);
}

/// Remove the password-prompt line (and any trailing CR/LF/space) from captured
/// output so the returned stdout starts at the remote command's own output. The
/// prompt is always the FIRST `password:`/`passcode:` occurrence (it precedes any
/// remote output), so matching the first hit is correct. The password itself is
/// never echoed by ssh, so it never appears here — this only hides the prompt text.
pub fn strip_injected_prompt(raw: &str) -> String {
    // ASCII-only lowercasing, NOT `to_lowercase()`. Unicode lowercasing is not
    // length-preserving — 'İ' (U+0130, 2 bytes) lowercases to "i\u{307}" (3 bytes) —
    // so an offset found in a `to_lowercase()` copy does not address the same place
    // in `raw`. Slicing `raw` at it either panics on a non-char-boundary or silently
    // cuts the wrong text. The markers below are pure ASCII, so ASCII folding finds
    // exactly the same matches while keeping every byte offset valid in `raw`.
    let lower = raw.to_ascii_lowercase();
    let mut best: Option<usize> = None;
    for marker in ["password:", "passcode:"] {
        if let Some(pos) = lower.find(marker) {
            let end = pos + marker.len();
            best = Some(best.map_or(end, |b| b.min(end)));
        }
    }
    match best {
        Some(end) => raw[end..].trim_start_matches([' ', '\r', '\n']).to_string(),
        None => raw.to_string(),
    }
}

/// Run `program args` in a real PTY, capturing output into a BOUNDED buffer while
/// injecting `inject_secret` exactly once at the password prompt (AC8). ssh reads
/// its password from a TTY, so a PTY — not `std::process::Command` — is required.
///
/// Blocking / synchronous: call from async code via `tokio::task::spawn_blocking`.
/// Waits up to `timeout` for the child to exit, then kills it (`timed_out=true`).
/// The secret is written only into the PTY and never appears in `stdout`.
///
/// `is_psmp` gates the AC2 challenge check: when true, a 2FA/OTP/passcode prompt
/// (`looks_like_challenge_prompt`) is classified BEFORE the password check, the
/// secret is never written, and the child is killed immediately (no waiting out
/// the full `timeout`). When false (direct SSH), challenge classification is
/// skipped entirely and behavior is byte-for-byte the prior direct-SSH path (AC4).
pub fn run_with_injection(
    program: &str,
    args: &[String],
    inject_secret: Option<Zeroizing<String>>,
    timeout: Duration,
    is_psmp: bool,
) -> Result<CommandOutput, String> {
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows: 24,
            cols: 80,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| format!("openpty failed: {e}"))?;

    let mut cmd = CommandBuilder::new(program);
    for a in args {
        cmd.arg(a);
    }
    cmd.env("TERM", "xterm-256color");
    // Same CLAUDE* strip as spawn_process — keep the child a clean top-level proc.
    for (k, _) in std::env::vars() {
        if k.starts_with("CLAUDE") || k == "AI_AGENT" {
            cmd.env_remove(&k);
        }
    }

    let mut child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|e| format!("spawn failed: {e}"))?;
    drop(pair.slave); // so the master reader sees EOF when the child exits

    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| format!("clone reader failed: {e}"))?;
    let writer = Arc::new(Mutex::new(
        pair.master
            .take_writer()
            .map_err(|e| format!("take writer failed: {e}"))?,
    ));
    // Hold the master open until after the reader thread joins so reads don't error.
    let _master = pair.master;

    let captured = Arc::new(Mutex::new(Vec::<u8>::new()));
    let injected_flag = Arc::new(AtomicBool::new(false));
    // AC2 — set (once) the instant a PSMP challenge prompt is seen; the outer poll
    // loop watches this to kill the child immediately instead of waiting `timeout`.
    let challenge_flag = Arc::new(AtomicBool::new(false));
    let inject = inject_secret.map(|s| (Arc::clone(&writer), s));
    let cap_for_thread = Arc::clone(&captured);
    let injf = Arc::clone(&injected_flag);
    let chf = Arc::clone(&challenge_flag);

    let reader_handle = std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        let mut injected = false;
        let mut tail = String::new();
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    // Watch the tail for a prompt, then act once. PSMP checks the
                    // 2FA/OTP challenge shape FIRST (AC2) — a match there means the
                    // secret is a password answering an OTP field, so we withhold
                    // it entirely rather than inject. Direct connections never run
                    // this branch (`is_psmp` false), so `passcode:` there still
                    // falls through to the ordinary password-prompt injection below
                    // exactly as before (AC4).
                    if let (false, Some((w, secret))) = (injected, inject.as_ref()) {
                        tail.push_str(&String::from_utf8_lossy(&buf[..n]));
                        trim_prompt_tail(&mut tail, 512);
                        if is_psmp && looks_like_challenge_prompt(&tail) {
                            injected = true; // one-shot: never (re)consider injecting this run
                            chf.store(true, Ordering::Relaxed);
                        } else if looks_like_password_prompt(&tail) {
                            if let Ok(mut wl) = w.lock() {
                                let _ = wl.write_all(secret.as_bytes());
                                let _ = wl.write_all(b"\n");
                                let _ = wl.flush();
                            }
                            injected = true;
                            injf.store(true, Ordering::Relaxed);
                        }
                    }
                    // Bounded accumulation: stop appending once the cap is reached.
                    if let Ok(mut c) = cap_for_thread.lock() {
                        if c.len() < CAPTURE_CAP {
                            let room = CAPTURE_CAP - c.len();
                            let take = room.min(n);
                            c.extend_from_slice(&buf[..take]);
                        }
                    }
                }
                Err(_) => break,
            }
        }
    });

    // Wait for exit or timeout, polling so we can enforce the deadline + kill. A
    // detected challenge (AC2) short-circuits this immediately — no reason to keep
    // a PSMP session open (or wait out `timeout`) once we know we won't inject.
    let deadline = Instant::now() + timeout;
    let mut exit_code = None;
    let mut timed_out = false;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                exit_code = Some(status.exit_code() as i32);
                break;
            }
            Ok(None) => {
                if challenge_flag.load(Ordering::Relaxed) {
                    let _ = child.kill();
                    let _ = child.wait();
                    break;
                }
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    timed_out = true;
                    break;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(_) => break,
        }
    }

    // Child gone → reader hits EOF → thread returns. Join before reading buffer.
    let _ = reader_handle.join();
    drop(writer);
    drop(_master);

    let injected = injected_flag.load(Ordering::Relaxed);
    let challenge_detected = challenge_flag.load(Ordering::Relaxed);
    let raw = captured
        .lock()
        .map(|c| String::from_utf8_lossy(&c).into_owned())
        .unwrap_or_default();
    let stdout = if injected {
        strip_injected_prompt(&raw)
    } else {
        raw
    };
    Ok(CommandOutput {
        stdout,
        exit_code,
        timed_out,
        challenge_detected,
        injected,
        stderr: String::new(), // PTY merges stderr into stdout; kept for API parity.
    })
}

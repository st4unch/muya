//! Deterministic SSH/SCP password injection via `SSH_ASKPASS` (replaces the racy
//! PTY-prompt-matching in `pty::run_with_injection` for the broker's ssh_run/ssh_scp).
//!
//! WHY (operator-confirmed against a real CyberArk PSMP, 2026-08-05): PTY-prompt
//! matching races the chunked "Vault Password:" keyboard-interactive challenge —
//! scp missed it (timeout) or caught it wrong (exit 255); ssh_run hit it ~1/3.
//! `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` (OpenSSH 8.4+; macOS ships 9/10) makes
//! ssh/scp fetch the password from a helper — no prompt timing, no PTY, no race.
//! Empirically verified against a live sshd on this macOS (OpenSSH 10.2p1).
//!
//! SECRET HANDOFF (no plaintext on disk): the secret is streamed to the helper over a
//! private 0600 **named pipe (FIFO)** — the FIFO node exists in a 0700 tempdir but the
//! secret itself only ever passes through the kernel pipe buffer, never a disk file.
//! A writer thread feeds the secret whenever the helper opens the FIFO; the helper
//! reads exactly ONE line, so a redundant write can never corrupt the password. The
//! secret is NEVER in the child's argv, env, `ps`/proc, logs, or on disk.
//!
//! AC6 PRESERVED: SSH_ASKPASS passes the prompt TEXT as argv[1]. For PSMP the helper
//! inspects it and REFUSES (exit 1, marker touched) a 2FA/OTP/passcode challenge, so
//! the password is never sent into an OTP field (account-lockout protection).

use std::ffi::CString;
use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use crate::pty::CommandOutput;

const CAPTURE_CAP: usize = 256 * 1024;

/// The askpass helper. `$1` = the prompt ssh/scp is asking for. Reads the secret as
/// ONE line from the FIFO (so a redundant write can't concatenate/corrupt it) and
/// prints it WITHOUT a trailing newline (ssh strips one trailing newline anyway).
const HELPER_SCRIPT: &str = r#"#!/bin/sh
: > "$MUYA_ASKPASS_CALLED"
if [ "${MUYA_ASKPASS_PSMP:-0}" = "1" ]; then
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    *passcode*|*one-time*|*one\ time*|*otp*|*verification\ code*)
      : > "$MUYA_ASKPASS_CHALLENGE"; exit 1 ;;
  esac
fi
IFS= read -r __pw < "$MUYA_ASKPASS_FIFO"
printf '%s' "$__pw"
"#;

struct Askpass {
    _dir: tempfile::TempDir,
    script: PathBuf,
    fifo: PathBuf,
    called: PathBuf,
    challenge: PathBuf,
}

fn setup_askpass() -> Result<Askpass, String> {
    let dir = tempfile::Builder::new()
        .prefix("muya-askpass-")
        .tempdir()
        .map_err(|e| format!("askpass tempdir: {e}"))?;
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("askpass tempdir perms: {e}"))?;
    let fifo = dir.path().join("p");
    let c = CString::new(fifo.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
    // SAFETY: `c` is a valid NUL-terminated path in a dir we just created 0700.
    if unsafe { libc::mkfifo(c.as_ptr(), 0o600) } != 0 {
        return Err(format!("mkfifo: {}", std::io::Error::last_os_error()));
    }
    let script = dir.path().join("askpass");
    {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o700)
            .open(&script)
            .map_err(|e| format!("askpass script: {e}"))?;
        f.write_all(HELPER_SCRIPT.as_bytes())
            .map_err(|e| format!("askpass script write: {e}"))?;
    }
    Ok(Askpass {
        script,
        fifo,
        called: dir.path().join("called"),
        challenge: dir.path().join("challenge"),
        _dir: dir,
    })
}

/// Feed the secret into the FIFO on demand until `stop` is set. Opening the write end
/// non-blocking returns ENXIO while no reader (the helper) is attached; once the
/// helper opens the FIFO for reading, the open succeeds and we write `secret\n`.
fn fifo_writer(fifo: &Path, secret: Zeroizing<String>, stop: &AtomicBool) {
    let mut payload = secret.as_bytes().to_vec();
    payload.push(b'\n');
    while !stop.load(Ordering::Relaxed) {
        match std::fs::OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(fifo)
        {
            // A reader is attached → hand it the secret. Errors (e.g. the helper
            // already read its one line and closed → EPIPE) are ignored: the helper
            // takes only the FIRST line, so this can never corrupt the password.
            Ok(mut f) => {
                let _ = f.write_all(&payload);
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(_) => std::thread::sleep(Duration::from_millis(15)),
        }
    }
    payload.iter_mut().for_each(|b| *b = 0); // best-effort wipe of the copy
}

/// Run `program args`, answering the SSH password prompt deterministically via
/// SSH_ASKPASS when `secret` is `Some`. Mirrors `pty::run_with_injection`'s
/// `CommandOutput` contract. `secret = None` runs the command plainly. No PTY, no race.
pub fn run_with_askpass(
    program: &str,
    args: &[String],
    secret: Option<Zeroizing<String>>,
    timeout: Duration,
    is_psmp: bool,
) -> Result<CommandOutput, String> {
    let ap = match secret {
        Some(_) => Some(setup_askpass()?),
        None => None,
    };

    // Start feeding the FIFO before spawning the child so the secret is ready the
    // instant ssh/scp calls the helper.
    let stop = Arc::new(AtomicBool::new(false));
    let writer = match (&ap, secret) {
        (Some(ap), Some(sec)) => {
            let fifo = ap.fifo.clone();
            let stop_c = Arc::clone(&stop);
            Some(std::thread::spawn(move || fifo_writer(&fifo, sec, &stop_c)))
        }
        _ => None,
    };

    let mut cmd = Command::new(program);
    cmd.args(args)
        .env("TERM", "xterm-256color")
        // No controlling TTY: askpass is used precisely so no PTY/prompt is needed.
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        // Capture stderr so a failed ssh/scp surfaces its REAL error (auth/PSMP DLP/
        // protocol message) instead of a bare exit code. Never holds the password.
        .stderr(Stdio::piped());
    if let Some(ap) = &ap {
        cmd.env("SSH_ASKPASS", &ap.script)
            .env("SSH_ASKPASS_REQUIRE", "force")
            // Some OpenSSH builds still gate askpass on DISPLAY even with
            // REQUIRE=force; a dummy value is harmless and covers that.
            .env("DISPLAY", ":0")
            .env("MUYA_ASKPASS_FIFO", &ap.fifo)
            .env("MUYA_ASKPASS_CALLED", &ap.called)
            .env("MUYA_ASKPASS_CHALLENGE", &ap.challenge)
            .env("MUYA_ASKPASS_PSMP", if is_psmp { "1" } else { "0" });
    }
    for (k, _) in std::env::vars() {
        if k.starts_with("CLAUDE") || k == "AI_AGENT" {
            cmd.env_remove(&k);
        }
    }

    let child = cmd.spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => {
            stop.store(true, Ordering::Relaxed);
            if let Some(w) = writer {
                let _ = w.join();
            }
            return Err(format!("spawn {program}: {e}"));
        }
    };

    // Drain stdout on a thread into a BOUNDED buffer (no pipe deadlock / memory growth).
    let captured = Arc::new(Mutex::new(Vec::<u8>::new()));
    let reader_handle = child.stdout.take().map(|mut out| {
        let cap = Arc::clone(&captured);
        std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match out.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if let Ok(mut c) = cap.lock() {
                            if c.len() < CAPTURE_CAP {
                                let room = CAPTURE_CAP - c.len();
                                c.extend_from_slice(&buf[..room.min(n)]);
                            }
                        }
                    }
                }
            }
        })
    });

    // Same bounded drain for stderr (the real error on a failed transfer).
    let captured_err = Arc::new(Mutex::new(Vec::<u8>::new()));
    let err_handle = child.stderr.take().map(|mut err| {
        let cap = Arc::clone(&captured_err);
        std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match err.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if let Ok(mut c) = cap.lock() {
                            if c.len() < CAPTURE_CAP {
                                let room = CAPTURE_CAP - c.len();
                                c.extend_from_slice(&buf[..room.min(n)]);
                            }
                        }
                    }
                }
            }
        })
    });

    let deadline = Instant::now() + timeout;
    let mut exit_code = None;
    let mut timed_out = false;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                exit_code = status.code();
                break;
            }
            Ok(None) => {
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

    // Stop the FIFO writer. If it's parked in a blocking spot, a self-open unblocks it;
    // with O_NONBLOCK it just falls through on the next loop check.
    stop.store(true, Ordering::Relaxed);
    if let Some(ap) = &ap {
        let _ = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&ap.fifo);
    }
    if let Some(w) = writer {
        let _ = w.join();
    }
    if let Some(h) = reader_handle {
        let _ = h.join();
    }
    if let Some(h) = err_handle {
        let _ = h.join();
    }

    let challenge_detected = ap.as_ref().map(|a| a.challenge.exists()).unwrap_or(false);
    let injected = ap.as_ref().map(|a| a.called.exists()).unwrap_or(false) && !challenge_detected;
    let stdout = captured
        .lock()
        .map(|c| String::from_utf8_lossy(&c).into_owned())
        .unwrap_or_default();
    let stderr = captured_err
        .lock()
        .map(|c| String::from_utf8_lossy(&c).into_owned())
        .unwrap_or_default();

    // `ap` (the TempDir, incl. the FIFO node) is unlinked here on Drop.
    Ok(CommandOutput {
        stdout,
        exit_code,
        timed_out,
        challenge_detected,
        injected,
        stderr,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // A prompt-answering run against `cat` isn't meaningful; use the full path with a
    // trivial child (`true`) to exercise setup/writer/cleanup, and a live ssh test for
    // real auth. Challenge refusal is verified at the helper-script level (it exits
    // before ever touching the FIFO).
    fn run_helper(prompt: &str, psmp: &str) -> (bool, String, bool) {
        let d = tempfile::tempdir().unwrap();
        let script = d.path().join("askpass");
        std::fs::write(&script, HELPER_SCRIPT).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
        // Feed the FIFO from a thread so the helper's read completes.
        let fifo = d.path().join("p");
        let c = CString::new(fifo.as_os_str().as_bytes()).unwrap();
        unsafe { libc::mkfifo(c.as_ptr(), 0o600) };
        let stop = Arc::new(AtomicBool::new(false));
        let fifo_c = fifo.clone();
        let stop_c = Arc::clone(&stop);
        let w = std::thread::spawn(move || {
            fifo_writer(&fifo_c, Zeroizing::new("Sup3rSecret!".to_string()), &stop_c)
        });
        let out = Command::new(&script)
            .arg(prompt)
            .env("MUYA_ASKPASS_FIFO", &fifo)
            .env("MUYA_ASKPASS_CALLED", d.path().join("called"))
            .env("MUYA_ASKPASS_CHALLENGE", d.path().join("chal"))
            .env("MUYA_ASKPASS_PSMP", psmp)
            .output()
            .unwrap();
        stop.store(true, Ordering::Relaxed);
        let _ = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&fifo);
        let _ = w.join();
        (
            out.status.success(),
            String::from_utf8_lossy(&out.stdout).into_owned(),
            d.path().join("chal").exists(),
        )
    }

    #[test]
    fn helper_returns_secret_for_password_prompt() {
        let (ok, sout, chal) = run_helper("Vault Password:", "1");
        assert!(ok);
        assert_eq!(sout, "Sup3rSecret!");
        assert!(!chal);
    }

    #[test]
    fn helper_refuses_psmp_otp_challenge() {
        for prompt in ["Enter your passcode:", "One-time code:", "OTP:"] {
            let (ok, sout, chal) = run_helper(prompt, "1");
            assert!(!ok, "{prompt} must be refused");
            assert!(sout.is_empty(), "{prompt} must not leak the secret");
            assert!(chal, "{prompt} must mark challenge");
        }
    }

    #[test]
    fn helper_direct_does_not_refuse_passcode() {
        let (ok, sout, _) = run_helper("passcode:", "0");
        assert!(ok);
        assert_eq!(sout, "Sup3rSecret!");
    }

    #[test]
    fn cleanup_leaves_no_askpass_tempdir() {
        let out = run_with_askpass(
            "true",
            &[],
            Some(Zeroizing::new("s3cr3t".to_string())),
            Duration::from_secs(5),
            false,
        )
        .unwrap();
        assert_eq!(out.exit_code, Some(0));
        let leftover = std::fs::read_dir(std::env::temp_dir())
            .unwrap()
            .filter_map(|e| e.ok())
            .any(|e| e.file_name().to_string_lossy().starts_with("muya-askpass-"));
        assert!(!leftover, "askpass tempdir must be cleaned up");
    }

    // LIVE determinism (Docker `muya-ssh-test`, testuser/Sup3rSecret!@127.0.0.1:2222).
    //   cargo test --lib askpass_ssh_run_live -- --ignored --nocapture
    #[test]
    #[ignore = "needs the muya-ssh-test docker container"]
    fn askpass_ssh_run_live() {
        let args: Vec<String> = [
            "-o",
            "PubkeyAuthentication=no",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "LogLevel=ERROR",
            "-p",
            "2222",
            "testuser@127.0.0.1",
            "echo MUYA_ASKPASS_OK",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        for i in 0..15 {
            let out = run_with_askpass(
                "ssh",
                &args,
                Some(Zeroizing::new("Sup3rSecret!".to_string())),
                Duration::from_secs(30),
                false,
            )
            .unwrap();
            assert_eq!(out.exit_code, Some(0), "run {i}: exit {:?}", out.exit_code);
            assert!(!out.timed_out, "run {i}: timed out");
            assert!(out.injected, "run {i}: helper not called");
            assert!(
                out.stdout.contains("MUYA_ASKPASS_OK"),
                "run {i}: stdout={:?}",
                out.stdout
            );
        }
        println!("askpass_ssh_run_live: 15/15 deterministic auth via SSH_ASKPASS (FIFO)");
    }
}

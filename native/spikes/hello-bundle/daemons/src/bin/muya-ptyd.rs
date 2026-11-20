//! Stub `muya-ptyd`: accepts only `muyad`, owns PTY sessions and refuses peers inside them.
//!
//! Requests: `hello`, `sessions` (session ids it owns), `probe <socket>` (runs
//! `muyad --probe <socket>` inside a new PTY session and returns what it printed).

use hello_daemons::*;
use std::io::{Read, Write};
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

type Sessions = Arc<Mutex<Vec<i32>>>;

fn main() {
    let started = Instant::now();
    let listener = match listen("ptyd") {
        Ok(l) => l,
        Err(e) => {
            log("ptyd", &format!("cannot listen: {e}"));
            std::process::exit(1);
        }
    };
    log(
        "ptyd",
        &format!(
            "listening after {} us, team={:?}",
            started.elapsed().as_micros(),
            own_team()
        ),
    );
    let sessions: Sessions = Arc::default();
    for stream in listener.incoming().flatten() {
        let sessions = sessions.clone();
        std::thread::spawn(move || handle(stream, sessions));
    }
}

fn handle(mut stream: UnixStream, sessions: Sessions) {
    let sids = sessions.lock().unwrap().clone();
    let peer = match verify_peer(&stream, MUYAD_ID, Some(&sids)) {
        Ok(p) => p,
        Err(why) => {
            log("ptyd", &format!("refused: {why}"));
            let _ = writeln!(stream, "refused: {why}");
            return;
        }
    };
    serve_lines(&mut stream, |line| match line.split_once(' ').unwrap_or((line, "")) {
        ("ping", _) => "pong".to_owned(),
        ("hello", _) => format!(
            r#"{{"who":"ptyd","version":"{VERSION}","pid":{},"peer_pid":{},"peer_check_us":{},"peak_rss_kb":{}}}"#,
            std::process::id(),
            peer.pid,
            peer.check_us,
            peak_rss_kb()
        ),
        ("sessions", _) => format!("{:?}", sessions.lock().unwrap()),
        ("probe", target) => probe(target, &sessions),
        ("envprobe", _) => env_probe(&sessions),
        _ => "error: unknown request".to_owned(),
    });
}

/// Starts `muyad --probe <target>` as the leader of a new PTY session, like a shell would be.
fn probe(target: &str, sessions: &Sessions) -> String {
    let muyad = match std::env::current_exe() {
        Ok(p) => p.with_file_name("muyad"),
        Err(e) => return format!("error: {e}"),
    };
    let mut cmd = Command::new(muyad);
    cmd.args(["--probe", target]);
    run_in_session(cmd, sessions, 10)
}

/// S5: what a session shell sees when ptyd (a LaunchAgent) starts it — the user's login shell,
/// interactive like Terminal.app, reporting PATH and whether `claude` resolves and runs.
fn env_probe(sessions: &Sessions) -> String {
    let shell = unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if pw.is_null() { "/bin/zsh".to_owned() } else { std::ffi::CStr::from_ptr((*pw).pw_shell).to_string_lossy().into_owned() }
    };
    let script = r#"printf '\n@@PATH=%s\n@@SHELL=%s\n@@HOME=%s\n@@LANG=%s\n@@TERM=%s\n' "$PATH" "$SHELL" "$HOME" "$LANG" "$TERM"; printf '@@CLAUDE=%s\n' "$(command -v claude)"; printf '@@VERSION=%s\n' "$(claude --version 2>&1 | head -1)"; exit"#;
    let mut cmd = Command::new(&shell);
    cmd.args(["-l", "-i", "-c", script]).env_clear().env("HOME", std::env::var("HOME").unwrap_or_default())
        .env("USER", std::env::var("USER").unwrap_or_default()).env("SHELL", &shell).env("TERM", "xterm-256color")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    let out = run_in_session(cmd, sessions, 20);
    // Interactive shells may print escape sequences in front of a line; find the marker anywhere.
    out.split(['\r', '\n']).filter_map(|l| l.find("@@").map(|i| &l[i + 2..])).collect::<Vec<_>>().join(" | ")
}

/// Runs `cmd` as the leader of a new PTY session and returns what it printed.
fn run_in_session(mut cmd: Command, sessions: &Sessions, timeout_s: u64) -> String {
    let (mut master, slave) = match open_pty() {
        Ok(p) => p,
        Err(e) => return format!("error: openpty: {e}"),
    };
    cmd.stdin(Stdio::from(slave.try_clone().unwrap()))
        .stdout(Stdio::from(slave.try_clone().unwrap()))
        .stderr(Stdio::from(slave));
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 || libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return format!("error: spawn: {e}"),
    };
    let sid = child.id() as i32; // setsid makes the child its own session leader
    sessions.lock().unwrap().push(sid);
    drop(cmd); // closes our copies of the slave so EOF/EIO arrives when the child exits
    let deadline = Instant::now() + Duration::from_secs(timeout_s);
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    while Instant::now() < deadline {
        match master.read(&mut buf) {
            Ok(0) | Err(_) => break, // EIO once the child side is closed
            Ok(n) => out.extend_from_slice(&buf[..n]),
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    sessions.lock().unwrap().retain(|s| *s != sid);
    format!("session {sid}: {}", String::from_utf8_lossy(&out).trim())
}

fn open_pty() -> std::io::Result<(std::fs::File, OwnedFd)> {
    let (mut master, mut slave) = (0, 0);
    let rc = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    unsafe {
        Ok((
            std::fs::File::from_raw_fd(master),
            OwnedFd::from_raw_fd(slave),
        ))
    }
}

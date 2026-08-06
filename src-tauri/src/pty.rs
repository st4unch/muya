//! Real interactive terminals backed by a PTY (pseudo-terminal). Each spawn opens
//! a login shell via the `portable-pty` crate (wezterm). Output streams to the
//! frontend over a Tauri `Channel`; xterm.js renders it. Input flows back through
//! `pty_write`. This is the hand-rolled alternative to `tauri-plugin-pty` chosen
//! for dependency stability (PRD §15.5 D-pty).

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use tauri::ipc::{Channel, InvokeResponseBody};
use tauri::State;
use zeroize::Zeroizing;

// Output is streamed to the frontend over the channel as two message shapes:
//   - data: an `InvokeResponseBody::Raw` (bytes). Batches ≥1KB travel Tauri's
//     binary fetch path (no JSON), reaching JS as an ArrayBuffer → xterm.write.
//     Sending raw (not a `{type,bytes}` JSON enum) avoids ~4x byte-array JSON
//     bloat that, under a high-output flood, saturates the webview message pump
//     and delays the user's own keystroke echo. See src/perf/harness.ts.
//   - exit: a tiny JSON `{"type":"exit"}` object.
// The frontend discriminates by `msg instanceof ArrayBuffer`.
fn exit_event() -> InvokeResponseBody {
    InvokeResponseBody::Json("{\"type\":\"exit\"}".to_string())
}

struct PtyHandle {
    // Shared with the reader thread so a password can be injected into the PTY
    // (SSH auth) without the secret ever crossing into JS. `pty_write` locks it
    // for user keystrokes; the injector locks it once for the password.
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn portable_pty::Child + Send + Sync>,
}

#[derive(Default)]
pub struct PtyManager {
    sessions: Mutex<HashMap<String, PtyHandle>>,
    counter: AtomicU64,
}

fn default_shell() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string())
}

/// True when the output tail ends in an interactive password/passcode prompt —
/// the trigger for one-shot SSH password injection. Matched case-insensitively on
/// the trailing text (trimmed) so `Password:`, `user@host's password:` and RADIUS
/// `Passcode:` all fire, while incidental mentions mid-line (which have more text
/// after them) do not.
fn looks_like_password_prompt(tail: &str) -> bool {
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
fn looks_like_challenge_prompt(tail: &str) -> bool {
    let t = tail.trim_end().to_lowercase();
    t.ends_with("passcode:")
        || t.ends_with("verification code:")
        || t.ends_with("one-time")
        || t.ends_with("otp:")
}

/// Spawn a login shell in a PTY. Returns the session id used by the other commands.
#[tauri::command]
pub fn pty_spawn(
    state: State<PtyManager>,
    on_event: Channel<InvokeResponseBody>,
    cwd: Option<String>,
    shell: Option<String>,
    cols: Option<u16>,
    rows: Option<u16>,
) -> Result<String, String> {
    let shell = shell.unwrap_or_else(default_shell);
    // Login shell so the user's full PATH (incl. ~/.local/bin) is available — `claude`
    // resolves inside the terminal. macOS GUI apps otherwise inherit a minimal PATH.
    spawn_process(
        &state,
        on_event,
        &shell,
        &["-l".to_string()],
        cwd.as_deref(),
        cols,
        rows,
        None,
    )
}

/// Spawn `program` with `args` in a PTY, streaming output to `on_event`. When
/// `inject_secret` is Some, a reader-side watcher writes it into the PTY the first
/// time a password/passcode prompt appears — used for SSH password auth so the
/// secret is handled entirely in Rust and never reaches the JS/webview layer.
/// Returns the session id used by `pty_write`/`pty_resize`/`pty_kill`.
#[allow(clippy::too_many_arguments)]
pub fn spawn_process(
    manager: &PtyManager,
    on_event: Channel<InvokeResponseBody>,
    program: &str,
    args: &[String],
    cwd: Option<&str>,
    cols: Option<u16>,
    rows: Option<u16>,
    inject_secret: Option<Zeroizing<String>>,
) -> Result<String, String> {
    let pty_system = native_pty_system();
    let size = PtySize {
        rows: rows.unwrap_or(24),
        cols: cols.unwrap_or(80),
        pixel_width: 0,
        pixel_height: 0,
    };
    let pair = pty_system
        .openpty(size)
        .map_err(|e| format!("openpty failed: {e}"))?;

    let mut cmd = CommandBuilder::new(program);
    for a in args {
        cmd.arg(a);
    }
    cmd.env("TERM", "xterm-256color");
    // The control plane may itself be launched from inside a Claude Code session
    // (notably during dev), which leaks CLAUDE* env vars. Those mark the new process
    // as a *child* session and disable session persistence — so a `claude` started in
    // this terminal can't be backgrounded ("nothing to resume"). Strip them so every
    // spawned shell/`claude` runs as a clean, persistable, top-level session.
    for (k, _) in std::env::vars() {
        if k.starts_with("CLAUDE") || k == "AI_AGENT" {
            cmd.env_remove(&k);
        }
    }
    if let Some(dir) = cwd.filter(|d| !d.is_empty()) {
        cmd.cwd(dir);
    }

    let child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|e| format!("spawn failed: {e}"))?;
    // Drop the slave so the master gets EOF when the child exits.
    drop(pair.slave);

    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| format!("clone reader failed: {e}"))?;
    let writer = Arc::new(Mutex::new(
        pair.master
            .take_writer()
            .map_err(|e| format!("take writer failed: {e}"))?,
    ));

    let id = format!("pty-{}", manager.counter.fetch_add(1, Ordering::Relaxed));

    // Password injection: give the reader thread a writer handle + the secret. It
    // fires exactly once, when the output tail looks like a password prompt.
    let inject = inject_secret.map(|s| (Arc::clone(&writer), s));

    // Output is delivered in two stages to keep a high-output terminal (e.g. a
    // `claude` TUI redrawing, or a runaway `yes`) from (a) saturating the webview's
    // single-threaded native→JS message pump — which delays the user's own
    // keystroke echo (~400ms, measured; see src/perf/harness.ts) — and (b) growing
    // memory without bound. Both come from the same root: nothing throttles a
    // producer that outpaces the webview consumer.
    //
    // Stage 1 — reader thread: blocking reads push raw chunks into a BOUNDED queue.
    // When the consumer lags, `tx.send` blocks → the reader stops draining the PTY
    // → the OS PTY buffer fills → the child's write() blocks. That backpressure is
    // what bounds memory and throttles a runaway producer.
    let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(256); // ≤256×8KB ≈ 2MB buffered
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        let mut injected = false;
        let mut tail = String::new();
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    // Watch the output tail for a password prompt, then inject once.
                    if let (false, Some((w, secret))) = (injected, inject.as_ref()) {
                        tail.push_str(&String::from_utf8_lossy(&buf[..n]));
                        if tail.len() > 512 {
                            let cut = tail.len() - 512;
                            tail.drain(..cut);
                        }
                        if looks_like_password_prompt(&tail) {
                            if let Ok(mut wl) = w.lock() {
                                let _ = wl.write_all(secret.as_bytes());
                                let _ = wl.write_all(b"\n");
                                let _ = wl.flush();
                            }
                            injected = true;
                        }
                    }
                    if tx.send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        // Dropping `tx` signals EOF to the coalescer below.
    });

    // Stage 2 — coalescer: drain the queue into one Channel event, then pace. A lone
    // keystroke echo flushes immediately (the pause is AFTER the send, so it adds no
    // echo latency); a sustained stream coalesces up to MAX_BATCH and is capped at
    // ~MAX_BATCH/FLUSH ≈ 16 MB/s of events. The pacing is what makes the bounded
    // queue above fill and apply backpressure — without it the consumer would never
    // signal "slow down" and memory/event-rate would run away.
    let ch = on_event.clone();
    std::thread::spawn(move || {
        const MAX_BATCH: usize = 128 * 1024;
        const FLUSH: Duration = Duration::from_millis(8);
        while let Ok(first) = rx.recv() {
            let mut batch = first;
            loop {
                if batch.len() >= MAX_BATCH {
                    break;
                }
                match rx.try_recv() {
                    Ok(more) => batch.extend_from_slice(&more),
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        let _ = ch.send(InvokeResponseBody::Raw(batch));
                        let _ = ch.send(exit_event());
                        return;
                    }
                }
            }
            if ch.send(InvokeResponseBody::Raw(batch)).is_err() {
                return;
            }
            std::thread::sleep(FLUSH);
        }
        let _ = ch.send(exit_event());
    });

    manager.sessions.lock().unwrap().insert(
        id.clone(),
        PtyHandle {
            writer,
            master: pair.master,
            child,
        },
    );
    Ok(id)
}

// ---------------------------------------------------------------------------
// One-shot capture-with-injection (SSH Agent Broker, Faz 2 — AC8/AC9)
// ---------------------------------------------------------------------------

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
const CAPTURE_CAP: usize = 256 * 1024;

/// Remove the password-prompt line (and any trailing CR/LF/space) from captured
/// output so the returned stdout starts at the remote command's own output. The
/// prompt is always the FIRST `password:`/`passcode:` occurrence (it precedes any
/// remote output), so matching the first hit is correct. The password itself is
/// never echoed by ssh, so it never appears here — this only hides the prompt text.
fn strip_injected_prompt(raw: &str) -> String {
    let lower = raw.to_lowercase();
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
                        if tail.len() > 512 {
                            let cut = tail.len() - 512;
                            tail.drain(..cut);
                        }
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

/// Write user input (keystrokes) to a PTY.
#[tauri::command]
pub fn pty_write(state: State<PtyManager>, id: String, data: String) -> Result<(), String> {
    let sessions = state.sessions.lock().unwrap();
    let h = sessions.get(&id).ok_or_else(|| format!("no pty {id}"))?;
    let mut w = h.writer.lock().map_err(|_| "writer poisoned".to_string())?;
    w.write_all(data.as_bytes())
        .map_err(|e| format!("write failed: {e}"))?;
    w.flush().map_err(|e| format!("flush failed: {e}"))
}

/// Resize a PTY when the xterm viewport changes.
#[tauri::command]
pub fn pty_resize(
    state: State<PtyManager>,
    id: String,
    cols: u16,
    rows: u16,
) -> Result<(), String> {
    let sessions = state.sessions.lock().unwrap();
    let h = sessions.get(&id).ok_or_else(|| format!("no pty {id}"))?;
    h.master
        .resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| format!("resize failed: {e}"))
}

/// Kill every active PTY session. Called before process exit so no shells are orphaned.
pub fn kill_all(manager: &PtyManager) {
    if let Ok(mut sessions) = manager.sessions.lock() {
        for (_, mut h) in sessions.drain() {
            let _ = h.child.kill();
        }
    }
}

/// Kill a PTY's child process and forget the session.
#[tauri::command]
pub fn pty_kill(state: State<PtyManager>, id: String) -> Result<(), String> {
    let mut sessions = state.sessions.lock().unwrap();
    if let Some(mut h) = sessions.remove(&id) {
        let _ = h.child.kill();
    }
    Ok(())
}

/// Parse `lsof -Fpn` output into (pid → cwd). The format is a record stream:
/// `p<pid>` starts a process block, `n<path>` gives a path within it. We asked
/// for `-d cwd` so the only path per block is that process's working directory.
fn parse_lsof_cwds(out: &str) -> HashMap<u32, String> {
    let mut map = HashMap::new();
    let mut cur: Option<u32> = None;
    for line in out.lines() {
        let (tag, rest) = match line.split_at_checked(1) {
            Some(v) => v,
            None => continue,
        };
        match tag {
            "p" => cur = rest.trim().parse::<u32>().ok(),
            "n" => {
                if let Some(pid) = cur {
                    // First path wins; -d cwd yields exactly one per process.
                    map.entry(pid).or_insert_with(|| rest.trim().to_string());
                }
            }
            _ => {}
        }
    }
    map
}

/// Live working directory of each requested PTY's shell.
///
/// The list shows where a terminal *currently* is, not where it was spawned — so
/// this reads each shell process's actual cwd. All pids go into ONE `lsof` call,
/// so cost is constant regardless of how many terminals are open (polling one
/// process per terminal would spawn N subprocesses per tick).
///
/// Ids with no live process, or whose cwd can't be read, are simply omitted.
#[tauri::command(async)]
pub fn pty_cwds(
    state: State<PtyManager>,
    ids: Vec<String>,
) -> Result<HashMap<String, String>, String> {
    // id → pid for the requested, still-running sessions.
    let id_pids: Vec<(String, u32)> = {
        let sessions = state.sessions.lock().unwrap();
        ids.iter()
            .filter_map(|id| {
                sessions
                    .get(id)
                    .and_then(|h| h.child.process_id().map(|p| (id.clone(), p)))
            })
            .collect()
    };
    if id_pids.is_empty() {
        return Ok(HashMap::new());
    }

    let pid_csv = id_pids
        .iter()
        .map(|(_, p)| p.to_string())
        .collect::<Vec<_>>()
        .join(",");

    let output = std::process::Command::new("/usr/sbin/lsof")
        .args(["-a", "-p", &pid_csv, "-d", "cwd", "-Fpn"])
        .output()
        .map_err(|e| format!("lsof failed: {e}"))?;
    // lsof exits non-zero when *some* pids are gone; parse whatever it produced.
    let by_pid = parse_lsof_cwds(&String::from_utf8_lossy(&output.stdout));

    Ok(id_pids
        .into_iter()
        .filter_map(|(id, pid)| by_pid.get(&pid).map(|cwd| (id, cwd.clone())))
        .collect())
}

/// Parse `ps -Ao pid=,ppid=` into a child→parent map.
fn parse_ppid_map(out: &str) -> HashMap<u32, u32> {
    let mut map = HashMap::new();
    for line in out.lines() {
        let mut it = line.split_whitespace();
        if let (Some(pid), Some(ppid)) = (it.next(), it.next()) {
            if let (Ok(p), Ok(pp)) = (pid.parse::<u32>(), ppid.parse::<u32>()) {
                map.insert(p, pp);
            }
        }
    }
    map
}

/// Walk up from `pid` and return the first ancestor present in `roots`.
/// Bounded so a cycle or a very deep tree can't spin forever.
fn owning_root(pid: u32, roots: &HashMap<u32, String>, ppid: &HashMap<u32, u32>) -> Option<String> {
    let mut cur = pid;
    for _ in 0..64 {
        if let Some(owner) = roots.get(&cur) {
            return Some(owner.clone());
        }
        match ppid.get(&cur) {
            Some(&parent) if parent != cur && parent != 0 => cur = parent,
            _ => break,
        }
    }
    None
}

/// Identity of the Claude session running inside a tab.
#[derive(serde::Serialize)]
pub struct TabSession {
    /// Session id — what `claude --resume <id>` needs.
    pub id: String,
    /// The session's own name (e.g. a `/rename`d "muya-all"), so the tab label can
    /// match what Claude calls itself instead of just the folder name.
    pub name: String,
    /// Mapped status ("working" | "waiting-for-input" | "idle" | "stopped") — lets
    /// the UI flag a tab whose session is paused waiting for the operator.
    pub status: String,
}

/// Map each requested PTY to the Claude session running **inside that tab**.
///
/// A tab must resume ITS OWN prior conversation, not merely the newest session in
/// the same folder (two tabs can share a folder). We therefore resolve identity by
/// process ancestry: `claude agents --json` reports each live session with its pid;
/// whichever session's process descends from a tab's shell belongs to that tab.
/// The frontend persists the result so the tab can `--resume` exactly it later.
#[tauri::command(async)]
pub async fn pty_session_ids(
    state: State<'_, PtyManager>,
    ids: Vec<String>,
) -> Result<HashMap<String, TabSession>, String> {
    // Read the (in-memory) shell pid → tab id map under the lock first…
    let roots: HashMap<u32, String> = {
        let sessions = state.sessions.lock().unwrap();
        ids.iter()
            .filter_map(|id| {
                sessions
                    .get(id)
                    .and_then(|h| h.child.process_id())
                    .map(|p| (p, id.clone()))
            })
            .collect()
    };
    if roots.is_empty() {
        return Ok(HashMap::new());
    }
    // …then offload the two subprocesses (`ps` + `claude agents --json`) to the
    // blocking pool. This command is polled every few seconds; running its
    // subprocesses on a tokio WORKER thread starved the pool shared with fs
    // commands and stalled file listing for ~10s (L31).
    tokio::task::spawn_blocking(move || pty_session_ids_blocking(roots))
        .await
        .map_err(|e| format!("session-ids task join failed: {e}"))?
}

fn pty_session_ids_blocking(
    roots: HashMap<u32, String>,
) -> Result<HashMap<String, TabSession>, String> {
    let ps = std::process::Command::new("/bin/ps")
        .args(["-Ao", "pid=,ppid="])
        .output()
        .map_err(|e| format!("ps failed: {e}"))?;
    let ppid = parse_ppid_map(&String::from_utf8_lossy(&ps.stdout));

    // Live Claude sessions carry the session id we want to resume later.
    let agents = crate::agents::list_agent_sessions_sync(Some(true)).unwrap_or_default();

    let mut out = HashMap::new();
    for a in agents {
        let (Some(pid), false) = (a.pid, a.id.is_empty()) else {
            continue;
        };
        if pid <= 0 {
            continue;
        }
        if let Some(tab) = owning_root(pid as u32, &roots, &ppid) {
            out.insert(
                tab,
                TabSession {
                    id: a.id.clone(),
                    name: a.name.clone(),
                    status: a.status.clone(),
                },
            );
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {

    #[test]
    fn parse_ppid_map_reads_pid_parent_pairs() {
        let m = super::parse_ppid_map("  100  1\n  201  100\n 302   201\nbogus\n");
        assert_eq!(m.get(&201), Some(&100));
        assert_eq!(m.get(&302), Some(&201));
        assert_eq!(m.len(), 3);
    }

    #[test]
    fn owning_root_finds_the_tab_that_owns_a_descendant() {
        // shell 100 (tab A) → zsh 201 → claude 302
        let mut roots = std::collections::HashMap::new();
        roots.insert(100u32, "pty-A".to_string());
        let ppid = super::parse_ppid_map("100 1\n201 100\n302 201\n900 1\n");
        assert_eq!(
            super::owning_root(302, &roots, &ppid).as_deref(),
            Some("pty-A")
        );
        // An unrelated process must not be attributed to the tab.
        assert_eq!(super::owning_root(900, &roots, &ppid), None);
    }

    #[test]
    fn owning_root_terminates_on_cycles() {
        let mut roots = std::collections::HashMap::new();
        roots.insert(1u32, "pty-Z".to_string());
        // 5 → 6 → 5 cycle, never reaching a root: must return, not hang.
        let ppid = super::parse_ppid_map("5 6\n6 5\n");
        assert_eq!(super::owning_root(5, &roots, &ppid), None);
    }

    #[test]
    fn parse_lsof_cwds_maps_each_pid_to_its_cwd() {
        // Real `lsof -Fpn -d cwd` shape: p<pid> block header, n<path> record.
        let out = "p101\nfcwd\nn/Users/me/projects/alpha\np202\nfcwd\nn/tmp/beta\n";
        let map = super::parse_lsof_cwds(out);
        assert_eq!(
            map.get(&101).map(String::as_str),
            Some("/Users/me/projects/alpha")
        );
        assert_eq!(map.get(&202).map(String::as_str), Some("/tmp/beta"));
        assert_eq!(map.len(), 2);
    }

    #[test]
    fn parse_lsof_cwds_tolerates_empty_and_garbage() {
        assert!(super::parse_lsof_cwds("").is_empty());
        // A path with no preceding pid header must not panic or be attributed.
        assert!(super::parse_lsof_cwds("n/orphan/path\n").is_empty());
    }

    // Password-injection trigger: real ssh prompt shapes fire; incidental
    // mid-line mentions and empty tails do not.
    #[test]
    fn password_prompt_matches_ssh_prompts() {
        assert!(super::looks_like_password_prompt(
            "oracle@10.0.0.5's password: "
        ));
        assert!(super::looks_like_password_prompt("Password:"));
        assert!(super::looks_like_password_prompt("\r\nPassword: "));
        assert!(super::looks_like_password_prompt("Passcode: ")); // RADIUS
                                                                  // Not a prompt: text continues after the word, or it's unrelated output.
        assert!(!super::looks_like_password_prompt(
            "Your password: was changed yesterday"
        ));
        assert!(!super::looks_like_password_prompt("Last login: today"));
        assert!(!super::looks_like_password_prompt(""));
    }

    // AC2 — PSMP 2FA/OTP challenge prompt shapes are recognized so the injector
    // can withhold the password instead of burning a RADIUS auth attempt on them.
    #[test]
    fn challenge_prompt_matches_2fa_shapes() {
        assert!(super::looks_like_challenge_prompt("Passcode: "));
        assert!(super::looks_like_challenge_prompt(
            "Enter verification code: "
        ));
        assert!(super::looks_like_challenge_prompt(
            "Please respond to the one-time"
        ));
        assert!(super::looks_like_challenge_prompt("OTP: "));
        assert!(super::looks_like_challenge_prompt("\r\nPasscode: "));
        // Not a challenge: unrelated text, or text continues after the marker.
        assert!(!super::looks_like_challenge_prompt("Last login: today"));
        assert!(!super::looks_like_challenge_prompt(
            "one-time offer expires soon"
        ));
        assert!(!super::looks_like_challenge_prompt(""));
    }
    use super::*;

    /// Proves the PTY layer works on this machine end to end (without the Tauri
    /// Channel): open a pty, run a command, read its output back.
    #[test]
    fn pty_echo_roundtrip() {
        let sys = native_pty_system();
        let pair = sys
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .expect("openpty");
        let mut cmd = CommandBuilder::new(default_shell());
        cmd.arg("-lc");
        cmd.arg("echo apex-pty-ok");
        let mut reader = pair.master.try_clone_reader().expect("reader");
        let mut child = pair.slave.spawn_command(cmd).expect("spawn");
        drop(pair.slave);
        // Read while the process runs (blocking reads): collect until we see the
        // marker or hit EOF. Reading only after wait() can miss the buffered output.
        let mut out = Vec::new();
        let mut buf = [0u8; 1024];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    out.extend_from_slice(&buf[..n]);
                    if String::from_utf8_lossy(&out).contains("apex-pty-ok") {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = child.wait();
        let s = String::from_utf8_lossy(&out);
        println!("pty output: {s:?}");
        assert!(
            s.contains("apex-pty-ok"),
            "expected echo output, got: {s:?}"
        );
    }

    /// END-TO-END password injection against a REAL sshd (Docker openssh-server on
    /// 127.0.0.1:2222, user `testuser`, pw `Sup3rSecret!`). Proves the reader-side
    /// injector answers ssh's password prompt so a remote command actually runs —
    /// the core "CyberArk/stored password is selected but nothing logs in" fix.
    ///
    /// Ignored by default (needs the container). Run:
    ///   docker run -d --name muya-ssh-test -e PASSWORD_ACCESS=true \
    ///     -e USER_NAME=testuser -e USER_PASSWORD='Sup3rSecret!' -p 2222:2222 \
    ///     lscr.io/linuxserver/openssh-server
    ///   cargo test pty_injection_logs_into_real_sshd -- --ignored --nocapture
    #[test]
    #[ignore]
    fn pty_injection_logs_into_real_sshd() {
        use std::sync::mpsc;
        use std::time::{Duration, Instant};

        let sys = native_pty_system();
        let pair = sys
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .expect("openpty");
        let mut cmd = CommandBuilder::new("ssh");
        for a in [
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "ConnectTimeout=10",
            "-p",
            "2222",
            "testuser@127.0.0.1",
            "echo MUYA_INJECT_OK",
        ] {
            cmd.arg(a);
        }
        let mut reader = pair.master.try_clone_reader().expect("reader");
        let writer = std::sync::Arc::new(std::sync::Mutex::new(
            pair.master.take_writer().expect("writer"),
        ));
        let mut child = pair.slave.spawn_command(cmd).expect("spawn ssh");
        drop(pair.slave);

        // Same injection shape as spawn_process: match the prompt tail, inject once.
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let w = std::sync::Arc::clone(&writer);
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            let mut injected = false;
            let mut tail = String::new();
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        if !injected {
                            tail.push_str(&String::from_utf8_lossy(&buf[..n]));
                            if tail.len() > 512 {
                                let cut = tail.len() - 512;
                                tail.drain(..cut);
                            }
                            if super::looks_like_password_prompt(&tail) {
                                let mut wl = w.lock().unwrap();
                                wl.write_all(b"Sup3rSecret!\n").unwrap();
                                wl.flush().unwrap();
                                injected = true;
                            }
                        }
                        if tx.send(buf[..n].to_vec()).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        });

        let mut out = String::new();
        let deadline = Instant::now() + Duration::from_secs(25);
        while Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(500)) {
                Ok(chunk) => {
                    out.push_str(&String::from_utf8_lossy(&chunk));
                    if out.contains("MUYA_INJECT_OK") {
                        break;
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if out.contains("MUYA_INJECT_OK") {
                        break;
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
        let _ = child.kill();
        println!("ssh session output:\n{out}");
        assert!(
            out.contains("MUYA_INJECT_OK"),
            "injected password did not log in / run the remote command; got:\n{out}"
        );
    }

    // AC9 — the injected password prompt is stripped from captured stdout, and a
    // capture with no prompt is returned unchanged. The password never appears.
    #[test]
    fn strip_injected_prompt_removes_prompt_line() {
        let raw = "\r\ntestuser@127.0.0.1's password: \r\nMUYA_RUN_OK\r\n";
        let out = super::strip_injected_prompt(raw);
        assert!(out.starts_with("MUYA_RUN_OK"), "got: {out:?}");
        assert!(!out.to_lowercase().contains("password:"), "got: {out:?}");
        // RADIUS passcode prompt shape.
        assert!(super::strip_injected_prompt("Passcode: \r\nHELLO").starts_with("HELLO"));
        // No prompt → unchanged.
        assert_eq!(super::strip_injected_prompt("plain output"), "plain output");
    }

    // AC2 — a PSMP connection that shows a 2FA/passcode CHALLENGE must never have
    // the stored secret injected into it. Uses a real PTY (no Docker/network
    // needed): `sh` prints a layered "Passcode: " prompt and then blocks on
    // `read`, so if the secret were ever written it would come back out as
    // "GOT:<secret>". `is_psmp=true` must (a) never write the secret and (b) kill
    // the child immediately rather than waiting out `timeout` — proven by the
    // short elapsed time even though `timeout` is generous.
    #[test]
    fn ac2_psmp_challenge_prompt_withholds_injection() {
        use std::time::Instant;
        use zeroize::Zeroizing;
        let args: Vec<String> = vec![
            "-c".to_string(),
            "printf 'Passcode: '; read line; echo \"GOT:$line\"".to_string(),
        ];
        let start = Instant::now();
        let out = super::run_with_injection(
            "sh",
            &args,
            Some(Zeroizing::new("mysecret".to_string())),
            Duration::from_secs(20),
            true, // PSMP
        )
        .expect("run_with_injection");
        assert!(
            out.challenge_detected,
            "expected challenge_detected, got: {out:?}"
        );
        assert!(!out.injected, "secret must NOT have been injected: {out:?}");
        assert!(
            !out.stdout.to_lowercase().contains("got:"),
            "secret leaked into child output: {:?}",
            out.stdout
        );
        assert!(
            !out.stdout.contains("mysecret"),
            "SECRET LEAKED into captured stdout: {:?}",
            out.stdout
        );
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "challenge should short-circuit immediately, not wait out the 20s timeout; \
             elapsed={:?}",
            start.elapsed()
        );
    }

    // AC4 — regression guard: the SAME "Passcode:" prompt shape on a DIRECT (non-
    // PSMP) connection still injects exactly as before the AC2 change. Challenge
    // classification is gated strictly on `is_psmp`.
    #[test]
    fn ac4_direct_still_injects_on_passcode_prompt() {
        use zeroize::Zeroizing;
        let args: Vec<String> = vec![
            "-c".to_string(),
            "printf 'Passcode: '; read line; echo \"GOT:$line\"".to_string(),
        ];
        let out = super::run_with_injection(
            "sh",
            &args,
            Some(Zeroizing::new("mysecret".to_string())),
            Duration::from_secs(20),
            false, // direct — not PSMP
        )
        .expect("run_with_injection");
        assert!(
            !out.challenge_detected,
            "direct connections must never set challenge_detected: {out:?}"
        );
        assert!(
            out.injected,
            "direct must still inject on passcode: {out:?}"
        );
        assert!(
            out.stdout.contains("GOT:mysecret"),
            "expected the secret to have reached the child as before, got: {:?}",
            out.stdout
        );
    }

    /// END-TO-END (AC8): `run_with_injection` runs a single remote command over ssh
    /// against the Docker sshd (127.0.0.1:2222, testuser / Sup3rSecret!), injecting
    /// the password at the prompt and CAPTURING stdout. Proves the non-interactive
    /// `ssh_run` path returns the remote output and never leaks the password.
    ///
    ///   docker start muya-ssh-test  # or `docker run` per the header above
    ///   cargo test run_with_injection_live -- --ignored --nocapture
    #[test]
    #[ignore]
    fn run_with_injection_live() {
        use zeroize::Zeroizing;
        let args: Vec<String> = [
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "LogLevel=ERROR",
            "-o",
            "ConnectTimeout=10",
            "-p",
            "2222",
            "testuser@127.0.0.1",
            "echo MUYA_RUN_OK",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();

        let out = super::run_with_injection(
            "ssh",
            &args,
            Some(Zeroizing::new("Sup3rSecret!".to_string())),
            Duration::from_secs(25),
            false, // direct SSH, not PSMP — no challenge gating
        )
        .expect("run_with_injection");

        println!("captured stdout: {:?}", out.stdout);
        println!("exit_code={:?} timed_out={}", out.exit_code, out.timed_out);
        assert!(
            out.stdout.contains("MUYA_RUN_OK"),
            "remote command output missing; got: {:?}",
            out.stdout
        );
        assert!(
            !out.stdout.contains("Sup3rSecret!"),
            "SECRET LEAKED into captured stdout: {:?}",
            out.stdout
        );
        assert!(!out.timed_out, "run should not have timed out");
    }

    /// Proves the CLAUDE* env strip works: a shell spawned with the strip sees an
    /// empty $CLAUDECODE even though the parent process has it set.
    #[test]
    fn pty_strips_claude_env() {
        std::env::set_var("CLAUDECODE", "1");
        let sys = native_pty_system();
        let pair = sys
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .expect("openpty");
        let mut cmd = CommandBuilder::new(default_shell());
        cmd.arg("-lc");
        cmd.arg("printf 'CC=[%s]\\n' \"$CLAUDECODE\"");
        for (k, _) in std::env::vars() {
            if k.starts_with("CLAUDE") || k == "AI_AGENT" {
                cmd.env_remove(&k);
            }
        }
        let mut reader = pair.master.try_clone_reader().expect("reader");
        let mut child = pair.slave.spawn_command(cmd).expect("spawn");
        drop(pair.slave);
        let mut out = Vec::new();
        let mut buf = [0u8; 1024];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    out.extend_from_slice(&buf[..n]);
                    if String::from_utf8_lossy(&out).contains("CC=[") {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = child.wait();
        let s = String::from_utf8_lossy(&out);
        println!("env output: {s:?}");
        assert!(
            s.contains("CC=[]"),
            "CLAUDECODE should be stripped, got: {s:?}"
        );
    }
}

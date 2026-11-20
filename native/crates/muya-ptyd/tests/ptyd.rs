//! Drives the real `muya-ptyd` binary over its socket (unsigned test build: same-user peers).

use muya_proto::{Control, Decoder, ErrorCode, Frame, Role};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

struct Ptyd {
    child: Child,
    sock: PathBuf,
    dir: PathBuf,
}

impl Ptyd {
    fn start() -> Self {
        // sun_path is 103 bytes: keep the test socket short.
        let dir = PathBuf::from(format!(
            "/tmp/muya-ptyd-test-{}-{}",
            std::process::id(),
            rand_suffix()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("p.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_muya-ptyd"))
            .env("MUYA_PTYD_EXIT_WITH_PARENT", "1")
            .arg("--socket")
            .arg(&sock)
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !sock.exists() {
            assert!(Instant::now() < deadline, "ptyd did not start");
            std::thread::sleep(Duration::from_millis(10));
        }
        Self { child, sock, dir }
    }
    fn client(&self) -> Conn {
        Conn::open(&self.sock, Role::Muyad)
    }
}

impl Drop for Ptyd {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Unique per test in this process: tests run in parallel and the clock has only microsecond
/// resolution here, so a time-based name collided and one test removed another's socket.
fn rand_suffix() -> u32 {
    use std::sync::atomic::{AtomicU32, Ordering};
    static NEXT: AtomicU32 = AtomicU32::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

struct Conn {
    s: UnixStream,
    dec: Decoder,
    pending: Vec<Frame>,
    /// Output bytes received per session.
    output: std::collections::HashMap<u64, Vec<u8>>,
}

impl Conn {
    fn raw(path: &PathBuf) -> Self {
        let s = UnixStream::connect(path).unwrap();
        s.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
        Self {
            s,
            dec: Decoder::default(),
            pending: Vec::new(),
            output: Default::default(),
        }
    }
    fn open(path: &PathBuf, role: Role) -> Self {
        let mut c = Self::raw(path);
        c.send(Frame::Control(muya_proto::hello(role, "test")));
        assert!(matches!(c.control(), Control::Welcome { .. }));
        c
    }
    fn send(&mut self, f: Frame) {
        self.s.write_all(&f.encode()).unwrap();
    }
    fn pump(&mut self) -> bool {
        let mut buf = [0u8; 65536];
        match self.s.read(&mut buf) {
            Ok(0) => return false,
            Ok(n) => self.dec.push(&buf[..n]),
            Err(_) => {}
        }
        while let Some(f) = self.dec.next_frame().unwrap() {
            if let Frame::Output { session, data, .. } = &f {
                self.output
                    .entry(*session)
                    .or_default()
                    .extend_from_slice(data);
            }
            self.pending.push(f);
        }
        true
    }
    /// The next control frame that is not an Exited event.
    fn control(&mut self) -> Control {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(i) = self.pending.iter().position(
                |f| matches!(f, Frame::Control(c) if !matches!(c, Control::Exited { .. })),
            ) {
                let Frame::Control(c) = self.pending.remove(i) else {
                    unreachable!()
                };
                return c;
            }
            assert!(Instant::now() < deadline, "no reply");
            self.pump();
        }
    }
    fn request(&mut self, c: Control) -> Control {
        self.send(Frame::Control(c));
        self.control()
    }
    fn spawn(&mut self, script: &str, env: &[(&str, &str)]) -> u64 {
        let env = env
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        match self.request(Control::Spawn {
            argv: vec!["/bin/sh".into(), "-c".into(), script.into()],
            cwd: "/tmp".into(),
            env,
            cols: 80,
            rows: 24,
        }) {
            Control::Spawned { id, .. } => id,
            other => panic!("{other:?}"),
        }
    }
    fn wait_output(&mut self, id: u64, needle: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let text =
                String::from_utf8_lossy(self.output.get(&id).map(Vec::as_slice).unwrap_or(&[]))
                    .into_owned();
            if text.contains(needle) {
                return text;
            }
            assert!(Instant::now() < deadline, "no {needle:?} in {text:?}");
            self.pump();
        }
    }
    fn wait_exited(&mut self, id: u64) -> i32 {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(Frame::Control(Control::Exited { status, .. })) = self
                .pending
                .iter()
                .find(|f| matches!(f, Frame::Control(Control::Exited { id: i, .. }) if *i == id))
            {
                return *status;
            }
            assert!(Instant::now() < deadline, "no exit");
            self.pump();
        }
    }
    fn sessions(&mut self) -> Vec<muya_proto::SessionInfo> {
        match self.request(Control::List) {
            Control::Sessions { sessions } => sessions,
            other => panic!("{other:?}"),
        }
    }
}

#[test]
fn handshake_versions_and_roles() {
    let d = Ptyd::start();
    let mut c = Conn::raw(&d.sock);
    c.send(Frame::Control(Control::Hello {
        major: 2,
        minor: 0,
        role: Role::Muyad,
        build: "future".into(),
    }));
    assert!(matches!(
        c.control(),
        Control::Error {
            code: ErrorCode::Incompatible,
            ..
        }
    ));
    let mut c = Conn::raw(&d.sock);
    c.send(Frame::Control(muya_proto::hello(Role::App, "x")));
    assert!(
        matches!(
            c.control(),
            Control::Error {
                code: ErrorCode::Refused,
                ..
            }
        ),
        "the app talks to muyad, not ptyd"
    );
    let mut c = Conn::raw(&d.sock);
    c.send(Frame::Control(Control::Hello {
        major: 1,
        minor: 0,
        role: Role::Muyad,
        build: "n-1".into(),
    }));
    assert!(matches!(c.control(), Control::Welcome { .. }));
}

/// AC19: a hello of another major gets the versions and the live sessions (with their folders); a
/// message this build does not know is answered, not fatal; a message above the announced minor is
/// refused; only muyad can restart ptyd, and `Upgrade` ends the sessions and the process.
#[test]
fn version_skew_upgrade_and_minor_gating() {
    let mut d = Ptyd::start();
    let mut c = d.client();
    let id = c.spawn("sleep 600", &[]);
    let pid = c.sessions()[0].pid;
    assert_eq!(c.sessions()[0].cwd, "/tmp");

    let mut f = Conn::raw(&d.sock);
    f.send(Frame::Control(Control::Hello { major: 2, minor: 9, role: Role::Muyad, build: "future".into() }));
    let Control::Error { code: ErrorCode::Incompatible, detail: Some(det), .. } = f.control() else { panic!("no detail") };
    assert_eq!((det.daemon.major, det.daemon.minor), (muya_proto::PROTO_MAJOR, muya_proto::PROTO_MINOR));
    assert_eq!((det.client.major, det.client.minor, det.client.build.as_str()), (2, 9, "future"));
    assert_eq!(det.sessions.len(), 1);
    assert_eq!((det.sessions[0].id, det.sessions[0].pid, det.sessions[0].cwd.as_str()), (id, pid, "/tmp"));

    // Unknown message: answered, the connection lives on.
    let mut body = vec![muya_proto::KIND_CONTROL];
    body.extend(br#"{"type":"teleport"}"#);
    let mut raw = (body.len() as u32).to_be_bytes().to_vec();
    raw.extend(body);
    c.s.write_all(&raw).unwrap();
    assert!(matches!(c.control(), Control::Error { code: ErrorCode::BadRequest, .. }));
    assert_eq!(c.sessions().len(), 1);

    // A connection that announced an old minor does not get Upgrade.
    let mut old = Conn::raw(&d.sock);
    old.send(Frame::Control(Control::Hello { major: 1, minor: 0, role: Role::Muyad, build: "n-3".into() }));
    assert!(matches!(old.control(), Control::Welcome { .. }));
    assert!(matches!(old.request(Control::Upgrade), Control::Error { code: ErrorCode::BadRequest, .. }));
    // muyactl cannot restart ptyd.
    let mut ctl = Conn::open(&d.sock, Role::Muyactl);
    assert!(matches!(ctl.request(Control::Upgrade), Control::Error { code: ErrorCode::BadRequest, .. }));
    assert_eq!(c.sessions().len(), 1);

    // muyad can: sessions end, the plan comes back, the process exits (0).
    let Control::Upgrading { plan, ptyd_restarting } = c.request(Control::Upgrade) else { panic!("no upgrading") };
    assert!(ptyd_restarting);
    assert_eq!((plan.len(), plan[0].id, plan[0].cwd.as_str()), (1, id, "/tmp"));
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(st) = d.child.try_wait().unwrap() {
            break st;
        }
        assert!(Instant::now() < deadline, "ptyd did not exit");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(status.success());
    wait_gone(pid);
}

fn wait_gone(pid: i32) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(Instant::now() < deadline, "session {pid} still alive");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn spawn_attach_input_output_exit() {
    let d = Ptyd::start();
    let mut c = d.client();
    let id = c.spawn(r#"printf ready; read x; printf "got:%s" "$x""#, &[]);
    assert!(matches!(
        c.request(Control::Attach { id }),
        Control::Attached { .. }
    ));
    c.wait_output(id, "ready");
    c.send(Frame::Input {
        session: id,
        data: "hi şğ\r".as_bytes().to_vec(),
    });
    c.wait_output(id, "got:hi şğ");
    assert_eq!(c.wait_exited(id), 0);
}

#[test]
fn sessions_get_iutf8_and_no_claude_variables() {
    let d = Ptyd::start();
    let mut c = d.client();
    let id = c.spawn(
        "env; stty -a; echo END",
        &[
            ("CLAUDE_CODE_CHILD_SESSION", "1"),
            ("CLAUDECODE", "1"),
            ("LANG", "tr_TR.UTF-8"),
            ("PATH", "/usr/bin:/bin"),
        ],
    );
    c.request(Control::Attach { id });
    let out = c.wait_output(id, "END");
    assert!(!out.contains("CLAUDE"), "{out}");
    assert!(out.contains("LANG=tr_TR.UTF-8"));
    assert!(
        out.split_whitespace().any(|w| w == "iutf8"),
        "IUTF8 not set: {out}"
    );
}

#[test]
fn late_attach_gets_ring_and_modes_after_bytes_scrolled_out() {
    let d = Ptyd::start();
    let mut c = d.client();
    let id = c.spawn(r#"printf '\033[?2004h\033[3;20r\033[>1u'; head -c 3000000 /dev/zero | tr '\0' a; printf DONE; sleep 30"#, &[]);
    // Wait until the program has printed everything (an early client sees DONE), so the ring is
    // final before the late attach. Gating on a byte count alone raced: the escapes, the 3 MB and
    // DONE are separate writes, so a late attach could land before DONE and receive it live on
    // top of the ring replay (+4 bytes in the final length check).
    c.request(Control::Attach { id });
    c.wait_output(id, "DONE");
    let mut late = d.client();
    let Control::Attached {
        start_seq,
        end_seq,
        modes,
        ..
    } = late.request(Control::Attach { id })
    else {
        panic!()
    };
    assert!(
        start_seq > 0 && end_seq - start_seq == muya_ptyd::ring::RING_BYTES as u64,
        "{start_seq}..{end_seq}"
    );
    assert!(
        modes.contains("\x1b[?2004h")
            && modes.contains("\x1b[3;20r")
            && modes.contains("\x1b[=1;1u"),
        "{modes:?}"
    );
    // The replay is exactly the ring window and ends with the program's last bytes.
    late.wait_output(id, "DONE");
    assert_eq!(late.output[&id].len() as u64, end_seq - start_seq);
    assert!(late.output[&id].ends_with(b"aDONE"));
}

#[test]
fn a_dying_client_does_not_take_sessions_with_it() {
    let d = Ptyd::start();
    let mut a = d.client();
    let id = a.spawn("while :; do printf x; sleep 0.01; done", &[]);
    a.request(Control::Attach { id });
    a.wait_output(id, "xxx");
    drop(a);
    std::thread::sleep(Duration::from_millis(300));
    let mut b = d.client();
    let s = b.sessions().into_iter().find(|s| s.id == id).unwrap();
    assert_eq!(s.exited, None);
    assert_eq!(unsafe { libc::kill(s.pid, 0) }, 0);
}

/// Regression ("the page is half empty"): posix_spawn left sessions WITHOUT a controlling terminal (tpgid 0), so a resize
/// changed the winsize but no program ever got SIGWINCH and full-screen programs (Claude) kept the width they started with.
#[test]
fn a_resize_delivers_sigwinch_and_the_session_has_a_controlling_terminal() {
    let d = Ptyd::start();
    let mut c = d.client();
    let script = "echo TPGID=$(ps -o tpgid= -p $$ | tr -d ' '); python3 -c \"import signal,time,os; signal.signal(signal.SIGWINCH, lambda *a: print('WINCH %d %d' % os.get_terminal_size()[::-1], flush=True)); print('ready', flush=True); [time.sleep(0.1) for _ in range(300)]\"";
    // An interactive login shell, like every real session (muyad's session_command): it is the case that broke.
    let id = match c.request(Control::Spawn {
        argv: vec!["/bin/zsh".into(), "-l".into(), "-i".into(), "-c".into(), script.into()],
        cwd: "/tmp".into(),
        env: vec![("PATH".into(), "/usr/bin:/bin:/usr/sbin:/sbin".into()), ("HOME".into(), "/tmp".into())],
        cols: 80,
        rows: 24,
    }) {
        Control::Spawned { id, .. } => id,
        other => panic!("{other:?}"),
    };
    c.request(Control::Attach { id });
    let out = c.wait_output(id, "ready");
    let tpgid = out.lines().find_map(|l| l.trim().strip_prefix("TPGID=")).unwrap_or("?").to_string();
    assert!(tpgid != "0" && tpgid != "-1" && tpgid != "?", "no controlling terminal (tpgid {tpgid})");
    assert_eq!(c.request(Control::Resize { id, cols: 150, rows: 40 }), Control::Ok);
    c.wait_output(id, "WINCH 40 150");
    assert_eq!(c.request(Control::Resize { id, cols: 61, rows: 20 }), Control::Ok);
    c.wait_output(id, "WINCH 20 61");
}

#[test]
fn resize_reaches_the_program_and_close_ends_it() {
    let d = Ptyd::start();
    let mut c = d.client();
    let id = c.spawn("sleep 0.5; stty size; sleep 30", &[]);
    c.request(Control::Attach { id });
    assert_eq!(
        c.request(Control::Resize {
            id,
            cols: 101,
            rows: 33
        }),
        Control::Ok
    );
    c.wait_output(id, "33 101");
    let pid = c.sessions().iter().find(|s| s.id == id).unwrap().pid;
    assert_eq!(c.request(Control::Close { id }), Control::Ok);
    assert!(c.sessions().iter().all(|s| s.id != id));
    let deadline = Instant::now() + Duration::from_secs(5);
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(Instant::now() < deadline, "session process survived Close");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_process_inside_a_session_is_refused() {
    let d = Ptyd::start();
    let mut c = d.client();
    // nc connects from inside the session and prints whatever ptyd answers.
    let id = c.spawn(
        &format!("nc -U {} </dev/null; sleep 5", d.sock.display()),
        &[],
    );
    c.request(Control::Attach { id });
    c.wait_output(id, "inside PTY session");
}

/// Security: no socket of ptyd (its listener or a client connection) may leak into a session.
/// On macOS a socket gets FD_CLOEXEC only after it is created, so a session forked by another
/// thread in that window would inherit it (a session could then talk to ptyd as muyad).
#[test]
fn sessions_inherit_no_ptyd_sockets_under_concurrent_load() {
    let d = Ptyd::start();
    let sock = d.sock.clone();
    let workers: Vec<_> = (0..6)
        .map(|_| {
            let sock = sock.clone();
            std::thread::spawn(move || {
                let mut c = Conn::open(&sock, Role::Muyad);
                let mut ids = Vec::new();
                for _ in 0..15 {
                    // Count this shell's own unix-socket descriptors.
                    ids.push(c.spawn(r#"n=$(lsof -a -p $$ -U -F f 2>/dev/null | grep -c '^f'); echo "UNIXFDS=$n"; sleep 2"#, &[]));
                    // Churn connections meanwhile, so accepts race with forks.
                    let _ = Conn::open(&sock, Role::Muyad);
                }
                let mut leaks = Vec::new();
                for id in ids {
                    c.request(Control::Attach { id });
                    let out = c.wait_output(id, "UNIXFDS=");
                    let n: u32 = out.split("UNIXFDS=").nth(1).and_then(|s| s.split_whitespace().next()).and_then(|s| s.parse().ok()).unwrap_or(0);
                    if n > 0 {
                        leaks.push((id, n));
                    }
                }
                leaks
            })
        })
        .collect();
    let leaks: Vec<_> = workers
        .into_iter()
        .flat_map(|w| w.join().unwrap())
        .collect();
    assert!(
        leaks.is_empty(),
        "sessions holding unix sockets (session, count): {leaks:?}"
    );
}

/// Concurrent spawns from several clients: every session must get its own tty. `ttyname` returns a
/// pointer into one process-wide buffer, so two spawning threads could swap paths: a session then
/// opened another session's tty, or a half-written path (spawn failed with ENXIO / ENOENT).
#[test]
fn concurrent_spawns_each_get_their_own_tty() {
    let d = Ptyd::start();
    let sock = d.sock.clone();
    // 40 sessions: the system has only 511 ptys (kern.tty.ptmx_max) shared with every terminal.
    let workers: Vec<_> = (0..4)
        .map(|_| {
            let sock = sock.clone();
            std::thread::spawn(move || {
                let mut c = Conn::open(&sock, Role::Muyad);
                let ids: Vec<u64> = (0..10).map(|_| c.spawn("tty; sleep 20", &[])).collect();
                ids.into_iter()
                    .map(|id| {
                        c.request(Control::Attach { id });
                        let out = c.wait_output(id, "/dev/");
                        let tty = out
                            .split_whitespace()
                            .find(|w| w.starts_with("/dev/"))
                            .unwrap()
                            .to_owned();
                        (id, tty)
                    })
                    .collect::<Vec<_>>()
            })
        })
        .collect();
    let all: Vec<(u64, String)> = workers
        .into_iter()
        .flat_map(|w| w.join().unwrap())
        .collect();
    let distinct: std::collections::HashSet<_> = all.iter().map(|(_, t)| t).collect();
    assert_eq!(distinct.len(), all.len(), "sessions share a tty: {all:?}");
}

/// The session has a controlling terminal with job control: Ctrl+C reaches the foreground
/// program as SIGINT, and SIGPIPE is not left ignored by ptyd.
#[test]
fn ctrl_c_interrupts_and_sigpipe_is_default() {
    let d = Ptyd::start();
    let mut c = d.client();
    let id = c.spawn(
        r#"trap 'echo GOT-INT; exit 7' INT; echo READY; while :; do sleep 0.1; done"#,
        &[],
    );
    c.request(Control::Attach { id });
    c.wait_output(id, "READY");
    c.send(Frame::Input {
        session: id,
        data: vec![0x03],
    });
    c.wait_output(id, "GOT-INT");
    assert_eq!(c.wait_exited(id), 7);
    // `yes | head -1` only ends when yes dies of SIGPIPE.
    let id = c.spawn("yes | head -1 >/dev/null; echo PIPE-OK", &[]);
    c.request(Control::Attach { id });
    c.wait_output(id, "PIPE-OK");
}

/// Deterministic form of the leak check: with POSIX_SPAWN_CLOEXEC_DEFAULT a session starts with
/// exactly stdin/stdout/stderr open (the slave tty), whatever ptyd had open at that moment.
/// Probed with fstat from a program started directly (no shell, which opens its own).
#[test]
fn a_session_starts_with_only_stdio_open() {
    let d = Ptyd::start();
    let mut c = d.client();
    // Keep a few extra connections open in ptyd while the session starts.
    let _others: Vec<Conn> = (0..5).map(|_| d.client()).collect();
    let probe = "import os, stat\nr = []\nfor f in range(256):\n    try:\n        m = os.fstat(f).st_mode\n        r.append('%d:%s' % (f, 'chr' if stat.S_ISCHR(m) else 'sock' if stat.S_ISSOCK(m) else 'fifo' if stat.S_ISFIFO(m) else 'other'))\n    except OSError:\n        pass\nprint('FDS ' + ' '.join(r) + ' END')";
    let argv = vec![
        "/usr/bin/python3".to_string(),
        "-I".into(),
        "-c".into(),
        probe.into(),
    ];
    let Control::Spawned { id, .. } = c.request(Control::Spawn {
        argv,
        cwd: "/tmp".into(),
        env: vec![],
        cols: 80,
        rows: 24,
    }) else {
        panic!()
    };
    c.request(Control::Attach { id });
    let out = c.wait_output(id, " END");
    let fds = out
        .split("FDS ")
        .nth(1)
        .unwrap()
        .split(" END")
        .next()
        .unwrap()
        .to_owned();
    assert_eq!(
        fds, "0:chr 1:chr 2:chr",
        "a session must start with only the tty as stdio"
    );
}

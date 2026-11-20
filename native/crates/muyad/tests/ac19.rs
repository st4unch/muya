//! PRD AC19 (daemon side): a protocol-incompatible update shows "restart sessions now / later".
//! - the version error names both versions and lists the live sessions with their Claude session ids;
//! - "later": the running daemons keep serving over a compatibility hello (session PIDs unchanged);
//! - "now": `Control::Upgrade` keeps a resume plan, ends the sessions and both daemons exit; the
//!   next daemons (here started by the test, as launchd would) hand the plan to the app by rpc.
//!
//! Needs the ptyd binary: `cargo build --workspace`.

use muya_proto::{Control, Decoder, ErrorCode, Frame, Incompat, LiveSession, Role};
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant};

const CLAUDE_A: &str = "0f3c9d1e-aaaa-4bbb-8ccc-000000000001";

fn wait_until(what: &str, mut ok: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while !ok() {
        assert!(Instant::now() < deadline, "timed out: {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

/// Everything one test starts lives under its own temp dir and dies with it.
struct Stack {
    dir: PathBuf,
    children: Vec<Child>,
}

impl Drop for Stack {
    fn drop(&mut self) {
        for c in self.children.iter_mut().rev() {
            let _ = c.kill();
            let _ = c.wait();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Stack {
    fn new(tag: &str) -> Self {
        let dir = PathBuf::from(format!("/tmp/muya-ac19-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("bin")).unwrap();
        std::fs::create_dir_all(dir.join("home")).unwrap();
        std::fs::create_dir_all(dir.join("work-a")).unwrap();
        std::fs::create_dir_all(dir.join("work-b")).unwrap();
        // A stand-in `claude` that answers `agents --json` from a file the test fills in.
        let shim = dir.join("bin/claude");
        std::fs::write(&shim, "#!/bin/sh\ncase \"$1\" in agents) cat \"$FAKE_AGENTS_FILE\" ;; *) echo fake ;; esac\n").unwrap();
        std::fs::set_permissions(&shim, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        std::fs::write(dir.join("agents.json"), "[]").unwrap();
        Self { dir, children: Vec::new() }
    }
    fn ptyd_sock(&self) -> PathBuf {
        self.dir.join("p.sock")
    }
    fn muyad_sock(&self) -> PathBuf {
        self.dir.join("m.sock")
    }
    fn wait_for(&self, p: &Path) {
        wait_until(&format!("{} to appear", p.display()), || p.exists());
    }
    /// Starts a ptyd and returns its index in `children`.
    fn start_ptyd(&mut self) -> usize {
        let bin = Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name("muya-ptyd");
        assert!(bin.exists(), "build ptyd first: cargo build --workspace");
        let _ = std::fs::remove_file(self.ptyd_sock());
        let c = Command::new(bin).env("MUYA_PTYD_EXIT_WITH_PARENT", "1").arg("--socket").arg(self.ptyd_sock()).spawn().unwrap();
        self.children.push(c);
        self.wait_for(&self.ptyd_sock());
        self.children.len() - 1
    }
    fn start_muyad(&mut self, ptyd_sock: &Path) -> usize {
        let _ = std::fs::remove_file(self.muyad_sock());
        let path = format!("{}:/usr/bin:/bin", self.dir.join("bin").display());
        let c = Command::new(env!("CARGO_BIN_EXE_muyad"))
            .env("HOME", self.dir.join("home"))
            .env("PATH", path)
            .env("SHELL", "/bin/sh")
            .env("FAKE_AGENTS_FILE", self.dir.join("agents.json"))
            .arg("--socket")
            .arg(self.muyad_sock())
            .arg("--ptyd")
            .arg(ptyd_sock)
            .arg("--state-dir")
            .arg(&self.dir)
            .spawn()
            .unwrap();
        self.children.push(c);
        self.wait_for(&self.muyad_sock());
        self.children.len() - 1
    }
    fn exited(&mut self, idx: usize, within: Duration) -> Option<std::process::ExitStatus> {
        let deadline = Instant::now() + within;
        loop {
            if let Some(st) = self.children[idx].try_wait().unwrap() {
                return Some(st);
            }
            if Instant::now() > deadline {
                return None;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

struct Client {
    s: UnixStream,
    dec: Decoder,
    queue: VecDeque<Frame>,
}

impl Client {
    fn connect(sock: &Path) -> Self {
        let s = connect_retry(sock);
        s.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
        Self { s, dec: Decoder::default(), queue: VecDeque::new() }
    }
    fn send(&mut self, c: Control) {
        self.s.write_all(&Frame::Control(c).encode()).unwrap();
    }
    /// A control frame whose JSON this build cannot parse (a message from the future).
    fn send_raw_json(&mut self, json: &str) {
        let mut body = vec![muya_proto::KIND_CONTROL];
        body.extend(json.as_bytes());
        let mut out = (body.len() as u32).to_be_bytes().to_vec();
        out.extend(body);
        self.s.write_all(&out).unwrap();
    }
    fn next(&mut self, within: Duration) -> Option<Frame> {
        let deadline = Instant::now() + within;
        let mut buf = [0u8; 65536];
        loop {
            if let Some(f) = self.queue.pop_front() {
                return Some(f);
            }
            if Instant::now() > deadline {
                return None;
            }
            if let Ok(n) = self.s.read(&mut buf) {
                if n == 0 {
                    return None;
                }
                self.dec.push(&buf[..n]);
            }
            while let Ok(Some(f)) = self.dec.next_frame() {
                self.queue.push_back(f);
            }
        }
    }
    /// The next control frame matching `pick`; others (output, screen) are skipped.
    fn control<T>(&mut self, mut pick: impl FnMut(&Control) -> Option<T>) -> T {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let f = self.next(left).expect("connection ended or timed out");
            if let Frame::Control(c) = &f
                && let Some(v) = pick(c)
            {
                return v;
            }
        }
    }
    fn welcomed(sock: &Path, major: u16, minor: u16) -> Self {
        let mut c = Self::connect(sock);
        c.send(Control::Hello { major, minor, role: Role::App, build: "ac19".into() });
        c.control(|c| matches!(c, Control::Welcome { .. }).then_some(()));
        c
    }
    fn rpc(&mut self, req: u64, method: &str, params: &str) -> serde_json::Value {
        self.send(Control::Rpc { req, method: method.into(), params: params.into() });
        let (ok, result) = self.control(|c| match c {
            Control::RpcReply { req: r, ok, result } if *r == req => Some((*ok, result.clone())),
            _ => None,
        });
        assert!(ok, "{method}: {result}");
        serde_json::from_str(&result).unwrap()
    }
    fn spawn(&mut self, argv: &[&str], cwd: &Path) -> (u64, i32) {
        self.send(Control::Spawn { argv: argv.iter().map(|a| a.to_string()).collect(), cwd: cwd.display().to_string(), env: vec![], cols: 80, rows: 24 });
        self.control(|c| match c {
            Control::Spawned { id, pid } => Some((*id, *pid)),
            _ => None,
        })
    }
    fn sessions(&mut self) -> Vec<muya_proto::SessionInfo> {
        self.send(Control::List);
        self.control(|c| match c {
            Control::Sessions { sessions } => Some(sessions.clone()),
            _ => None,
        })
    }
}

fn write_agents(stack: &Stack, entries: &[(&str, i32, &Path)]) {
    let list: Vec<_> = entries
        .iter()
        .map(|(id, pid, cwd)| serde_json::json!({ "sessionId": id, "pid": pid, "cwd": cwd.display().to_string(), "kind": "interactive", "status": "idle", "startedAt": 1 }))
        .collect();
    std::fs::write(stack.dir.join("agents.json"), serde_json::to_string(&list).unwrap()).unwrap();
}

/// A hello with a major this build does not serve -> the typed error with versions and sessions.
fn incompat_of(sock: &Path, major: u16) -> Incompat {
    let mut c = Client::connect(sock);
    c.send(Control::Hello { major, minor: 4, role: Role::App, build: "future".into() });
    c.control(|c| match c {
        Control::Error { code: ErrorCode::Incompatible, detail: Some(d), .. } => Some((**d).clone()),
        _ => None,
    })
}

/// "Later": the running muyad keeps its sessions; a newer-major app that talks the daemon's own
/// hello gets the core operations, and what the daemon does not know is answered, not fatal.
#[test]
fn later_keeps_sessions_running_and_the_core_works_over_a_compat_hello() {
    let mut st = Stack::new("later");
    let p = st.ptyd_sock();
    st.start_ptyd();
    st.start_muyad(&p);
    let mut app = Client::welcomed(&st.muyad_sock(), muya_proto::PROTO_MAJOR, muya_proto::PROTO_MINOR);
    let (cat_id, cat_pid) = app.spawn(&["/bin/cat"], &st.dir.join("work-a"));
    let (_, sleep_pid) = app.spawn(&["/bin/sh", "-c", "sleep 600"], &st.dir.join("work-b"));
    write_agents(&st, &[(CLAUDE_A, sleep_pid, &st.dir.join("work-b"))]);

    // A future app (major 2): refused with everything the dialog needs.
    let d = incompat_of(&st.muyad_sock(), muya_proto::PROTO_MAJOR + 1);
    assert_eq!((d.daemon.major, d.daemon.minor), (muya_proto::PROTO_MAJOR, muya_proto::PROTO_MINOR));
    assert_eq!(d.daemon.build, env!("CARGO_PKG_VERSION"));
    assert_eq!((d.client.major, d.client.minor, d.client.build.as_str()), (muya_proto::PROTO_MAJOR + 1, 4, "future"));
    assert_eq!((d.required.major, d.required.minor), (muya_proto::PROTO_MAJOR, muya_proto::MINOR_FLOOR));
    assert_eq!(d.sessions.len(), 2);
    let cat = d.sessions.iter().find(|s| s.id == cat_id).unwrap();
    assert_eq!((cat.pid, cat.cwd.as_str(), cat.claude_session_id.as_deref()), (cat_pid, st.dir.join("work-a").to_str().unwrap(), None));
    let sleeper = d.sessions.iter().find(|s| s.pid == sleep_pid).unwrap();
    assert_eq!(sleeper.claude_session_id.as_deref(), Some(CLAUDE_A));
    assert_eq!(sleeper.cwd, st.dir.join("work-b").to_str().unwrap());

    // "Later": speak what the daemon says it speaks. The core messages work, a typed echo comes back.
    let mut later = Client::welcomed(&st.muyad_sock(), d.speak.major, d.speak.minor);
    assert_eq!(later.sessions().iter().map(|s| s.pid).collect::<Vec<_>>(), vec![cat_pid, sleep_pid]);
    later.send(Control::Attach { id: cat_id });
    later.control(|c| matches!(c, Control::Attached { .. }).then_some(()));
    later.send(Control::Key { id: cat_id, key: "h".into(), mods: 0, text: None });
    later.send(Control::Paste { id: cat_id, text: "i\n".into() });
    later.send(Control::Resize { id: cat_id, cols: 100, rows: 30 });
    let mut seen = Vec::new();
    wait_until("cat to echo `hi`", || {
        while let Some(f) = later.next(Duration::from_millis(30)) {
            if let Frame::Output { data, .. } = f {
                seen.extend(data);
            }
        }
        String::from_utf8_lossy(&seen).contains("hi")
    });
    // A message from the future does not end the connection ...
    later.send_raw_json(r#"{"type":"teleport","id":1}"#);
    let refusal = later.control(|c| match c {
        Control::Error { code, message, .. } => Some((code.clone(), message.clone())),
        _ => None,
    });
    assert_eq!(refusal.0, ErrorCode::BadRequest, "{}", refusal.1);
    assert!(refusal.1.contains("unknown message"), "{}", refusal.1);
    assert_eq!(later.sessions().len(), 2);
    // ... and a message above the announced minor is refused before it is looked at.
    let mut old = Client::welcomed(&st.muyad_sock(), muya_proto::PROTO_MAJOR, 0);
    old.send(Control::Rpc { req: 1, method: "upgrade.status".into(), params: "{}".into() });
    old.send(Control::Upgrade);
    let mut refusals = 0;
    while refusals < 2 {
        let msg = old.control(|c| match c {
            Control::Error { code: ErrorCode::BadRequest, message, .. } => Some(message.clone()),
            _ => None,
        });
        assert!(msg.contains("needs protocol minor"), "{msg}");
        refusals += 1;
    }
    assert_eq!(old.sessions().len(), 2);

    // Nothing above restarted anything.
    assert!(alive(cat_pid) && alive(sleep_pid));
    assert_eq!(app.sessions().iter().map(|s| s.pid).collect::<Vec<_>>(), vec![cat_pid, sleep_pid]);
}

/// "Now": the plan is kept, both daemons exit, sessions end; the new daemons (new processes) hand the
/// plan to the app, which forgets it once it respawned the sessions.
#[test]
fn now_keeps_a_resume_plan_ends_the_sessions_and_the_new_daemons_serve_it() {
    let mut st = Stack::new("now");
    let p = st.ptyd_sock();
    let ptyd1 = st.start_ptyd();
    let muyad1 = st.start_muyad(&p);
    let (old_ptyd_pid, old_muyad_pid) = (st.children[ptyd1].id(), st.children[muyad1].id());
    let mut app = Client::welcomed(&st.muyad_sock(), muya_proto::PROTO_MAJOR, muya_proto::PROTO_MINOR);
    let (id_a, pid_a) = app.spawn(&["/bin/sh", "-c", "sleep 600"], &st.dir.join("work-a"));
    let (id_b, pid_b) = app.spawn(&["/bin/sh", "-c", "sleep 600"], &st.dir.join("work-b"));
    write_agents(&st, &[(CLAUDE_A, pid_a, &st.dir.join("work-a"))]);

    // muyactl cannot restart anything; an old connection cannot either (see the "later" test).
    let mut ctl = Client::connect(&st.muyad_sock());
    ctl.send(Control::Hello { major: muya_proto::PROTO_MAJOR, minor: muya_proto::PROTO_MINOR, role: Role::Muyactl, build: "ctl".into() });
    ctl.control(|c| matches!(c, Control::Welcome { .. }).then_some(()));
    ctl.send(Control::Upgrade);
    assert!(matches!(ctl.control(|c| matches!(c, Control::Error { .. }).then(|| c.clone())), Control::Error { code: ErrorCode::BadRequest, .. }));
    assert!(alive(pid_a) && alive(pid_b));

    app.send(Control::Upgrade);
    let (plan, ptyd_restarting) = app.control(|c| match c {
        Control::Upgrading { plan, ptyd_restarting } => Some((plan.clone(), *ptyd_restarting)),
        _ => None,
    });
    assert!(ptyd_restarting);
    let expect = |id: u64, pid: i32, dir: &str, claude: Option<&str>| LiveSession {
        id,
        pid,
        cwd: st.dir.join(dir).display().to_string(),
        claude_session_id: claude.map(Into::into),
        exited: None,
    };
    assert_eq!(plan, vec![expect(id_a, pid_a, "work-a", Some(CLAUDE_A)), expect(id_b, pid_b, "work-b", None)]);

    // Both daemons stop on their own (exit 0), and the sessions are gone with them.
    let muyad_status = st.exited(muyad1, Duration::from_secs(10)).expect("old muyad exits");
    let ptyd_status = st.exited(ptyd1, Duration::from_secs(10)).expect("old ptyd exits");
    assert!(muyad_status.success() && ptyd_status.success(), "{muyad_status:?} {ptyd_status:?}");
    wait_until("old sessions to end", || !alive(pid_a) && !alive(pid_b));
    let plan_file = st.dir.join(muyad::RESUME_PLAN_FILE);
    assert_eq!(std::fs::metadata(&plan_file).unwrap().permissions().mode_bits() & 0o777, 0o600);

    // The supervisor (launchd) starts the new builds: new processes, an empty session table, the plan.
    let ptyd2 = st.start_ptyd();
    let muyad2 = st.start_muyad(&p);
    assert_ne!(st.children[ptyd2].id(), old_ptyd_pid);
    assert_ne!(st.children[muyad2].id(), old_muyad_pid);
    let mut app = Client::welcomed(&st.muyad_sock(), muya_proto::PROTO_MAJOR, muya_proto::PROTO_MINOR);
    assert!(app.sessions().is_empty());
    let got = app.rpc(1, "upgrade.resume_plan", "{}");
    assert_eq!(got["pending"], true);
    assert_eq!(got["from_build"], env!("CARGO_PKG_VERSION"));
    let got_plan: Vec<LiveSession> = serde_json::from_value(got["sessions"].clone()).unwrap();
    assert_eq!(got_plan, plan);
    // The app respawns each one where it was (`claude --resume <id>` for the Claude ones).
    for s in &got_plan {
        let (_, pid) = app.spawn(&["/bin/sh", "-c", "sleep 600"], Path::new(&s.cwd));
        assert!(pid != s.pid && alive(pid));
    }
    assert_eq!(app.rpc(2, "upgrade.resume_done", "{}")["ok"], true);
    assert_eq!(app.rpc(3, "upgrade.resume_plan", "{}")["pending"], false);
    assert!(!plan_file.exists());
    let status = app.rpc(4, "upgrade.status", "{}");
    assert_eq!(status["restart_needed"], false);
    assert_eq!(status["ptyd"]["major"], muya_proto::PROTO_MAJOR);
}

trait ModeBits {
    fn mode_bits(&self) -> u32;
}
impl ModeBits for std::fs::Permissions {
    fn mode_bits(&self) -> u32 {
        std::os::unix::fs::PermissionsExt::mode(self)
    }
}

/// A ptyd of another major: muyad links to it in compatibility mode, reports it by rpc, and "now"
/// (which that ptyd cannot be told) ends its sessions one by one and says ptyd is not restarting.
#[test]
fn muyad_links_a_ptyd_of_another_major_and_upgrade_ends_its_sessions_one_by_one() {
    let mut st = Stack::new("oldptyd");
    const OLD_MAJOR: u16 = 7;
    let listener = UnixListener::bind(st.ptyd_sock()).unwrap();
    let closed: std::sync::Arc<std::sync::Mutex<Vec<u64>>> = Default::default();
    let log = closed.clone();
    let hellos: std::sync::Arc<std::sync::Mutex<Vec<(u16, u16)>>> = Default::default();
    let hello_log = hellos.clone();
    // The fake ptyd: major 7, no cwd in its session list, answers only the core messages.
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let (log, hello_log) = (log.clone(), hello_log.clone());
            std::thread::spawn(move || {
                let mut r = stream.try_clone().unwrap();
                let mut w = stream;
                let mut dec = Decoder::default();
                let mut buf = [0u8; 4096];
                let say = |w: &mut UnixStream, c: Control| w.write_all(&Frame::Control(c).encode()).unwrap();
                loop {
                    match r.read(&mut buf) {
                        Ok(0) | Err(_) => return,
                        Ok(n) => dec.push(&buf[..n]),
                    }
                    while let Ok(Some(Frame::Control(c))) = dec.next_frame() {
                        match c {
                            Control::Hello { major, minor, .. } => {
                                hello_log.lock().unwrap().push((major, minor));
                                if major == OLD_MAJOR {
                                    say(&mut w, Control::Welcome { major: OLD_MAJOR, minor: 0, server_build: "old-ptyd".into() });
                                } else {
                                    let v = |b: &str| muya_proto::Version { major: OLD_MAJOR, minor: 0, build: b.into() };
                                    let detail = Incompat {
                                        daemon: v("old-ptyd"),
                                        client: muya_proto::Version { major, minor, build: "new".into() },
                                        required: v("old-ptyd"),
                                        speak: v("old-ptyd"),
                                        sessions: vec![],
                                    };
                                    say(&mut w, Control::Error { code: ErrorCode::Incompatible, message: "no".into(), detail: Some(Box::new(detail)) });
                                }
                            }
                            Control::List => say(&mut w, Control::Sessions { sessions: vec![muya_proto::SessionInfo { id: 5, pid: 4242, cols: 80, rows: 24, end_seq: 0, exited: None, cwd: String::new() }] }),
                            Control::Attach { id } => say(&mut w, Control::Attached { id, start_seq: 0, end_seq: 0, modes: String::new() }),
                            Control::Close { id } => {
                                log.lock().unwrap().push(id);
                                say(&mut w, Control::Ok);
                            }
                            other => say(&mut w, Control::Error { code: ErrorCode::BadRequest, message: format!("old ptyd: {other:?}"), detail: None }),
                        }
                    }
                }
            });
        }
    });
    let muyad = st.start_muyad(&st.ptyd_sock());
    let mut app = Client::welcomed(&st.muyad_sock(), muya_proto::PROTO_MAJOR, muya_proto::PROTO_MINOR);
    // First our own hello, refused; then the one the old ptyd said it speaks.
    assert_eq!(*hellos.lock().unwrap(), vec![(muya_proto::PROTO_MAJOR, muya_proto::PROTO_MINOR), (OLD_MAJOR, 0)]);
    let status = app.rpc(1, "upgrade.status", "{}");
    assert_eq!(status["ptyd_compat"], true);
    assert_eq!(status["restart_needed"], true);
    assert_eq!(status["ptyd"]["build"], "old-ptyd");
    assert_eq!(status["ptyd"]["major"], OLD_MAJOR);
    assert_eq!(status["ptyd_required"]["major"], muya_proto::PROTO_MAJOR);
    assert_eq!(status["sessions"][0]["id"], 5);
    // The session is listed and usable through the compat link.
    assert_eq!(app.sessions().iter().map(|s| s.id).collect::<Vec<_>>(), vec![5]);

    app.send(Control::Upgrade);
    let (plan, ptyd_restarting) = app.control(|c| match c {
        Control::Upgrading { plan, ptyd_restarting } => Some((plan.clone(), *ptyd_restarting)),
        _ => None,
    });
    assert!(!ptyd_restarting, "a ptyd this old cannot be told to restart");
    assert_eq!(plan.iter().map(|s| s.id).collect::<Vec<_>>(), vec![5]);
    assert_eq!(*closed.lock().unwrap(), vec![5]);
    assert!(st.exited(muyad, Duration::from_secs(10)).expect("muyad exits").success());
}

/// Connects to a daemon that was just started: the socket file can exist before the daemon accepts (a busy machine), so a refused
/// connection is retried for up to 20 s instead of failing the test.
fn connect_retry(p: impl AsRef<std::path::Path>) -> std::os::unix::net::UnixStream {
    let end = std::time::Instant::now() + std::time::Duration::from_secs(20);
    loop {
        match std::os::unix::net::UnixStream::connect(p.as_ref()) {
            Ok(s) => return s,
            Err(e) if std::time::Instant::now() < end => {
                let _ = e;
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(e) => panic!("{}: {e}", p.as_ref().display()),
        }
    }
}

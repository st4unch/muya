//! `muya-ptyd` (PRD §5): owns PTY masters and their children, a bounded memory-only output ring
//! and a mode tracker per session, and fans output out to attached clients (muyad). It does no
//! VT parsing beyond the tracker, has no network, holds no secrets, writes no terminal content
//! to disk. muyad can crash and re-adopt every session (Faz 0 S4).
//!
//! Faz 0 rules applied here: IUTF8 on the slave after it is opened; no CLAUDE* variable reaches a
//! session; fixed-capacity ring; a slow or dead client is dropped, never waited for; peers are
//! checked once per connection and refused when they run inside one of our sessions.

pub mod ring;
pub mod tracker;

use muya_proto::{Control, Decoder, ErrorCode, Frame, Role, SessionInfo};
use ring::Ring;
use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tracker::ModeTracker;

/// A client that writes slower than this is dropped; it re-attaches and resyncs (PRD §5).
const CLIENT_WRITE_TIMEOUT: Duration = Duration::from_millis(500);

pub struct Client {
    out: Mutex<UnixStream>,
}

impl Client {
    pub fn send(&self, frame: &Frame) -> io::Result<()> {
        self.send_raw(&frame.encode())
    }
    fn send_raw(&self, bytes: &[u8]) -> io::Result<()> {
        self.out.lock().unwrap().write_all(bytes)
    }
}

struct SessionState {
    ring: Ring,
    tracker: ModeTracker,
    subs: Vec<Arc<Client>>,
    exited: Option<i32>,
    cols: u16,
    rows: u16,
}

pub struct Session {
    pub id: u64,
    pub pid: i32,
    /// The folder the session was started in.
    pub cwd: String,
    master: OwnedFd,
    state: Mutex<SessionState>,
}

impl Session {
    fn info(&self) -> SessionInfo {
        let st = self.state.lock().unwrap();
        SessionInfo {
            id: self.id,
            pid: self.pid,
            cols: st.cols,
            rows: st.rows,
            end_seq: st.ring.end(),
            exited: st.exited,
            cwd: self.cwd.clone(),
        }
    }

    fn write_input(&self, mut data: &[u8]) -> io::Result<()> {
        while !data.is_empty() {
            let n =
                unsafe { libc::write(self.master.as_raw_fd(), data.as_ptr().cast(), data.len()) };
            if n < 0 {
                let e = io::Error::last_os_error();
                if e.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(e);
            }
            data = &data[n as usize..];
        }
        Ok(())
    }

    fn set_size(&self, cols: u16, rows: u16) {
        let ws = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        unsafe { libc::ioctl(self.master.as_raw_fd(), libc::TIOCSWINSZ, &ws) };
        let mut st = self.state.lock().unwrap();
        (st.cols, st.rows) = (cols, rows);
    }
}

#[derive(Default)]
pub struct Daemon {
    sessions: Mutex<BTreeMap<u64, Arc<Session>>>,
    next_id: AtomicU64,
    pub build: String,
    /// Runs after an accepted `Upgrade` once its reply is written: the binary exits so launchd starts
    /// the new build. Unset (tests driving the library) = the daemon only ends its sessions.
    on_upgrade: std::sync::OnceLock<Box<dyn Fn() + Send + Sync>>,
}

impl Daemon {
    pub fn new(build: &str) -> Arc<Self> {
        Arc::new(Self {
            build: build.to_owned(),
            next_id: AtomicU64::new(1),
            ..Default::default()
        })
    }

    /// Installs what happens after an `Upgrade` (once).
    pub fn set_on_upgrade(&self, f: impl Fn() + Send + Sync + 'static) {
        let _ = self.on_upgrade.set(Box::new(f));
    }

    /// The sessions as the version-skew error and the upgrade plan list them (no Claude ids: ptyd
    /// does not know them; muyad adds them).
    fn live_sessions(&self) -> Vec<muya_proto::LiveSession> {
        self.sessions
            .lock()
            .unwrap()
            .values()
            .map(|s| {
                let i = s.info();
                muya_proto::LiveSession { id: i.id, pid: i.pid, cwd: i.cwd, claude_session_id: None, exited: i.exited }
            })
            .collect()
    }

    /// Session ids of every live child: peers inside these sessions are refused.
    pub fn session_sids(&self) -> Vec<i32> {
        self.sessions
            .lock()
            .unwrap()
            .values()
            .map(|s| s.pid)
            .collect()
    }

    pub fn spawn(
        self: &Arc<Self>,
        argv: &[String],
        cwd: &str,
        env: &[(String, String)],
        cols: u16,
        rows: u16,
    ) -> io::Result<(u64, i32)> {
        if argv.is_empty() {
            return Err(io::Error::other("empty argv"));
        }
        let (mut m, mut s) = (0, 0);
        let mut ws = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        if unsafe {
            libc::openpty(
                &mut m,
                &mut s,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut ws,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        let (master, slave) = unsafe { (OwnedFd::from_raw_fd(m), OwnedFd::from_raw_fd(s)) };
        unsafe {
            libc::fcntl(master.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC);
            // openpty already opened the slave (macOS resets tty settings on that first open),
            // so settings made now stick. IUTF8: Backspace erases a whole UTF-8 character (S3).
            let mut t: libc::termios = std::mem::zeroed();
            libc::tcgetattr(slave.as_raw_fd(), &mut t);
            t.c_iflag |= libc::IUTF8;
            libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &t);
        }
        // The app's own Claude markers must never reach a session (Faz 0 corpus finding).
        let env: Vec<(String, String)> = env
            .iter()
            .filter(|(k, _)| !k.starts_with("CLAUDE"))
            .cloned()
            .collect();
        let pid = spawn_session(argv, cwd, &env, &slave)?;
        drop(slave);
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let session = Arc::new(Session {
            id,
            pid,
            cwd: cwd.to_owned(),
            master,
            state: Mutex::new(SessionState {
                ring: Ring::default(),
                tracker: ModeTracker::default(),
                subs: Vec::new(),
                exited: None,
                cols,
                rows,
            }),
        });
        self.sessions.lock().unwrap().insert(id, session.clone());

        let pump = session.clone();
        std::thread::Builder::new()
            .name(format!("pty-{id}"))
            .spawn(move || pump_output(&pump))?;
        let waiter = session.clone();
        std::thread::Builder::new()
            .name(format!("wait-{id}"))
            .spawn(move || {
                let status = wait_exit_status(pid);
                let mut st = waiter.state.lock().unwrap();
                st.exited = Some(status);
                let frame = Frame::Control(Control::Exited {
                    id: waiter.id,
                    status,
                })
                .encode();
                st.subs.retain(|c| c.send_raw(&frame).is_ok());
            })?;
        Ok((id, pid))
    }

    fn get(&self, id: u64) -> Option<Arc<Session>> {
        self.sessions.lock().unwrap().get(&id).cloned()
    }

    fn close(&self, id: u64) -> bool {
        let Some(s) = self.sessions.lock().unwrap().remove(&id) else {
            return false;
        };
        let mut st = s.state.lock().unwrap();
        if st.exited.is_none() {
            unsafe { libc::killpg(s.pid, libc::SIGHUP) };
        }
        st.ring.wipe();
        st.subs.clear();
        true
    }

    /// Serves one client connection until it closes. `trusted` = the peer gate passed.
    pub fn serve(self: &Arc<Self>, stream: UnixStream) {
        muya_proto::tune_link(std::os::fd::AsRawFd::as_raw_fd(&stream));
        let _ = stream.set_write_timeout(Some(CLIENT_WRITE_TIMEOUT));
        let Ok(reader) = stream.try_clone() else {
            return;
        };
        let client = Arc::new(Client {
            out: Mutex::new(stream),
        });
        let mut reader = reader;
        let mut dec = Decoder::default();
        let mut buf = vec![0u8; 64 * 1024];
        let mut greeted = false;
        let mut role = Role::Muyad;
        let mut announced = 0u16;
        loop {
            let n = match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            dec.push(&buf[..n]);
            loop {
                let frame = match dec.next_frame() {
                    Ok(Some(f)) => f,
                    Ok(None) => break,
                    // A message this build does not know (a peer of another major, AC19): the frame
                    // was consumed whole, so the stream is still in step. Answer and carry on.
                    Err(muya_proto::DecodeError::Json(why)) if greeted => {
                        let _ = client.send(&error(ErrorCode::BadRequest, &format!("unknown message: {why}")));
                        continue;
                    }
                    Err(e) => {
                        let _ =
                            client.send(&error(ErrorCode::BadRequest, &format!("bad frame: {e}")));
                        return;
                    }
                };
                if !greeted {
                    let Frame::Control(hello) = &frame else {
                        return;
                    };
                    let reply = muya_proto::negotiate_with(hello, &self.build, || self.live_sessions());
                    let ok = matches!(reply, Control::Welcome { .. })
                        && matches!(
                            hello,
                            Control::Hello {
                                role: Role::Muyad | Role::Muyactl,
                                ..
                            }
                        );
                    let reply = if matches!(reply, Control::Welcome { .. }) && !ok {
                        Control::Error {
                            code: ErrorCode::Refused,
                            message: "ptyd serves muyad only".into(),
                            detail: None,
                        }
                    } else {
                        reply
                    };
                    let _ = client.send(&Frame::Control(reply));
                    if !ok {
                        return;
                    }
                    greeted = true;
                    announced = muya_proto::hello_minor(hello);
                    if let Control::Hello { role: r, .. } = hello {
                        role = *r;
                    }
                    continue;
                }
                if let Frame::Control(c) = &frame
                    && let Some(refusal) = muya_proto::needs_minor(c, announced)
                {
                    let _ = client.send(&Frame::Control(refusal));
                    continue;
                }
                if matches!(frame, Frame::Control(Control::Upgrade)) {
                    self.upgrade(&client, role);
                    continue;
                }
                if self.handle(&client, frame).is_err() {
                    return;
                }
            }
        }
    }

    /// `Upgrade` (muyad only): ends every session (SIGHUP to its group, ring wiped), answers with the
    /// list that was running, then hands over to `on_upgrade` (exit -> launchd starts the new build).
    fn upgrade(&self, client: &Arc<Client>, role: Role) {
        if role != Role::Muyad {
            let _ = client.send(&error(ErrorCode::BadRequest, "only muyad restarts ptyd"));
            return;
        }
        let plan = self.live_sessions();
        let ids: Vec<u64> = plan.iter().map(|s| s.id).collect();
        for id in ids {
            self.close(id);
        }
        let _ = client.send(&Frame::Control(Control::Upgrading { plan, ptyd_restarting: true }));
        if let Some(f) = self.on_upgrade.get() {
            f();
        }
    }

    fn handle(self: &Arc<Self>, client: &Arc<Client>, frame: Frame) -> io::Result<()> {
        let reply = match frame {
            Frame::Input { session, data } => {
                if let Some(s) = self.get(session) {
                    let _ = s.write_input(&data);
                }
                return Ok(());
            }
            Frame::Output { .. } => error(ErrorCode::BadRequest, "clients do not send output"),
            Frame::Control(c) => match c {
                Control::Spawn {
                    argv,
                    cwd,
                    env,
                    cols,
                    rows,
                } => match self.spawn(&argv, &cwd, &env, cols, rows) {
                    Ok((id, pid)) => Frame::Control(Control::Spawned { id, pid }),
                    Err(e) => error(ErrorCode::Internal, &format!("spawn: {e}")),
                },
                Control::List => {
                    let sessions = self
                        .sessions
                        .lock()
                        .unwrap()
                        .values()
                        .map(|s| s.info())
                        .collect();
                    Frame::Control(Control::Sessions { sessions })
                }
                Control::Attach { id } => {
                    let Some(s) = self.get(id) else {
                        return client.send(&error(ErrorCode::NoSuchSession, "no such session"));
                    };
                    // Header, ring and subscription under one lock: no gap, no duplicate.
                    let mut st = s.state.lock().unwrap();
                    client.send(&Frame::Control(Control::Attached {
                        id,
                        start_seq: st.ring.start,
                        end_seq: st.ring.end(),
                        modes: st.tracker.restore_sequence(),
                    }))?;
                    for f in muya_proto::output_frames(id, st.ring.start, &st.ring.contents()) {
                        client.send(&f)?;
                    }
                    if let Some(status) = st.exited {
                        client.send(&Frame::Control(Control::Exited { id, status }))?;
                    }
                    st.subs.push(client.clone());
                    return Ok(());
                }
                Control::Resize { id, cols, rows } => match self.get(id) {
                    Some(s) => {
                        s.set_size(cols, rows);
                        Frame::Control(Control::Ok)
                    }
                    None => error(ErrorCode::NoSuchSession, "no such session"),
                },
                Control::Resync { id } => match self.get(id) {
                    Some(s) => {
                        // Jiggle the size: TUIs repaint on SIGWINCH (Faz 0 S4 resync).
                        let (cols, rows) = {
                            let st = s.state.lock().unwrap();
                            (st.cols, st.rows)
                        };
                        s.set_size(cols, rows.saturating_sub(1).max(1));
                        std::thread::sleep(Duration::from_millis(30));
                        s.set_size(cols, rows);
                        Frame::Control(Control::Ok)
                    }
                    None => error(ErrorCode::NoSuchSession, "no such session"),
                },
                Control::Signal { id, signal } => match self.get(id) {
                    Some(s) => {
                        unsafe { libc::killpg(s.pid, signal) };
                        Frame::Control(Control::Ok)
                    }
                    None => error(ErrorCode::NoSuchSession, "no such session"),
                },
                Control::Close { id } => match self.close(id) {
                    true => Frame::Control(Control::Ok),
                    false => error(ErrorCode::NoSuchSession, "no such session"),
                },
                _ => error(ErrorCode::BadRequest, "unexpected message"),
            },
        };
        client.send(&reply)
    }
}

fn error(code: ErrorCode, message: &str) -> Frame {
    Frame::Control(Control::Error {
        code,
        message: message.to_owned(),
        detail: None,
    })
}

fn pump_output(s: &Session) {
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = unsafe { libc::read(s.master.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
        if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
            continue;
        }
        if n <= 0 {
            return; // EIO once the child side is closed
        }
        let data = &buf[..n as usize];
        let mut st = s.state.lock().unwrap();
        let seq = st.ring.end();
        st.ring.push(data);
        st.tracker.feed(data);
        let frame = Frame::Output {
            session: s.id,
            seq,
            data: data.to_vec(),
        }
        .encode();
        st.subs.retain(|c| c.send_raw(&frame).is_ok());
    }
}

// macOS posix_spawn extensions missing from the libc crate.
const POSIX_SPAWN_SETSID: libc::c_short = 0x0400;
unsafe extern "C" {
    fn posix_spawn_file_actions_addchdir_np(actions: *mut libc::posix_spawn_file_actions_t, path: *const libc::c_char) -> libc::c_int;
}

/// Starts a session leader on the PTY slave with posix_spawn and POSIX_SPAWN_CLOEXEC_DEFAULT:
/// the child gets exactly stdin/stdout/stderr = the slave and nothing else. A fork-based spawn
/// let descriptors created concurrently by other threads (sockets, other sessions' PTY masters)
/// leak into sessions — on macOS FD_CLOEXEC is set only after a descriptor is created (found by
/// a muya-core test where a closed socket kept accepting). Signal dispositions are reset and the
/// mask cleared (an ignored SIGPIPE would otherwise survive exec).
fn spawn_session(argv: &[String], cwd: &str, env: &[(String, String)], slave: &OwnedFd) -> io::Result<i32> {
    use std::ffi::CString;
    let cstr = |s: &str| CString::new(s).map_err(|_| io::Error::other("NUL in argument"));
    // The program is started through this same binary (`muya-ptyd --exec-with-ctty -- argv...`): on macOS the child
    // of posix_spawn(SETSID) does not get a controlling terminal by merely having the slave on fd 0 (tpgid 0: no job
    // control, and no SIGWINCH after a resize, so full-screen programs such as Claude kept the width they started with).
    // The helper is the session leader: it claims the tty explicitly (TIOCSCTTY) and then execs the real program, so the
    // pid, argv and environment the program sees do not change.
    let exe = std::env::current_exe()?;
    let exe_c = cstr(&exe.to_string_lossy())?;
    let mut argv_c: Vec<CString> = vec![exe_c.clone(), cstr("--exec-with-ctty")?];
    for a in argv {
        argv_c.push(cstr(a)?);
    }
    let mut tty_buf = [0 as libc::c_char; 256];
    if unsafe { libc::ttyname_r(slave.as_raw_fd(), tty_buf.as_mut_ptr(), tty_buf.len()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let tty = unsafe { std::ffi::CStr::from_ptr(tty_buf.as_ptr()) }.to_owned();
    let env_c: Vec<CString> = env.iter().map(|(k, v)| cstr(&format!("{k}={v}"))).collect::<io::Result<_>>()?;
    let mut argv_p: Vec<*mut libc::c_char> = argv_c.iter().map(|c| c.as_ptr() as *mut _).collect();
    argv_p.push(std::ptr::null_mut());
    let mut env_p: Vec<*mut libc::c_char> = env_c.iter().map(|c| c.as_ptr() as *mut _).collect();
    env_p.push(std::ptr::null_mut());
    let cwd_c = cstr(cwd)?;
    unsafe {
        let mut attr: libc::posix_spawnattr_t = std::ptr::null_mut();
        let mut acts: libc::posix_spawn_file_actions_t = std::ptr::null_mut();
        libc::posix_spawnattr_init(&mut attr);
        libc::posix_spawn_file_actions_init(&mut acts);
        let flags = POSIX_SPAWN_SETSID | libc::POSIX_SPAWN_CLOEXEC_DEFAULT as libc::c_short | libc::POSIX_SPAWN_SETSIGDEF as libc::c_short | libc::POSIX_SPAWN_SETSIGMASK as libc::c_short;
        libc::posix_spawnattr_setflags(&mut attr, flags);
        let mut all: libc::sigset_t = std::mem::zeroed();
        libc::sigfillset(&mut all);
        libc::posix_spawnattr_setsigdefault(&mut attr, &all);
        let mut none: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut none);
        libc::posix_spawnattr_setsigmask(&mut attr, &none);
        libc::posix_spawn_file_actions_addopen(&mut acts, 0, tty.as_ptr(), libc::O_RDWR, 0);
        libc::posix_spawn_file_actions_adddup2(&mut acts, 0, 1);
        libc::posix_spawn_file_actions_adddup2(&mut acts, 0, 2);
        posix_spawn_file_actions_addchdir_np(&mut acts, cwd_c.as_ptr());
        let mut pid: libc::pid_t = 0;
        let rc = libc::posix_spawn(&mut pid, exe_c.as_ptr(), &acts, &attr, argv_p.as_ptr(), env_p.as_ptr());
        libc::posix_spawn_file_actions_destroy(&mut acts);
        libc::posix_spawnattr_destroy(&mut attr);
        if rc != 0 {
            return Err(io::Error::from_raw_os_error(rc));
        }
        Ok(pid)
    }
}

/// Blocks until `pid` exits: its exit code, or 128 + signal.
fn wait_exit_status(pid: i32) -> i32 {
    let mut status = 0;
    loop {
        let r = unsafe { libc::waitpid(pid, &mut status, 0) };
        if r == pid {
            break;
        }
        if r < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return -1;
        }
    }
    if libc::WIFEXITED(status) { libc::WEXITSTATUS(status) } else if libc::WIFSIGNALED(status) { 128 + libc::WTERMSIG(status) } else { -1 }
}

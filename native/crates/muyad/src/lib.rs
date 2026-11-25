//! `muyad` (PRD §5): one libghostty-vt terminal per ptyd session (authoritative state), re-adopted
//! from ptyd's ring + mode header whenever muyad starts; serves the app (and `muyactl`).
//!
//! Re-adopt (Faz 0 S4): attach -> replay the ring with terminal replies suppressed -> apply the
//! tracked modes -> ask ptyd for a SIGWINCH resync so programs that drew parts of their screen
//! long ago repaint them.

pub mod actor;
pub mod bridge_host;
pub mod broker_host;
pub mod prompt_watch;
pub mod rpc;
pub mod rpc_agents;
pub mod rpc_bridge;
pub mod rpc_git;
pub mod rpc_resources;
pub mod rpc_term_history;
pub mod rpc_vault_notes;
pub mod vault_idle;
pub mod scheduler_host;
pub mod ssh_connect;
pub mod switchover_host;
pub mod terminals;

use actor::Cmd;
use muya_proto::{Control, Decoder, ErrorCode, Frame, Incompat, LiveSession, Role, SessionInfo, Version};
use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Entry {
    tx: Sender<Cmd>,
    info: SessionInfo,
    /// Set while the ring is being replayed: (end_seq of the ring, modes to apply after it).
    replay: Option<(u64, String)>,
}

/// ptyd cannot be reached (nothing listens on its socket): in practice its LaunchAgent is not
/// approved in System Settings > Login Items (PRD AC21). Carried inside an `io::Error`; the
/// request handlers turn it into [`ErrorCode::NotApproved`].
#[derive(Debug)]
pub struct PtydUnavailable(pub String);

impl std::fmt::Display for PtydUnavailable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "muya-ptyd is not reachable ({}). Approve Muya in System Settings > General > Login Items.", self.0)
    }
}

impl std::error::Error for PtydUnavailable {}

/// True when `e` is a [`PtydUnavailable`].
pub fn is_ptyd_unavailable(e: &io::Error) -> bool {
    e.get_ref().is_some_and(|inner| inner.is::<PtydUnavailable>())
}

fn unavailable(why: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, PtydUnavailable(why.to_string()))
}

pub struct Muyad {
    /// The write side of the ptyd link; `None` until ptyd was reachable (see [`Muyad::ensure_link`]).
    to_ptyd: Mutex<Option<UnixStream>>,
    replies: Mutex<Option<Receiver<Control>>>,
    ptyd_path: std::path::PathBuf,
    /// Serializes link attempts.
    link_lock: Mutex<()>,
    request_lock: Mutex<()>,
    sessions: Mutex<BTreeMap<u64, Entry>>,
    pub build: String,
    /// Wall time of the last re-adopt, for `muyactl status`.
    pub readopt_ms: Mutex<u128>,
    /// Attached app clients (role App), the targets of [`Muyad::emit_event`].
    apps: Mutex<Vec<(u64, Arc<ClientOut>)>>,
    next_client: std::sync::atomic::AtomicU64,
    /// Core-logic calls (`Control::Rpc`); set once at startup, before the first client is served.
    rpc: std::sync::OnceLock<Arc<rpc::Rpc>>,
    /// Working directories of the sessions this daemon spawned: the roots the git/plan Rpc methods
    /// accept (a re-adopted session is unknown until the app pushes `workspace.set_roots`).
    spawn_cwds: Mutex<Vec<String>>,
    /// Capture-file token of each spawned session (`pty-<n>`, see `statusline`), by session id.
    status_tokens: Mutex<std::collections::HashMap<u64, String>>,
    spawn_count: std::sync::atomic::AtomicU64,
    /// What ptyd announced in its welcome; `None` while unlinked.
    ptyd_version: Mutex<Option<Version>>,
    /// Set when ptyd's major differs from ours and the link runs in compatibility mode ("later",
    /// AC19): what ptyd reported (its versions and sessions). The app is told through `upgrade.status`.
    ptyd_incompat: Mutex<Option<Incompat>>,
    /// Where the resume plan is kept across the restart ("restart now", AC19).
    state_dir: Mutex<Option<std::path::PathBuf>>,
    /// Finds the Claude session id of each live session; defaults to `claude agents --json`.
    claude_ids: std::sync::OnceLock<ClaudeIds>,
    /// Runs after an accepted `Upgrade` once its reply is written (the binary exits so launchd
    /// starts the new build). Unset (tests driving the library) = sessions end, the process stays.
    on_upgrade: std::sync::OnceLock<Box<dyn Fn() + Send + Sync>>,
    /// An upgrade is under way: a second one is refused, ptyd going away is expected.
    upgrading: std::sync::atomic::AtomicBool,
    /// Permission prompts while no app is attached (AC12); unset = off.
    prompt_watch: std::sync::OnceLock<Arc<prompt_watch::PromptWatch>>,
    /// Names of the terminals the MCP broker opened (`open_terminal`), by session id.
    term_names: Mutex<std::collections::HashMap<u64, String>>,
}

/// Maps a session id to the Claude session id running inside it.
pub type ClaudeIds = Box<dyn Fn(&[SessionInfo]) -> BTreeMap<u64, (String, Option<String>)> + Send + Sync>;

/// File name of the resume plan inside the state dir.
pub const RESUME_PLAN_FILE: &str = "resume-plan.json";

impl Muyad {
    /// Connects to ptyd, says hello, re-adopts every live session.
    pub fn connect(ptyd: &std::path::Path, build: &str) -> io::Result<Arc<Self>> {
        let me = Self::offline(ptyd, build);
        me.ensure_link()?;
        Ok(me)
    }

    /// A muyad that is not linked to ptyd yet. Every request that needs ptyd tries to link first
    /// and answers [`PtydUnavailable`] (-> [`ErrorCode::NotApproved`]) while ptyd is unreachable,
    /// so approving the LaunchAgent later works without restarting muyad (AC21).
    pub fn offline(ptyd: &std::path::Path, build: &str) -> Arc<Self> {
        Arc::new(Self {
            to_ptyd: Mutex::new(None),
            replies: Mutex::new(None),
            ptyd_path: ptyd.to_owned(),
            link_lock: Mutex::new(()),
            request_lock: Mutex::new(()),
            sessions: Mutex::new(BTreeMap::new()),
            build: build.to_owned(),
            readopt_ms: Mutex::new(0),
            apps: Mutex::new(Vec::new()),
            next_client: std::sync::atomic::AtomicU64::new(1),
            rpc: std::sync::OnceLock::new(),
            spawn_cwds: Mutex::new(Vec::new()),
            status_tokens: Mutex::new(Default::default()),
            spawn_count: std::sync::atomic::AtomicU64::new(1),
            ptyd_version: Mutex::new(None),
            ptyd_incompat: Mutex::new(None),
            state_dir: Mutex::new(None),
            claude_ids: std::sync::OnceLock::new(),
            on_upgrade: std::sync::OnceLock::new(),
            upgrading: std::sync::atomic::AtomicBool::new(false),
            prompt_watch: std::sync::OnceLock::new(),
            term_names: Mutex::new(Default::default()),
        })
    }

    /// Whether the ptyd link is up.
    pub fn is_linked(&self) -> bool {
        self.to_ptyd.lock().unwrap().is_some()
    }

    /// Links to ptyd if not yet: connect, hello, re-adopt every live session. `PtydUnavailable`
    /// when nothing listens on ptyd's socket.
    pub fn ensure_link(self: &Arc<Self>) -> io::Result<()> {
        let _attempt = self.link_lock.lock().unwrap();
        if self.is_linked() {
            return Ok(());
        }
        let started = std::time::Instant::now();
        // First with our own version; when ptyd's major differs it answers a typed error that names the
        // hello it still understands, and we link in compatibility mode with that ("later", AC19). The
        // link only ever carries the messages every minor knows (spawn/list/attach/resize/resync/
        // signal/close + raw input), so it is safe by construction.
        let mut hello = muya_proto::hello(Role::Muyad, &self.build);
        for attempt in 0..2 {
            let mut stream = UnixStream::connect(&self.ptyd_path).map_err(|e| unavailable(e))?;
            muya_proto::tune_link(std::os::fd::AsRawFd::as_raw_fd(&stream));
            stream.write_all(&Frame::Control(hello.clone()).encode())?;
            let reader = stream.try_clone()?;
            let (reply_tx, reply_rx) = channel();
            *self.replies.lock().unwrap() = Some(reply_rx);
            *self.to_ptyd.lock().unwrap() = Some(stream);
            let weak = Arc::downgrade(self);
            std::thread::Builder::new().name("ptyd-reader".into()).spawn(move || read_ptyd(reader, weak, reply_tx))?;
            let welcome = self.replies.lock().unwrap().as_ref().map(|r| r.recv_timeout(Duration::from_secs(5)));
            // Not linked after all: forget the half-open link.
            let forget = || {
                *self.to_ptyd.lock().unwrap() = None;
                *self.replies.lock().unwrap() = None;
            };
            match welcome {
                Some(Ok(Control::Welcome { major, minor, server_build })) => {
                    *self.ptyd_version.lock().unwrap() = Some(Version { major, minor, build: server_build });
                    if attempt == 0 {
                        *self.ptyd_incompat.lock().unwrap() = None;
                    }
                    break;
                }
                Some(Ok(Control::Error { code: ErrorCode::Incompatible, detail: Some(d), .. })) if attempt == 0 => {
                    forget();
                    hello = Control::Hello { major: d.speak.major, minor: d.speak.minor, role: Role::Muyad, build: self.build.clone() };
                    eprintln!("muyad: ptyd {} speaks protocol {}.{}; linking in compatibility mode", d.daemon.build, d.daemon.major, d.daemon.minor);
                    *self.ptyd_incompat.lock().unwrap() = Some(*d);
                }
                other => {
                    forget();
                    return Err(match other {
                        Some(Ok(other)) => io::Error::other(format!("ptyd refused: {other:?}")),
                        _ => io::Error::other("ptyd did not answer hello"),
                    });
                }
            }
        }
        let Control::Sessions { sessions } = self.request_linked(Control::List)? else { return Err(io::Error::other("bad list reply")) };
        // Pipelined: start every actor, send every Attach in one write, then collect the
        // replies. One round trip per session made re-adopting 100 sessions take ~4 s
        // under load (muya-load).
        let ids: Vec<u64> = sessions.iter().map(|s| s.id).collect();
        for info in sessions {
            self.start_actor(info, true)?;
        }
        self.attach_all(&ids)?;
        *self.readopt_ms.lock().unwrap() = started.elapsed().as_millis();
        Ok(())
    }

    /// Installs the handler of `Control::Rpc` (once).
    pub fn set_rpc(&self, r: rpc::Rpc) {
        let _ = self.rpc.set(Arc::new(r));
    }

    /// One request to ptyd and its reply (serialized: ptyd answers in order).
    pub fn request(self: &Arc<Self>, c: Control) -> io::Result<Control> {
        self.ensure_link()?;
        self.request_linked(c)
    }

    /// [`Muyad::request`] on an established link (also used while linking, which holds `link_lock`).
    fn request_linked(&self, c: Control) -> io::Result<Control> {
        let _g = self.request_lock.lock().unwrap();
        self.write_ptyd(&Frame::Control(c).encode())?;
        let replies = self.replies.lock().unwrap();
        let replies = replies.as_ref().ok_or_else(|| unavailable("link lost"))?;
        replies.recv_timeout(Duration::from_secs(10)).map_err(|_| io::Error::other("ptyd did not answer"))
    }

    fn write_ptyd(&self, bytes: &[u8]) -> io::Result<()> {
        self.to_ptyd.lock().unwrap().as_mut().ok_or_else(|| unavailable("not linked"))?.write_all(bytes)
    }

    fn send_input(&self, session: u64, data: Vec<u8>) {
        if !data.is_empty() {
            let _ = self.write_ptyd(&Frame::Input { session, data }.encode());
        }
    }

    /// Starts the actor for a session, then attaches to ptyd (header and ring arrive on the
    /// reader thread, in order, after the entry exists).
    fn adopt(self: &Arc<Self>, info: SessionInfo, replaying: bool) -> io::Result<()> {
        let id = info.id;
        self.start_actor(info, replaying)?;
        self.attach_all(&[id])
    }

    /// Attaches to many sessions with one write; ptyd answers in order.
    fn attach_all(&self, ids: &[u64]) -> io::Result<()> {
        let _g = self.request_lock.lock().unwrap();
        let mut batch = Vec::new();
        for id in ids {
            batch.extend(Frame::Control(Control::Attach { id: *id }).encode());
        }
        self.write_ptyd(&batch)?;
        let replies = self.replies.lock().unwrap();
        let replies = replies.as_ref().ok_or_else(|| unavailable("link lost"))?;
        for id in ids {
            match replies.recv_timeout(Duration::from_secs(10)) {
                Ok(Control::Attached { .. }) => {}
                Ok(other) => return Err(io::Error::other(format!("attach {id}: {other:?}"))),
                Err(_) => return Err(io::Error::other(format!("attach {id}: ptyd did not answer"))),
            }
        }
        Ok(())
    }

    /// Creates the session's actor and registry entry (no attach yet).
    fn start_actor(self: &Arc<Self>, info: SessionInfo, replaying: bool) -> io::Result<()> {
        let (tx, rx) = channel();
        let (id, cols, rows) = (info.id, info.cols, info.rows);
        let weak = Arc::downgrade(self);
        std::thread::Builder::new().name(format!("session-{id}")).spawn(move || {
            let to_pty = move |data: &[u8]| {
                if let Some(me) = weak.upgrade() {
                    me.send_input(id, data.to_vec());
                }
            };
            actor::run(id, cols, rows, rx, to_pty, replaying);
        })?;
        if let Some(status) = info.exited {
            let _ = tx.send(Cmd::Exited(status));
        }
        self.watch_prompts(&tx);
        self.sessions.lock().unwrap().insert(id, Entry { tx, info, replay: None });
        Ok(())
    }

    /// Hooks the prompt watcher into a session as a screen-only sink (no output frames, so no cost
    /// while the screen does not change).
    fn watch_prompts(&self, tx: &Sender<Cmd>) {
        let Some(watch) = self.prompt_watch.get() else { return };
        let watch = watch.clone();
        let sink: actor::Sink = Arc::new(move |f: &Frame| {
            if let Frame::Control(Control::Screen { id, state }) = f {
                watch.screen(*id, state);
            }
            true
        });
        let (reply, _) = channel();
        let _ = tx.send(Cmd::Detach { key: usize::MAX, sink, reply });
    }

    /// Turns on permission-prompt handling for the sessions that exist now and every later one.
    pub fn enable_prompt_watch(self: &Arc<Self>, cfg: prompt_watch::PromptConfig) {
        let (w1, w2) = (Arc::downgrade(self), Arc::downgrade(self));
        let watch = prompt_watch::PromptWatch::new(
            cfg,
            move |id, data| {
                if let Some(me) = w1.upgrade() {
                    me.send_input(id, data);
                }
            },
            move || w2.upgrade().is_none_or(|me| !me.apps.lock().unwrap().is_empty()),
        );
        if self.prompt_watch.set(watch).is_err() {
            return;
        }
        let existing: Vec<(u64, Sender<Cmd>)> = self.sessions.lock().unwrap().iter().map(|(i, e)| (*i, e.tx.clone())).collect();
        for (_, tx) in existing {
            self.watch_prompts(&tx);
        }
    }

    fn actor(&self, id: u64) -> Option<Sender<Cmd>> {
        self.sessions.lock().unwrap().get(&id).map(|e| e.tx.clone())
    }

    fn ask<T>(&self, id: u64, make: impl FnOnce(Sender<T>) -> Cmd) -> Option<T> {
        let (tx, rx) = channel();
        self.actor(id)?.send(make(tx)).ok()?;
        rx.recv_timeout(Duration::from_secs(5)).ok()
    }

    pub fn sessions(&self) -> Vec<SessionInfo> {
        self.sessions.lock().unwrap().values().map(|e| e.info.clone()).collect()
    }

    /// Types `text` into a live session and submits it: Enter follows 150 ms later as its own key press,
    /// because one chunk would let a TUI take the Enter for part of a paste (what the app's "Scheduled
    /// Prompt" does too). Err = the session is not running.
    pub fn type_line(self: &Arc<Self>, id: u64, text: &str) -> Result<(), String> {
        let live = self.sessions.lock().unwrap().get(&id).map(|e| e.info.exited.is_none());
        match live {
            Some(true) => {}
            _ => return Err("not running".into()),
        }
        self.send_input(id, text.as_bytes().to_vec());
        let me = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(150));
            me.send_input(id, b"\r".to_vec());
        });
        Ok(())
    }

    /// Working directories of the sessions spawned through this daemon (bounded list).
    /// The status-capture token (`pty-<n>`) of a session this daemon spawned.
    pub fn status_token(&self, id: u64) -> Option<String> {
        self.status_tokens.lock().unwrap().get(&id).cloned()
    }

    pub fn spawn_cwds(&self) -> Vec<String> {
        self.spawn_cwds.lock().unwrap().clone()
    }

    /// Session ids of every live session (peers inside them are refused on the client socket).
    pub fn session_sids(&self) -> Vec<i32> {
        self.sessions.lock().unwrap().values().map(|e| e.info.pid).collect()
    }

    pub fn spawn(self: &Arc<Self>, argv: Vec<String>, cwd: String, env: Vec<(String, String)>, cols: u16, rows: u16) -> io::Result<(u64, i32)> {
        let (argv, mut env) = session_command(argv, env);
        // Per-terminal zsh history (term_history) and the Claude status-line capture file, as the Tauri
        // app's pty.rs sets them up. Both are optional: a failure leaves the terminal as it was.
        let n = self.spawn_count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let key = format!("t{}-{n}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs()));
        let shell = argv.first().cloned().unwrap_or_default();
        let name = std::path::Path::new(&cwd).file_name().map(|s| s.to_string_lossy().into_owned());
        env.extend(muya_core::term_history::spawn_env(&key, name.as_deref(), Some(&cwd), &shell));
        crate::rpc_resources::ensure_statusline();
        let token = format!("pty-{n}");
        let tapped = muya_core::statusline::status_file_for(&token);
        if let Some(f) = &tapped {
            env.push(("MUYA_STATUS_FILE".into(), f.to_string_lossy().into_owned()));
        }
        match self.request(Control::Spawn { argv, cwd: cwd.clone(), env, cols, rows })? {
            Control::Spawned { id, pid } => {
                if tapped.is_some() {
                    self.status_tokens.lock().unwrap().insert(id, token);
                }
                self.adopt(SessionInfo { id, pid, cols, rows, end_seq: 0, exited: None, cwd: cwd.clone() }, false)?;
                {
                    let mut cwds = self.spawn_cwds.lock().unwrap();
                    if !cwds.contains(&cwd) && cwds.len() < 256 {
                        cwds.push(cwd);
                    }
                }
                Ok((id, pid))
            }
            Control::Error { message, .. } => Err(io::Error::other(message)),
            other => Err(io::Error::other(format!("{other:?}"))),
        }
    }

    /// Sends an event to every attached app client. Err when no app is attached (the event is
    /// dropped; the broker tells the agent). Clients whose socket fails are forgotten.
    pub fn emit_event(&self, name: &str, payload: &serde_json::Value) -> Result<(), String> {
        let bytes = Frame::Control(Control::Event { name: name.to_owned(), payload: payload.to_string() })
            .try_encode()
            .map_err(|n| format!("event {name} is too large ({n} bytes, limit {})", muya_proto::MAX_FRAME))?;
        fan_out(&self.apps, &bytes)
    }

    /// Serves one app/muyactl connection (peer already verified).
    pub fn serve(self: &Arc<Self>, stream: UnixStream) {
        let mut registered = None;
        self.serve_inner(stream, &mut registered);
        if let Some(cid) = registered {
            self.apps.lock().unwrap().retain(|(id, _)| *id != cid);
        }
    }

    fn serve_inner(self: &Arc<Self>, stream: UnixStream, registered: &mut Option<u64>) {
        let Ok(mut reader) = stream.try_clone() else { return };
        muya_proto::tune_link(std::os::fd::AsRawFd::as_raw_fd(&stream));
        let _ = stream.set_write_timeout(Some(Duration::from_millis(500)));
        let out = ClientOut::new(stream);
        let send = |f: &Frame| out.write(&f.encode());
        let mut dec = Decoder::default();
        let mut buf = vec![0u8; 64 * 1024];
        let mut role: Option<Role> = None;
        let mut announced = 0u16;
        // Running rpc calls of this connection, so `RpcCancel` can stop one.
        let cancels: Arc<Mutex<std::collections::HashMap<u64, Arc<std::sync::atomic::AtomicBool>>>> = Arc::default();
        loop {
            let n = match reader.read(&mut buf) {
                Ok(0) | Err(_) => return,
                Ok(n) => n,
            };
            dec.push(&buf[..n]);
            loop {
                let frame = match dec.next_frame() {
                    Ok(Some(f)) => f,
                    Ok(None) => break,
                    // A message this build does not know (a peer of another major, AC19): the frame was
                    // consumed whole, so the stream is still in step. Answer and carry on.
                    Err(muya_proto::DecodeError::Json(why)) if role.is_some() => {
                        if !send(&Frame::Control(Control::Error { code: ErrorCode::BadRequest, message: format!("unknown message: {why}"), detail: None })) {
                            return;
                        }
                        continue;
                    }
                    Err(_) => return,
                };
                let Some(r) = role else {
                    let Frame::Control(hello) = &frame else { return };
                    let reply = muya_proto::negotiate_with(hello, &self.build, || self.live_sessions());
                    let allowed = matches!(hello, Control::Hello { role: Role::App | Role::Muyactl, .. });
                    let welcome = matches!(reply, Control::Welcome { .. });
                    send(&Frame::Control(if welcome && !allowed {
                        Control::Error { code: ErrorCode::Refused, message: "this socket serves the app and muyactl".into(), detail: None }
                    } else {
                        reply
                    }));
                    if !(welcome && allowed) {
                        return;
                    }
                    announced = muya_proto::hello_minor(hello);
                    if let Control::Hello { role: r, .. } = hello {
                        role = Some(*r);
                        if *r == Role::App {
                            let cid = self.next_client.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                            out.start_event_writer();
                            self.apps.lock().unwrap().push((cid, out.clone()));
                            *registered = Some(cid);
                        }
                    }
                    continue;
                };
                // A connection that announced an older minor never gets a newer message (AC19 "later").
                if let Frame::Control(c) = &frame
                    && let Some(refusal) = muya_proto::needs_minor(c, announced)
                {
                    if !send(&Frame::Control(refusal)) {
                        return;
                    }
                    continue;
                }
                let reply = match (r, frame) {
                    (_, Frame::Control(Control::Upgrade)) if r != Role::App => Some(Control::Error {
                        code: ErrorCode::BadRequest,
                        message: "only the app restarts the sessions".into(),
                        detail: None,
                    }),
                    (_, Frame::Control(Control::Upgrade)) => Some(self.upgrade()),
                    (_, Frame::Control(Control::List)) => Some(Control::Sessions { sessions: self.sessions() }),
                    #[cfg(debug_assertions)]
                    (_, Frame::Control(Control::Inspect { id })) => match (
                        self.ask(id, |reply| Cmd::Modes { reply }),
                        self.ask(id, |reply| Cmd::Fingerprint { reply }),
                        self.ask(id, |reply| Cmd::Screen { reply }),
                    ) {
                        (Some(modes), Some(fingerprint), Some(screen)) => Some(Control::Inspected { modes, fingerprint, screen }),
                        _ => Some(no_session()),
                    },
                    (Role::Muyactl, _) => Some(Control::Error { code: ErrorCode::BadRequest, message: "muyactl is read-only".into(), detail: None }),
                    (_, Frame::Input { session, data }) => {
                        self.send_input(session, data);
                        None
                    }
                    (_, Frame::Control(Control::Rpc { req, method, params })) => {
                        self.start_rpc(req, method, params, &out, &cancels);
                        None
                    }
                    (_, Frame::Control(Control::RpcCancel { req })) => {
                        if let Some(flag) = cancels.lock().unwrap().get(&req) {
                            flag.store(true, std::sync::atomic::Ordering::Relaxed);
                        }
                        Some(Control::Ok)
                    }
                    (_, Frame::Control(c)) => Some(self.handle(c, &out)),
                    (_, Frame::Output { .. }) => Some(Control::Error { code: ErrorCode::BadRequest, message: "clients do not send output".into(), detail: None }),
                };
                if let Some(c) = reply
                    && !send(&Frame::Control(c))
                {
                    return;
                }
            }
        }
    }

    /// Runs an rpc call on its own thread and writes the `RpcReply` when it is done.
    fn start_rpc(
        self: &Arc<Self>,
        req: u64,
        method: String,
        params: String,
        out: &Arc<ClientOut>,
        cancels: &Arc<Mutex<std::collections::HashMap<u64, Arc<std::sync::atomic::AtomicBool>>>>,
    ) {
        let flag = Arc::new(std::sync::atomic::AtomicBool::new(false));
        cancels.lock().unwrap().insert(req, flag.clone());
        let (thread_out, cancels, handler) = (out.clone(), cancels.clone(), self.rpc.get().cloned());
        let spawned = std::thread::Builder::new().name("rpc".into()).spawn(move || {
            let outcome = match handler {
                Some(h) => h.call(&method, &params, &flag),
                None => Err("this muyad serves no rpc calls".to_string()),
            };
            let was_cancelled = flag.load(std::sync::atomic::Ordering::Relaxed);
            cancels.lock().unwrap().remove(&req);
            let (ok, result) = match outcome {
                Ok(_) if was_cancelled && method == "sessions.search" => (true, serde_json::Value::Null.to_string()),
                Ok(v) => (true, v.to_string()),
                Err(e) => (false, e),
            };
            let (ok, result) = if result.len() > muya_proto::MAX_FRAME - 4096 {
                (false, "the answer is too large".to_string())
            } else {
                (ok, result)
            };
            thread_out.write(&Frame::Control(Control::RpcReply { req, ok, result }).encode());
        });
        if spawned.is_err() {
            out.write(&Frame::Control(Control::RpcReply { req, ok: false, result: "could not start the call".into() }).encode());
        }
    }

    fn handle(self: &Arc<Self>, c: Control, out: &Arc<ClientOut>) -> Control {
        match c {
            Control::Spawn { argv, cwd, env, cols, rows } => match self.spawn(argv, cwd, env, cols, rows) {
                Ok((id, pid)) => Control::Spawned { id, pid },
                Err(e) => internal(e),
            },
            Control::Attach { id } => {
                let key = Arc::as_ptr(out) as usize;
                let out = out.clone();
                let sink: actor::Sink = Arc::new(move |f: &Frame| out.write(&f.encode()));
                // The actor sends Attached + snapshot itself, so no live frame can overtake them.
                match self.ask(id, |reply| Cmd::Subscribe { key, sink, reply }) {
                    Some(()) => Control::Ok,
                    None => no_session(),
                }
            }
            Control::Detach { id } => {
                let key = Arc::as_ptr(out) as usize;
                let out = out.clone();
                let sink: actor::Sink = Arc::new(move |f: &Frame| out.write(&f.encode()));
                match self.ask(id, |reply| Cmd::Detach { key, sink, reply }) {
                    Some(()) => Control::Ok,
                    None => no_session(),
                }
            }
            Control::Key { id, key, mods, text } => self.encode_and_send(id, |reply| Cmd::Key { key, mods, text, reply }),
            Control::Paste { id, text } => self.encode_and_send(id, |reply| Cmd::Paste { text, reply }),
            Control::Mouse { id, col, row, button, action, mods } => {
                self.encode_and_send(id, |reply| Cmd::Mouse { col, row, button, action, mods, reply })
            }
            Control::Resize { id, cols, rows } => {
                let Some(tx) = self.actor(id) else { return no_session() };
                let _ = tx.send(Cmd::Resize { cols, rows });
                if let Some(e) = self.sessions.lock().unwrap().get_mut(&id) {
                    (e.info.cols, e.info.rows) = (cols, rows);
                }
                self.request(Control::Resize { id, cols, rows }).unwrap_or_else(|e| internal(e))
            }
            Control::Close { id } => {
                if let Some(e) = self.sessions.lock().unwrap().remove(&id) {
                    let _ = e.tx.send(Cmd::Stop);
                }
                self.request(Control::Close { id }).unwrap_or_else(|e| internal(e))
            }
            _ => Control::Error { code: ErrorCode::BadRequest, message: "unexpected message".into(), detail: None },
        }
    }

    fn encode_and_send(&self, id: u64, make: impl FnOnce(Sender<Vec<u8>>) -> Cmd) -> Control {
        match self.ask(id, make) {
            Some(bytes) => {
                self.send_input(id, bytes);
                Control::Ok
            }
            None => no_session(),
        }
    }
}

// ---- Version skew: "restart sessions now / later" (PRD AC19, R7) -------------------------------

impl Muyad {
    /// Where the resume plan survives the restart (a private folder; the file holds folders and ids).
    pub fn set_state_dir(&self, dir: &std::path::Path) {
        *self.state_dir.lock().unwrap() = Some(dir.to_owned());
    }

    /// Replaces how Claude session ids are found (once). Tests; the default asks `claude agents --json`.
    pub fn set_claude_ids(&self, f: impl Fn(&[SessionInfo]) -> BTreeMap<u64, (String, Option<String>)> + Send + Sync + 'static) {
        let _ = self.claude_ids.set(Box::new(f));
    }

    /// Installs what happens after an `Upgrade` once its reply is written (once).
    pub fn set_on_upgrade(&self, f: impl Fn() + Send + Sync + 'static) {
        let _ = self.on_upgrade.set(Box::new(f));
    }

    /// Every session with its folder and Claude conversation, as the version dialog lists them.
    pub fn live_sessions(&self) -> Vec<LiveSession> {
        let infos = self.sessions();
        let claude = match self.claude_ids.get() {
            Some(f) => f(&infos),
            None => default_claude_ids(&infos),
        };
        infos
            .into_iter()
            .map(|i| {
                let found = claude.get(&i.id);
                let cwd = if !i.cwd.is_empty() { i.cwd.clone() } else { found.and_then(|(_, c)| c.clone()).unwrap_or_default() };
                LiveSession { id: i.id, pid: i.pid, cwd, claude_session_id: found.map(|(id, _)| id.clone()), exited: i.exited }
            })
            .collect()
    }

    /// "Restart sessions now": keeps the resume plan, ends the sessions, tells ptyd to start over
    /// and (after the reply is written) hands over to `on_upgrade`. App only (checked by the caller).
    fn upgrade(self: &Arc<Self>) -> Control {
        use std::sync::atomic::Ordering::SeqCst;
        if self.upgrading.swap(true, SeqCst) {
            return Control::Error { code: ErrorCode::BadRequest, message: "an upgrade is already under way".into(), detail: None };
        }
        let plan: Vec<LiveSession> = self.live_sessions().into_iter().filter(|s| s.exited.is_none()).collect();
        if let Err(e) = self.write_resume_plan(&plan) {
            self.upgrading.store(false, SeqCst);
            return internal(e);
        }
        let ptyd_new_enough = self.ptyd_version.lock().unwrap().as_ref().is_some_and(|v| v.major == muya_proto::PROTO_MAJOR && v.minor >= muya_proto::MINOR_UPGRADE);
        let mut ptyd_restarting = false;
        if self.is_linked() && ptyd_new_enough {
            ptyd_restarting = matches!(self.request(Control::Upgrade), Ok(Control::Upgrading { .. }));
        }
        if !ptyd_restarting && self.is_linked() {
            // An older (or unreachable) ptyd cannot be told: end the sessions one by one; the app
            // restarts that ptyd through launchd.
            for s in &plan {
                let _ = self.request(Control::Close { id: s.id });
            }
        }
        let this = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200)); // the reply goes out first
            if let Some(f) = this.on_upgrade.get() {
                f();
            }
        });
        Control::Upgrading { plan, ptyd_restarting }
    }

    fn plan_path(&self) -> Option<std::path::PathBuf> {
        self.state_dir.lock().unwrap().as_ref().map(|d| d.join(RESUME_PLAN_FILE))
    }

    fn write_resume_plan(&self, plan: &[LiveSession]) -> io::Result<()> {
        let Some(path) = self.plan_path() else { return Ok(()) };
        let body = serde_json::json!({
            "from_build": self.build,
            "created_at_ms": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0),
            "sessions": plan,
        });
        // Private file, replaced atomically: a crash between the two halves of the restart never
        // leaves a half-written plan.
        let tmp = path.with_extension("json.tmp");
        {
            use std::os::unix::fs::OpenOptionsExt;
            let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp)?;
            f.write_all(body.to_string().as_bytes())?;
            f.sync_all()?;
        }
        std::fs::rename(&tmp, &path)
    }

    /// The `upgrade.resume_plan` rpc: what the previous build was running when it was restarted.
    pub fn resume_plan(&self) -> serde_json::Value {
        let read = self.plan_path().and_then(|p| std::fs::read_to_string(p).ok()).and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok());
        match read {
            Some(mut v) => {
                v["pending"] = true.into();
                v
            }
            None => serde_json::json!({ "pending": false, "sessions": [] }),
        }
    }

    /// The `upgrade.resume_done` rpc: the app has respawned the sessions; forget the plan.
    pub fn resume_done(&self) -> io::Result<()> {
        match self.plan_path() {
            Some(p) => match std::fs::remove_file(p) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
                _ => Ok(()),
            },
            None => Ok(()),
        }
    }

    /// The `upgrade.status` rpc: is a restart needed, and what would it end.
    pub fn upgrade_status(&self) -> serde_json::Value {
        let ptyd = self.ptyd_version.lock().unwrap().clone();
        let incompat = self.ptyd_incompat.lock().unwrap().clone();
        serde_json::json!({
            "muyad": Version { major: muya_proto::PROTO_MAJOR, minor: muya_proto::PROTO_MINOR, build: self.build.clone() },
            "ptyd": ptyd,
            "ptyd_compat": incompat.is_some(),
            "ptyd_required": incompat.as_ref().map(|d| d.client.clone()),
            "restart_needed": incompat.is_some(),
            "sessions": self.live_sessions(),
        })
    }
}

/// Finds the Claude conversation in each session: `claude agents --json` lists live conversations
/// with the pid of the `claude` process; a process belongs to the session whose leader is its
/// session id (`getsid`), however deep a shell started it.
fn default_claude_ids(infos: &[SessionInfo]) -> BTreeMap<u64, (String, Option<String>)> {
    let mut out = BTreeMap::new();
    let Ok(agents) = muya_core::agents::list_agent_sessions_fresh(None) else { return out };
    for a in agents {
        if a.agent != "claude" || a.id.is_empty() || a.parent_id.is_some() {
            continue;
        }
        let Some(pid) = a.pid.and_then(|p| i32::try_from(p).ok()) else { continue };
        let sid = unsafe { libc::getsid(pid) };
        if sid <= 0 {
            continue;
        }
        if let Some(info) = infos.iter().find(|i| i.pid == sid) {
            let cwd = (!a.worktree.is_empty()).then(|| a.worktree.clone());
            out.entry(info.id).or_insert((a.id.clone(), cwd));
        }
    }
    out
}

fn no_session() -> Control {
    Control::Error { code: ErrorCode::NoSuchSession, message: "no such session".into(), detail: None }
}

fn internal(e: io::Error) -> Control {
    let code = if is_ptyd_unavailable(&e) { ErrorCode::NotApproved } else { ErrorCode::Internal };
    Control::Error { code, message: e.to_string(), detail: None }
}

/// Demultiplexes ptyd's stream: output to actors, Attached headers handled here (so the ring
/// that follows is recognised in order), other control messages to the waiting requester.
fn read_ptyd(mut stream: UnixStream, me: std::sync::Weak<Muyad>, replies: Sender<Control>) {
    let mut dec = Decoder::default();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = match stream.read(&mut buf) {
            Ok(0) | Err(_) => {
                let upgrading = me.upgrade().is_some_and(|m| m.upgrading.load(std::sync::atomic::Ordering::Relaxed));
                eprintln!("muyad: ptyd connection closed");
                // launchd restarts muyad, which re-adopts (after an upgrade: with the new build).
                std::process::exit(if upgrading { 0 } else { 2 });
            }
            Ok(n) => n,
        };
        dec.push(&buf[..n]);
        while let Ok(Some(frame)) = dec.next_frame() {
            let Some(me) = me.upgrade() else { return };
            match frame {
                Frame::Output { session, seq, data } => {
                    let mut sessions = me.sessions.lock().unwrap();
                    let Some(e) = sessions.get_mut(&session) else { continue };
                    let end = seq + data.len() as u64;
                    let _ = e.tx.send(Cmd::Output { seq, data });
                    e.info.end_seq = end;
                    if let Some((ring_end, _)) = &e.replay
                        && end >= *ring_end
                    {
                        let (_, modes) = e.replay.take().unwrap();
                        finish_replay(&me, session, &e.tx, modes);
                    }
                }
                Frame::Control(Control::Attached { id, start_seq, end_seq, modes }) => {
                    if let Some(e) = me.sessions.lock().unwrap().get_mut(&id) {
                        if start_seq == end_seq {
                            finish_replay(&me, id, &e.tx, modes.clone());
                        } else {
                            e.replay = Some((end_seq, modes.clone()));
                        }
                    }
                    let _ = replies.send(Control::Attached { id, start_seq, end_seq, modes });
                }
                Frame::Control(Control::Exited { id, status }) => {
                    if let Some(e) = me.sessions.lock().unwrap().get_mut(&id) {
                        e.info.exited = Some(status);
                        let _ = e.tx.send(Cmd::Exited(status));
                    }
                }
                Frame::Control(c) => {
                    let _ = replies.send(c);
                }
                Frame::Input { .. } => {}
            }
        }
    }
}

/// After the ring: apply tracked modes, then (off this thread: it waits for a reply this thread
/// delivers) ask ptyd for a repaint.
fn finish_replay(me: &Arc<Muyad>, id: u64, tx: &Sender<Cmd>, modes: String) {
    let _ = tx.send(Cmd::Replayed { modes });
    let me = me.clone();
    std::thread::spawn(move || {
        let _ = me.request(Control::Resync { id });
    });
}

/// The command and environment a session runs with: the user's login shell when no argv is
/// given, a clean environment (no CLAUDE* markers; ptyd strips them too), LANG from the user's
/// locale like Terminal.app (Faz 0 S5: the agent environment has none).
pub fn session_command(argv: Vec<String>, env: Vec<(String, String)>) -> (Vec<String>, Vec<(String, String)>) {
    let shell = login_shell();
    let argv = if argv.is_empty() { vec![shell.clone(), "-l".into()] } else { argv };
    let mut out: BTreeMap<String, String> = BTreeMap::new();
    for k in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
        if let Ok(v) = std::env::var(k) {
            out.insert(k.into(), v);
        }
    }
    out.insert("SHELL".into(), shell);
    out.insert("PATH".into(), "/usr/bin:/bin:/usr/sbin:/sbin".into());
    out.insert("TERM".into(), "xterm-256color".into());
    out.insert("COLORTERM".into(), "truecolor".into());
    out.insert("TERM_PROGRAM".into(), "Muya".into());
    out.insert("LANG".into(), locale_lang());
    for (k, v) in env {
        out.insert(k, v);
    }
    out.retain(|k, _| !k.starts_with("CLAUDE"));
    (argv, out.into_iter().collect())
}

fn login_shell() -> String {
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if !pw.is_null() && !(*pw).pw_shell.is_null() {
            return std::ffi::CStr::from_ptr((*pw).pw_shell).to_string_lossy().into_owned();
        }
    }
    "/bin/zsh".into()
}

/// `<AppleLocale>.UTF-8` when the system has that locale, else `en_US.UTF-8`.
pub fn locale_lang() -> String {
    let id = std::process::Command::new("/usr/bin/defaults")
        .args(["read", "-g", "AppleLocale"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().split('@').next().unwrap_or("").to_owned())
        .unwrap_or_default();
    let candidate = format!("{id}.UTF-8");
    if !id.is_empty() && std::path::Path::new("/usr/share/locale").join(&candidate).exists() {
        candidate
    } else {
        "en_US.UTF-8".into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_env_is_clean_and_has_a_real_locale() {
        let (argv, env) = session_command(vec![], vec![("CLAUDECODE".into(), "1".into()), ("FOO".into(), "bar".into())]);
        assert_eq!(argv.last().map(String::as_str), Some("-l"));
        let get = |k: &str| env.iter().find(|(a, _)| a == k).map(|(_, v)| v.clone());
        assert_eq!(get("CLAUDECODE"), None);
        assert_eq!(get("FOO").as_deref(), Some("bar"));
        assert_eq!(get("TERM").as_deref(), Some("xterm-256color"));
        let lang = get("LANG").unwrap();
        assert!(std::path::Path::new("/usr/share/locale").join(&lang).exists(), "{lang}");
    }
}

/// How many events may wait for one slow app client before it is dropped.
const EVENT_QUEUE: usize = 256;

/// One client connection's write side. Every write goes through here so that a failure (a timeout after a
/// half-written frame included) shuts the socket down: a framed stream that lost part of a frame can never
/// be used again, and the reader then ends the connection.
pub(crate) struct ClientOut {
    stream: Mutex<UnixStream>,
    dead: std::sync::atomic::AtomicBool,
    events: Mutex<Option<std::sync::mpsc::SyncSender<Vec<u8>>>>,
}

impl ClientOut {
    fn new(stream: UnixStream) -> Arc<Self> {
        Arc::new(ClientOut { stream: Mutex::new(stream), dead: Default::default(), events: Mutex::new(None) })
    }

    /// Writes one whole frame; `false` (and the connection shut down) when that failed or already had.
    fn write(&self, bytes: &[u8]) -> bool {
        use std::sync::atomic::Ordering::Relaxed;
        if self.dead.load(Relaxed) {
            return false;
        }
        let mut s = self.stream.lock().unwrap();
        if s.write_all(bytes).is_ok() {
            return true;
        }
        self.dead.store(true, Relaxed);
        let _ = s.shutdown(std::net::Shutdown::Both);
        false
    }

    fn kill(&self) {
        self.dead.store(true, std::sync::atomic::Ordering::Relaxed);
        let _ = self.stream.lock().unwrap_or_else(|e| e.into_inner()).shutdown(std::net::Shutdown::Both);
    }

    /// Events leave through their own thread and a bounded queue, so a client that stops reading delays only itself.
    fn start_event_writer(self: &Arc<Self>) {
        let (tx, rx) = std::sync::mpsc::sync_channel::<Vec<u8>>(EVENT_QUEUE);
        *self.events.lock().unwrap() = Some(tx);
        let me = Arc::downgrade(self);
        let _ = std::thread::Builder::new().name("client-events".into()).spawn(move || {
            while let Ok(bytes) = rx.recv() {
                let Some(out) = me.upgrade() else { return };
                if !out.write(&bytes) {
                    return;
                }
            }
        });
    }

    /// Queues an event; `false` when the client is gone or fell `EVENT_QUEUE` events behind (it is dropped then).
    fn enqueue(&self, bytes: &[u8]) -> bool {
        let guard = self.events.lock().unwrap();
        let Some(tx) = guard.as_ref() else { return false };
        match tx.try_send(bytes.to_vec()) {
            Ok(()) => true,
            Err(_) => {
                drop(guard);
                self.kill();
                false
            }
        }
    }
}

/// Sends `bytes` to every app client without holding the client list while writing; the clients that failed are forgotten.
fn fan_out(apps: &Mutex<Vec<(u64, Arc<ClientOut>)>>, bytes: &[u8]) -> Result<(), String> {
    let snapshot: Vec<(u64, Arc<ClientOut>)> = apps.lock().unwrap().clone();
    let gone: Vec<u64> = snapshot.iter().filter(|(_, out)| !out.enqueue(bytes)).map(|(id, _)| *id).collect();
    let mut apps = apps.lock().unwrap();
    if !gone.is_empty() {
        apps.retain(|(id, _)| !gone.contains(id));
    }
    if apps.is_empty() { Err("no app attached".into()) } else { Ok(()) }
}

#[cfg(test)]
mod client_out_tests {
    use super::*;
    use std::io::Read;
    use std::time::{Duration, Instant};

    fn client() -> (Arc<ClientOut>, UnixStream) {
        let (a, b) = UnixStream::pair().unwrap();
        a.set_write_timeout(Some(Duration::from_millis(100))).unwrap();
        let out = ClientOut::new(a);
        out.start_event_writer();
        (out, b)
    }

    #[test]
    fn a_failed_write_shuts_the_connection_down() {
        let (a, mut b) = UnixStream::pair().unwrap();
        a.set_write_timeout(Some(Duration::from_millis(50))).unwrap();
        let out = ClientOut::new(a);
        // The peer never reads: the kernel buffer fills, the write times out half-way.
        let big = vec![7u8; 8 << 20];
        assert!(!out.write(&big));
        assert!(!out.write(b"x"), "a dead connection takes no more frames");
        // The peer sees the stream end instead of the start of a new frame behind a torn one.
        b.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let mut sink = vec![0u8; 1 << 16];
        let mut ended = false;
        for _ in 0..1000 {
            match b.read(&mut sink) {
                Ok(0) | Err(_) => {
                    ended = true;
                    break;
                }
                Ok(_) => {}
            }
        }
        assert!(ended);
    }

    #[test]
    fn a_slow_app_client_does_not_stall_the_others() {
        let (slow, _slow_peer_never_reads) = client();
        let (fast, mut fast_peer) = client();
        let apps = Mutex::new(vec![(1u64, slow.clone()), (2u64, fast.clone())]);
        let event = vec![1u8; 64 * 1024];
        let t = Instant::now();
        // More than the slow client's socket buffer can hold (events are paced like real ones, so the queue never fills for the fast one).
        let reader = std::thread::spawn(move || {
            let mut got = 0usize;
            let mut buf = vec![0u8; 1 << 16];
            fast_peer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            while got < 200 * 64 * 1024 {
                match fast_peer.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => got += n,
                }
            }
            got
        });
        for _ in 0..200 {
            std::thread::sleep(Duration::from_millis(2));
            assert!(fan_out(&apps, &event).is_ok());
        }
        let got = reader.join().unwrap();
        assert_eq!(got, 200 * 64 * 1024, "the fast client got every event");
        assert!(t.elapsed() < Duration::from_secs(4), "emitting took {:?}", t.elapsed());
        let ids: Vec<u64> = apps.lock().unwrap().iter().map(|(id, _)| *id).collect();
        assert_eq!(ids, vec![2], "only the slow client was dropped");
    }
}

/// The last `max` lines of a screen: right-trimmed, with the empty rows under the last output dropped.
pub fn tail_lines(lines: Vec<String>, max: usize) -> Vec<String> {
    let mut v: Vec<String> = lines.into_iter().map(|l| l.trim_end().to_string()).collect();
    while v.last().is_some_and(|l| l.is_empty()) {
        v.pop();
    }
    let skip = v.len().saturating_sub(max);
    v.split_off(skip)
}

#[cfg(test)]
mod tail_tests {
    use super::tail_lines;
    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }
    #[test]
    fn drops_empty_rows_below_the_output_and_keeps_the_last_n() {
        assert_eq!(tail_lines(s(&["a  ", "b", "", "  ", ""]), 20), s(&["a", "b"]));
        assert_eq!(tail_lines(s(&["1", "2", "3", "4"]), 2), s(&["3", "4"]));
        assert_eq!(tail_lines(s(&["", ""]), 5), Vec::<String>::new());
        assert_eq!(tail_lines(s(&["x", "", "y"]), 5), s(&["x", "", "y"]), "blank rows between output stay");
    }
}

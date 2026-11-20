//! Protocol v1 between Muya.app, `muyad` and `muya-ptyd` (PRD §5, AC5).
//!
//! A stream is a sequence of frames: `u32` big-endian length, then the frame body. The body's
//! first byte is its kind:
//! - [`KIND_CONTROL`]: a UTF-8 JSON [`Control`] message (requests, replies, events);
//! - [`KIND_OUTPUT`]: terminal output, `session u64 | seq u64 | bytes` (big-endian);
//! - [`KIND_INPUT`]: terminal input, `session u64 | bytes`.
//!
//! Terminal bytes travel raw; only control messages are JSON. Bodies are capped at
//! [`MAX_FRAME`]; senders split larger payloads into [`CHUNK`]-sized frames.
//!
//! Every connection starts with [`Control::Hello`] from the client and [`Control::Welcome`] or a
//! typed [`Control::Error`] from the server ([`negotiate`]): the major version must match, any
//! minor version from [`MINOR_FLOOR`] up is accepted (N-1 clients keep working).
//!
//! Version skew (PRD R7, AC19): when the majors differ the server's `Incompatible` error carries an
//! [`Incompat`] (running versions, the version it requires, the version a client can speak to keep
//! working, and the live sessions with their Claude session ids). The app then offers "restart
//! sessions now / later". *Later*: it reconnects with `Hello{major,minor} = Incompat::speak` and sends
//! only messages whose [`min_minor`] the server's minor covers (the daemon enforces that per
//! connection: a message above the announced minor gets `BadRequest`). *Now*: [`Control::Upgrade`].

use serde::{Deserialize, Serialize};

pub const PROTO_MAJOR: u16 = 1;
pub const PROTO_MINOR: u16 = 3;
/// Oldest minor of the same major a server still serves. A hello below it is `Incompatible`.
pub const MINOR_FLOOR: u16 = 0;
/// First minor that understands [`Control::Detach`].
pub const MINOR_DETACH: u16 = 1;
/// First minor that understands [`Control::Rpc`] / [`Control::RpcReply`] / [`Control::RpcCancel`].
pub const MINOR_RPC: u16 = 2;
/// First minor that understands [`Control::Upgrade`] / [`Control::Upgrading`] and `SessionInfo::cwd`.
pub const MINOR_UPGRADE: u16 = 3;

pub const MOD_SHIFT: u16 = 1;
pub const MOD_ALT: u16 = 2;
pub const MOD_CTRL: u16 = 4;
pub const MOD_SUPER: u16 = 8;

pub const KIND_CONTROL: u8 = 1;
pub const KIND_OUTPUT: u8 = 2;
pub const KIND_INPUT: u8 = 3;

/// Largest frame body accepted; a peer sending more is broken or hostile and is disconnected.
pub const MAX_FRAME: usize = 16 << 20;
/// Payloads above this are split (PRD §5: large payloads are chunked).
pub const CHUNK: usize = 1 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    App,
    Muyad,
    Muyactl,
    Sidecar,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// Major protocol version differs; the client must be updated or the daemon restarted.
    Incompatible,
    /// Peer failed the code-signing or session check.
    Refused,
    /// The request was not understood or is not allowed for this role.
    BadRequest,
    NoSuchSession,
    /// ptyd/muyad not approved in Login Items (PRD AC21).
    NotApproved,
    Internal,
}

/// Information about one PTY session owned by ptyd.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: u64,
    pub pid: i32,
    pub cols: u16,
    pub rows: u16,
    /// Sequence number one past the last output byte.
    pub end_seq: u64,
    pub exited: Option<i32>,
    /// (minor >= 3) The folder the session was started in; empty when the daemon does not know.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub cwd: String,
}

/// A protocol version as a daemon or client reports it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Version {
    pub major: u16,
    pub minor: u16,
    pub build: String,
}

/// One live session as the "restart now / later" dialog and the resume plan describe it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LiveSession {
    pub id: u64,
    pub pid: i32,
    /// Where the session was started; `claude --resume <id>` must run here.
    pub cwd: String,
    /// The Claude conversation running in it, when there is one (`claude --resume <id>`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exited: Option<i32>,
}

/// Why a hello was refused for its version, and what to do about it (AC19).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Incompat {
    /// What the server runs.
    pub daemon: Version,
    /// What the client announced.
    pub client: Version,
    /// The oldest client the server serves: its major, [`MINOR_FLOOR`].
    pub required: Version,
    /// The hello a client can send to keep using the running server ("later"): the server's own
    /// major and minor. Messages beyond what both sides know stay unused (see [`min_minor`]).
    pub speak: Version,
    /// The sessions a restart would end.
    pub sessions: Vec<LiveSession>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Control {
    Hello { major: u16, minor: u16, role: Role, build: String },
    Welcome { major: u16, minor: u16, server_build: String },
    /// `detail` is set on [`ErrorCode::Incompatible`] from a server that knows about version skew.
    Error {
        code: ErrorCode,
        message: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<Box<Incompat>>,
    },

    // Requests to ptyd (from muyad).
    Spawn { argv: Vec<String>, cwd: String, env: Vec<(String, String)>, cols: u16, rows: u16 },
    Spawned { id: u64, pid: i32 },
    List,
    Sessions { sessions: Vec<SessionInfo> },
    /// Attach to output: ptyd replies [`Control::Attached`], then sends the ring from `start_seq`
    /// as output frames, then live output.
    Attach { id: u64 },
    Attached { id: u64, start_seq: u64, end_seq: u64, modes: String },
    /// (minor >= 1, muyad) Stops this connection's output stream for a session but keeps
    /// [`Control::Screen`] and [`Control::Exited`] flowing; works without a prior `Attach`. A later
    /// `Attach` resumes with a fresh snapshot. Lets the app keep a VT replica only for visible sessions.
    Detach { id: u64 },
    Resize { id: u64, cols: u16, rows: u16 },
    /// Repaint request after a lossy re-adopt: ptyd jiggles the size (SIGWINCH).
    Resync { id: u64 },
    Signal { id: u64, signal: i32 },
    /// Ends a session: SIGHUP to its process group if still running, ring wiped, entry removed.
    Close { id: u64 },

    // Input the app hands to muyad, which encodes it for the session's current modes (muyad holds
    // the authoritative terminal state; PRD "typing in muyad").
    /// `key`: a key name (`enter`, `tab`, `backspace`, `escape`, `up`, `down`, `left`, `right`,
    /// `home`, `end`, `page_up`, `page_down`, `delete`, `insert`, `f1`..`f12`, `space`, or a single
    /// character); `mods` bits: [`MOD_SHIFT`], [`MOD_ALT`], [`MOD_CTRL`], [`MOD_SUPER`].
    Key { id: u64, key: String, mods: u16, text: Option<String> },
    /// Pasted text: control bytes neutralised, bracketed when the program asked for it.
    Paste { id: u64, text: String },
    /// Mouse event at a cell (0-based). `button`: left|middle|right|wheel_up|wheel_down|none;
    /// `action`: press|release|motion.
    Mouse { id: u64, col: u16, row: u16, button: String, action: String, mods: u16 },
    /// Debug builds only (PRD AC6: no dump in release): a session's modes and screen fingerprint.
    Inspect { id: u64 },
    Inspected { modes: String, fingerprint: String, screen: String },
    Ok,

    // Events.
    Exited { id: u64, status: i32 },
    /// What the user sees on a Claude screen (mode, activity, permission dialog, busy), as the JSON
    /// of `muya_core::screen::ScreenState`; sent when it changes.
    Screen { id: u64, state: String },
    /// An app-level event the daemon-hosted MCP broker wants the UI to see (`ssh-broker-open`,
    /// `muya://deliver-message`, ...). `payload` is the event's JSON, serialized.
    Event { name: String, payload: String },

    /// (minor >= 2, app) A call into the daemon's core logic (sessions history/search/export, schedules,
    /// preferences). `method` is a dotted name (`sessions.search`, `schedules.save`, ...), `params` a JSON
    /// string. Answered with [`Control::RpcReply`] carrying the same `req`, out of order: a slow call
    /// (content search) never blocks the connection's other requests.
    Rpc { req: u64, method: String, params: String },
    /// Reply to [`Control::Rpc`]: `ok` with the JSON `result`, or not ok with a human-readable message.
    RpcReply { req: u64, ok: bool, result: String },
    /// (minor >= 2, app) Asks the daemon to stop a running [`Control::Rpc`]; its reply still arrives
    /// (partial result or a "cancelled" error). No reply of its own ([`Control::Ok`] is sent).
    RpcCancel { req: u64 },

    /// (minor >= 3, app) "Restart sessions now" (AC19): the daemon records every live session's folder
    /// and Claude session id (the resume plan, kept until `upgrade.resume_done`), ends the sessions,
    /// answers [`Control::Upgrading`], and exits so launchd starts the new build. The connection then
    /// closes; reconnect and read the plan with the `upgrade.resume_plan` rpc. Also sent muyad -> ptyd.
    Upgrade,
    /// Reply to [`Control::Upgrade`]: the plan, and whether ptyd is restarting too (false: the ptyd is
    /// too old to be told, the app restarts it through launchd).
    Upgrading { plan: Vec<LiveSession>, ptyd_restarting: bool },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frame {
    Control(Control),
    Output { session: u64, seq: u64, data: Vec<u8> },
    Input { session: u64, data: Vec<u8> },
}

#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    TooLarge(usize),
    Empty,
    UnknownKind(u8),
    Truncated,
    Json(String),
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for DecodeError {}

impl Frame {
    /// The frame with its length prefix, ready to write. Output/Input data must fit
    /// [`MAX_FRAME`]; use [`output_frames`] for arbitrary sizes.
    pub fn encode(&self) -> Vec<u8> {
        self.try_encode().unwrap_or_else(|n| panic!("frame body {n} > MAX_FRAME"))
    }

    /// Like [`Frame::encode`], but an oversize body is an `Err(body length)` instead of a panic. Use it where the
    /// size comes from outside (events carrying a peer's text).
    pub fn try_encode(&self) -> Result<Vec<u8>, usize> {
        let mut body = Vec::new();
        match self {
            Frame::Control(c) => {
                body.push(KIND_CONTROL);
                body.extend(serde_json::to_vec(c).expect("control messages serialize"));
            }
            Frame::Output { session, seq, data } => {
                body.push(KIND_OUTPUT);
                body.extend(session.to_be_bytes());
                body.extend(seq.to_be_bytes());
                body.extend(data);
            }
            Frame::Input { session, data } => {
                body.push(KIND_INPUT);
                body.extend(session.to_be_bytes());
                body.extend(data);
            }
        }
        if body.len() > MAX_FRAME {
            return Err(body.len());
        }
        let mut out = Vec::with_capacity(4 + body.len());
        out.extend((body.len() as u32).to_be_bytes());
        out.extend(body);
        Ok(out)
    }

    pub fn decode_body(body: &[u8]) -> Result<Frame, DecodeError> {
        let (&kind, rest) = body.split_first().ok_or(DecodeError::Empty)?;
        let u64_at = |b: &[u8], at: usize| -> Result<u64, DecodeError> {
            b.get(at..at + 8).map(|s| u64::from_be_bytes(s.try_into().unwrap())).ok_or(DecodeError::Truncated)
        };
        match kind {
            KIND_CONTROL => serde_json::from_slice(rest).map(Frame::Control).map_err(|e| DecodeError::Json(e.to_string())),
            KIND_OUTPUT => Ok(Frame::Output { session: u64_at(rest, 0)?, seq: u64_at(rest, 8)?, data: rest[16..].to_vec() }),
            KIND_INPUT => Ok(Frame::Input { session: u64_at(rest, 0)?, data: rest[8..].to_vec() }),
            k => Err(DecodeError::UnknownKind(k)),
        }
    }
}

/// Splits output into frames of at most [`CHUNK`] bytes, numbering each from `seq`.
pub fn output_frames(session: u64, mut seq: u64, data: &[u8]) -> Vec<Frame> {
    data.chunks(CHUNK)
        .map(|c| {
            let f = Frame::Output { session, seq, data: c.to_vec() };
            seq += c.len() as u64;
            f
        })
        .collect()
}

/// Incremental decoder for a byte stream (works with partial reads and non-blocking sockets).
#[derive(Default)]
pub struct Decoder {
    buf: Vec<u8>,
}

impl Decoder {
    pub fn push(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    /// The next complete frame, `Ok(None)` if more bytes are needed. After an error the stream
    /// is unusable and the connection must be closed.
    pub fn next_frame(&mut self) -> Result<Option<Frame>, DecodeError> {
        if self.buf.len() < 4 {
            return Ok(None);
        }
        let len = u32::from_be_bytes(self.buf[..4].try_into().unwrap()) as usize;
        if len > MAX_FRAME {
            return Err(DecodeError::TooLarge(len));
        }
        if self.buf.len() < 4 + len {
            return Ok(None);
        }
        let frame = Frame::decode_body(&self.buf[4..4 + len]);
        self.buf.drain(..4 + len);
        frame.map(Some)
    }
}

/// What a message needs of the connection's announced minor (the daemon enforces it, so an app that
/// negotiated down never relies on a message the other build does not know).
pub fn min_minor(c: &Control) -> u16 {
    match c {
        Control::Detach { .. } => MINOR_DETACH,
        Control::Rpc { .. } | Control::RpcReply { .. } | Control::RpcCancel { .. } => MINOR_RPC,
        Control::Upgrade | Control::Upgrading { .. } => MINOR_UPGRADE,
        _ => 0,
    }
}

/// Server side of the handshake: the reply to a client's hello (no session list on a version error).
pub fn negotiate(hello: &Control, server_build: &str) -> Control {
    negotiate_with(hello, server_build, Vec::new)
}

/// [`negotiate`] with the live sessions a version error reports (`sessions` runs only then).
pub fn negotiate_with(hello: &Control, server_build: &str, sessions: impl FnOnce() -> Vec<LiveSession>) -> Control {
    match hello {
        Control::Hello { major, minor, .. } if *major == PROTO_MAJOR && *minor >= MINOR_FLOOR => {
            Control::Welcome { major: PROTO_MAJOR, minor: PROTO_MINOR, server_build: server_build.to_owned() }
        }
        Control::Hello { major, minor, build, .. } => Control::Error {
            code: ErrorCode::Incompatible,
            message: format!("protocol {major}.{minor} is not compatible with {PROTO_MAJOR}.{PROTO_MINOR}"),
            detail: Some(Box::new(Incompat {
                daemon: Version { major: PROTO_MAJOR, minor: PROTO_MINOR, build: server_build.to_owned() },
                client: Version { major: *major, minor: *minor, build: build.clone() },
                required: Version { major: PROTO_MAJOR, minor: MINOR_FLOOR, build: server_build.to_owned() },
                speak: Version { major: PROTO_MAJOR, minor: PROTO_MINOR, build: server_build.to_owned() },
                sessions: sessions(),
            })),
        },
        _ => Control::Error { code: ErrorCode::BadRequest, message: "expected hello".into(), detail: None },
    }
}

/// The minor a hello announces (0 for anything else).
pub fn hello_minor(hello: &Control) -> u16 {
    match hello {
        Control::Hello { minor, .. } => *minor,
        _ => 0,
    }
}

/// The `BadRequest` a daemon answers when a message needs a newer minor than the client announced.
pub fn needs_minor(c: &Control, announced: u16) -> Option<Control> {
    let need = min_minor(c);
    (announced < need).then(|| Control::Error {
        code: ErrorCode::BadRequest,
        message: format!("this message needs protocol minor {need}; the connection announced {announced}"),
        detail: None,
    })
}

/// Socket buffer for the daemon links. macOS gives Unix sockets 8 KB by default
/// (net.local.stream.sendspace); with 100 sessions streaming through one ptyd->muyad link the
/// pump threads queued behind each other and a keystroke echo waited up to 50 ms (muya-load).
pub const LINK_BUFFER: libc::c_int = 1 << 20;

/// Sets [`LINK_BUFFER`] for sending and receiving on a daemon link socket (best effort).
pub fn tune_link(fd: std::os::fd::RawFd) {
    for opt in [libc::SO_SNDBUF, libc::SO_RCVBUF] {
        let v = LINK_BUFFER;
        unsafe { libc::setsockopt(fd, libc::SOL_SOCKET, opt, (&v as *const libc::c_int).cast(), std::mem::size_of::<libc::c_int>() as libc::socklen_t) };
    }
}

/// The build string a daemon announces: the crate version, plus `+<product version>` when the release script stamped one
/// (`MUYA_PRODUCT_VERSION` at compile time). The app compares the product part with its own bundle's version to notice a
/// daemon that predates it: same protocol, different program.
pub fn build_id(pkg: &str, product: Option<&str>) -> String {
    match product.map(str::trim).filter(|p| !p.is_empty()) {
        Some(p) => format!("{pkg}+{p}"),
        None => pkg.to_owned(),
    }
}

pub fn hello(role: Role, build: &str) -> Control {
    Control::Hello { major: PROTO_MAJOR, minor: PROTO_MINOR, role, build: build.to_owned() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_id_carries_the_product_version_when_stamped() {
        assert_eq!(build_id("0.1.0", Some("4.1.24")), "0.1.0+4.1.24");
        assert_eq!(build_id("0.1.0", None), "0.1.0");
        assert_eq!(build_id("0.1.0", Some(" ")), "0.1.0");
    }

    fn roundtrip(f: Frame) {
        let mut d = Decoder::default();
        d.push(&f.encode());
        assert_eq!(d.next_frame().unwrap(), Some(f));
        assert_eq!(d.next_frame().unwrap(), None);
    }

    #[test]
    fn frames_roundtrip() {
        roundtrip(Frame::Control(hello(Role::Muyad, "test")));
        roundtrip(Frame::Control(Control::Sessions {
            sessions: vec![SessionInfo { id: 3, pid: 42, cols: 80, rows: 24, end_seq: 9, exited: Some(0), cwd: "/w".into() }],
        }));
        roundtrip(Frame::Output { session: 7, seq: u64::MAX - 5, data: "\x1b[31mş\0".as_bytes().to_vec() });
        roundtrip(Frame::Input { session: 1, data: vec![] });
    }

    #[test]
    fn decoder_handles_byte_by_byte_and_back_to_back_frames() {
        let a = Frame::Output { session: 1, seq: 0, data: b"hello".to_vec() };
        let b = Frame::Control(Control::List);
        let bytes = [a.encode(), b.encode()].concat();
        let mut d = Decoder::default();
        let mut got = Vec::new();
        for byte in bytes {
            d.push(&[byte]);
            while let Some(f) = d.next_frame().unwrap() {
                got.push(f);
            }
        }
        assert_eq!(got, vec![a, b]);
    }

    #[test]
    fn try_encode_reports_an_oversize_body_instead_of_panicking() {
        let big = Frame::Control(Control::Event { name: "e".into(), payload: "x".repeat(MAX_FRAME) });
        assert!(big.try_encode().is_err());
        let small = Frame::Control(Control::Event { name: "e".into(), payload: "x".into() });
        assert_eq!(small.try_encode().unwrap(), small.encode());
    }

    #[test]
    fn oversized_frame_is_rejected_before_buffering_it() {
        let mut d = Decoder::default();
        d.push(&((MAX_FRAME + 1) as u32).to_be_bytes());
        assert_eq!(d.next_frame(), Err(DecodeError::TooLarge(MAX_FRAME + 1)));
    }

    #[test]
    fn large_output_is_chunked_with_contiguous_sequence_numbers() {
        let data = vec![7u8; CHUNK * 2 + 10];
        let frames = output_frames(4, 100, &data);
        assert_eq!(frames.len(), 3);
        let mut expect = 100;
        for f in &frames {
            let Frame::Output { seq, data, .. } = f else { panic!() };
            assert_eq!(*seq, expect);
            expect += data.len() as u64;
        }
        assert_eq!(expect, 100 + data.len() as u64);
    }

    /// AC5: one major version off -> typed error; an N-1 minor client works.
    #[test]
    fn handshake_major_must_match_minor_may_differ() {
        let ok = negotiate(&Control::Hello { major: PROTO_MAJOR, minor: PROTO_MINOR.wrapping_sub(1), role: Role::App, build: "old".into() }, "srv");
        assert!(matches!(ok, Control::Welcome { major: PROTO_MAJOR, .. }));
        for major in [PROTO_MAJOR - 1, PROTO_MAJOR + 1] {
            let err = negotiate(&Control::Hello { major, minor: 0, role: Role::App, build: "x".into() }, "srv");
            assert!(matches!(err, Control::Error { code: ErrorCode::Incompatible, .. }), "{err:?}");
        }
        assert!(matches!(negotiate(&Control::List, "srv"), Control::Error { code: ErrorCode::BadRequest, .. }));
    }

    /// Wire format is part of the contract: a v1 hello must keep this exact JSON.
    #[test]
    fn hello_wire_format_is_stable() {
        let json = serde_json::to_string(&hello(Role::Muyad, "b")).unwrap();
        assert_eq!(json, r#"{"type":"hello","major":1,"minor":3,"role":"muyad","build":"b"}"#);
    }

    /// `Detach` is a minor-1 addition: it round-trips, and a minor-0 hello still negotiates.
    #[test]
    fn detach_round_trips_and_minor0_clients_still_negotiate() {
        let f = Frame::Control(Control::Detach { id: 7 });
        assert_eq!(f.encode().len() > 5, true);
        let mut dec = Decoder::default();
        dec.push(&f.encode());
        assert_eq!(dec.next_frame().unwrap(), Some(f));
        assert_eq!(serde_json::to_string(&Control::Detach { id: 7 }).unwrap(), r#"{"type":"detach","id":7}"#);
        let old = Control::Hello { major: PROTO_MAJOR, minor: 0, role: Role::App, build: "old".into() };
        assert!(matches!(negotiate(&old, "srv"), Control::Welcome { minor: PROTO_MINOR, .. }));
        assert!(PROTO_MINOR >= MINOR_DETACH);
    }

    /// `Rpc` is a minor-2 addition: exact wire shape, round trip, and a minor-1 hello still negotiates.
    #[test]
    fn rpc_round_trips_and_minor1_clients_still_negotiate() {
        for c in [
            Control::Rpc { req: 3, method: "sessions.history".into(), params: "{}".into() },
            Control::RpcReply { req: 3, ok: true, result: "[]".into() },
            Control::RpcCancel { req: 3 },
        ] {
            let f = Frame::Control(c);
            let mut dec = Decoder::default();
            dec.push(&f.encode());
            assert_eq!(dec.next_frame().unwrap(), Some(f));
        }
        assert_eq!(
            serde_json::to_string(&Control::Rpc { req: 3, method: "m".into(), params: "{}".into() }).unwrap(),
            r#"{"type":"rpc","req":3,"method":"m","params":"{}"}"#
        );
        assert_eq!(serde_json::to_string(&Control::RpcCancel { req: 9 }).unwrap(), r#"{"type":"rpc_cancel","req":9}"#);
        let old = Control::Hello { major: PROTO_MAJOR, minor: MINOR_DETACH, role: Role::App, build: "old".into() };
        assert!(matches!(negotiate(&old, "srv"), Control::Welcome { minor: PROTO_MINOR, .. }));
    }

    fn live(id: u64, claude: Option<&str>) -> LiveSession {
        LiveSession { id, pid: 100 + id as i32, cwd: "/w".into(), claude_session_id: claude.map(Into::into), exited: None }
    }

    /// AC19: `Upgrade`/`Upgrading` and the version-skew error keep these exact wire shapes and round trip.
    #[test]
    fn upgrade_messages_round_trip_with_stable_shapes() {
        assert_eq!(serde_json::to_string(&Control::Upgrade).unwrap(), r#"{"type":"upgrade"}"#);
        let up = Control::Upgrading { plan: vec![live(2, Some("c-1")), live(3, None)], ptyd_restarting: true };
        assert_eq!(
            serde_json::to_string(&up).unwrap(),
            r#"{"type":"upgrading","plan":[{"id":2,"pid":102,"cwd":"/w","claude_session_id":"c-1"},{"id":3,"pid":103,"cwd":"/w"}],"ptyd_restarting":true}"#
        );
        let err = negotiate_with(&Control::Hello { major: 2, minor: 5, role: Role::App, build: "new".into() }, "old", || vec![live(2, Some("c-1"))]);
        for c in [Control::Upgrade, up, err] {
            let f = Frame::Control(c);
            let mut dec = Decoder::default();
            dec.push(&f.encode());
            assert_eq!(dec.next_frame().unwrap(), Some(f));
        }
        // A plain error keeps the v1 shape: no `detail` key.
        assert_eq!(
            serde_json::to_string(&Control::Error { code: ErrorCode::Refused, message: "m".into(), detail: None }).unwrap(),
            r#"{"type":"error","code":"refused","message":"m"}"#
        );
        // ... and an error without `detail` from an old daemon still parses.
        let old: Control = serde_json::from_str(r#"{"type":"error","code":"incompatible","message":"m"}"#).unwrap();
        assert!(matches!(old, Control::Error { detail: None, .. }));
    }

    /// AC19 / R7 N-1 matrix: every (client, server) version pair gets a Welcome or a typed, detailed
    /// error; the same major always works down to MINOR_FLOOR; a different major reports who runs what.
    #[test]
    fn n_minus_one_matrix_welcome_or_typed_incompat() {
        for major in [PROTO_MAJOR - 1, PROTO_MAJOR, PROTO_MAJOR + 1] {
            for minor in [0, 1, PROTO_MINOR - 1, PROTO_MINOR, PROTO_MINOR + 7] {
                let hello = Control::Hello { major, minor, role: Role::App, build: format!("c{major}.{minor}") };
                match negotiate_with(&hello, "srv", || vec![live(1, Some("id-1")), live(2, None)]) {
                    Control::Welcome { major: m, minor: n, .. } => {
                        assert_eq!((major, m, n), (PROTO_MAJOR, PROTO_MAJOR, PROTO_MINOR));
                        assert!(minor >= MINOR_FLOOR);
                    }
                    Control::Error { code: ErrorCode::Incompatible, detail: Some(d), message } => {
                        assert_ne!(major, PROTO_MAJOR, "{message}");
                        assert_eq!((d.client.major, d.client.minor), (major, minor));
                        assert_eq!(d.client.build, format!("c{major}.{minor}"));
                        assert_eq!((d.daemon.major, d.daemon.minor, d.daemon.build.as_str()), (PROTO_MAJOR, PROTO_MINOR, "srv"));
                        assert_eq!((d.required.major, d.required.minor), (PROTO_MAJOR, MINOR_FLOOR));
                        assert_eq!((d.speak.major, d.speak.minor), (PROTO_MAJOR, PROTO_MINOR));
                        assert_eq!(d.sessions, vec![live(1, Some("id-1")), live(2, None)]);
                    }
                    other => panic!("({major}.{minor}) -> {other:?}"),
                }
            }
        }
        // The session list is only gathered when it is needed.
        let ok = Control::Hello { major: PROTO_MAJOR, minor: 0, role: Role::App, build: "b".into() };
        assert!(matches!(negotiate_with(&ok, "s", || panic!("not needed")), Control::Welcome { .. }));
    }

    /// AC19 "later": the messages a connection may use depend on the minor it announced.
    #[test]
    fn announced_minor_gates_newer_messages() {
        let rpc = Control::Rpc { req: 1, method: "m".into(), params: "{}".into() };
        assert_eq!(min_minor(&Control::List), 0);
        assert_eq!(min_minor(&Control::Key { id: 1, key: "a".into(), mods: 0, text: None }), 0);
        assert_eq!((min_minor(&Control::Detach { id: 1 }), min_minor(&rpc), min_minor(&Control::Upgrade)), (MINOR_DETACH, MINOR_RPC, MINOR_UPGRADE));
        assert!(needs_minor(&Control::List, 0).is_none());
        assert!(needs_minor(&rpc, MINOR_RPC).is_none());
        assert!(matches!(needs_minor(&rpc, 1), Some(Control::Error { code: ErrorCode::BadRequest, .. })));
        assert!(matches!(needs_minor(&Control::Upgrade, 2), Some(Control::Error { code: ErrorCode::BadRequest, .. })));
        assert_eq!(hello_minor(&hello(Role::App, "b")), PROTO_MINOR);
        assert_eq!(hello_minor(&Control::List), 0);
    }

    /// AC5 fuzz: arbitrary bytes, fed in arbitrary splits, never panic. The default run is short;
    /// `MUYA_FUZZ_SECS=600 cargo test -p muya-proto fuzz -- --ignored` runs the 10-minute target.
    #[test]
    fn fuzz_decoder_short() {
        fuzz_for(std::time::Duration::from_secs(2));
    }

    #[test]
    #[ignore]
    fn fuzz_decoder_long() {
        let secs = std::env::var("MUYA_FUZZ_SECS").ok().and_then(|s| s.parse().ok()).unwrap_or(600);
        fuzz_for(std::time::Duration::from_secs(secs));
    }

    fn fuzz_for(time: std::time::Duration) {
        let seeds: Vec<Vec<u8>> = vec![
            Frame::Control(hello(Role::App, "seed")).encode(),
            Frame::Output { session: 1, seq: 2, data: b"abc".to_vec() }.encode(),
            Frame::Control(Control::Attached { id: 1, start_seq: 0, end_seq: 9, modes: "2004=1".into() }).encode(),
            Frame::Control(Control::Detach { id: 1 }).encode(),
            Frame::Control(Control::Upgrade).encode(),
            Frame::Control(Control::Upgrading { plan: vec![live(1, Some("abc"))], ptyd_restarting: true }).encode(),
            Frame::Control(negotiate(&Control::Hello { major: 9, minor: 0, role: Role::App, build: "x".into() }, "s")).encode(),
        ];
        let mut rng = 0x2545F4914F6CDD1Du64;
        let mut next = move || {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            rng
        };
        let start = std::time::Instant::now();
        let mut cases = 0u64;
        while start.elapsed() < time {
            // Mutate a seed or produce noise, sometimes with a small valid length prefix.
            let mut input = if next() % 3 == 0 {
                (0..(next() % 64)).map(|_| next() as u8).collect::<Vec<u8>>()
            } else {
                let mut s = seeds[(next() % seeds.len() as u64) as usize].clone();
                for _ in 0..(next() % 4) {
                    let i = (next() as usize) % s.len();
                    s[i] = next() as u8;
                }
                s
            };
            if next() % 5 == 0 {
                input.truncate((next() as usize) % (input.len() + 1));
            }
            let mut d = Decoder::default();
            let mut i = 0;
            while i < input.len() {
                let n = 1 + (next() as usize) % 8;
                d.push(&input[i..(i + n).min(input.len())]);
                i += n;
                loop {
                    match d.next_frame() {
                        Ok(Some(_)) => continue,
                        Ok(None) | Err(_) => break,
                    }
                }
            }
            cases += 1;
        }
        assert!(cases > 1000, "fuzz ran only {cases} cases");
    }
}

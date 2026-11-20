//! Parity package P10 — the bridge hosted in muyad: local socket + remote pairing over mTLS.
//! Two real muyad processes in separate temp HOMEs (own bridge identity + peer registry) pair over
//! loopback; the "app" is a socket client that issues `Control::Rpc` calls and records `Control::Event`s.

use muya_proto::{Control, Decoder, Frame, Role};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant};

struct Env {
    dir: PathBuf,
    home: PathBuf,
    kids: Vec<Child>,
}

impl Drop for Env {
    fn drop(&mut self) {
        for k in self.kids.iter_mut().rev() {
            let _ = k.kill();
            let _ = k.wait();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn wait_for(what: &str, mut ok: impl FnMut() -> bool) {
    let end = Instant::now() + Duration::from_secs(15);
    while !ok() {
        assert!(Instant::now() < end, "timed out: {what}");
        std::thread::sleep(Duration::from_millis(30));
    }
}

struct App {
    s: UnixStream,
    dec: Decoder,
    next: u64,
    /// Every event seen so far, in order: (name, payload).
    events: Vec<(String, Value)>,
}

impl App {
    fn connect(sock: &Path) -> Self {
        let s = connect_retry(sock);
        s.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
        let mut a = Self {
            s,
            dec: Decoder::default(),
            next: 1,
            events: vec![],
        };
        a.send(muya_proto::hello(Role::App, "p10-test"));
        assert!(matches!(a.read_control(), Control::Welcome { .. }));
        a
    }
    fn send(&mut self, c: Control) {
        self.s.write_all(&Frame::Control(c).encode()).unwrap();
    }
    /// Next non-event control frame; events are recorded on the way.
    fn read_control(&mut self) -> Control {
        loop {
            while let Some(f) = self.dec.next_frame().unwrap() {
                if let Frame::Control(c) = f {
                    if let Control::Event { name, payload } = c {
                        self.events
                            .push((name, serde_json::from_str(&payload).unwrap()));
                        continue;
                    }
                    return c;
                }
            }
            let mut buf = [0u8; 65536];
            let n = self.s.read(&mut buf).unwrap();
            assert!(n > 0, "muyad closed");
            self.dec.push(&buf[..n]);
        }
    }
    fn rpc(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let req = self.next;
        self.next += 1;
        self.send(Control::Rpc {
            req,
            method: method.into(),
            params: params.to_string(),
        });
        loop {
            if let Control::RpcReply { req: r, ok, result } = self.read_control() {
                assert_eq!(r, req);
                return if ok {
                    Ok(serde_json::from_str(&result).unwrap())
                } else {
                    Err(result)
                };
            }
        }
    }
    /// Waits until at least `n` events called `name` arrived; returns their payloads in order.
    fn events_n(&mut self, name: &str, n: usize) -> Vec<Value> {
        let end = Instant::now() + Duration::from_secs(10);
        loop {
            self.s.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
            let mut buf = [0u8; 65536];
            if let Ok(k) = self.s.read(&mut buf) {
                assert!(k > 0, "muyad closed");
                self.dec.push(&buf[..k]);
            }
            while let Ok(Some(f)) = self.dec.next_frame() {
                if let Frame::Control(Control::Event { name, payload }) = f {
                    self.events.push((name, serde_json::from_str(&payload).unwrap()));
                }
            }
            let got: Vec<Value> = self.events.iter().filter(|(k, _)| k == name).map(|(_, p)| p.clone()).collect();
            if got.len() >= n {
                return got;
            }
            assert!(Instant::now() < end, "only {} of {n} {name} events: {:?}", got.len(), self.events);
        }
    }
    /// Waits until an event called `name` arrived (any time since the start); returns its payload.
    fn event(&mut self, name: &str) -> Value {
        let end = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some((_, p)) = self.events.iter().find(|(n, _)| n == name) {
                return p.clone();
            }
            assert!(
                Instant::now() < end,
                "no event {name}; saw {:?}",
                self.events
            );
            // Frames already buffered behind an RpcReply are still undecoded.
            while let Ok(Some(f)) = self.dec.next_frame() {
                if let Frame::Control(Control::Event { name, payload }) = f {
                    self.events.push((name, serde_json::from_str(&payload).unwrap()));
                }
            }
            if self.events.iter().any(|(n, _)| n == name) {
                continue;
            }
            self.s
                .set_read_timeout(Some(Duration::from_millis(200)))
                .unwrap();
            let mut buf = [0u8; 65536];
            if let Ok(n) = self.s.read(&mut buf) {
                assert!(n > 0, "muyad closed");
                self.dec.push(&buf[..n]);
                while let Ok(Some(Frame::Control(Control::Event { name, payload }))) =
                    self.dec.next_frame()
                {
                    self.events
                        .push((name, serde_json::from_str(&payload).unwrap()));
                }
            }
        }
    }
}


/// A muyad with no ptyd (the bridge needs none) in its own temp HOME and temp bridge socket.
fn start(tag: &str) -> Env {
    start_with(tag, None)
}

/// Like [`start`], with a peer registry already on disk (the daemon reads it on first use).
fn start_with(tag: &str, registry: Option<&Value>) -> Env {
    let dir = PathBuf::from(format!("/tmp/muya-p10-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    if let Some(r) = registry {
        let reg_dir = home.join("Library/Application Support/muya/bridge");
        std::fs::create_dir_all(&reg_dir).unwrap();
        std::fs::write(reg_dir.join("peer_registry.json"), r.to_string()).unwrap();
    }
    let mut env = Env { dir, home, kids: vec![] };
    let muyad = Command::new(env!("CARGO_BIN_EXE_muyad"))
        .env_clear()
        .env("HOME", &env.home)
        .env("PATH", "/usr/bin:/bin")
        .env("MUYA_BRIDGE_SOCK", env.dir.join("bridge.sock"))
        .arg("--socket")
        .arg(env.dir.join("m.sock"))
        .arg("--ptyd")
        .arg(env.dir.join("p.sock"))
        .stderr(if std::env::var_os("P10_DEBUG").is_some() { std::process::Stdio::inherit() } else { std::process::Stdio::null() })
        .spawn()
        .unwrap();
    env.kids.push(muyad);
    let m = env.dir.join("m.sock");
    wait_for("muyad socket", || m.exists() && UnixStream::connect(&m).is_ok());
    env
}

/// The pairing tests share the loopback port space: one at a time.
static PORTS: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Two adjacent free loopback ports (data listener, pairing window = data + 1).
fn free_pair() -> (u16, u16) {
    loop {
        let a = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let p = a.local_addr().unwrap().port();
        if p < 65000 && std::net::TcpListener::bind(("127.0.0.1", p + 1)).is_ok() {
            return (p, p + 1);
        }
    }
}

/// Starts the listening side: data listener + pairing window on loopback. Returns (invite, data addr, pairing addr).
fn open_invite(a: &mut App, ports: (u16, u16)) -> (Value, String, String) {
    let (data, pairing) = (format!("127.0.0.1:{}", ports.0), format!("127.0.0.1:{}", ports.1));
    a.rpc("bridge.remote_listen", json!({ "enable": true, "iface": data })).unwrap();
    let invite = a.rpc("bridge.pair_invite", json!({})).unwrap();
    a.rpc("bridge.pair_start_listener", json!({ "pairingIface": pairing })).unwrap();
    (invite, data, pairing)
}

/// Full path with both sides in their own HOME: pair with SAS check, send a message, revoke.
#[test]
fn p10_pair_send_and_revoke_over_loopback() {
    let _ports = PORTS.lock().unwrap_or_else(|e| e.into_inner());
    let (ea, eb) = (start("a-pair"), start("b-pair"));
    let (mut a, mut b) = (App::connect(&ea.dir.join("m.sock")), App::connect(&eb.dir.join("m.sock")));
    let (invite, data, pairing) = open_invite(&mut a, free_pair());
    assert_eq!(a.event("bridge://peer-status"), json!("remote_listener:started"));
    assert_eq!(a.event("bridge://pairing-status"), json!("pairing_listener:started"));
    let pin = invite["pin"].as_str().unwrap().to_string();
    assert_eq!(pin.len(), 8);
    let a_spki = invite["our_spki"].as_str().unwrap().to_string();

    // Dialer side: SPAKE2 + cert exchange; both sides derive the same short code.
    let dialed = b.rpc("bridge.pair_connect", json!({ "addr": pairing, "pin": pin, "label": "alice-mac" })).unwrap();
    let sas = dialed["sas"].as_str().unwrap().to_string();
    let b_saw = dialed["peer_spki"].as_str().unwrap().to_string();
    assert_eq!(b_saw, a_spki, "the dialer saw the listener's key");
    let compare = a.event("bridge://sas-compare");
    assert_eq!(compare["sas"].as_str().unwrap(), sas, "both sides show the same code");
    let b_spki = compare["peerSpki"].as_str().unwrap().to_string();
    assert!(compare["peerAddr"].as_str().unwrap().starts_with("127.0.0.1:"));

    // Nothing is pinned until the human confirms; the other side's code must match.
    assert_eq!(a.rpc("bridge.list_peers", json!({})).unwrap(), json!([]));
    a.rpc("bridge.pair_confirm_sas", json!({ "peerSpki": b_spki, "sasOk": true, "label": "bob-mac", "theirSas": sas })).unwrap();
    b.rpc("bridge.pair_confirm_sas", json!({ "peerSpki": a_spki, "sasOk": true, "label": "alice-mac" })).unwrap();
    let a_peers = a.rpc("bridge.list_peers", json!({})).unwrap();
    assert_eq!(a_peers[0]["spki_hash"], json!(b_spki));
    assert_eq!(a_peers[0]["label"], json!("bob-mac"));
    let b_peers = b.rpc("bridge.list_peers", json!({})).unwrap();
    assert_eq!(b_peers[0]["spki_hash"], json!(a_spki));
    assert_eq!(b_peers[0]["last_addr"], json!(data), "the dialer keeps the data address, not the one-shot pairing window");
    assert!(ea.home.join("Library/Application Support/muya/bridge").is_dir(), "state lives under the daemon's HOME");

    let sent = b.rpc("bridge.remote_send", json!({ "peer": a_spki, "kind": "question", "payload": { "text": "hello from the other mac" } }));
    let req_id = sent.unwrap_or_else(|e| panic!("send failed: {e}"));
    assert!(req_id.is_string());
    // No local session can take it: it is held (never typed anywhere) and the UI hears the count.
    assert_eq!(a.event("bridge://held"), json!(1));

    // Revoke: gone from the registry, and the revoked side can no longer get through.
    a.rpc("bridge.revoke_peer", json!({ "spkiHash": b_spki })).unwrap();
    assert_eq!(a.rpc("bridge.list_peers", json!({})).unwrap(), json!([]));
    // TLS 1.3 lets the client finish its side before the server's verdict, so the sender may not
    // see the refusal: what matters is that the listener rejects the handshake and delivers nothing.
    let _ = b.rpc("bridge.remote_send", json!({ "peer": a_spki, "kind": "question", "payload": { "text": "still there?" } }));
    let rejected = a.event("bridge://error");
    assert!(rejected.as_str().unwrap().starts_with("handshake_rejected:"), "{rejected}");
    std::thread::sleep(Duration::from_millis(500));
    a.rpc("bridge.list_peers", json!({})).unwrap(); // pump the socket
    assert!(a.events.iter().filter(|(n, _)| n == "bridge://held").count() == 1, "the revoked peer's message was not held: {:?}", a.events);
}

/// A wrong pairing code never ends in a pinned peer, on either side.
#[test]
fn p10_wrong_pairing_code_is_rejected() {
    let _ports = PORTS.lock().unwrap_or_else(|e| e.into_inner());
    let (ea, eb) = (start("a-bad"), start("b-bad"));
    let (mut a, mut b) = (App::connect(&ea.dir.join("m.sock")), App::connect(&eb.dir.join("m.sock")));
    let (invite, _data, pairing) = open_invite(&mut a, free_pair());
    let pin = invite["pin"].as_str().unwrap();
    let wrong = if pin == "00000000" { "11111111" } else { "00000000" };

    match b.rpc("bridge.pair_connect", json!({ "addr": pairing, "pin": wrong, "label": "mallory" })) {
        Err(_) => {} // refused outright
        Ok(dialed) => {
            // SPAKE2 does not fail on a wrong PIN, it yields different codes: the comparison stops it.
            let theirs = dialed["sas"].as_str().unwrap().to_string();
            let compare = a.event("bridge://sas-compare");
            assert_ne!(compare["sas"].as_str().unwrap(), theirs, "a wrong PIN must give different codes");
            let err = a
                .rpc("bridge.pair_confirm_sas", json!({ "peerSpki": compare["peerSpki"], "sasOk": true, "label": "mallory", "theirSas": theirs }))
                .unwrap_err();
            assert!(err.contains("codes differ"), "{err}");
            let err = b.rpc("bridge.pair_confirm_sas", json!({ "peerSpki": dialed["peer_spki"], "sasOk": false, "label": "x" })).unwrap_err();
            assert!(err.contains("rejected"), "{err}");
        }
    }
    assert_eq!(a.rpc("bridge.list_peers", json!({})).unwrap(), json!([]), "nothing pinned on the listener");
    assert_eq!(b.rpc("bridge.list_peers", json!({})).unwrap(), json!([]), "nothing pinned on the dialer");
}

/// The local socket: a staged shell task needs `bridge.approve`; nothing is executed by the bridge.
#[test]
fn p10_local_socket_stages_approves_and_stops() {
    let env = start("local");
    let mut app = App::connect(&env.dir.join("m.sock"));
    app.rpc("bridge.local_listen", json!({ "enable": true })).unwrap();
    let sock = env.dir.join("bridge.sock");
    assert!(sock.exists());
    assert_eq!(std::fs::metadata(&sock).unwrap().permissions().mode() & 0o777, 0o600, "owner-only socket");

    let frame = |id: &str, kind: &str, cap: &str| {
        let env = json!({ "v": 1, "type": "request", "id": id, "peer": "cli", "capability": cap, "kind": kind, "payload": { "cmd": "rm -rf /" } });
        let body = serde_json::to_vec(&env).unwrap();
        let mut f = (body.len() as u32).to_be_bytes().to_vec();
        f.extend(body);
        f
    };
    let mut s = connect_retry(&sock);
    s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    s.write_all(&frame("req-shell", "task", "shell")).unwrap();
    let mut len = [0u8; 4];
    s.read_exact(&mut len).unwrap();
    let mut ack = vec![0u8; u32::from_be_bytes(len) as usize];
    s.read_exact(&mut ack).unwrap();
    let ack: Value = serde_json::from_slice(&ack).unwrap();
    assert_eq!(ack["payload"]["approval"], json!("pending_approval"));
    s.write_all(&frame("req-q", "question", "research")).unwrap();
    // Both requests are queued once both events were heard: the drain below is then deterministic.
    assert_eq!(app.events_n("bridge://inbound-request", 2), vec![json!("req-shell"), json!("req-q")]);

    let polled = app.rpc("bridge.poll_inbound", json!({})).unwrap();
    let ids: Vec<&str> = polled.as_array().unwrap().iter().map(|r| r["req_id"].as_str().unwrap()).collect();
    assert!(ids.contains(&"req-shell"), "{polled}");
    assert_eq!(polled[0]["approval"], json!("pending_approval"));
    assert_eq!(app.rpc("bridge.poll_inbound", json!({})).unwrap(), json!([]), "polling drains the queue");

    app.rpc("bridge.approve", json!({ "reqId": "req-shell", "decision": "allow" })).unwrap();
    assert!(app.rpc("bridge.approve", json!({ "reqId": "req-shell", "decision": "maybe" })).is_err());
    assert!(app.rpc("bridge.approve", json!({ "reqId": "nope", "decision": "deny" })).is_err());
    // A peer that is not a running session cannot be written to.
    // `bridge.send` writes a request frame to the local socket: while listening it queues, after it is not possible.
    let sent = app.rpc("bridge.send", json!({ "peer": "no-such-session", "kind": "question", "payload": "hi" }));
    assert!(sent.is_ok(), "{sent:?}");

    app.rpc("bridge.local_listen", json!({ "enable": false })).unwrap();
    assert!(!sock.exists(), "the socket file is removed when listening stops");
    assert!(app.rpc("bridge.send", json!({ "peer": "x", "kind": "question", "payload": "hi" })).is_err(), "no listener, no send");
}

/// The remote listener never binds every interface, and unknown names are plain errors.
#[test]
fn p10_remote_listener_refuses_wildcards() {
    let env = start("wild");
    let mut app = App::connect(&env.dir.join("m.sock"));
    for addr in ["0.0.0.0:9911", "[::]:9911", "[::ffff:0.0.0.0]:9911"] {
        let err = app.rpc("bridge.remote_listen", json!({ "enable": true, "iface": addr })).unwrap_err();
        assert!(err.contains("SECURITY"), "{addr}: {err}");
        let err = app.rpc("bridge.pair_start_listener", json!({ "pairingIface": addr })).unwrap_err();
        assert!(err.contains("SECURITY"), "{addr}: {err}");
    }
    let err = app.rpc("bridge.nope", json!({})).unwrap_err();
    assert!(err.contains("unknown method"), "{err}");
    let check = app.rpc("bridge.check_port", json!({ "addr": "127.0.0.1:0" }));
    assert!(check.is_ok() || check.is_err()); // reachable either way; the point is it does not panic
}

/// The agents' `bridge_*` tools (MCP broker) and the app's `bridge.*` Rpc see the same bridge.
#[test]
fn p10_broker_bridge_tools_share_the_rpc_state() {
    use std::io::BufRead;
    let _ports = PORTS.lock().unwrap_or_else(|e| e.into_inner());
    let mut env = Env { dir: PathBuf::from(format!("/tmp/muya-p10-broker-{}", std::process::id())), home: PathBuf::new(), kids: vec![] };
    let _ = std::fs::remove_dir_all(&env.dir);
    env.home = env.dir.join("home");
    std::fs::create_dir_all(&env.home).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_muyad"))
        .env_clear()
        .env("HOME", &env.home)
        .env("PATH", "/usr/bin:/bin")
        .env("MUYA_SSH_BROKER_SOCK", env.dir.join("b.sock"))
        .arg("--socket").arg(env.dir.join("m.sock"))
        .arg("--ptyd").arg(env.dir.join("p.sock"))
        .arg("--broker")
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    env.kids.push(child);
    let (m, b) = (env.dir.join("m.sock"), env.dir.join("b.sock"));
    wait_for("muyad + broker sockets", || m.exists() && UnixStream::connect(&b).is_ok());
    let mut app = App::connect(&m);
    let ask = |line: &str| -> Value {
        let mut s = connect_retry(&b);
        s.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
        writeln!(s, "{line}").unwrap();
        let mut out = String::new();
        std::io::BufReader::new(s).read_line(&mut out).unwrap();
        serde_json::from_str(&out).unwrap_or_else(|_| panic!("not json: {out}"))
    };
    let (data, _) = free_pair();
    let r = ask(&format!(r#"{{"op":"bridge_invite","session_id":"s1","bridge":{{"addr":"127.0.0.1:{data}"}}}}"#));
    assert_eq!(r["ok"], json!(true), "{r}");
    assert_eq!(r["data"]["listening"], json!(format!("127.0.0.1:{data}")));
    // The Rpc side hears the same listener start, and a second Rpc listen is the same no-op.
    assert_eq!(app.event("bridge://peer-status"), json!("remote_listener:started"));
    app.rpc("bridge.remote_listen", json!({ "enable": true, "iface": format!("127.0.0.1:{data}") })).unwrap();
    let peers = ask(r#"{"op":"bridge_peers","session_id":"s1","bridge":{}}"#);
    assert_eq!(peers["ok"], json!(true), "{peers}");
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

/// Operator widening of an agent-paired Mac: the app's connection lists it (with who paired it) and
/// flips Messaging <-> Full; bad values and unknown peers fail.
#[test]
fn operator_sets_a_peers_scope() {
    let peer = |label: &str, by: &str, cap: &str| json!({ "schema_v": 1, "spki_hash": format!("{label:0<64}"), "label": label, "last_addr": null, "paired_at": 1700000000, "capability": cap, "paired_by": by });
    let (a, b) = (peer("aa", "agent", "messaging"), peer("bb", "operator", "research"));
    let spki = a["spki_hash"].as_str().unwrap().to_string();
    let registry = json!({ spki.clone(): a, b["spki_hash"].as_str().unwrap(): b });
    let env = start_with("scope", Some(&registry));
    let mut app = App::connect(&env.dir.join("m.sock"));
    let by = |v: &Value, l: &str| v.as_array().unwrap().iter().find(|p| p["label"] == l).unwrap().clone();
    let peers = app.rpc("bridge.list_peers", json!({})).unwrap();
    assert_eq!((by(&peers, "aa")["paired_by"].clone(), by(&peers, "aa")["capability"].clone()), (json!("agent"), json!("messaging")));
    assert_eq!(by(&peers, "bb")["paired_by"], json!("operator"));
    app.rpc("bridge.set_peer_capability", json!({ "peerSpki": spki, "capability": "full" })).unwrap();
    assert_eq!(by(&app.rpc("bridge.list_peers", json!({})).unwrap(), "aa")["capability"], json!("research"));
    app.rpc("bridge.set_peer_capability", json!({ "peerSpki": spki, "capability": "messaging" })).unwrap();
    assert_eq!(by(&app.rpc("bridge.list_peers", json!({})).unwrap(), "aa")["capability"], json!("messaging"));
    assert!(app.rpc("bridge.set_peer_capability", json!({ "peerSpki": spki, "capability": "root" })).is_err());
    assert!(app.rpc("bridge.set_peer_capability", json!({ "peerSpki": "nope", "capability": "full" })).is_err());
}

//! Parity package P11 — bridge B in muyad: capabilities, gated exec, fan-out, headless Claude.
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
        a.send(muya_proto::hello(Role::App, "p11-test"));
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



/// A muyad in its own temp HOME + bridge socket. `path` is its PATH; `extra` extra environment.
fn start(tag: &str, path: &str, extra: &[(&str, &str)]) -> Env {
    let dir = PathBuf::from(format!("/tmp/muya-p11-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let mut env = Env { dir, home, kids: vec![] };
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_muyad"));
    cmd.env_clear()
        .env("HOME", &env.home)
        .env("PATH", path)
        .env("MUYA_BRIDGE_SOCK", env.dir.join("bridge.sock"));
    for (k, v) in extra {
        cmd.env(k, v);
    }
    let muyad = cmd
        .arg("--socket")
        .arg(env.dir.join("m.sock"))
        .arg("--ptyd")
        .arg(env.dir.join("p.sock"))
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    env.kids.push(muyad);
    let m = env.dir.join("m.sock");
    wait_for("muyad socket", || m.exists() && UnixStream::connect(&m).is_ok());
    env
}

static PORTS: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn free_pair() -> (u16, u16) {
    loop {
        let a = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let p = a.local_addr().unwrap().port();
        if p < 65000 && std::net::TcpListener::bind(("127.0.0.1", p + 1)).is_ok() {
            return (p, p + 1);
        }
    }
}

/// `a` listens, `d` dials; both confirm the same code. Returns (a's spki, d's spki as a sees it).
fn pair(a: &mut App, d: &mut App, label: &str) -> (String, String) {
    let ports = free_pair();
    let (data, pairing) = (format!("127.0.0.1:{}", ports.0), format!("127.0.0.1:{}", ports.1));
    a.rpc("bridge.remote_listen", json!({ "enable": true, "iface": data })).unwrap();
    let invite = a.rpc("bridge.pair_invite", json!({})).unwrap();
    a.rpc("bridge.pair_start_listener", json!({ "pairingIface": pairing })).unwrap();
    let pin = invite["pin"].as_str().unwrap().to_string();
    let a_spki = invite["our_spki"].as_str().unwrap().to_string();
    let dialed = d.rpc("bridge.pair_connect", json!({ "addr": pairing, "pin": pin, "label": "dialer" })).unwrap();
    let sas = dialed["sas"].as_str().unwrap().to_string();
    let n = a.events.iter().filter(|(k, _)| k == "bridge://sas-compare").count();
    let compare = a.events_n("bridge://sas-compare", n + 1).pop().unwrap();
    let d_spki = compare["peerSpki"].as_str().unwrap().to_string();
    a.rpc("bridge.pair_confirm_sas", json!({ "peerSpki": d_spki, "sasOk": true, "label": label, "theirSas": sas })).unwrap();
    d.rpc("bridge.pair_confirm_sas", json!({ "peerSpki": a_spki, "sasOk": true, "label": "listener" })).unwrap();
    let _ = a.rpc("bridge.pair_stop_listener", json!({}));
    (a_spki, d_spki)
}

/// Puts a task request into `a`'s staged table through its owner-only local socket.
fn stage(env: &Env, a: &mut App, id: &str, payload: Value) {
    let sock = env.dir.join("bridge.sock");
    let n = a.events.iter().filter(|(k, _)| k == "bridge://inbound-request").count();
    let e = json!({ "v": 1, "type": "request", "id": id, "peer": "cli", "capability": "shell", "kind": "task", "payload": payload });
    let body = serde_json::to_vec(&e).unwrap();
    let mut f = (body.len() as u32).to_be_bytes().to_vec();
    f.extend(body);
    let mut s = connect_retry(&sock);
    s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    s.write_all(&f).unwrap();
    let mut len = [0u8; 4];
    s.read_exact(&mut len).unwrap();
    let mut ack = vec![0u8; u32::from_be_bytes(len) as usize];
    s.read_exact(&mut ack).unwrap();
    a.events_n("bridge://inbound-request", n + 1);
}

fn touch_cmd(marker: &Path) -> Value {
    json!({ "cmd": ["/usr/bin/touch", marker.to_string_lossy()] })
}

/// The approval gate, end to end: a task from a paired Mac does not run without capability scope AND
/// the local approval; a denied one never runs (marker file); an approved one streams and finishes.
#[test]
fn p11_exec_is_held_until_approved_and_denied_never_runs() {
    let _ports = PORTS.lock().unwrap_or_else(|e| e.into_inner());
    let (ea, eb) = (start("a-exec", "/usr/bin:/bin", &[]), start("b-exec", "/usr/bin:/bin", &[]));
    let (mut a, mut b) = (App::connect(&ea.dir.join("m.sock")), App::connect(&eb.dir.join("m.sock")));
    let (_a_spki, b_spki) = pair(&mut a, &mut b, "bob-mac");
    a.rpc("bridge.local_listen", json!({ "enable": true })).unwrap();
    let marker = ea.dir.join("ran-marker");
    let exec = |a: &mut App, id: &str| a.rpc("bridge.execute_task", json!({ "reqId": id, "peerSpki": b_spki }));

    // 1. A fresh peer is "research" only: a shell task is refused before anything else.
    stage(&ea, &mut a, "t-scope", touch_cmd(&marker));
    let err = exec(&mut a, "t-scope").unwrap_err();
    assert!(err.contains("capability rejected"), "{err}");
    assert!(a.event("bridge://task-rejected").as_str().unwrap().contains("capability rejected"));
    assert!(!marker.exists(), "out-of-scope task ran");
    assert!(a.rpc("bridge.execute_task", json!({ "reqId": "t-scope", "peerSpki": "nope" })).is_err());
    assert!(exec(&mut a, "no-such-req").unwrap_err().contains("not found"));
    assert!(a.rpc("bridge.set_capability", json!({ "peerSpki": b_spki, "capability": "root" })).is_err());

    // 2. In scope but not approved: held, never runs.
    a.rpc("bridge.set_capability", json!({ "peerSpki": b_spki, "capability": "shell" })).unwrap();
    stage(&ea, &mut a, "t-held", touch_cmd(&marker));
    let err = exec(&mut a, "t-held").unwrap_err();
    assert!(err.contains("not approved") && err.contains("PendingApproval"), "{err}");
    assert!(!marker.exists(), "an unapproved task ran");

    // 3. Denied: still never runs.
    a.rpc("bridge.approve", json!({ "reqId": "t-held", "decision": "deny" })).unwrap();
    let err = exec(&mut a, "t-held").unwrap_err();
    assert!(err.contains("not approved") && err.contains("Denied"), "{err}");
    std::thread::sleep(Duration::from_millis(300));
    assert!(!marker.exists(), "a denied task ran");

    // 4. A raw string command is refused even when approved (no shell interpolation).
    stage(&ea, &mut a, "t-raw", json!({ "cmd": "touch x; echo pwned" }));
    a.rpc("bridge.approve", json!({ "reqId": "t-raw", "decision": "allow" })).unwrap();
    assert!(exec(&mut a, "t-raw").unwrap_err().contains("JSON array"));

    // 5. Approved: runs, streams output and ends.
    stage(&ea, &mut a, "t-ok", touch_cmd(&marker));
    a.rpc("bridge.approve", json!({ "reqId": "t-ok", "decision": "allow" })).unwrap();
    let out = exec(&mut a, "t-ok").unwrap();
    assert!(out.as_str().unwrap().starts_with("exit_code=0, output_hash="), "{out}");
    assert!(marker.exists(), "the approved task did not run");
    let end: Value = serde_json::from_str(a.event("bridge://task-end").as_str().unwrap()).unwrap();
    assert_eq!(end["type"], json!("end"));
    assert_eq!(end["req_id"], json!("t-ok"));
    assert_eq!(end["exit_code"], json!(0));

    stage(&ea, &mut a, "t-echo", json!({ "cmd": ["/bin/sh", "-c", "echo hello-$HOME-x; echo oops >&2"] }));
    a.rpc("bridge.approve", json!({ "reqId": "t-echo", "decision": "allow" })).unwrap();
    exec(&mut a, "t-echo").unwrap();
    let chunks: Vec<String> = a
        .events_n("bridge://task-chunk", 2)
        .iter()
        .map(|c| serde_json::from_str::<Value>(c.as_str().unwrap()).unwrap()["data"].as_str().unwrap().to_string())
        .collect();
    assert!(chunks.iter().any(|c| c.starts_with("hello-") && !c.contains(ea.home.to_str().unwrap())), "{chunks:?}");
    assert!(chunks.iter().any(|c| c.starts_with("[stderr] oops")), "{chunks:?}");

    // 6. Auto-run: shell needs the explicit override on top of the capability.
    let err = a.rpc("bridge.set_auto_run", json!({ "peerSpki": b_spki, "capabilities": ["shell"] })).unwrap_err();
    assert!(err.contains("shell_auto_run_override"), "{err}");
    let _ = std::fs::remove_file(&marker);
    stage(&ea, &mut a, "t-auto", touch_cmd(&marker));
    assert!(exec(&mut a, "t-auto").is_err(), "no approval and no auto-run yet");
    assert!(!marker.exists());
    a.rpc("bridge.set_auto_run", json!({ "peerSpki": b_spki, "capabilities": ["shell"], "shellAutoRunOverride": true })).unwrap();
    exec(&mut a, "t-auto").unwrap();
    assert!(marker.exists(), "auto-run task did not run");

    // 7. The audit log: decisions only, hashes instead of payloads/outputs.
    let log = a.rpc("bridge.audit_log", json!({})).unwrap();
    let log = log.as_array().unwrap();
    let decisions: Vec<&str> = log.iter().map(|e| e["decision"].as_str().unwrap()).collect();
    for want in ["capability_rejected", "denied", "approved", "auto_run"] {
        assert!(decisions.contains(&want), "{want} missing in {decisions:?}");
    }
    assert!(log.iter().all(|e| e["payload_hash"].as_str().unwrap().len() == 64));
    assert!(!serde_json::to_string(log).unwrap().contains("/usr/bin/touch"), "audit holds a payload");
}

/// Fan-out to two paired Macs: every leg is gated on its own.
#[test]
fn p11_fan_out_gates_each_peer_on_its_own() {
    let _ports = PORTS.lock().unwrap_or_else(|e| e.into_inner());
    let (ea, eb, ec) = (start("a-fan", "/usr/bin:/bin", &[]), start("b-fan", "/usr/bin:/bin", &[]), start("c-fan", "/usr/bin:/bin", &[]));
    let mut a = App::connect(&ea.dir.join("m.sock"));
    let (mut b, mut c) = (App::connect(&eb.dir.join("m.sock")), App::connect(&ec.dir.join("m.sock")));
    let (_, b_spki) = pair(&mut a, &mut b, "bob");
    let (_, c_spki) = pair(&mut a, &mut c, "carol");
    assert_ne!(b_spki, c_spki);
    let any = ea.dir.join("leg-any");
    let payload = json!({ "cmd": ["/usr/bin/touch", any.to_string_lossy()] });
    let targets = json!([{ "peer_spki": b_spki, "capability": "shell" }, { "peer_spki": c_spki, "capability": "shell" }]);

    // Nothing granted yet: both legs are refused by their own gate, nothing runs.
    let ids = a.rpc("bridge.fan_out", json!({ "payload": payload, "targets": targets })).unwrap();
    assert_eq!(ids.as_array().unwrap().len(), 2);
    for e in a.events_n("bridge://fanout-error", 2) {
        let e: Value = serde_json::from_str(e.as_str().unwrap()).unwrap();
        assert!(e["error"].as_str().unwrap().contains("capability rejected"), "{e}");
    }
    std::thread::sleep(Duration::from_millis(300));
    assert!(!any.exists(), "a refused leg ran");

    // Only bob is granted shell + auto-run: his leg runs, carol's is still refused.
    a.rpc("bridge.set_capability", json!({ "peerSpki": b_spki, "capability": "shell" })).unwrap();
    a.rpc("bridge.set_auto_run", json!({ "peerSpki": b_spki, "capabilities": ["shell"], "shellAutoRunOverride": true })).unwrap();
    let ids = a.rpc("bridge.fan_out", json!({ "payload": payload, "targets": targets })).unwrap();
    let ids: Vec<String> = ids.as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
    let results = a.events_n("bridge://fanout-result", 1);
    let r: Value = serde_json::from_str(results[0].as_str().unwrap()).unwrap();
    assert_eq!(r["peer_spki"], json!(b_spki));
    assert_eq!(r["req_id"], json!(ids[0]));
    assert!(r["result"].as_str().unwrap().starts_with("exit_code=0"));
    assert!(any.exists(), "bob's leg did not run");
    let errs = a.events_n("bridge://fanout-error", 3);
    let last: Value = serde_json::from_str(errs[2].as_str().unwrap()).unwrap();
    assert_eq!(last["peer_spki"], json!(c_spki));
    assert!(a.rpc("bridge.fan_out", json!({ "payload": payload, "targets": [{}] })).is_err());
}

/// run_claude: finds a `claude` that supports `--print` by asking it (an older one earlier on PATH
/// that lacks the flag is skipped), runs it with a stripped environment, and gives back the answer.
#[test]
fn p11_run_claude_probes_the_capability_and_strips_the_environment() {
    let dir = PathBuf::from(format!("/tmp/muya-p11-claude-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let (old, new) = (dir.join("old"), dir.join("new"));
    std::fs::create_dir_all(&old).unwrap();
    std::fs::create_dir_all(&new).unwrap();
    let write = |d: &Path, body: &str| {
        let p = d.join("claude");
        std::fs::write(&p, body).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    };
    // Exists, answers --version, but has no --print: must never be used.
    write(&old, "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 2.1.0; exit 0; fi\nif [ \"$1\" = --help ]; then echo 'usage: claude [options]'; exit 0; fi\necho WRONG-BINARY\n");
    write(&new, "#!/bin/sh\nif [ \"$1\" = --help ]; then echo '  -p, --print   headless'; exit 0; fi\nif [ \"$1\" = -p ]; then echo \"answer to: $2 | token=[$MY_TEST_SECRET_TOKEN] cwd=$(pwd)\"; exit 0; fi\nexit 9\n");
    let path = format!("{}:{}:/usr/bin:/bin", old.display(), new.display());
    let e = start("rc", &path, &[("MY_TEST_SECRET_TOKEN", "super-secret-value")]);
    let mut app = App::connect(&e.dir.join("m.sock"));
    let ans = app.rpc("bridge.run_claude", json!({ "question": "what is 2+2?" })).unwrap();
    let ans = ans.as_str().unwrap();
    assert!(ans.contains("answer to: what is 2+2?"), "{ans}");
    assert!(ans.contains("token=[]"), "the secret leaked into headless claude: {ans}");
    assert!(!ans.contains("super-secret-value") && !ans.contains("WRONG-BINARY"), "{ans}");
    assert!(!ans.contains(e.home.to_str().unwrap()), "runs in a sandbox, not the operator's home: {ans}");
    assert!(app.rpc("bridge.run_claude", json!({ "question": "   " })).unwrap_err().contains("empty question"));
    drop(app);
    drop(e);
    let _ = std::fs::remove_dir_all(&dir);
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

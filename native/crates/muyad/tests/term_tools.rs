//! docs/prd-native-mcp-terminal.md — `open_terminal`, `send_terminal` and `broadcast` through the real broker
//! socket of a real muyad + ptyd (no fake `claude`: the terminals here are plain shells, so `claude agents`
//! is empty). The "app" is a socket client that attaches to the sessions and reads what the shells print.

use muya_proto::{Control, Decoder, Frame, Role};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct Env {
    dir: PathBuf,
    kids: Vec<Child>,
    /// Fake sidecar subscription: makes this test process a VERIFIED caller (an unverified peer may not broadcast).
    _sub: Option<UnixStream>,
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
    let end = Instant::now() + Duration::from_secs(20);
    while !ok() {
        assert!(Instant::now() < end, "timed out: {what}");
        std::thread::sleep(Duration::from_millis(30));
    }
}

fn start(tag: &str) -> Env {
    let dir = PathBuf::from(format!("/tmp/muya-tt-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    // A short, quiet prompt; nothing else of the machine's shell setup leaks in.
    std::fs::write(home.join(".zshrc"), "PROMPT='%# '\nunsetopt BEEP\n").unwrap();
    let ptyd = Command::new(Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name("muya-ptyd"))
        .env("MUYA_PTYD_EXIT_WITH_PARENT", "1")
        .arg("--socket")
        .arg(dir.join("p.sock"))
        .spawn()
        .expect("cargo build --workspace first");
    let mut env = Env { dir, kids: vec![ptyd], _sub: None };
    let p = env.dir.join("p.sock");
    wait_for("ptyd", || p.exists());
    let muyad = Command::new(env!("CARGO_BIN_EXE_muyad"))
        .env_clear()
        .env("HOME", &home)
        .env("PATH", "/usr/bin:/bin")
        .env("MUYA_SSH_BROKER_SOCK", env.dir.join("b.sock"))
        .arg("--socket")
        .arg(env.dir.join("m.sock"))
        .arg("--ptyd")
        .arg(&p)
        .arg("--broker")
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    env.kids.push(muyad);
    let (m, b) = (env.dir.join("m.sock"), env.dir.join("b.sock"));
    wait_for("muyad + broker sockets", || m.exists() && b.exists() && UnixStream::connect(&b).is_ok());
    let mut sub = UnixStream::connect(&b).unwrap();
    writeln!(sub, r#"{{"op":"subscribe","sessionId":"term-tools-caller"}}"#).unwrap();
    let mut ack = String::new();
    BufReader::new(sub.try_clone().unwrap()).read_line(&mut ack).unwrap();
    assert!(ack.contains(r#""ok":true"#), "subscribe: {ack}");
    env._sub = Some(sub);
    env
}

fn broker(env: &Env, req: Value) -> Value {
    let mut s = UnixStream::connect(env.dir.join("b.sock")).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    writeln!(s, "{req}").unwrap();
    let mut out = String::new();
    BufReader::new(s).read_line(&mut out).unwrap();
    serde_json::from_str(&out).unwrap_or_else(|_| panic!("not json: {out}"))
}

/// An attached app: records events and the output of every session it attached to.
struct App {
    s: UnixStream,
    dec: Decoder,
    events: Vec<(String, Value)>,
    out: HashMap<u64, Vec<u8>>,
}

impl App {
    fn connect(sock: &Path) -> Self {
        let s = UnixStream::connect(sock).unwrap();
        s.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        let mut a = Self { s, dec: Decoder::default(), events: vec![], out: HashMap::new() };
        a.s.write_all(&Frame::Control(muya_proto::hello(Role::App, "tt-test")).encode()).unwrap();
        a.pump_until(|_| false, Duration::from_millis(300)); // the welcome
        a
    }
    fn pump(&mut self) {
        let mut buf = [0u8; 65536];
        if let Ok(n) = self.s.read(&mut buf) {
            assert!(n > 0, "muyad closed");
            self.dec.push(&buf[..n]);
        }
        while let Some(f) = self.dec.next_frame().unwrap() {
            match f {
                Frame::Output { session, data, .. } => self.out.entry(session).or_default().extend(data),
                Frame::Control(Control::Event { name, payload }) => self.events.push((name, serde_json::from_str(&payload).unwrap())),
                _ => {}
            }
        }
    }
    fn pump_until(&mut self, mut done: impl FnMut(&mut Self) -> bool, within: Duration) -> bool {
        let end = Instant::now() + within;
        loop {
            self.pump();
            if done(self) {
                return true;
            }
            if Instant::now() > end {
                return false;
            }
        }
    }
    fn event(&mut self, name: &str) -> Value {
        assert!(self.pump_until(|a| a.events.iter().any(|(n, _)| n == name), Duration::from_secs(10)), "no event {name}: {:?}", self.events);
        self.events.iter().find(|(n, _)| n == name).unwrap().1.clone()
    }
    fn attach(&mut self, id: u64) {
        self.s.write_all(&Frame::Control(Control::Attach { id }).encode()).unwrap();
    }
    fn shows(&mut self, id: u64, needle: &str) -> bool {
        let n = needle.as_bytes().to_vec();
        self.pump_until(|a| a.out.get(&id).is_some_and(|o| o.windows(n.len()).any(|w| w == n.as_slice())), Duration::from_secs(15))
    }
}

#[test]
fn open_terminal_send_terminal_and_broadcast_reach_real_shells() {
    let env = start("e2e");
    let mut app = App::connect(&env.dir.join("m.sock"));

    // open_terminal: a shell tab with a name; the app is told to adopt it; the first command runs.
    let r = broker(&env, json!({"op":"open_terminal","name":"alpha","cwd":"/tmp","command":"echo FIRST$((6*7))"}));
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["name"], "alpha");
    let a = r["id"].as_u64().unwrap();
    let ev = app.event("muya://terminal-opened");
    assert_eq!((ev["id"].as_u64(), ev["name"].as_str(), ev["cwd"].as_str()), (Some(a), Some("alpha"), Some("/tmp")));
    app.attach(a);
    assert!(app.shows(a, "FIRST42"), "the first command ran: {}", String::from_utf8_lossy(app.out.get(&a).map_or(&[][..], |v| v)));

    // send_terminal: raw text + Enter by name (and by id); the tab shows the output.
    let r = broker(&env, json!({"op":"send_terminal","target":"alpha","command":"echo HI$((6*7))"}));
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["target"]["id"], a);
    assert!(app.shows(a, "HI42"), "send_terminal output");
    // enter:false types but does not run.
    let r = broker(&env, json!({"op":"send_terminal","target":a.to_string(),"command":"echo HELD$((6*7))","enter":false}));
    assert_eq!(r["ok"], true, "{r}");
    assert!(app.shows(a, "echo HELD$((6*7))"), "typed text is echoed");
    assert!(!app.shows_quick(a, "HELD42"), "not executed without Enter");
    let r = broker(&env, json!({"op":"send_terminal","target":"alpha","command":"\u{15}echo CTRL"})); // a control byte in the text is neutralised, not typed as a key
    assert_eq!(r["ok"], true, "{r}");

    // Two more tabs; names must be unique and a missing target is an error.
    let b = broker(&env, json!({"op":"open_terminal","name":"beta"}))["id"].as_u64().unwrap();
    let c = broker(&env, json!({"op":"open_terminal"}));
    assert_eq!(c["name"], "terminal-1", "{c}");
    let c = c["id"].as_u64().unwrap();
    assert_eq!(broker(&env, json!({"op":"open_terminal","name":"ALPHA"}))["ok"], false);
    assert_eq!(broker(&env, json!({"op":"send_terminal","target":"nope","command":"x"}))["ok"], false);
    app.attach(b);
    app.attach(c);

    // broadcast: all three shells run it; one result per target.
    let r = broker(&env, json!({"op":"broadcast","command":"echo BC$((6*7))"}));
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!((r["sent"].as_u64(), r["skipped"].as_u64()), (Some(3), Some(0)), "{r}");
    for id in [a, b, c] {
        assert!(app.shows(id, "BC42"), "broadcast reached {id}");
    }
    assert_eq!(r["results"].as_array().unwrap().iter().filter(|x| x["status"] == "sent").count(), 3);
    // kind:"claude" matches nothing here.
    let r = broker(&env, json!({"op":"broadcast","command":"x","kind":"claude"}));
    assert_eq!((r["ok"].as_bool(), r["sent"].as_u64()), (Some(true), Some(0)), "{r}");
}

impl App {
    /// Whether `needle` shows up within a short window (for "must NOT appear" checks).
    fn shows_quick(&mut self, id: u64, needle: &str) -> bool {
        let n = needle.as_bytes().to_vec();
        self.pump_until(|a| a.out.get(&id).is_some_and(|o| o.windows(n.len()).any(|w| w == n.as_slice())), Duration::from_millis(800))
    }
}

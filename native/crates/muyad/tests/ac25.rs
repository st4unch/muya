//! PRD AC25: `send_to_session` (deliver "muya"/"keys") retried with the same `idempotencyKey` types
//! its text once — also when muyad is killed with SIGKILL between the two attempts.
//!
//! Everything runs against a temp HOME with a FAKE `claude` that lists one session; the real CLI is
//! never reachable (PATH is `/usr/bin:/bin`). The "app" is a plain socket client that counts the
//! `muya://deliver-message` events muyad sends it (that event is what makes the frontend type).

use muya_proto::{Control, Decoder, Frame, Role};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

struct Env {
    dir: PathBuf,
    home: PathBuf,
    ptyd: Child,
    muyad: Option<Child>,
    /// The fake sidecar subscription that makes this test process a VERIFIED caller (M8): an unverified
    /// socket peer may only type into sessions it opened itself.
    sub: Option<UnixStream>,
}

impl Drop for Env {
    fn drop(&mut self) {
        if let Some(m) = self.muyad.as_mut() {
            let _ = m.kill();
            let _ = m.wait();
        }
        let _ = self.ptyd.kill();
        let _ = self.ptyd.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn wait_for(what: &str, mut ok: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !ok() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn script(path: &Path, body: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn setup(tag: &str) -> Env {
    let dir = PathBuf::from(format!("/tmp/muya-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    script(
        &home.join(".local/bin/claude"),
        // The registry also lists the test process as the sidecar's session: a claimed identity must be backed by it.
        &format!("#!/bin/sh\nif [ \"$1\" = agents ]; then echo '[{{\"sessionId\":\"sess-1\",\"pid\":1,\"name\":\"worker\",\"cwd\":\"/tmp\",\"kind\":\"interactive\",\"startedAt\":1,\"status\":\"idle\"}},{{\"sessionId\":\"ac25-caller\",\"pid\":{},\"name\":\"ac25-caller\",\"cwd\":\"/tmp\",\"kind\":\"interactive\",\"startedAt\":1,\"status\":\"idle\"}}]'; exit 0; fi\nexit 1\n", std::process::id()),
    );
    script(
        &dir.join("fakeshell"),
        "#!/bin/sh\nwhile [ \"$1\" != -c ]; do shift; done\nshift\ncase \"$1\" in \"command -v\"*) exit 1;; esac\nexec /bin/sh -c \"$1\"\n",
    );
    let ptyd = Command::new(Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name("muya-ptyd"))
        .env("MUYA_PTYD_EXIT_WITH_PARENT", "1")
        .arg("--socket")
        .arg(dir.join("p.sock"))
        .spawn()
        .expect("cargo build --workspace first");
    let p = dir.join("p.sock");
    wait_for("ptyd socket", || p.exists());
    Env { dir, home, ptyd, muyad: None, sub: None }
}

fn start_muyad(env: &mut Env) {
    let _ = std::fs::remove_file(env.dir.join("m.sock"));
    let child = Command::new(env!("CARGO_BIN_EXE_muyad"))
        .env_clear()
        .env("MUYA_BROKER_TRACKING", "off") // these tests have no Claude: the event path is what they check
        .env("HOME", &env.home)
        .env("PATH", "/usr/bin:/bin")
        .env("SHELL", env.dir.join("fakeshell"))
        .env("MUYA_SSH_BROKER_SOCK", env.dir.join("b.sock"))
        .arg("--socket")
        .arg(env.dir.join("m.sock"))
        .arg("--ptyd")
        .arg(env.dir.join("p.sock"))
        .arg("--broker")
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    env.muyad = Some(child);
    let (m, b) = (env.dir.join("m.sock"), env.dir.join("b.sock"));
    wait_for("muyad + broker sockets", || m.exists() && b.exists() && UnixStream::connect(&b).is_ok());
    let mut sub = connect_retry(&b);
    writeln!(sub, r#"{{"op":"subscribe","sessionId":"ac25-caller"}}"#).unwrap();
    let mut ack = String::new();
    BufReader::new(sub.try_clone().unwrap()).read_line(&mut ack).unwrap();
    assert!(ack.contains(r#""ok":true"#), "subscribe: {ack}");
    env.sub = Some(sub);
}

/// SIGKILL: no shutdown hooks, nothing flushed that was not already on disk.
fn kill9(env: &mut Env) {
    env.sub = None;
    let mut m = env.muyad.take().unwrap();
    unsafe { libc::kill(m.id() as i32, libc::SIGKILL) };
    let _ = m.wait();
    let _ = std::fs::remove_file(env.dir.join("b.sock"));
}

/// An attached app: every `muya://deliver-message` payload arrives on the channel.
fn attach_app(env: &Env) -> (UnixStream, Receiver<serde_json::Value>) {
    let mut s = connect_retry(env.dir.join("m.sock"));
    s.write_all(&Frame::Control(muya_proto::hello(Role::App, "ac25")).encode()).unwrap();
    let (tx, rx) = channel();
    let mut reader = s.try_clone().unwrap();
    std::thread::spawn(move || {
        let (mut dec, mut buf) = (Decoder::default(), [0u8; 65536]);
        loop {
            let Ok(n) = reader.read(&mut buf) else { return };
            if n == 0 {
                return;
            }
            dec.push(&buf[..n]);
            while let Ok(Some(f)) = dec.next_frame() {
                if let Frame::Control(Control::Event { name, payload }) = f
                    && name == "muya://deliver-message"
                {
                    let _ = tx.send(serde_json::from_str(&payload).unwrap());
                }
            }
        }
    });
    // The attach is registered once Welcome was answered; a List round trip proves it.
    s.write_all(&Frame::Control(Control::List).encode()).unwrap();
    std::thread::sleep(Duration::from_millis(300));
    (s, rx)
}

fn send(env: &Env, extra: &str) -> serde_json::Value {
    let mut s = connect_retry(env.dir.join("b.sock"));
    s.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
    writeln!(s, r#"{{"op":"send_to_session","target":"worker","text":"deploy now\n","deliver":"keys"{extra}}}"#).unwrap();
    let mut line = String::new();
    BufReader::new(s).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|_| panic!("not json: {line}"))
}

fn drain(rx: &Receiver<serde_json::Value>, wait: Duration) -> Vec<serde_json::Value> {
    std::thread::sleep(wait);
    rx.try_iter().collect()
}

#[test]
fn same_key_types_once_even_when_muyad_is_kill9ed_between_the_attempts() {
    let mut env = setup("ac25a");
    start_muyad(&mut env);
    let (app, rx) = attach_app(&env);

    let r = send(&env, r#","idempotencyKey":"msg-1""#);
    assert_eq!(r["ok"], true, "{r}");
    assert!(r.get("duplicate").is_none(), "{r}");
    let typed = drain(&rx, Duration::from_millis(500));
    assert_eq!(typed.len(), 1, "first attempt types once: {typed:?}");
    assert_eq!(typed[0]["sessionId"], "sess-1");
    assert_eq!(typed[0]["text"], "deploy now\r", "a line feed in keys is sent as Enter");

    // The app/muyad dies right after the first attempt (the caller never saw the reply).
    drop(app);
    kill9(&mut env);
    start_muyad(&mut env);
    let (_app2, rx2) = attach_app(&env);

    let r = send(&env, r#","idempotencyKey":"msg-1""#);
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["duplicate"], true, "the retry must be recognised: {r}");
    assert!(drain(&rx2, Duration::from_millis(700)).is_empty(), "the retry typed again");

    // Control: a NEW key and a call without a key still type (the channel is not just dead).
    assert_eq!(send(&env, r#","idempotencyKey":"msg-2""#)["ok"], true);
    assert_eq!(send(&env, "")["ok"], true);
    assert_eq!(send(&env, "")["ok"], true);
    assert_eq!(drain(&rx2, Duration::from_millis(500)).len(), 3, "new key + two keyless sends each type");
}

#[test]
fn a_failed_hand_off_gives_the_key_back() {
    let mut env = setup("ac25b");
    start_muyad(&mut env);
    // No app attached: the broker tells the agent it failed, and the key must stay usable.
    let r = send(&env, r#","idempotencyKey":"msg-9""#);
    assert_eq!(r["ok"], false, "{r}");
    let (_app, rx) = attach_app(&env);
    let r = send(&env, r#","idempotencyKey":"msg-9""#);
    assert_eq!(r["ok"], true, "{r}");
    assert!(r.get("duplicate").is_none(), "{r}");
    assert_eq!(drain(&rx, Duration::from_millis(500)).len(), 1);
    // And now it is a duplicate.
    assert_eq!(send(&env, r#","idempotencyKey":"msg-9""#)["duplicate"], true);
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

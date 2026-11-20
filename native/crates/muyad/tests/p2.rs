//! Parity package P2 — the daemon side of agent control, metrics, operations and the UI events.
//! A real muyad (+ ptyd, broker) in a temp HOME with a FAKE `claude`; the "app" is a socket client
//! that issues `Control::Rpc` calls and records every `Control::Event` muyad sends it.

use muya_proto::{Control, Decoder, Frame, Role};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
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

const FAKE_CLAUDE: &str = r#"#!/bin/sh
case "$1" in
  --version) echo "2.1.300 (Claude Code)";;
  agents) echo '[{"sessionId":"sess-1","pid":1,"name":"worker","cwd":"/tmp","kind":"interactive","startedAt":1,"status":"idle"}]';;
  stop) if [ "$2" = bad ]; then echo "no such agent" >&2; exit 1; fi; echo "stopped $2";;
  *) exit 1;;
esac
"#;

fn start(tag: &str) -> Env {
    let dir = PathBuf::from(format!("/tmp/muya-p2-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    std::fs::create_dir_all(home.join(".claude/projects/-work-alpha")).unwrap();
    let fake = home.join(".local/bin/claude");
    std::fs::create_dir_all(fake.parent().unwrap()).unwrap();
    std::fs::write(&fake, FAKE_CLAUDE).unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let ptyd = Command::new(Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name("muya-ptyd"))
        .env("MUYA_PTYD_EXIT_WITH_PARENT", "1")
        .arg("--socket")
        .arg(dir.join("p.sock"))
        .spawn()
        .expect("cargo build --workspace first");
    let mut env = Env {
        dir,
        home,
        kids: vec![ptyd],
    };
    let p = env.dir.join("p.sock");
    wait_for("ptyd", || p.exists());
    let muyad = Command::new(env!("CARGO_BIN_EXE_muyad"))
        .env_clear()
        .env("MUYA_BROKER_TRACKING", "off") // these tests have no Claude: the event path is what they check
        .env("HOME", &env.home)
        .env("PATH", "/usr/bin:/bin")
        .env("MUYA_SSH_BROKER_SOCK", env.dir.join("b.sock"))
        .arg("--socket")
        .arg(env.dir.join("m.sock"))
        .arg("--ptyd")
        .arg(&p)
        .arg("--broker")
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    env.kids.push(muyad);
    let (m, b) = (env.dir.join("m.sock"), env.dir.join("b.sock"));
    wait_for("muyad + broker sockets", || {
        m.exists() && b.exists() && UnixStream::connect(&b).is_ok()
    });
    env
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
        a.send(muya_proto::hello(Role::App, "p2-test"));
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
            // A round trip pumps the socket so queued events are decoded.
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

fn broker(env: &Env, line: &str) -> Value {
    let mut s = connect_retry(env.dir.join("b.sock"));
    s.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
    writeln!(s, "{line}").unwrap();
    let mut out = String::new();
    BufReader::new(s).read_line(&mut out).unwrap();
    serde_json::from_str(&out).unwrap_or_else(|_| panic!("not json: {out}"))
}

/// `agents.channels_supported`, `agents.stop`, `agents.kill`: same answers as the Tauri commands.
#[test]
fn p2_agents_channels_stop_kill() {
    let env = start("agents");
    let mut app = App::connect(&env.dir.join("m.sock"));

    assert_eq!(
        app.rpc("agents.channels_supported", json!({})).unwrap(),
        json!(true),
        "fake claude is 2.1.300"
    );

    assert_eq!(
        app.rpc("agents.stop", json!({ "id": "abc" })).unwrap(),
        json!("stopped abc")
    );
    let err = app.rpc("agents.stop", json!({ "id": "bad" })).unwrap_err();
    assert!(err.contains("no such agent"), "{err}");
    assert!(
        app.rpc("agents.stop", json!({ "id": "--all" })).is_err(),
        "an option is not an id"
    );
    // kill with a background id goes through `claude stop`.
    assert_eq!(
        app.rpc("agents.kill", json!({ "id": "xyz" })).unwrap(),
        json!("stopped xyz")
    );

    // kill by pid terminates an interactive session's process.
    let mut victim = Command::new("/bin/sleep").arg("60").spawn().unwrap();
    let pid = victim.id() as i64;
    let msg = app.rpc("agents.kill", json!({ "pid": pid })).unwrap();
    assert_eq!(msg, json!(format!("sent SIGTERM to pid {pid}")));
    wait_for("victim exit", || victim.try_wait().unwrap().is_some());

    // Never a process group, init, or the daemon itself.
    for pid in [0i64, 1, -1] {
        assert!(
            app.rpc("agents.kill", json!({ "pid": pid })).is_err(),
            "pid {pid} must be refused"
        );
    }
    assert!(app.rpc("agents.kill", json!({})).is_err());
}

/// `agents.touched_files` reads the files the agent of a session touched from its transcript.
#[test]
fn p2_agents_touched_files() {
    let env = start("touched");
    let t = |name: &str, input: &str, ts: &str| {
        format!(
            r#"{{"type":"assistant","timestamp":"{ts}","message":{{"content":[{{"type":"tool_use","name":"{name}","input":{input}}}]}}}}"#
        )
    };
    let body = [
        t(
            "Read",
            r#"{"file_path":"/work/alpha/a.rs"}"#,
            "2026-01-01T00:00:01Z",
        ),
        t(
            "Edit",
            r#"{"file_path":"/work/alpha/a.rs","old_string":"x"}"#,
            "2026-01-01T00:00:02Z",
        ),
    ]
    .join("\n");
    std::fs::write(
        env.home.join(".claude/projects/-work-alpha/s-touch.jsonl"),
        body + "\n",
    )
    .unwrap();
    let mut app = App::connect(&env.dir.join("m.sock"));

    let got = app
        .rpc(
            "agents.touched_files",
            json!({ "cwd": "/work/alpha", "sessionId": "s-touch" }),
        )
        .unwrap();
    let got = got.as_array().unwrap();
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(got[0]["path"], "/work/alpha/a.rs");
    assert_eq!(got[0]["action"], "modified");
    assert_eq!(got[0]["count"], 2);
    assert_eq!(
        app.rpc(
            "agents.touched_files",
            json!({ "cwd": "/work/alpha", "sessionId": "nope" })
        )
        .unwrap(),
        json!([])
    );
    assert!(app
        .rpc(
            "agents.touched_files",
            json!({ "cwd": "/work/alpha", "sessionId": "../x" })
        )
        .is_err());
    assert!(app
        .rpc(
            "agents.touched_files",
            json!({ "cwd": "relative", "sessionId": "s-touch" })
        )
        .is_err());
}

/// `agent_ops.list` / `agent_ops.upsert`: operator-defined operations; list never shows the program.
#[test]
fn p2_agent_ops_list_and_upsert() {
    let env = start("ops");
    let mut app = App::connect(&env.dir.join("m.sock"));
    assert_eq!(app.rpc("agent_ops.list", json!({})).unwrap(), json!([]));

    let op = |desc: &str| json!({ "name": "s3-ls", "description": desc, "program": "/usr/bin/true", "pinnedArgv": ["s3", "ls"], "allowedFlags": ["--region=eu-west-1"], "envMap": {} });
    app.rpc("agent_ops.upsert", json!({ "op": op("first") }))
        .unwrap();
    app.rpc("agent_ops.upsert", json!({ "op": op("second") }))
        .unwrap();
    let list = app.rpc("agent_ops.list", json!({})).unwrap();
    assert_eq!(
        list,
        json!([{ "name": "s3-ls", "description": "second" }]),
        "upsert replaces by name, list hides the program"
    );
    let file = std::fs::read_to_string(env.home.join(".claude/muya-agent-ops.json")).unwrap();
    assert!(file.contains("/usr/bin/true"), "{file}");

    // Refused: no name, a PATH-relative program.
    let mut bad = op("x");
    bad["name"] = json!("  ");
    assert!(app.rpc("agent_ops.upsert", json!({ "op": bad })).is_err());
    let mut bad = op("x");
    bad["program"] = json!("aws");
    assert!(app
        .rpc("agent_ops.upsert", json!({ "op": bad }))
        .unwrap_err()
        .contains("absolute"));
}

/// `metrics.get`: shape, that muyad / ptyd / a spawned session show up, and what one call costs.
#[test]
fn p2_metrics_get_shape_and_cost() {
    let env = start("metrics");
    let mut app = App::connect(&env.dir.join("m.sock"));
    app.send(Control::Spawn {
        argv: vec!["/bin/sh".into(), "-c".into(), "sleep 30".into()],
        cwd: "/tmp".into(),
        env: vec![],
        cols: 80,
        rows: 24,
    });
    let session_pid = match app.read_control() {
        Control::Spawned { pid, .. } => pid as u64,
        other => panic!("{other:?}"),
    };

    let first = app.rpc("metrics.get", json!({})).unwrap();
    let rows = first["processes"].as_array().unwrap();
    let names: Vec<&str> = rows.iter().map(|r| r["name"].as_str().unwrap()).collect();
    for want in ["muyad", "muya-ptyd", "session"] {
        assert!(names.contains(&want), "{want} missing in {names:?}");
    }
    assert!(rows
        .iter()
        .any(|r| r["name"] == "session" && r["pid"] == session_pid));
    let mem: f64 = rows.iter().map(|r| r["memMb"].as_f64().unwrap()).sum();
    assert!(
        first["memMb"].as_f64().unwrap() > 1.0
            && (first["memMb"].as_f64().unwrap() - mem).abs() < 0.001,
        "{first}"
    );
    assert!(first["cpu"].as_f64().unwrap() >= 0.0);

    // Cost of the 2.5 s header poll: the wall time of one call, and the CPU muyad itself spends.
    let muyad_pid = rows.iter().find(|r| r["name"] == "muyad").unwrap()["pid"]
        .as_u64()
        .unwrap();
    let cpu_ticks = |pid: u64| -> f64 {
        let out = Command::new("/bin/ps")
            .args(["-o", "cputime=", "-p", &pid.to_string()])
            .output()
            .unwrap();
        let t = String::from_utf8_lossy(&out.stdout).trim().to_string(); // [[dd-]hh:]mm:ss.ss
        let secs = t
            .rsplit(':')
            .enumerate()
            .map(|(i, p)| p.parse::<f64>().unwrap_or(0.0) * 60f64.powi(i as i32))
            .sum::<f64>();
        secs
    };
    let (before, t0) = (cpu_ticks(muyad_pid), Instant::now());
    for _ in 0..40 {
        app.rpc("metrics.get", json!({})).unwrap();
    }
    let per_call = t0.elapsed() / 40;
    let spent = cpu_ticks(muyad_pid) - before;
    eprintln!("metrics.get: {per_call:?} per call, muyad CPU {spent:.2}s for 40 calls");
    assert!(
        per_call < Duration::from_millis(50),
        "a poll must stay cheap, took {per_call:?}"
    );
}

/// `vault.lock` answers and tells every attached app with `muya://vault-locked` (payload null,
/// like the Tauri app's `emit("muya://vault-locked", ())`).
#[test]
fn p2_vault_lock_emits_vault_locked() {
    let env = start("vault");
    let mut app = App::connect(&env.dir.join("m.sock"));
    let mut other = App::connect(&env.dir.join("m.sock"));
    assert_eq!(app.rpc("vault.lock", json!({})).unwrap(), Value::Null);
    assert_eq!(app.event("muya://vault-locked"), Value::Null);
    assert_eq!(
        other.event("muya://vault-locked"),
        Value::Null,
        "every attached app hears it"
    );
}

/// The three broker events the app listens for, with the payload shapes the Tauri app got:
/// `muya://open-agent-session`, `muya://close-agent-session`, `muya://deliver-message`.
#[test]
fn p2_open_close_deliver_events() {
    let env = start("events");
    let mut app = App::connect(&env.dir.join("m.sock"));
    app.rpc("agents.channels_supported", json!({})).unwrap(); // proves the attach is registered

    let r = broker(
        &env,
        r#"{"op":"open_session","name":"worker","cwd":"/tmp","initialMessage":"hi","openedBy":"boss","unattended":false}"#,
    );
    assert_eq!(r["ok"], true, "{r}");
    let open = app.event("muya://open-agent-session");
    assert_eq!(open["name"], "worker");
    assert_eq!(open["cwd"], "/tmp");
    assert_eq!(open["initialMessage"], "hi");
    assert_eq!(open["agent"], "claude");
    assert_eq!(open["openedBy"], "boss");
    assert_eq!(open["unattended"], false);
    assert!(open["splitWith"].is_null());

    let r = broker(
        &env,
        r#"{"op":"send_to_session","target":"worker","text":"deploy\n","deliver":"keys"}"#,
    );
    assert_eq!(r["ok"], true, "{r}");
    let msg = app.event("muya://deliver-message");
    assert_eq!(msg["sessionId"], "sess-1");

    let r = broker(&env, r#"{"op":"close_session","target":"worker"}"#);
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(
        app.event("muya://close-agent-session"),
        json!({ "sessionId": "sess-1" })
    );

    // Only sessions open_session opened may be closed.
    let r = broker(&env, r#"{"op":"close_session","target":"worker"}"#);
    assert_eq!(r["ok"], false, "{r}");
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

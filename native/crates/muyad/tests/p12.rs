//! Parity package P12 — `notes_vault.*` (the Obsidian notes vault) against a real muyad in a temp HOME.
//! The "python" is a shell script playing the smart-connections MCP server over JSON lines.

//! that issues `Control::Rpc` calls and records every `Control::Event` muyad sends it.

use muya_proto::{Control, Decoder, Frame, Role};
use serde_json::{json, Value};
use std::io::{Read, Write};
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

fn script(path: &Path, body: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn start(tag: &str) -> Env {
    let dir = PathBuf::from(format!("/tmp/muya-p12-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    script(&home.join("fakepy"), FAKE_PY);
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
        .env("HOME", &env.home)
        .env("PATH", "/usr/bin:/bin")
        .env("VAULT_PYTHON", env.home.join("fakepy"))
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
        a.send(muya_proto::hello(Role::App, "p12-test"));
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
}

/// Stands in for `python server.py`: answers `initialize` and every `tools/call`, stays silent for notifications.
const FAKE_PY: &str = r##"#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":0,"result":{"capabilities":{}}}';;
    *'"tools/call"'*) echo '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"blocks\":[{\"path\":\"notes/a.md\",\"similarity\":0.9,\"text\":\"alpha\"},{\"path\":\"notes/b.md\",\"similarity\":0.1,\"text\":\"weak\"}]}"}]}}';;
  esac
done
"##;

#[test]
fn p12_notes_vault_methods_over_rpc() {
    let env = start("vault");
    let mut app = App::connect(&env.dir.join("m.sock"));

    // Nothing configured, nothing installed: clean "off" state, no process.
    let st = app.rpc("notes_vault.status", json!({})).unwrap();
    assert_eq!(st["configuredPath"], Value::Null);
    assert_eq!(st["resolvedPath"], Value::Null);
    assert_eq!(st["serverInstalled"], false);
    assert_eq!(app.rpc("notes_vault.search", json!({"query": "x"})).unwrap_err(), "mcp_unavailable");
    assert_eq!(app.rpc("notes_vault.detect_candidates", json!({})).unwrap(), json!([]));

    // A vault in an ordinary folder is offered; one under Library/CloudStorage is never scanned.
    let vault = env.home.join("Obsidian/Notes");
    std::fs::create_dir_all(vault.join(".obsidian")).unwrap();
    let cloud = env.home.join("Library/CloudStorage/OneDrive/Secret");
    std::fs::create_dir_all(cloud.join(".obsidian")).unwrap();
    let cands = app.rpc("notes_vault.detect_candidates", json!({})).unwrap();
    assert_eq!(cands, json!([vault.to_string_lossy()]), "only the ordinary-folder vault, never CloudStorage");

    // set_path validates.
    let bad = app.rpc("notes_vault.set_path", json!({"path": env.home.join("nowhere").to_string_lossy()})).unwrap_err();
    assert!(bad.contains("not an Obsidian vault"), "{bad}");
    assert!(app.rpc("notes_vault.set_path", json!({"path": "  "})).unwrap_err().contains("path is required"));
    // An explicitly chosen cloud vault is accepted (that is the user's own action).
    app.rpc("notes_vault.set_path", json!({"path": cloud.to_string_lossy()})).unwrap();
    let st = app.rpc("notes_vault.status", json!({})).unwrap();
    assert_eq!(st["configuredPath"], json!(cloud.to_string_lossy()));
    app.rpc("notes_vault.set_path", json!({"path": vault.to_string_lossy()})).unwrap();
    let cfg = std::fs::read_to_string(env.home.join(".claude/muya-vault-config.json")).unwrap();
    assert!(cfg.contains("Notes"), "config persisted: {cfg}");

    // Install the helper, restart, search: the weak block (0.1 < 0.35) is filtered out.
    let server = env.home.join("smart-connections-mcp/server.py");
    std::fs::create_dir_all(server.parent().unwrap()).unwrap();
    std::fs::write(&server, "# fake\n").unwrap();
    // VAULT_MCP_DIR is not set in the daemon: ~/smart-connections-mcp is found through HOME.
    let st = app.rpc("notes_vault.status", json!({})).unwrap();
    assert_eq!(st["serverInstalled"], true);
    assert_eq!(st["resolvedPath"], json!(vault.to_string_lossy()));
    app.rpc("notes_vault.restart", json!({})).unwrap();
    let hits = app.rpc("notes_vault.search", json!({"query": "alpha", "maxBlocks": 3, "timeoutMs": 2000})).unwrap();
    let hits = hits.as_array().unwrap();
    assert_eq!(hits.len(), 1, "{hits:?}");
    assert_eq!(hits[0]["path"], "notes/a.md");
    assert_eq!(hits[0]["text"], "alpha");
    // The password-store methods are untouched by the new namespace.
    assert!(app.rpc("vault.status", json!({})).is_ok());
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

//! PRD AC4: the MCP broker hosted by `muyad --broker`, exercised through the real
//! `muya-ssh-mcp` sidecar (src-tauri/target/debug/muya-ssh-mcp; the test skips with a message if
//! it is not built: `cd src-tauri && cargo build --bin muya-ssh-mcp`).
//! Same check from the shell against any broker socket: `native/tests/ac4-tools-list.sh <socket>`.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct Daemons {
    dir: PathBuf,
    children: Vec<Child>,
}

impl Drop for Daemons {
    fn drop(&mut self) {
        for c in self.children.iter_mut().rev() {
            let _ = c.kill();
            let _ = c.wait();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn wait_for(p: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !p.exists() {
        assert!(Instant::now() < deadline, "{} never appeared", p.display());
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// The sidecar of THIS checkout. `cargo build` in src-tauri copies a prebuilt `binaries/muya-ssh-mcp-*` over
/// target/debug/muya-ssh-mcp, so an existing file can be stale (an older tools/list): build it once here instead of
/// trusting whatever is there. A failed build is a clear panic, not a silent skip.
fn sidecar() -> Option<PathBuf> {
    static BUILT: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();
    BUILT
        .get_or_init(|| {
            let tauri = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../src-tauri");
            if !tauri.join("Cargo.toml").exists() {
                eprintln!("SKIPPED: no src-tauri next to native/ (not a full checkout)");
                return None;
            }
            let out = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()))
                .args(["build", "--bin", "muya-ssh-mcp"])
                .env("CARGO_INCREMENTAL", "0")
                .current_dir(&tauri)
                .output()
                .expect("could not run cargo to build the sidecar");
            assert!(
                out.status.success(),
                "building the sidecar failed (cd src-tauri && cargo build --bin muya-ssh-mcp):\n{}",
                String::from_utf8_lossy(&out.stderr)
            );
            let p = tauri.join("target/debug/muya-ssh-mcp");
            assert!(p.exists(), "the sidecar build succeeded but {} is missing", p.display());
            Some(p)
        })
        .clone()
}

fn start(tag: &str) -> Daemons {
    let bin = |n: &str| Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name(n);
    assert!(bin("muya-ptyd").exists(), "cargo build --workspace first");
    let dir = PathBuf::from(format!("/tmp/muya-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("home")).unwrap();
    let ptyd = Command::new(bin("muya-ptyd"))
        .env("MUYA_PTYD_EXIT_WITH_PARENT", "1")
        .arg("--socket")
        .arg(dir.join("p.sock"))
        .spawn()
        .unwrap();
    wait_for(&dir.join("p.sock"));
    let muyad = Command::new(env!("CARGO_BIN_EXE_muyad"))
        .env("HOME", dir.join("home"))
        .env("MUYA_SSH_BROKER_SOCK", dir.join("b.sock"))
        .arg("--socket")
        .arg(dir.join("m.sock"))
        .arg("--ptyd")
        .arg(dir.join("p.sock"))
        .arg("--broker")
        .spawn()
        .unwrap();
    wait_for(&dir.join("m.sock"));
    wait_for(&dir.join("b.sock"));
    Daemons { dir, children: vec![ptyd, muyad] }
}

/// Runs the sidecar against the broker socket with the given JSON-RPC lines; returns one reply
/// line per request id (stdin stays open until all replies arrived).
fn mcp(bin: &Path, sock: &Path, lines: &[&str]) -> Vec<String> {
    let mut child = Command::new(bin)
        .env("MUYA_SSH_BROKER_SOCK", sock)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());
    let mut replies = Vec::new();
    for l in lines {
        writeln!(stdin, "{l}").unwrap();
        let mut line = String::new();
        out.read_line(&mut line).unwrap();
        replies.push(line.trim_end().to_owned());
    }
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();
    replies
}

fn broker_op(sock: &Path, req: &str) -> String {
    let mut s = connect_retry(sock);
    s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    writeln!(s, "{req}").unwrap();
    let mut line = String::new();
    BufReader::new(s).read_line(&mut line).unwrap();
    line
}

#[test]
fn sidecar_talks_to_the_broker_in_muyad() {
    let Some(bin) = sidecar() else {
        eprintln!("SKIPPED: build the sidecar first: cd src-tauri && cargo build --bin muya-ssh-mcp");
        return;
    };
    let d = start("broker");
    let sock = d.dir.join("b.sock");

    let r = mcp(
        &bin,
        &sock,
        &[
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ssh_list_servers","arguments":{}}}"#,
        ],
    );
    let snapshot = std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../muya-core/tests/snapshots/tools-list.json")).unwrap();
    assert_eq!(r[1], snapshot.trim_end_matches('\n'), "tools/list differs from the snapshot");
    let v: serde_json::Value = serde_json::from_str(&r[2]).unwrap();
    let text = v["result"]["content"][0]["text"].as_str().unwrap_or_else(|| panic!("{}", r[2]));
    let inner: serde_json::Value = serde_json::from_str(text).unwrap_or_else(|_| panic!("not json: {text}"));
    assert!(v["result"]["isError"].as_bool() != Some(true), "{}", r[2]);
    let servers = inner.get("servers").unwrap_or(&inner);
    assert!(servers.as_array().is_some_and(|a| a.is_empty()), "expected the empty list: {text}");

    for req in [r#"{"op":"list_secrets"}"#, r#"{"op":"get_secret","name":"x"}"#] {
        let resp = broker_op(&sock, req);
        let v: serde_json::Value = serde_json::from_str(&resp).unwrap();
        assert_eq!(v["ok"], false, "{resp}");
        assert_eq!(v["error"], muya_core::credstore::LOCKED_MSG, "{resp}");
    }
}

/// An argument the schema does not declare is refused by the sidecar, and `kind` (declared) reaches the broker, which
/// refuses an unknown value: neither is swallowed while a Claude session opens (MCP defect 5).
#[test]
fn undeclared_arguments_and_unknown_kinds_are_refused() {
    let Some(bin) = sidecar() else { return };
    let d = start("broker3");
    let sock = d.dir.join("b.sock");
    let r = mcp(
        &bin,
        &sock,
        &[
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"open_session","arguments":{"name":"x","frobnicate":true}}}"#,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"open_session","arguments":{"name":"x","kind":"terminal"}}}"#,
            r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"schedule_create","arguments":{"name":"a","prompt":"p","folder":"/tmp","schedule":{"kind":"interval","minutes":10},"modle":"x"}}}"#,
        ],
    );
    for (i, want) in [(1, "no argument 'frobnicate'"), (2, "unknown kind 'terminal'"), (3, "no argument 'modle'")] {
        let v: serde_json::Value = serde_json::from_str(&r[i]).unwrap();
        assert_eq!(v["result"]["isError"], true, "{}", r[i]);
        assert!(v["result"]["content"][0]["text"].as_str().unwrap().contains(want), "{}", r[i]);
    }
}

/// Defect 7 against a freshly built sidecar: model and effort are in the schema and come back from schedules_list.
/// (The operator's copy was two weeks old and had neither field; `--version` says which sidecar runs.)
#[test]
fn schedule_model_and_effort_round_trip_and_the_sidecar_reports_its_version() {
    let Some(bin) = sidecar() else { return };
    let v = Command::new(&bin).arg("--version").output().unwrap();
    let v = String::from_utf8_lossy(&v.stdout).to_string();
    assert!(v.starts_with("muya") && v.contains("+tools-"), "{v}");
    let d = start("broker4");
    let sock = d.dir.join("b.sock");
    let create = r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"schedule_create","arguments":{"name":"zz-model","prompt":"p","folder":"/tmp","schedule":{"kind":"interval","minutes":10},"enabled":false,"model":"sonnet","effort":"low"}}}"#;
    let r = mcp(
        &bin,
        &sock,
        &[
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            create,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"schedules_list","arguments":{}}}"#,
        ],
    );
    let init: serde_json::Value = serde_json::from_str(&r[0]).unwrap();
    assert!(init["result"]["serverInfo"]["version"].as_str().unwrap().contains("+tools-"), "{}", r[0]);
    let c: serde_json::Value = serde_json::from_str(&r[1]).unwrap();
    assert_ne!(c["result"]["isError"], true, "{}", r[1]);
    let list = r[2].replace("\\\"", "\"");
    assert!(list.contains("\"model\": \"sonnet\"") && list.contains("\"effort\": \"low\""), "{}", r[2]);
}

#[test]
fn a_live_broker_socket_is_not_taken_over() {
    let Some(_) = sidecar() else { return };
    let d = start("broker2");
    // A second muyad pointed at the same (live) broker socket must start without taking it.
    let ptyd2 = d.dir.join("p.sock");
    let mut second = Command::new(env!("CARGO_BIN_EXE_muyad"))
        .env("HOME", d.dir.join("home"))
        .env("MUYA_SSH_BROKER_SOCK", d.dir.join("b.sock"))
        .arg("--socket")
        .arg(d.dir.join("m2.sock"))
        .arg("--ptyd")
        .arg(&ptyd2)
        .arg("--broker")
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    wait_for(&d.dir.join("m2.sock"));
    let _ = second.kill();
    let mut err = String::new();
    second.stderr.take().unwrap().read_to_string(&mut err).unwrap();
    let _ = second.wait();
    assert!(err.contains("broker not started") && err.contains("already serves the SSH broker"), "{err}");
    // And the first broker still answers.
    assert!(broker_op(&d.dir.join("b.sock"), r#"{"op":"list_servers"}"#).contains("\"ok\":true"));
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

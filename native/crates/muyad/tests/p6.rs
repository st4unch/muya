//! Parity package P6 — git.branch_detail / branch_file_pair / create_worktree / remove_worktree and file_history.*
//! against a real muyad in a temp HOME with a hermetic temp repo.

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
    let dir = PathBuf::from(format!("/tmp/muya-p6-{tag}-{}", std::process::id()));
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
        a.send(muya_proto::hello(Role::App, "p6-test"));
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

fn git(dir: &Path, args: &[&str]) -> String {
    let o = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false"])
        .args(args)
        .output()
        .unwrap();
    assert!(o.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&o.stderr));
    String::from_utf8_lossy(&o.stdout).trim().to_string()
}

fn make_repo(path: &Path) {
    std::fs::create_dir_all(path).unwrap();
    git(path, &["init", "-q", "-b", "main"]);
    std::fs::write(path.join("a.txt"), "one\n").unwrap();
    std::fs::write(path.join("d.txt"), "gone\n").unwrap();
    git(path, &["add", "."]);
    git(path, &["commit", "-q", "-m", "first"]);
    git(path, &["checkout", "-q", "-b", "feat"]);
    std::fs::write(path.join("a.txt"), "one\ntwo\n").unwrap();
    std::fs::write(path.join("n.txt"), "new\n").unwrap();
    git(path, &["rm", "-q", "d.txt"]);
    git(path, &["add", "."]);
    git(path, &["commit", "-q", "-m", "second"]);
    git(path, &["checkout", "-q", "main"]);
}

#[test]
fn p6_branch_detail_and_file_pair() {
    let env = start("detail");
    let repo = std::fs::canonicalize(&env.dir).unwrap().join("repo");
    make_repo(&repo);
    let cwd = repo.to_str().unwrap();
    let mut app = App::connect(&env.dir.join("m.sock"));
    let q = json!({ "cwd": cwd, "branch": "feat" });
    assert!(app.rpc("git.branch_detail", q.clone()).unwrap_err().contains("not one of Muya's workspaces"));
    app.rpc("workspace.set_roots", json!({ "roots": [cwd] })).unwrap();

    let d = app.rpc("git.branch_detail", q).unwrap();
    assert_eq!(d["base"], "main");
    assert_eq!(d["ahead"], 1);
    assert_eq!(d["behind"], 0);
    assert_eq!(d["commits"][0]["subject"], "second");
    let files: Vec<&str> = d["changedFiles"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
    assert!(files.contains(&"a.txt") && files.contains(&"n.txt") && files.contains(&"d.txt"), "{files:?}");
    // The status letters travel with the names: modified, added, deleted.
    let status: std::collections::BTreeMap<String, String> = d["changedStatus"].as_array().unwrap().iter()
        .map(|v| (v["path"].as_str().unwrap().to_string(), v["status"].as_str().unwrap().to_string())).collect();
    assert_eq!(status.get("a.txt").map(String::as_str), Some("M"), "{status:?}");
    assert_eq!(status.get("n.txt").map(String::as_str), Some("A"), "{status:?}");
    assert_eq!(status.get("d.txt").map(String::as_str), Some("D"), "{status:?}");
    assert_eq!(status.len(), files.len());
    assert!(app.rpc("git.branch_detail", json!({ "cwd": cwd, "branch": "nope" })).unwrap_err().contains("unknown branch"));
    assert!(app.rpc("git.branch_detail", json!({ "cwd": cwd, "branch": "--all" })).is_err());

    let pair = app.rpc("git.branch_file_pair", json!({ "cwd": cwd, "base": "main", "branch": "feat", "path": "a.txt" })).unwrap();
    assert_eq!(pair, json!(["one\n", "one\ntwo\n"]));
    let added = app.rpc("git.branch_file_pair", json!({ "cwd": cwd, "base": "main", "branch": "feat", "path": "n.txt" })).unwrap();
    assert_eq!(added, json!(["", "new\n"]));
    assert!(app.rpc("git.branch_file_pair", json!({ "cwd": cwd, "base": "main", "branch": "feat", "path": "../x" })).is_err());
    assert!(app.rpc("git.branch_file_pair", json!({ "cwd": "/tmp", "base": "main", "branch": "feat", "path": "a.txt" })).is_err());
}

#[test]
fn p6_worktrees_are_confined_to_the_roots() {
    let env = start("wt");
    let base = std::fs::canonicalize(&env.dir).unwrap();
    let (repo, other) = (base.join("repo"), base.join("other"));
    make_repo(&repo);
    make_repo(&other);
    let mut app = App::connect(&env.dir.join("m.sock"));
    // No roots: nothing is created.
    assert!(app.rpc("git.create_worktree", json!({ "cwd": repo.to_str().unwrap(), "branch": "wt1" })).is_err());
    assert!(!base.join("repo-worktrees").exists());
    app.rpc("workspace.set_roots", json!({ "roots": [repo.to_str().unwrap()] })).unwrap();

    let wt = app.rpc("git.create_worktree", json!({ "cwd": repo.to_str().unwrap(), "branch": "wt1" })).unwrap();
    let wt = wt.as_str().unwrap().to_string();
    assert!(Path::new(&wt).join("a.txt").exists(), "{wt}");
    assert!(git(&repo, &["worktree", "list"]).contains("wt1"));

    // A repo that is not a root is refused and left untouched.
    let e = app.rpc("git.create_worktree", json!({ "cwd": other.to_str().unwrap(), "branch": "wt2" })).unwrap_err();
    assert!(e.contains("not one of Muya's workspaces"), "{e}");
    assert!(!base.join("other-worktrees").exists());
    // Bad branch names are refused too.
    assert!(app.rpc("git.create_worktree", json!({ "cwd": repo.to_str().unwrap(), "branch": "-x" })).is_err());

    // Removing: outside the roots is refused, the linked worktree of a root works.
    let o2 = app.rpc("git.remove_worktree", json!({ "worktree": other.to_str().unwrap() })).unwrap_err();
    assert!(o2.contains("not one of Muya's workspaces"), "{o2}");
    assert!(other.join(".git").exists());
    app.rpc("git.remove_worktree", json!({ "worktree": wt })).unwrap();
    assert!(!Path::new(&wt).exists());
    assert!(!git(&repo, &["worktree", "list"]).contains("wt1"));
}

#[test]
fn p6_file_history_snapshot_list_read() {
    let env = start("hist");
    let base = std::fs::canonicalize(&env.dir).unwrap();
    let repo = base.join("repo");
    make_repo(&repo);
    let f = repo.join("a.txt").to_str().unwrap().to_string();
    let mut app = App::connect(&env.dir.join("m.sock"));
    assert!(app.rpc("file_history.list", json!({ "path": f })).is_err());
    app.rpc("workspace.set_roots", json!({ "roots": [repo.to_str().unwrap()] })).unwrap();

    let v1 = app.rpc("file_history.snapshot", json!({ "path": f, "content": "v1\n", "kind": "saved" })).unwrap();
    assert!(v1["id"].is_string(), "{v1}");
    // Same content again is not a new version.
    assert!(app.rpc("file_history.snapshot", json!({ "path": f, "content": "v1\n", "kind": "saved" })).unwrap().is_null());
    let v2 = app.rpc("file_history.snapshot", json!({ "path": f, "content": "v2\n", "kind": "saved" })).unwrap();
    let list = app.rpc("file_history.list", json!({ "path": f })).unwrap();
    let list = list.as_array().unwrap();
    assert_eq!(list.len(), 2);
    assert_eq!(list[0]["id"], v2["id"]);
    let id1 = v1["id"].as_str().unwrap();
    assert_eq!(app.rpc("file_history.read", json!({ "path": f, "id": id1 })).unwrap(), json!("v1\n"));
    assert!(app.rpc("file_history.read", json!({ "path": f, "id": "../../etc/passwd" })).is_err());

    // Outside the roots: refused, and nothing is stored.
    let out = base.join("elsewhere.txt").to_str().unwrap().to_string();
    assert!(app.rpc("file_history.snapshot", json!({ "path": out, "content": "x", "kind": "saved" })).is_err());
    assert!(app.rpc("file_history.snapshot", json!({ "path": "rel.txt", "content": "x", "kind": "saved" })).is_err());
}

fn ps(pid: u32) -> (u64, String) {
    let o = Command::new("ps").args(["-o", "rss=,time=", "-p", &pid.to_string()]).output().unwrap();
    let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
    let mut it = s.split_whitespace();
    (it.next().unwrap().parse().unwrap(), it.next().unwrap().to_string())
}

/// Measurement (not a gate): muyad RSS / CPU time around `git.branch_detail` on a 5000-commit repo.
/// `cargo test -p muyad --test p6 -- --ignored --nocapture`
#[test]
#[ignore]
fn p6_measure_branch_detail_on_5k_commits() {
    let env = start("perf");
    let repo = std::fs::canonicalize(&env.dir).unwrap().join("repo");
    make_repo(&repo);
    // 5000 more commits on main, written with fast-import (a loop of `git commit` would take minutes).
    let mut stream = String::new();
    for i in 0..5000 {
        stream += &format!("commit refs/heads/main\ncommitter t <t@example.invalid> {} +0000\ndata 4\nc{:03}\n\n", 1_700_000_000 + i, i % 1000);
    }
    let mut child = Command::new("git").arg("-C").arg(&repo).args(["fast-import", "--quiet", "--force"]).stdin(std::process::Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(stream.as_bytes()).unwrap();
    assert!(child.wait().unwrap().success());
    assert_eq!(git(&repo, &["rev-list", "--count", "main"]).parse::<u32>().unwrap() >= 5000, true);

    let muyad_pid = env.kids.last().unwrap().id();
    let mut app = App::connect(&env.dir.join("m.sock"));
    app.rpc("workspace.set_roots", json!({ "roots": [repo.to_str().unwrap()] })).unwrap();
    let before = ps(muyad_pid);
    let t = Instant::now();
    let mut ok = 0;
    for _ in 0..20 {
        let d = app.rpc("git.branch_detail", json!({ "cwd": repo.to_str().unwrap(), "branch": "feat" })).unwrap();
        assert!(d["ahead"].is_number());
        ok += 1;
    }
    let wall = t.elapsed();
    let after = ps(muyad_pid);
    println!("branch_detail x{ok} on 5k commits: {:?} per call; muyad RSS {} -> {} KiB; cputime {} -> {}", wall / ok, before.0, after.0, before.1, after.1);
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

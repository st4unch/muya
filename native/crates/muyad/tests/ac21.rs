//! PRD AC21 (daemon side): while ptyd is not reachable (its LaunchAgent is not approved in Login
//! Items) muyad stays up, answers `Spawn` with the typed `NotApproved` error, and recovers by
//! itself — same muyad process — once ptyd appears.
//! Needs the ptyd binary: `cargo build --workspace`.

use muya_proto::{Control, Decoder, ErrorCode, Frame, Role};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant};

struct Procs {
    dir: PathBuf,
    children: Vec<Child>,
}

impl Drop for Procs {
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

/// Hello + one request on a fresh connection; the frame that answers the request.
fn ask(sock: &Path, req: Control) -> Control {
    let mut s = connect_retry(sock);
    s.set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    s.write_all(&Frame::Control(muya_proto::hello(Role::App, "ac21")).encode())
        .unwrap();
    s.write_all(&Frame::Control(req).encode()).unwrap();
    let mut dec = Decoder::default();
    let mut controls = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut buf = [0u8; 65536];
    while controls.len() < 2 {
        assert!(Instant::now() < deadline, "no answer: {controls:?}");
        if let Ok(n) = s.read(&mut buf) {
            dec.push(&buf[..n]);
        }
        while let Ok(Some(f)) = dec.next_frame() {
            if let Frame::Control(c) = f {
                controls.push(c);
            }
        }
    }
    assert!(
        matches!(controls[0], Control::Welcome { .. }),
        "{controls:?}"
    );
    controls.remove(1)
}

fn spawn_req() -> Control {
    Control::Spawn {
        argv: vec!["/bin/sh".into(), "-c".into(), "sleep 30".into()],
        cwd: "/tmp".into(),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

#[test]
fn spawn_is_a_typed_error_until_ptyd_appears_and_then_works_without_restart() {
    let bin = |n: &str| Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name(n);
    assert!(bin("muya-ptyd").exists(), "cargo build --workspace first");
    let dir = PathBuf::from(format!("/tmp/muya-ac21-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let (msock, psock) = (dir.join("m.sock"), dir.join("p.sock"));
    let muyad = Command::new(env!("CARGO_BIN_EXE_muyad"))
        .arg("--socket")
        .arg(&msock)
        .arg("--ptyd")
        .arg(&psock)
        .spawn()
        .unwrap();
    let mut procs = Procs {
        dir: dir.clone(),
        children: vec![muyad],
    };
    wait_for(&msock); // muyad serves although ptyd is not there (it waits ~2 s first)

    // Not approved: typed error, message tells the operator what to do; muyad keeps running.
    for _ in 0..2 {
        match ask(&msock, spawn_req()) {
            Control::Error {
                code: ErrorCode::NotApproved,
                message,
                ..
            } => {
                assert!(message.contains("Login Items"), "{message}");
            }
            other => panic!("expected NotApproved, got {other:?}"),
        }
    }
    assert!(
        procs.children[0].try_wait().unwrap().is_none(),
        "muyad must stay up"
    );
    // Requests that do not need ptyd still work.
    assert!(matches!(
        ask(&msock, Control::List),
        Control::Sessions { .. }
    ));

    // The operator approves: ptyd appears. The same muyad process spawns.
    let muyad_pid = procs.children[0].id();
    let ptyd = Command::new(bin("muya-ptyd"))
        .env("MUYA_PTYD_EXIT_WITH_PARENT", "1")
        .arg("--socket")
        .arg(&psock)
        .spawn()
        .unwrap();
    procs.children.push(ptyd);
    wait_for(&psock);
    let deadline = Instant::now() + Duration::from_secs(5);
    let spawned = loop {
        // The socket file exists a moment before ptyd accepts on it: NotApproved until then.
        match ask(&msock, spawn_req()) {
            Control::Spawned { id, pid } => break (id, pid),
            Control::Error {
                code: ErrorCode::NotApproved,
                ..
            } if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            other => panic!("expected Spawned after ptyd appeared, got {other:?}"),
        }
    };
    assert!(spawned.1 > 0);
    assert_eq!(procs.children[0].id(), muyad_pid);
    assert!(
        procs.children[0].try_wait().unwrap().is_none(),
        "no restart needed"
    );
    let Control::Sessions { sessions } = ask(&msock, Control::List) else {
        panic!()
    };
    assert!(sessions.iter().any(|s| s.id == spawned.0));
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

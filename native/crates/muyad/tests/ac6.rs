//! PRD AC6 (the parts testable without code signing; the identifier check itself is covered by
//! Faz 0 S2 with signed binaries): muyactl is read-only; a process inside a session is refused on
//! the client socket, also after a double-fork.
//! Needs the ptyd and muyactl binaries: `cargo build --workspace`.

use muya_proto::{Control, Decoder, Frame, Role};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
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

fn start(tag: &str) -> Daemons {
    let bin = |n: &str| Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name(n);
    assert!(bin("muya-ptyd").exists(), "cargo build --workspace first");
    let dir = PathBuf::from(format!("/tmp/muya-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let ptyd = Command::new(bin("muya-ptyd"))
            .env("MUYA_PTYD_EXIT_WITH_PARENT", "1").arg("--socket").arg(dir.join("p.sock")).spawn().unwrap();
    wait_for(&dir.join("p.sock"));
    let muyad = Command::new(env!("CARGO_BIN_EXE_muyad")).arg("--socket").arg(dir.join("m.sock")).arg("--ptyd").arg(dir.join("p.sock")).spawn().unwrap();
    wait_for(&dir.join("m.sock"));
    Daemons { dir, children: vec![ptyd, muyad] }
}

fn talk(sock: &Path, role: Role, req: Control) -> Vec<Frame> {
    let mut s = connect_retry(sock);
    s.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    s.write_all(&Frame::Control(muya_proto::hello(role, "ac6")).encode()).unwrap();
    s.write_all(&Frame::Control(req).encode()).unwrap();
    let mut dec = Decoder::default();
    let mut out = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut buf = [0u8; 65536];
    while out.len() < 2 && Instant::now() < deadline {
        if let Ok(n) = s.read(&mut buf) {
            dec.push(&buf[..n]);
        }
        while let Ok(Some(f)) = dec.next_frame() {
            out.push(f);
        }
    }
    out
}

#[test]
fn muyactl_is_read_only() {
    let d = start("ac6a");
    let sock = d.dir.join("m.sock");
    let r = talk(&sock, Role::Muyactl, Control::List);
    assert!(matches!(&r[1], Frame::Control(Control::Sessions { .. })), "{r:?}");
    let r = talk(&sock, Role::Muyactl, Control::Spawn { argv: vec!["/bin/sh".into()], cwd: "/tmp".into(), env: vec![], cols: 80, rows: 24 });
    assert!(matches!(&r[1], Frame::Control(Control::Error { message, .. }) if message.contains("read-only")), "{r:?}");
    let out = Command::new(Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name("muyactl")).args(["--socket"]).arg(&sock).arg("status").output().unwrap();
    assert!(out.status.success() && String::from_utf8_lossy(&out.stdout).contains("0 sessions"), "{out:?}");
}

#[test]
fn a_session_child_is_refused_also_after_a_double_fork() {
    let d = start("ac6b");
    let sock = d.dir.join("m.sock");
    // The grandchild is reparented to launchd (double fork) but keeps the session id.
    let script = format!("( ( sleep 0.3; nc -U {} </dev/null ) & ); sleep 3", sock.display());
    let r = talk(&sock, Role::App, Control::Spawn { argv: vec!["/bin/sh".into(), "-c".into(), script], cwd: "/tmp".into(), env: vec![], cols: 120, rows: 24 });
    let Frame::Control(Control::Spawned { id, .. }) = r[1] else { panic!("{r:?}") };
    let mut s = connect_retry(&sock);
    s.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    s.write_all(&Frame::Control(muya_proto::hello(Role::App, "ac6")).encode()).unwrap();
    s.write_all(&Frame::Control(Control::Attach { id }).encode()).unwrap();
    let mut dec = Decoder::default();
    let mut text = String::new();
    let deadline = Instant::now() + Duration::from_secs(8);
    let mut buf = [0u8; 65536];
    while !text.contains("inside PTY session") {
        assert!(Instant::now() < deadline, "not refused; output: {text:?}");
        if let Ok(n) = s.read(&mut buf) {
            dec.push(&buf[..n]);
        }
        while let Ok(Some(f)) = dec.next_frame() {
            if let Frame::Output { data, .. } = f {
                text += &String::from_utf8_lossy(&data);
            }
        }
    }
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

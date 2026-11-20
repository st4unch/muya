//! AC24 (per-session output subscription): `Detach` stops a connection's output stream but keeps
//! Screen/Exited; re-`Attach` resumes with a snapshot.
//! Needs the ptyd binary: `cargo build --workspace`.


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


fn frames(s: &mut UnixStream, dec: &mut Decoder, ms: u64) -> Vec<Frame> {
    let mut out = Vec::new();
    let end = Instant::now() + Duration::from_millis(ms);
    let mut buf = [0u8; 65536];
    while Instant::now() < end {
        if let Ok(n) = s.read(&mut buf) {
            dec.push(&buf[..n]);
        }
        while let Ok(Some(f)) = dec.next_frame() {
            out.push(f);
        }
    }
    out
}

fn is_out(f: &Frame) -> bool {
    matches!(f, Frame::Output { .. })
}

/// Detach stops a session's output for this connection (no replica cost), Screen/Exited keep
/// flowing, and a re-Attach resumes with a snapshot followed by live output.
#[test]
fn detach_stops_output_and_reattach_resumes_with_snapshot() {
    let d = start("ac24b");
    let sock = d.dir.join("m.sock");
    let mut s = connect_retry(&sock);
    s.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
    let mut dec = Decoder::default();
    s.write_all(&Frame::Control(muya_proto::hello(Role::App, "ac24b")).encode()).unwrap();
    let script = "i=0; while :; do echo line-$i; i=$((i+1)); sleep 0.05; done".to_string();
    s.write_all(&Frame::Control(Control::Spawn { argv: vec!["/bin/sh".into(), "-c".into(), script], cwd: "/tmp".into(), env: vec![], cols: 80, rows: 24 }).encode()).unwrap();
    let mut id = None;
    let end = Instant::now() + Duration::from_secs(5);
    while id.is_none() && Instant::now() < end {
        for f in frames(&mut s, &mut dec, 100) {
            if let Frame::Control(Control::Spawned { id: i, .. }) = f {
                id = Some(i);
            }
        }
    }
    let id = id.expect("spawned");
    s.write_all(&Frame::Control(Control::Attach { id }).encode()).unwrap();
    let got = frames(&mut s, &mut dec, 600);
    assert!(got.iter().filter(|f| is_out(f)).count() >= 2, "no live output: {got:?}");

    s.write_all(&Frame::Control(Control::Detach { id }).encode()).unwrap();
    let _ = frames(&mut s, &mut dec, 300); // drain what was in flight (+ Ok)
    let quiet = frames(&mut s, &mut dec, 800);
    assert!(!quiet.iter().any(is_out), "output after detach: {} frames", quiet.len());

    s.write_all(&Frame::Control(Control::Attach { id }).encode()).unwrap();
    let back = frames(&mut s, &mut dec, 800);
    let attached = back.iter().position(|f| matches!(f, Frame::Control(Control::Attached { .. }))).expect("Attached after re-attach");
    assert!(matches!(back.get(attached + 1), Some(Frame::Output { .. })), "snapshot must follow Attached: {back:?}");
    assert!(back.iter().filter(|f| is_out(f)).count() >= 3, "live output did not resume");

    // Detach on a connection that never attached: screen-only subscription, still answers Ok.
    let mut s2 = connect_retry(&sock);
    s2.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
    let mut dec2 = Decoder::default();
    s2.write_all(&Frame::Control(muya_proto::hello(Role::App, "ac24b")).encode()).unwrap();
    s2.write_all(&Frame::Control(Control::Detach { id }).encode()).unwrap();
    let f2 = frames(&mut s2, &mut dec2, 800);
    assert!(f2.iter().any(|f| matches!(f, Frame::Control(Control::Ok))), "{f2:?}");
    assert!(!f2.iter().any(is_out), "detached-only connection got output");
    s2.write_all(&Frame::Control(Control::Detach { id: 9999 }).encode()).unwrap();
    let f3 = frames(&mut s2, &mut dec2, 300);
    assert!(f3.iter().any(|f| matches!(f, Frame::Control(Control::Error { .. }))), "{f3:?}");
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

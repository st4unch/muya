//! PRD AC2: ptyd + muyad run 25 sessions headless; `kill -9 muyad` -> 25 PIDs unchanged, listed
//! again <= 5 s, and Shift+Enter / bracketed paste / mouse click into a session that set those
//! modes more than 10 MB of output earlier are encoded correctly.
//!
//! Needs the ptyd binary: `cargo build -p muya-ptyd` (the workspace test script builds all bins).

use muya_proto::{Control, Decoder, Frame, Role, MOD_SHIFT};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant};

struct Daemons {
    dir: PathBuf,
    ptyd: Child,
    muyad: Option<Child>,
}

impl Daemons {
    fn ptyd_sock(&self) -> PathBuf {
        self.dir.join("p.sock")
    }
    fn muyad_sock(&self) -> PathBuf {
        self.dir.join("m.sock")
    }
    fn start_muyad(&mut self) {
        let _ = std::fs::remove_file(self.muyad_sock());
        let child = Command::new(env!("CARGO_BIN_EXE_muyad")).arg("--socket").arg(self.muyad_sock()).arg("--ptyd").arg(self.ptyd_sock()).spawn().unwrap();
        self.muyad = Some(child);
    }
}

impl Drop for Daemons {
    fn drop(&mut self) {
        if let Some(m) = &mut self.muyad {
            let _ = m.kill();
            let _ = m.wait();
        }
        // Killing ptyd closes every PTY master: the sessions get SIGHUP.
        let _ = self.ptyd.kill();
        let _ = self.ptyd.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn start() -> Daemons {
    let ptyd_bin = Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name("muya-ptyd");
    assert!(ptyd_bin.exists(), "build ptyd first: cargo build -p muya-ptyd");
    let dir = PathBuf::from(format!("/tmp/muya-ac2-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let ptyd = Command::new(ptyd_bin)
            .env("MUYA_PTYD_EXIT_WITH_PARENT", "1").arg("--socket").arg(dir.join("p.sock")).spawn().unwrap();
    wait_for(&dir.join("p.sock"));
    let mut d = Daemons { dir, ptyd, muyad: None };
    d.start_muyad();
    d
}

fn wait_for(p: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !p.exists() {
        assert!(Instant::now() < deadline, "{} never appeared", p.display());
        std::thread::sleep(Duration::from_millis(10));
    }
}

struct App {
    s: UnixStream,
    dec: Decoder,
    controls: Vec<Control>,
    output: std::collections::HashMap<u64, Vec<u8>>,
}

impl App {
    fn connect(sock: &Path) -> Option<Self> {
        let s = UnixStream::connect(sock).ok()?;
        s.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
        let mut a = Self { s, dec: Decoder::default(), controls: Vec::new(), output: Default::default() };
        a.s.write_all(&Frame::Control(muya_proto::hello(Role::App, "ac2")).encode()).ok()?;
        matches!(a.control(), Control::Welcome { .. }).then_some(a)
    }
    fn pump(&mut self) {
        let mut buf = [0u8; 65536];
        if let Ok(n) = self.s.read(&mut buf) {
            self.dec.push(&buf[..n]);
        }
        while let Ok(Some(f)) = self.dec.next_frame() {
            match f {
                Frame::Output { session, data, .. } => self.output.entry(session).or_default().extend_from_slice(&data),
                Frame::Control(Control::Exited { .. } | Control::Attached { .. } | Control::Screen { .. }) => {}
                Frame::Control(c) => self.controls.push(c),
                Frame::Input { .. } => {}
            }
        }
    }
    fn control(&mut self) -> Control {
        let deadline = Instant::now() + Duration::from_secs(15);
        while self.controls.is_empty() {
            assert!(Instant::now() < deadline, "no reply from muyad");
            self.pump();
        }
        self.controls.remove(0)
    }
    fn request(&mut self, c: Control) -> Control {
        self.s.write_all(&Frame::Control(c).encode()).unwrap();
        self.control()
    }
    fn list(&mut self) -> Vec<muya_proto::SessionInfo> {
        match self.request(Control::List) {
            Control::Sessions { mut sessions } => {
                sessions.sort_by_key(|s| s.id);
                sessions
            }
            other => panic!("{other:?}"),
        }
    }
    fn wait_output(&mut self, id: u64, needle: &str) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let text = String::from_utf8_lossy(self.output.get(&id).map(Vec::as_slice).unwrap_or(&[])).into_owned();
            if text.contains(needle) {
                return;
            }
            assert!(Instant::now() < deadline, "{needle:?} never arrived; tail: {:?}", &text[text.len().saturating_sub(300)..]);
            self.pump();
        }
    }
}

fn sh(script: &str) -> Vec<String> {
    vec!["/bin/sh".into(), "-c".into(), script.into()]
}

#[test]
fn twenty_five_sessions_survive_kill_9_of_muyad_with_modes_intact() {
    let mut d = start();
    wait_for(&d.muyad_sock());
    let mut app = App::connect(&d.muyad_sock()).expect("muyad");

    // Session 0: set the modes, push 12 MB so the setting bytes leave the 1 MB ring, then print
    // every input byte as hex.
    let modes_then_echo = r#"printf '\033[?2004h\033[?1000h\033[?1006h\033[>1u'; head -c 12000000 /dev/zero | tr '\0' x; printf '\r\nFLOOD-DONE\r\n'; stty raw -echo; exec /usr/bin/python3 -u -c 'import os,sys
while True: sys.stdout.write("IN:" + os.read(0, 256).hex() + "\r\n")'"#;
    let Control::Spawned { id: s0, .. } = app.request(Control::Spawn { argv: sh(modes_then_echo), cwd: "/tmp".into(), env: vec![], cols: 100, rows: 30 }) else { panic!() };
    // Session 1 shows a Claude footer: after the restart the screen parser must see the mode again
    // within 5 s (Faz 0 S4 criterion "status parser recovers").
    let footer = r#"printf '\033[2J\033[30;1H  \342\217\265\342\217\265 accept edits on (shift+tab to cycle)'; sleep 600"#;
    let Control::Spawned { id: s1, .. } = app.request(Control::Spawn { argv: sh(footer), cwd: "/tmp".into(), env: vec![], cols: 100, rows: 30 }) else { panic!() };
    for i in 2..25 {
        let script = format!("i=0; while :; do printf 'session {i} line %d\\r\\n' $i; i=$((i+1)); sleep 0.05; done");
        assert!(matches!(app.request(Control::Spawn { argv: sh(&script), cwd: "/tmp".into(), env: vec![], cols: 100, rows: 30 }), Control::Spawned { .. }));
    }
    let deadline = Instant::now() + Duration::from_secs(60);
    while app.list().iter().find(|s| s.id == s0).unwrap().end_seq < 12_000_000 {
        assert!(Instant::now() < deadline, "flood did not finish");
        std::thread::sleep(Duration::from_millis(100));
    }
    let before: Vec<(u64, i32)> = app.list().iter().map(|s| (s.id, s.pid)).collect();
    assert_eq!(before.len(), 25);

    // kill -9 muyad, start it again, time until it lists all 25 sessions.
    let mut m = d.muyad.take().unwrap();
    let t0 = Instant::now();
    unsafe { libc::kill(m.id() as i32, libc::SIGKILL) };
    let _ = m.wait();
    d.start_muyad();
    let mut app = loop {
        if let Some(mut a) = App::connect(&d.muyad_sock())
            && a.list().len() == 25
        {
            break a;
        }
        assert!(t0.elapsed() < Duration::from_secs(5), "sessions not listed again within 5 s");
        std::thread::sleep(Duration::from_millis(20));
    };
    let relisted = t0.elapsed();
    let after: Vec<(u64, i32)> = app.list().iter().map(|s| (s.id, s.pid)).collect();
    assert_eq!(before, after, "PIDs changed");
    for (_, pid) in &after {
        assert_eq!(unsafe { libc::kill(*pid, 0) }, 0, "pid {pid} is gone");
    }
    eprintln!("AC2: kill -9 muyad -> 25 sessions listed again after {} ms", relisted.as_millis());

    // The screen parser recovered the Claude footer's mode.
    loop {
        let Control::Inspected { screen, .. } = app.request(Control::Inspect { id: s1 }) else { panic!() };
        if screen.contains(r#""mode":"acceptEdits""#) && screen.contains(r#""modeDetected":true"#) {
            break;
        }
        assert!(t0.elapsed() < Duration::from_secs(5), "screen state not recovered within 5 s: {screen}");
        std::thread::sleep(Duration::from_millis(50));
    }
    eprintln!("AC2: screen parser recovered after {} ms", t0.elapsed().as_millis());

    // Modes set >10 MB ago are back (re-adopt: ring replay + tracker header).
    let Control::Inspected { modes, .. } = app.request(Control::Inspect { id: s0 }) else { panic!() };
    assert_eq!(modes, "bracketed_paste=1 mouse=1 kitty=1");

    app.s.write_all(&Frame::Control(Control::Attach { id: s0 }).encode()).unwrap();
    assert_eq!(app.control(), Control::Ok);
    app.wait_output(s0, "FLOOD-DONE");
    std::thread::sleep(Duration::from_millis(300)); // let python start reading
    assert_eq!(app.request(Control::Key { id: s0, key: "enter".into(), mods: MOD_SHIFT, text: None }), Control::Ok);
    app.wait_output(s0, "IN:1b5b31333b3275"); // CSI 13;2u (Kitty, flags 1)
    assert_eq!(app.request(Control::Paste { id: s0, text: "hi".into() }), Control::Ok);
    app.wait_output(s0, "IN:1b5b3230307e68691b5b3230317e"); // ESC[200~hi ESC[201~
    assert_eq!(app.request(Control::Mouse { id: s0, col: 4, row: 2, button: "left".into(), action: "press".into(), mods: 0 }), Control::Ok);
    app.wait_output(s0, "IN:1b5b3c303b353b334d"); // SGR 1006: ESC[<0;5;3M
}

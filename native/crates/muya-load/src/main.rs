//! Load test for the native daemons (PRD AC7/AC8 daemon side, S9): starts muya-ptyd + muyad,
//! opens N sessions streaming Claude-like output (one "visible" fast, the rest slower), attaches
//! an app-like client to the visible sessions, and measures:
//! - CPU (from cputime deltas) and RSS of ptyd and muyad,
//! - keystroke echo latency through app -> muyad -> ptyd -> program -> back,
//! - attach (tab switch) latency to a hidden session until its snapshot arrives,
//! - bytes delivered to the client vs produced,
//! - with --kill: kill -9 muyad mid-run and time until all sessions are listed again.
//!
//!   muya-load [--sessions 25] [--visible 6] [--fast 1000000] [--rate 65536] [--seconds 20] [--kill]
//! Binaries are taken from the same directory as muya-load (cargo build --workspace).

use muya_proto::{Control, Decoder, Frame, Role};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant};

fn opt(args: &[String], name: &str, default: u64) -> u64 {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).and_then(|v| v.parse().ok()).unwrap_or(default)
}

const GENERATOR: &str = r#"
import sys, time
rate = int(sys.argv[1]); out = sys.stdout.buffer
lines = [("\x1b[38;5;%dm*\x1b[0m Read \x1b[1msrc/components/File%d.tsx\x1b[0m lorem ipsum \x1b[38;2;%d;120;200mşğüİı 日本語\x1b[0m %d\r\n" % (16 + i % 200, i, i % 255, i)).encode() for i in range(400)]
blob = b"".join(lines); pos = 0; step = max(1, rate // 100); t = time.monotonic()
while True:
    chunk = (blob + blob)[pos:pos + step]; pos = (pos + step) % len(blob)
    out.write(chunk); out.flush()
    t += 0.01; d = t - time.monotonic()
    if d > 0: time.sleep(d)
    else: t = time.monotonic()
"#;

struct Client {
    s: UnixStream,
    dec: Decoder,
    controls: Vec<Control>,
    bytes: u64,
    snapshots: Vec<(u64, Instant)>,
    echo_marks: Vec<(u8, Instant)>,
    /// Session whose Attached arrived; its next output frame is the snapshot.
    pending_snapshot: Option<u64>,
    ignore_ok: u32,
}

impl Client {
    fn connect(sock: &Path) -> Option<Self> {
        let s = UnixStream::connect(sock).ok()?;
        muya_proto::tune_link(std::os::fd::AsRawFd::as_raw_fd(&s));
        s.set_read_timeout(Some(Duration::from_millis(2))).ok()?;
        let mut c = Self { s, dec: Decoder::default(), controls: Vec::new(), bytes: 0, snapshots: Vec::new(), echo_marks: Vec::new(), pending_snapshot: None, ignore_ok: 0 };
        c.send(Frame::Control(muya_proto::hello(Role::App, "muya-load")));
        matches!(c.control(Duration::from_secs(5))?, Control::Welcome { .. }).then_some(c)
    }
    fn send(&mut self, f: Frame) {
        let _ = self.s.write_all(&f.encode());
    }
    /// Reads what is available; `echo_session` output bytes 0xF0..0xFF are echo markers.
    fn pump(&mut self, echo_session: Option<u64>) {
        let mut buf = [0u8; 256 * 1024];
        if let Ok(n) = self.s.read(&mut buf) {
            self.dec.push(&buf[..n]);
        }
        while let Ok(Some(f)) = self.dec.next_frame() {
            match f {
                Frame::Output { session, data, .. } => {
                    self.bytes += data.len() as u64;
                    if self.pending_snapshot == Some(session) {
                        self.snapshots.push((session, Instant::now()));
                        self.pending_snapshot = None;
                    }
                    if Some(session) == echo_session {
                        for b in data.iter().filter(|b| **b >= 0xF0) {
                            self.echo_marks.push((*b, Instant::now()));
                        }
                    }
                }
                Frame::Control(Control::Attached { id, .. }) => self.pending_snapshot = Some(id),
                // Replies to fire-and-forget requests (Attach during the run).
                Frame::Control(Control::Ok) if self.ignore_ok > 0 => self.ignore_ok -= 1,
                Frame::Control(Control::Exited { .. } | Control::Screen { .. }) => {}
                Frame::Control(c) => self.controls.push(c),
                Frame::Input { .. } => {}
            }
        }
    }
    fn control(&mut self, timeout: Duration) -> Option<Control> {
        let deadline = Instant::now() + timeout;
        while self.controls.is_empty() {
            if Instant::now() > deadline {
                return None;
            }
            self.pump(None);
        }
        Some(self.controls.remove(0))
    }
    fn request(&mut self, c: Control) -> Option<Control> {
        self.send(Frame::Control(c));
        self.control(Duration::from_secs(10))
    }
}

struct Proc {
    child: Child,
}
impl Drop for Proc {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn cputime_s(pid: u32) -> f64 {
    let out = Command::new("ps").args(["-o", "time=", "-p", &pid.to_string()]).output().ok();
    let t = out.map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned()).unwrap_or_default();
    // [[hh:]mm:]ss.cc
    t.split(':').fold(0.0, |acc, part| acc * 60.0 + part.parse::<f64>().unwrap_or(0.0))
}

fn rss_mb(pid: u32) -> f64 {
    let out = Command::new("ps").args(["-o", "rss=", "-p", &pid.to_string()]).output().ok();
    out.and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse::<f64>().ok()).unwrap_or(0.0) / 1024.0
}

fn pct(v: &mut [f64], p: f64) -> f64 {
    if v.is_empty() {
        return f64::NAN;
    }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[((v.len() as f64 * p) as usize).min(v.len() - 1)]
}

fn start_muyad(bin: &Path, dir: &Path) -> Proc {
    let _ = std::fs::remove_file(dir.join("m.sock"));
    let child = Command::new(bin.join("muyad")).arg("--socket").arg(dir.join("m.sock")).arg("--ptyd").arg(dir.join("p.sock")).stderr(std::process::Stdio::null()).spawn().expect("muyad");
    Proc { child }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let sessions = opt(&args, "--sessions", 25) as usize;
    let visible = (opt(&args, "--visible", 6) as usize).min(sessions);
    let fast = opt(&args, "--fast", 1_000_000);
    let rate = opt(&args, "--rate", 65_536);
    let seconds = opt(&args, "--seconds", 20);
    let kill = args.iter().any(|a| a == "--kill");
    let no_switch = args.iter().any(|a| a == "--no-switch");
    let bin: PathBuf = std::env::current_exe().unwrap().parent().unwrap().to_owned();
    let dir = PathBuf::from(format!("/tmp/muya-load-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();

    let ptyd = Proc {
        child: Command::new(bin.join("muya-ptyd")).arg("--socket").arg(dir.join("p.sock")).env("MUYA_PTYD_EXIT_WITH_PARENT", "1").stderr(std::process::Stdio::null()).spawn().expect("muya-ptyd"),
    };
    while !dir.join("p.sock").exists() {
        std::thread::sleep(Duration::from_millis(10));
    }
    let mut muyad = start_muyad(&bin, &dir);
    let mut app = loop {
        if let Some(c) = Client::connect(&dir.join("m.sock")) {
            break c;
        }
        std::thread::sleep(Duration::from_millis(20));
    };

    // Session 0: echo probe (raw tty, cat echoes every byte). Then the streaming sessions.
    let echo_script = "stty raw -echo; exec cat";
    let mut ids = Vec::new();
    let spawn = |app: &mut Client, script: Vec<String>| -> u64 {
        match app.request(Control::Spawn { argv: script, cwd: "/tmp".into(), env: vec![], cols: 120, rows: 40 }) {
            Some(Control::Spawned { id, .. }) => id,
            other => panic!("spawn: {other:?}"),
        }
    };
    let echo_id = spawn(&mut app, vec!["/bin/sh".into(), "-c".into(), echo_script.into()]);
    for i in 0..sessions {
        let r = if i == 0 { fast } else { rate };
        ids.push(spawn(&mut app, vec!["/usr/bin/python3".into(), "-c".into(), GENERATOR.into(), r.to_string()]));
    }
    // The app attaches to the visible sessions and the echo probe (hidden ones stay detached).
    for id in std::iter::once(echo_id).chain(ids.iter().take(visible).copied()) {
        let _ = app.request(Control::Attach { id });
    }
    std::thread::sleep(Duration::from_millis(500));

    let (ppid, mpid) = (ptyd.child.id(), muyad.child.id());
    let (p0, m0, t0) = (cputime_s(ppid), cputime_s(mpid), Instant::now());
    let bytes0 = app.bytes;
    let mut echo_ms = Vec::new();
    let mut attach_ms = Vec::new();
    let mut peak = (0.0f64, 0.0f64);
    let mut next_probe = Instant::now();
    let mut next_attach = Instant::now() + Duration::from_millis(700);
    let mut marker = 0xF0u8;
    let mut sent: Option<(u8, Instant)> = None;
    let mut hidden = visible;
    let mut last_sample = Instant::now();
    while t0.elapsed() < Duration::from_secs(seconds) {
        app.pump(Some(echo_id));
        if let Some((m, at)) = sent
            && let Some(pos) = app.echo_marks.iter().position(|(b, _)| *b == m)
        {
            let (_, got) = app.echo_marks.remove(pos);
            echo_ms.push(got.duration_since(at).as_secs_f64() * 1000.0);
            sent = None;
        }
        if sent.is_none() && Instant::now() >= next_probe {
            marker = if marker == 0xFF { 0xF0 } else { marker + 1 };
            app.echo_marks.clear();
            sent = Some((marker, Instant::now()));
            app.send(Frame::Input { session: echo_id, data: vec![marker] });
            next_probe = Instant::now() + Duration::from_millis(50);
        }
        if !no_switch && Instant::now() >= next_attach && hidden < ids.len() {
            // Tab switch: attach a hidden session, time until its snapshot frame arrives.
            let id = ids[hidden];
            hidden += 1;
            let start = Instant::now();
            app.snapshots.clear();
            app.ignore_ok += 1;
            app.send(Frame::Control(Control::Attach { id }));
            while !app.snapshots.iter().any(|(s, _)| *s == id) && start.elapsed() < Duration::from_secs(5) {
                app.pump(Some(echo_id));
            }
            if let Some((_, at)) = app.snapshots.iter().find(|(s, _)| *s == id) {
                attach_ms.push(at.duration_since(start).as_secs_f64() * 1000.0);
            }
            next_attach = Instant::now() + Duration::from_millis(700);
        }
        if last_sample.elapsed() >= Duration::from_secs(1) {
            peak = (peak.0.max(rss_mb(ppid)), peak.1.max(rss_mb(mpid)));
            last_sample = Instant::now();
        }
    }
    let secs = t0.elapsed().as_secs_f64();
    let (pcpu, mcpu) = ((cputime_s(ppid) - p0) / secs * 100.0, (cputime_s(mpid) - m0) / secs * 100.0);
    let delivered = (app.bytes - bytes0) as f64 / secs / 1e6;
    let produced = (fast + rate * (sessions as u64 - 1)) as f64 / 1e6;
    let visible_rate = (fast + rate * (visible as u64 - 1)) as f64 / 1e6;
    println!("muya-load: {sessions} sessions (1 at {fast} B/s, rest {rate} B/s), {visible} attached, {:.0} s", secs);
    println!("  ptyd : CPU {pcpu:.0}%  RSS peak {:.0} MB", peak.0);
    println!("  muyad: CPU {mcpu:.0}%  RSS peak {:.0} MB", peak.1);
    println!("  produced {produced:.2} MB/s, attached sessions produce ~{visible_rate:.2} MB/s, client received {delivered:.2} MB/s (incl. snapshots of switched tabs)");
    let n_echo = echo_ms.len();
    println!(
        "  keystroke echo app->muyad->ptyd->program->app: n={n_echo} p50 {:.2} p95 {:.2} p99 {:.2} max {:.2} ms",
        pct(&mut echo_ms, 0.5),
        pct(&mut echo_ms, 0.95),
        pct(&mut echo_ms, 0.99),
        echo_ms.iter().cloned().fold(0.0, f64::max)
    );
    let n_att = attach_ms.len();
    println!("  tab switch (attach hidden session -> snapshot received): n={n_att} p50 {:.1} p95 {:.1} max {:.1} ms", pct(&mut attach_ms, 0.5), pct(&mut attach_ms, 0.95), attach_ms.iter().cloned().fold(0.0, f64::max));

    if kill {
        let before = match app.request(Control::List) {
            Some(Control::Sessions { sessions }) => sessions.len(),
            _ => 0,
        };
        let start = Instant::now();
        unsafe { libc::kill(muyad.child.id() as i32, libc::SIGKILL) };
        let _ = muyad.child.wait();
        muyad = start_muyad(&bin, &dir);
        let relisted = loop {
            if let Some(mut c) = Client::connect(&dir.join("m.sock"))
                && let Some(Control::Sessions { sessions }) = c.request(Control::List)
                && sessions.len() == before
            {
                break start.elapsed();
            }
            if start.elapsed() > Duration::from_secs(10) {
                break Duration::from_secs(999);
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        println!("  kill -9 muyad under load: all {before} sessions listed again after {} ms", relisted.as_millis());
    }
    drop(muyad);
    drop(ptyd);
    let _ = std::fs::remove_dir_all(&dir);
}

//! Screen corpus capture (PRD Faz 0 seed for AC3): runs a program on a PTY, follows a step script
//! and writes `<name>.bin` (every byte the program printed so far) and `<name>.txt` (the screen
//! as text, one line per row) — the format of src/lib/__fixtures__/claude-screens/.
//!
//!   capture <out-dir> <script>
//!
//! Script, one step per line (# comments):
//!   size 120x40            run <shell command>      wait <ms>
//!   wait-for <text>        key enter|esc|tab|shift-tab|up|down|ctrl-c      type <text>
//!   choose <text>          (select the menu option containing <text>, then Enter)
//!   snap <name>
//!   snaps <name> <count> <interval-ms>   (a series: <name>-01 ... <name>-NN, one every interval)
//! Keys are encoded by libghostty-vt for the terminal's current modes (Kitty keyboard etc.).

use crash_iso::spawn_pty;
use libghostty_vt::key::{Action, Encoder, Event, Key, Mods};
use libghostty_vt::render::{CellIterator, RenderState, RowIterator};
use libghostty_vt::terminal::{Mode, ModeKind, Options, Terminal};
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd};
use std::sync::mpsc::{channel, Receiver};
use std::time::{Duration, Instant};

struct Run {
    term: Terminal<'static, 'static>,
    rx: Receiver<Vec<u8>>,
    all: Vec<u8>,
    master: i32,
    pid: i32,
}

impl Run {
    /// Feeds the terminal for the whole interval (a quiet program must not end the wait early).
    fn pump(&mut self, until: Instant) {
        while Instant::now() < until {
            match self.rx.recv_timeout(until.saturating_duration_since(Instant::now()).min(Duration::from_millis(20))) {
                Ok(bytes) => {
                    self.term.vt_write(&bytes);
                    self.all.extend_from_slice(&bytes);
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    std::thread::sleep(until.saturating_duration_since(Instant::now()));
                    return;
                }
            }
        }
    }

    fn screen(&self) -> String {
        let (mut st, mut rows, mut cells) = (
            RenderState::new().unwrap(),
            RowIterator::new().unwrap(),
            CellIterator::new().unwrap(),
        );
        let snap = st.update(&self.term).unwrap();
        let mut it = rows.update(&snap).unwrap();
        let mut out = Vec::new();
        while let Some(row) = it.next() {
            let mut line = String::new();
            let mut ci = cells.update(row).unwrap();
            while let Some(c) = ci.next() {
                let g = c.graphemes().unwrap_or_default();
                if g.is_empty() {
                    line.push(' ')
                } else {
                    line.extend(g)
                }
            }
            out.push(line.trim_end().to_owned());
        }
        out.join("\n") + "\n"
    }

    fn send(&self, bytes: &[u8]) {
        unsafe { libc::write(self.master, bytes.as_ptr().cast(), bytes.len()) };
    }

    fn key(&self, name: &str) {
        let (key, mods) = match name {
            "enter" => (Key::Enter, Mods::empty()),
            "esc" => (Key::Escape, Mods::empty()),
            "tab" => (Key::Tab, Mods::empty()),
            "shift-tab" => (Key::Tab, Mods::SHIFT),
            "up" => (Key::ArrowUp, Mods::empty()),
            "down" => (Key::ArrowDown, Mods::empty()),
            "ctrl-c" => (Key::C, Mods::CTRL),
            other => panic!("unknown key {other}"),
        };
        let mut enc = Encoder::new().unwrap();
        enc.set_options_from_terminal(&self.term);
        let mut ev = Event::new().unwrap();
        ev.set_action(Action::Press).set_key(key).set_mods(mods);
        if name == "ctrl-c" {
            ev.set_unshifted_codepoint('c');
        }
        let mut out = Vec::new();
        enc.encode_to_vec(&ev, &mut out).unwrap();
        eprintln!("key {name}: {out:?} (kitty flags {:?})", self.term.kitty_keyboard_flags().map(|f| f.bits()));
        self.send(&out);
    }
}

fn main() {
    // Captured screens must look like a user's session: a capture run from inside a Claude session
    // would pass its CLAUDE* markers on (Claude then shows "Transcript saving is off").
    for (k, _) in std::env::vars() {
        if k.starts_with("CLAUDE") {
            unsafe { std::env::remove_var(k) };
        }
    }
    let args: Vec<String> = std::env::args().collect();
    let (out, script) = (
        std::path::PathBuf::from(&args[1]),
        std::fs::read_to_string(&args[2]).expect("script"),
    );
    std::fs::create_dir_all(&out).unwrap();
    let (mut cols, mut rows) = (120u16, 40u16);
    let mut run: Option<Run> = None;
    for (n, raw) in script.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (cmd, arg) = line.split_once(' ').unwrap_or((line, ""));
        match cmd {
            "size" => {
                let (c, r) = arg.split_once('x').expect("size COLSxROWS");
                (cols, rows) = (c.parse().unwrap(), r.parse().unwrap());
            }
            "run" => {
                // Not a login shell: on a machine with two claude installs the login PATH puts the old one
                // first, and claude 2.1.316 then ignores Enter (measured). Inherit this environment.
                let child = spawn_pty(&["/bin/zsh", "-c", arg], cols, rows).expect("spawn");
                let master = child.master.as_raw_fd();
                let mut file = unsafe { std::fs::File::from_raw_fd(libc::dup(master)) };
                let (tx, rx) = channel();
                std::thread::spawn(move || {
                    let mut buf = vec![0u8; 65536];
                    while let Ok(n) = file.read(&mut buf) {
                        if n == 0 || tx.send(buf[..n].to_vec()).is_err() {
                            return;
                        }
                    }
                });
                let mut term = Terminal::new(Options {
                    cols,
                    rows,
                    max_scrollback: 1_000_000,
                })
                .unwrap();
                term.set_mode(Mode::new(2027, ModeKind::Dec), true).unwrap();
                // Answer the program's terminal queries (DA, Kitty keyboard, DSR): Claude waits
                // for them before it handles input.
                term.on_pty_write(move |_, data| unsafe {
                    if std::env::var_os("CAPTURE_DEBUG").is_some() {
                        eprintln!("reply to program: {:?}", String::from_utf8_lossy(data));
                    }
                    // CAPTURE_MIN_REPLIES: answer only DA1 and the Kitty keyboard query (diagnosis).
                    let minimal = std::env::var_os("CAPTURE_MIN_REPLIES").is_some();
                    if !minimal || (data.starts_with(b"\x1b[?") && matches!(data.last(), Some(b'c' | b'u'))) {
                        libc::write(master, data.as_ptr().cast(), data.len());
                    }
                })
                .unwrap();
                std::mem::forget(child.master); // closed when the process exits
                run = Some(Run {
                    term,
                    rx,
                    all: Vec::new(),
                    master,
                    pid: child.pid,
                });
            }
            "wait" => {
                let r = run.as_mut().expect("run first");
                r.pump(Instant::now() + Duration::from_millis(arg.parse().unwrap()));
            }
            "wait-for" => {
                let r = run.as_mut().expect("run first");
                let deadline = Instant::now() + Duration::from_secs(20);
                while !r.screen().contains(arg) {
                    assert!(
                        Instant::now() < deadline,
                        "line {}: timed out waiting for {arg:?}\n{}",
                        n + 1,
                        r.screen()
                    );
                    r.pump(Instant::now() + Duration::from_millis(100));
                }
                r.pump(Instant::now() + Duration::from_millis(300)); // let the frame settle
            }
            "key" => run.as_ref().expect("run first").key(arg),
            "choose" => {
                // Move the ❯ marker down to the option containing `arg`, then Enter. Option order
                // and default differ between Claude versions (2.1.316 defaults to "No, exit").
                let r = run.as_mut().expect("run first");
                for _ in 0..8 {
                    let on = r.screen().lines().any(|l| l.contains('❯') && l.contains(arg));
                    if on {
                        break;
                    }
                    r.key("down");
                    r.pump(Instant::now() + Duration::from_millis(300));
                }
                assert!(r.screen().lines().any(|l| l.contains('❯') && l.contains(arg)), "line {}: option {arg:?} not found", n + 1);
                // Claude ignores Enter until it has finished starting (seconds, varies by version
                // and environment): press again while the chosen option is still on screen.
                for _ in 0..10 {
                    r.key("enter");
                    r.pump(Instant::now() + Duration::from_secs(2));
                    if !r.screen().lines().any(|l| l.contains('❯') && l.contains(arg)) {
                        break;
                    }
                }
            }
            "type" => {
                let text = arg.replace("\\r", "\r").replace("\\n", "\n").replace("\\e", "\x1b");
                run.as_ref().expect("run first").send(text.as_bytes())
            }
            "snap" => {
                let r = run.as_mut().expect("run first");
                r.pump(Instant::now() + Duration::from_millis(200));
                std::fs::write(out.join(format!("{arg}.bin")), &r.all).unwrap();
                std::fs::write(out.join(format!("{arg}.txt")), r.screen()).unwrap();
                println!("snap {arg}: {} bytes, {}x{}", r.all.len(), cols, rows);
            }
            "snaps" => {
                let r = run.as_mut().expect("run first");
                let mut it = arg.split_whitespace();
                let (name, count, every): (&str, u32, u64) = (it.next().unwrap(), it.next().unwrap().parse().unwrap(), it.next().unwrap().parse().unwrap());
                for k in 1..=count {
                    r.pump(Instant::now() + Duration::from_millis(every));
                    std::fs::write(out.join(format!("{name}-{k:02}.bin")), &r.all).unwrap();
                    std::fs::write(out.join(format!("{name}-{k:02}.txt")), r.screen()).unwrap();
                    println!("snap {name}-{k:02}: {} bytes, {}x{}", r.all.len(), cols, rows);
                }
            }
            other => panic!("line {}: unknown step {other}", n + 1),
        }
    }
    if let Some(r) = run {
        unsafe { libc::killpg(r.pid, libc::SIGKILL) };
    }
}

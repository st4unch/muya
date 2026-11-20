//! Spike `muya-ptyd`: owns the PTYs; keeps a 1 MB memory-only ring and a mode tracker per
//! session; fans live output out to every attached client.
//!
//!   ptyd <socket> <sessions> <command...>   ("{i}" in the command is replaced by the session index)
//!
//! Requests: `list`, `attach <id>`, `input <id> <hex>`, `pause`, `resume`, `winch <id>`.

use crash_iso::*;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};

struct Session {
    child: Child,
    /// Ring, tracker and subscribers share one lock so an attach sees no gap or duplicate.
    state: Mutex<(Ring, ModeTracker, Vec<UnixStream>)>,
    rows: u16,
    cols: u16,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (path, count) = (&args[1], args[2].parse::<usize>().expect("sessions"));
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path).expect("bind");
    let sessions: Arc<Vec<Arc<Session>>> = Arc::new(
        (0..count)
            .map(|i| {
                let argv: Vec<String> = args[3..]
                    .iter()
                    .map(|a| a.replace("{i}", &i.to_string()))
                    .collect();
                let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
                let child = spawn_pty(&argv, 100, 30).expect("spawn");
                Arc::new(Session {
                    child,
                    state: Mutex::new(Default::default()),
                    rows: 30,
                    cols: 100,
                })
            })
            .collect(),
    );
    if std::env::var_os("PTYD_THREADS").is_some() {
        for s in sessions.iter() {
            let s = s.clone();
            std::thread::spawn(move || pump(&s));
        }
    } else {
        let all = sessions.clone();
        std::thread::spawn(move || pump_all(&all));
    }
    eprintln!("ptyd: {count} sessions, pid {}", std::process::id());
    for stream in listener.incoming().flatten() {
        let sessions = sessions.clone();
        std::thread::spawn(move || {
            let _ = serve(stream, &sessions);
        });
    }
}

/// One thread for every PTY (poll): 100 threads waking 100 times a second each cost far more
/// in context switches than the bytes they move.
fn pump_all(sessions: &[Arc<Session>]) {
    let mut fds: Vec<libc::pollfd> = sessions
        .iter()
        .map(|s| libc::pollfd { fd: s.child.master.as_raw_fd(), events: libc::POLLIN, revents: 0 })
        .collect();
    let mut buf = vec![0u8; 65536];
    loop {
        if unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as _, -1) } < 0 {
            continue;
        }
        for (i, pfd) in fds.iter_mut().enumerate() {
            if pfd.revents == 0 {
                continue;
            }
            if pfd.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 && pfd.revents & libc::POLLIN == 0 {
                pfd.fd = -1; // child gone; poll ignores negative fds
                continue;
            }
            let n = unsafe { libc::read(pfd.fd, buf.as_mut_ptr().cast(), buf.len()) };
            if n > 0 {
                deliver(&sessions[i], &buf[..n as usize]);
            }
        }
    }
}

/// Ring, tracker, then every client; a slow or dead client is dropped, never waited for
/// (PRD: it resyncs from a snapshot).
fn deliver(s: &Session, data: &[u8]) {
    let mut st = s.state.lock().unwrap();
    let (ring, tracker, subs) = &mut *st;
    ring.push(data);
    tracker.feed(data);
    subs.retain_mut(|c| write_frame(c, data).is_ok());
}

fn pump(s: &Session) {
    let mut f = unsafe { std::fs::File::from_raw_fd_borrowed(s.child.master.as_raw_fd()) };
    let mut buf = vec![0u8; 65536];
    loop {
        let n = match f.read(&mut buf) {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        deliver(s, &buf[..n]);
    }
}

fn serve(stream: UnixStream, sessions: &[Arc<Session>]) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let mut out = stream;
    let parts: Vec<&str> = line.split_whitespace().collect();
    let session = |i: Option<&&str>| {
        i.and_then(|s| s.parse::<usize>().ok())
            .and_then(|i| sessions.get(i))
    };
    match parts.first().copied() {
        Some("list") => {
            for (i, s) in sessions.iter().enumerate() {
                let end = s.state.lock().unwrap().0.end();
                writeln!(out, "{i} {} {end}", s.child.pid)?;
            }
            writeln!(out, "end")?;
        }
        Some("attach") => {
            let s = session(parts.get(1)).ok_or(std::io::ErrorKind::NotFound)?;
            let mut st = s.state.lock().unwrap();
            let (ring, tracker, subs) = &mut *st;
            writeln!(out, "ok {} {} {}", ring.start, ring.end(), tracker.encode())?;
            write_frame(&mut out, &ring.contents())?;
            out.set_write_timeout(Some(std::time::Duration::from_millis(200)))?;
            subs.push(out);
        }
        Some("input") => {
            let s = session(parts.get(1)).ok_or(std::io::ErrorKind::NotFound)?;
            let hex = parts.get(2).copied().unwrap_or("");
            let bytes: Vec<u8> = (0..hex.len() / 2)
                .filter_map(|i| u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).ok())
                .collect();
            unsafe {
                libc::write(
                    s.child.master.as_raw_fd(),
                    bytes.as_ptr().cast(),
                    bytes.len(),
                )
            };
            writeln!(out, "ok")?;
        }
        Some(cmd @ ("pause" | "resume")) => {
            let sig = if cmd == "pause" {
                libc::SIGSTOP
            } else {
                libc::SIGCONT
            };
            for s in sessions {
                unsafe { libc::killpg(s.child.pid, sig) };
            }
            writeln!(out, "ok")?;
        }
        Some("winch") => {
            // Jiggle the size: TUIs repaint on SIGWINCH (resync after a lossy replay).
            let s = session(parts.get(1)).ok_or(std::io::ErrorKind::NotFound)?;
            for rows in [s.rows - 1, s.rows] {
                let ws = libc::winsize {
                    ws_row: rows,
                    ws_col: s.cols,
                    ws_xpixel: 0,
                    ws_ypixel: 0,
                };
                unsafe { libc::ioctl(s.child.master.as_raw_fd(), libc::TIOCSWINSZ, &ws) };
                std::thread::sleep(std::time::Duration::from_millis(30));
            }
            writeln!(out, "ok")?;
        }
        _ => writeln!(out, "error: unknown request")?,
    }
    Ok(())
}

trait BorrowedFile {
    unsafe fn from_raw_fd_borrowed(fd: i32) -> std::mem::ManuallyDrop<std::fs::File>;
}
impl BorrowedFile for std::fs::File {
    unsafe fn from_raw_fd_borrowed(fd: i32) -> std::mem::ManuallyDrop<std::fs::File> {
        use std::os::fd::FromRawFd;
        std::mem::ManuallyDrop::new(unsafe { std::fs::File::from_raw_fd(fd) })
    }
}

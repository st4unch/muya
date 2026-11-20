//! Spike `muyad`: one libghostty-vt terminal per ptyd session, rebuilt on start from the ring and
//! the mode header (re-adopt). Each terminal lives in its own thread (actor); a control socket
//! answers `hash` (screen fingerprints), `modes <id>` and `shift-enter <id>`.
//!
//!   muyad <ptyd-socket> <control-socket>

use crash_iso::*;
use libghostty_vt::key::{Action, Encoder, Event, Key, Mods};
use libghostty_vt::terminal::{Mode, ModeKind, Options, Terminal};
use std::hash::{Hash, Hasher};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

enum Req {
    Hash(Sender<String>),
    Modes(Sender<String>),
    ShiftEnter(Sender<String>),
    Top(Sender<String>),
}

fn main() {
    let started = Instant::now();
    let args: Vec<String> = std::env::args().collect();
    let (ptyd, ctl) = (args[1].clone(), args[2].clone());
    let list = request_lines(&ptyd, "list");
    let ids: Vec<usize> = list
        .iter()
        .filter_map(|l| l.split(' ').next()?.parse().ok())
        .collect();
    let (ready_tx, ready_rx) = channel::<(usize, usize)>();
    let actors: Vec<Sender<Req>> = ids
        .iter()
        .map(|&id| {
            let (tx, rx) = channel();
            let (ptyd, ready) = (ptyd.clone(), ready_tx.clone());
            std::thread::spawn(move || session(id, &ptyd, rx, ready));
            tx
        })
        .collect();
    let mut replayed = 0;
    for _ in &ids {
        replayed += ready_rx.recv().expect("session ready").1;
    }
    eprintln!(
        "muyad: re-adopted {} sessions ({:.1} MB replayed) in {} ms, rss {:.0} MB",
        ids.len(),
        replayed as f64 / 1e6,
        started.elapsed().as_millis(),
        rss_mb(std::process::id())
    );
    let _ = std::fs::remove_file(&ctl);
    for stream in UnixListener::bind(&ctl)
        .expect("bind control")
        .incoming()
        .flatten()
    {
        let _ = control(stream, &actors);
    }
}

fn request_lines(path: &str, req: &str) -> Vec<String> {
    let mut s = UnixStream::connect(path).expect("ptyd");
    writeln!(s, "{req}").unwrap();
    BufReader::new(s)
        .lines()
        .map_while(Result::ok)
        .take_while(|l| l != "end")
        .collect()
}

fn session(id: usize, ptyd: &str, rx: Receiver<Req>, ready: Sender<(usize, usize)>) {
    let mut stream = UnixStream::connect(ptyd).expect("ptyd");
    writeln!(stream, "attach {id}").unwrap();
    let mut reader = BufReader::new(stream);
    let mut header = String::new();
    reader.read_line(&mut header).unwrap();
    let modes = header
        .split_whitespace()
        .nth(3)
        .unwrap_or(";kitty=0")
        .to_owned();

    let mut term = Terminal::new(Options {
        cols: 100,
        rows: 30,
        max_scrollback: 5_500_000,
    })
    .unwrap();
    term.set_mode(Mode::new(2027, ModeKind::Dec), true).unwrap();
    let mut ring = Vec::new();
    read_frame(&mut reader, &mut ring).unwrap();
    term.vt_write(&ring);
    apply_modes(&mut term, &modes);
    ready.send((id, ring.len())).unwrap();

    // Live frames come from a reader thread so the terminal stays in this thread.
    let (data_tx, data_rx) = channel::<Vec<u8>>();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        while read_frame(&mut reader, &mut buf).is_ok() {
            if data_tx.send(std::mem::take(&mut buf)).is_err() {
                return;
            }
        }
    });
    loop {
        match data_rx.recv_timeout(Duration::from_millis(5)) {
            Ok(bytes) => term.vt_write(&bytes),
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }
        while let Ok(req) = rx.try_recv() {
            match req {
                Req::Hash(reply) => {
                    let _ = reply.send(fingerprint(&term));
                }
                Req::Modes(reply) => {
                    let _ = reply.send(format!(
                        "bracketed_paste={} mouse={} kitty={}",
                        term.mode(Mode::BRACKETED_PASTE).unwrap() as u8,
                        term.is_mouse_tracking().unwrap() as u8,
                        term.kitty_keyboard_flags().unwrap().bits()
                    ));
                }
                Req::Top(reply) => {
                    use libghostty_vt::render::{CellIterator, RenderState, RowIterator};
                    let (mut st, mut rows, mut cells) = (RenderState::new().unwrap(), RowIterator::new().unwrap(), CellIterator::new().unwrap());
                    let snap = st.update(&term).unwrap();
                    let mut it = rows.update(&snap).unwrap();
                    let mut text = String::new();
                    for _ in 0..3 {
                        let Some(row) = it.next() else { break };
                        let mut ci = cells.update(row).unwrap();
                        while let Some(c) = ci.next() {
                            let g = c.graphemes().unwrap_or_default();
                            text.extend(if g.is_empty() { vec![' '] } else { g });
                        }
                        text.push('|');
                    }
                    let _ = reply.send(text.split_whitespace().collect::<Vec<_>>().join(" "));
                }
                Req::ShiftEnter(reply) => {
                    let mut enc = Encoder::new().unwrap();
                    enc.set_options_from_terminal(&term);
                    let mut ev = Event::new().unwrap();
                    ev.set_action(Action::Press)
                        .set_key(Key::Enter)
                        .set_mods(Mods::SHIFT);
                    let mut out = Vec::new();
                    enc.encode_to_vec(&ev, &mut out).unwrap();
                    let _ = reply.send(format!("{out:?}"));
                }
            }
        }
    }
}

/// After replaying the ring, put back modes whose setting bytes have scrolled out of it.
fn apply_modes(term: &mut Terminal, header: &str) {
    let (dec, kitty) = header.split_once(";kitty=").unwrap_or((header, "0"));
    for (k, v) in dec.split(',').filter_map(|kv| kv.split_once('=')) {
        let (Ok(k), on) = (k.parse::<u16>(), v == "1") else {
            continue;
        };
        if k == 1049 {
            continue; // switching screens would blank replayed content; a SIGWINCH repaint handles it
        }
        if term.mode(Mode::new(k, ModeKind::Dec)).unwrap_or(!on) != on {
            term.vt_write(format!("\x1b[?{k}{}", if on { 'h' } else { 'l' }).as_bytes());
        }
    }
    let flags: u8 = kitty.trim().parse().unwrap_or(0);
    if term.kitty_keyboard_flags().map(|f| f.bits()).unwrap_or(0) != flags {
        term.vt_write(format!("\x1b[>{flags}u").as_bytes());
    }
}

/// Fingerprints of the visible screen only (viewport cells: text, colors, style; cursor) — what
/// the user sees. Scrollback differs by design: a re-adopted muyad only has the 1 MB ring.
/// Second field hashes the same viewport as plain text.
fn fingerprint(term: &Terminal) -> String {
    use libghostty_vt::render::{CellIterator, RenderState, RowIterator};
    let (mut styled, mut plain) = (
        std::collections::hash_map::DefaultHasher::new(),
        std::collections::hash_map::DefaultHasher::new(),
    );
    let mut state = RenderState::new().unwrap();
    let mut rows = RowIterator::new().unwrap();
    let mut cells = CellIterator::new().unwrap();
    let snapshot = state.update(term).unwrap();
    format!("{:?}", snapshot.cursor_viewport().ok().flatten().map(|c| (c.x, c.y))).hash(&mut styled);
    let mut row_iter = rows.update(&snapshot).unwrap();
    while let Some(row) = row_iter.next() {
        let mut cell_iter = cells.update(row).unwrap();
        while let Some(cell) = cell_iter.next() {
            let g = cell.graphemes().unwrap_or_default();
            g.hash(&mut plain);
            g.hash(&mut styled);
            format!("{:?}{:?}{:?}", cell.fg_color().ok().flatten(), cell.bg_color().ok().flatten(), cell.style().ok()).hash(&mut styled);
        }
        '\n'.hash(&mut plain);
    }
    format!("{:016x} {:016x}", styled.finish(), plain.finish())
}

fn control(stream: UnixStream, actors: &[Sender<Req>]) -> std::io::Result<()> {
    let mut line = String::new();
    BufReader::new(stream.try_clone()?).read_line(&mut line)?;
    let mut out = stream;
    let parts: Vec<&str> = line.split_whitespace().collect();
    let ask = |i: usize, make: fn(Sender<String>) -> Req| -> String {
        let (tx, rx) = channel();
        actors[i].send(make(tx)).ok();
        rx.recv_timeout(Duration::from_secs(5))
            .unwrap_or_else(|_| "timeout".into())
    };
    match parts.first().copied() {
        Some("hash") => {
            for i in 0..actors.len() {
                writeln!(out, "{i} {}", ask(i, Req::Hash))?;
            }
        }
        Some("modes") => writeln!(out, "{}", ask(parts[1].parse().unwrap_or(0), Req::Modes))?,
        Some("top") => writeln!(out, "{}", ask(parts[1].parse().unwrap_or(0), Req::Top))?,
        Some("shift-enter") => writeln!(
            out,
            "{}",
            ask(parts[1].parse().unwrap_or(0), Req::ShiftEnter)
        )?,
        _ => writeln!(out, "error")?,
    }
    writeln!(out, "end")
}

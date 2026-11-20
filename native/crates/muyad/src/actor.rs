//! One thread per session owning its libghostty-vt terminal (the authoritative state, PRD §5).
//! Everything that reads or changes the terminal goes through this thread's channel, so a
//! snapshot and the start of live output for a new subscriber are atomic.

use libghostty_vt::fmt::{Format, Formatter, FormatterOptions};
use libghostty_vt::screen::CellWide;
use libghostty_vt::style;
use libghostty_vt::terminal::{Mode, ModeKind, Options, Point, PointCoordinate, Terminal};
use libghostty_vt::{key, mouse};
use muya_proto::Frame;
use std::cell::Cell;
use std::rc::Rc;
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};

/// Scrollback kept per session in muyad (bytes, not lines: `max_scrollback` is bytes, Faz 0).
/// ~5,500 rows at 120 columns, the size today's xterm keeps (5000 lines).
pub const SCROLLBACK_BYTES: usize = 5_500_000;

/// Longest a changed Claude screen waits before it is parsed again.
const SCREEN_EVERY: std::time::Duration = std::time::Duration::from_millis(100);

/// Somewhere to send frames for an attached app.
pub type Sink = Arc<dyn Fn(&Frame) -> bool + Send + Sync>;

pub enum Cmd {
    Output {
        seq: u64,
        data: Vec<u8>,
    },
    /// Ring replay finished: apply the tracked modes, then stop suppressing terminal replies.
    Replayed {
        modes: String,
    },
    Exited(i32),
    /// Sends `Attached` and a snapshot through the sink, then live output: all from this thread,
    /// so nothing overtakes the snapshot.
    Subscribe {
        key: usize,
        sink: Sink,
        reply: Sender<()>,
    },
    /// Output stops for this connection; Screen/Exited keep coming (inserts a screen-only sink).
    Detach {
        key: usize,
        sink: Sink,
        reply: Sender<()>,
    },
    Resize {
        cols: u16,
        rows: u16,
    },
    Key {
        key: String,
        mods: u16,
        text: Option<String>,
        reply: Sender<Vec<u8>>,
    },
    Paste {
        text: String,
        reply: Sender<Vec<u8>>,
    },
    Mouse {
        col: u16,
        row: u16,
        button: String,
        action: String,
        mods: u16,
        reply: Sender<Vec<u8>>,
    },
    Modes {
        reply: Sender<String>,
    },
    Screen {
        reply: Sender<String>,
    },
    Fingerprint {
        reply: Sender<String>,
    },
    /// The visible screen lines (secret gate, retype guard).
    Lines {
        reply: Sender<Vec<String>>,
    },
    Stop,
}

/// Runs the actor. `to_pty` receives terminal replies (DA, DSR, Kitty queries) for the program.
pub fn run(
    id: u64,
    cols: u16,
    rows: u16,
    rx: Receiver<Cmd>,
    to_pty: impl Fn(&[u8]) + 'static,
    replaying: bool,
) {
    let mut term = Terminal::new(Options {
        cols,
        rows,
        max_scrollback: SCROLLBACK_BYTES,
    })
    .expect("terminal");
    // Grapheme clustering on, like the Ghostty app (keeps 👍🏽 and 🇹🇷 in one cell; S1).
    let _ = term.set_mode(Mode::new(2027, ModeKind::Dec), true);
    // While the ring is replayed, the program's old queries must not be answered again: the
    // replies would reach it as unexpected input.
    let replay = Rc::new(Cell::new(replaying));
    let gate = replay.clone();
    let _ = term.on_pty_write(move |_, data| {
        if !gate.get() {
            to_pty(data);
        }
    });
    // (connection key, sink, wants output frames)
    let mut sinks: Vec<(usize, Sink, bool)> = Vec::new();
    let mut end_seq = 0u64;
    let mut exited: Option<i32> = None;
    let (mut cols, mut rows) = (cols, rows);
    // Screen state (Claude mode/activity/dialog) is parsed at most every SCREEN_EVERY while output
    // keeps coming, and pushed to subscribers only when it changes.
    let mut screen_dirty = false;
    let mut screen_state = String::new();
    let mut last_parse = std::time::Instant::now() - SCREEN_EVERY;
    loop {
        let cmd = match rx.recv_timeout(SCREEN_EVERY) {
            Ok(c) => Some(c),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => None,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
        };
        if screen_dirty && last_parse.elapsed() >= SCREEN_EVERY {
            screen_dirty = false;
            last_parse = std::time::Instant::now();
            let state = serde_json::to_string(&muya_core::screen::parse_claude_screen(
                &visible_lines(&term),
            ))
            .unwrap_or_default();
            if state != screen_state {
                screen_state = state;
                let frame = Frame::Control(muya_proto::Control::Screen {
                    id,
                    state: screen_state.clone(),
                });
                sinks.retain(|s| (s.1)(&frame));
            }
        }
        let Some(cmd) = cmd else { continue };
        match cmd {
            Cmd::Output { seq, data } => {
                term.vt_write(&data);
                end_seq = seq + data.len() as u64;
                screen_dirty = true;
                let frame = Frame::Output {
                    session: id,
                    seq,
                    data,
                };
                sinks.retain(|s| !s.2 || (s.1)(&frame));
            }
            Cmd::Replayed { modes } => {
                term.vt_write(modes.as_bytes());
                replay.set(false);
            }
            Cmd::Exited(status) => {
                exited = Some(status);
                let frame = Frame::Control(muya_proto::Control::Exited { id, status });
                sinks.retain(|s| (s.1)(&frame));
            }
            Cmd::Detach { key, sink, reply } => {
                if let Some(e) = sinks.iter_mut().find(|e| e.0 == key) {
                    e.2 = false;
                } else {
                    if !screen_state.is_empty() {
                        sink(&Frame::Control(muya_proto::Control::Screen { id, state: screen_state.clone() }));
                    }
                    if let Some(status) = exited {
                        sink(&Frame::Control(muya_proto::Control::Exited { id, status }));
                    }
                    sinks.push((key, sink, false));
                }
                let _ = reply.send(());
            }
            Cmd::Subscribe { key, sink, reply } => {
                sinks.retain(|e| e.0 != key);
                // The snapshot is the first output frame after Attached; live output continues
                // from end_seq.
                sink(&Frame::Control(muya_proto::Control::Attached {
                    id,
                    start_seq: end_seq,
                    end_seq,
                    modes: String::new(),
                }));
                sink(&Frame::Output {
                    session: id,
                    seq: end_seq,
                    data: snapshot(&term),
                });
                if !screen_state.is_empty() {
                    sink(&Frame::Control(muya_proto::Control::Screen {
                        id,
                        state: screen_state.clone(),
                    }));
                }
                let _ = reply.send(());
                if let Some(status) = exited {
                    sink(&Frame::Control(muya_proto::Control::Exited { id, status }));
                }
                sinks.push((key, sink, true));
            }
            Cmd::Resize { cols: c, rows: r } => {
                (cols, rows) = (c, r);
                let _ = term.resize(c, r, 8, 16);
            }
            Cmd::Key {
                key,
                mods,
                text,
                reply,
            } => {
                let _ = reply.send(encode_key(&term, &key, mods, text.as_deref()));
            }
            Cmd::Paste { text, reply } => {
                let bracketed = term.mode(Mode::BRACKETED_PASTE).unwrap_or(false);
                let mut data = text.into_bytes();
                let mut buf = vec![0u8; data.len() * 2 + 16];
                let n = libghostty_vt::paste::encode(&mut data, bracketed, &mut buf).unwrap_or(0);
                buf.truncate(n);
                let _ = reply.send(buf);
            }
            Cmd::Mouse {
                col,
                row,
                button,
                action,
                mods,
                reply,
            } => {
                let _ = reply.send(encode_mouse(
                    &term, cols, rows, col, row, &button, &action, mods,
                ));
            }
            Cmd::Screen { reply } => {
                let _ = reply.send(screen_state.clone());
            }
            Cmd::Modes { reply } => {
                let _ = reply.send(format!(
                    "bracketed_paste={} mouse={} kitty={}",
                    term.mode(Mode::BRACKETED_PASTE).unwrap_or(false) as u8,
                    term.is_mouse_tracking().unwrap_or(false) as u8,
                    term.kitty_keyboard_flags().map(|f| f.bits()).unwrap_or(0)
                ));
            }
            Cmd::Fingerprint { reply } => {
                let _ = reply.send(fingerprint(&term));
            }
            Cmd::Lines { reply } => {
                let _ = reply.send(visible_lines(&term));
            }
            Cmd::Stop => return,
        }
    }
}

/// A VT stream that rebuilds the terminal (screen, scrollback, styles, modes, cursor) on a fresh
/// replica: what the app's renderer starts from when it attaches.
fn snapshot(term: &Terminal) -> Vec<u8> {
    let opts = FormatterOptions::new()
        .with_format(Format::Vt)
        .with_unwrap(false)
        .with_trim(false)
        .with_modes(true)
        .with_scrolling_region(true)
        .with_tabstops(true)
        .with_keyboard(true)
        .with_cursor(true)
        .with_style(true)
        .with_hyperlink(true)
        .with_kitty_keyboard(true)
        .with_charsets(true);
    match Formatter::new(term, opts).and_then(|mut f| f.format_alloc(None).map(|b| b.to_vec())) {
        Ok(v) => {
            let mut out = [b"\x1bc".as_slice(), &v].concat();
            out.extend_from_slice(&final_cursor_position(term));
            out
        }
        Err(_) => Vec::new(),
    }
}

/// The formatter emits the cursor position before the tab stops (`ESC[3g`, `ESC[nG ESC H`…), and
/// setting a tab stop moves the cursor, so a replica would end on the last stop. A CUP as the very
/// last thing puts the cursor back. Left out under origin mode (CUP is margin-relative there and
/// the formatter's own position is the best that can be said) or with no known position.
fn final_cursor_position(term: &Terminal) -> Vec<u8> {
    if term.mode(Mode::ORIGIN).unwrap_or(false) {
        return Vec::new();
    }
    match (term.cursor_y(), term.cursor_x()) {
        (Ok(y), Ok(x)) => {
            let mut out = format!("\x1b[{};{}H", y as u32 + 1, x as u32 + 1).into_bytes();
            out.extend_from_slice(&pending_wrap_suffix(term, x, y));
            out
        }
        _ => Vec::new(),
    }
}

/// A CUP clears the deferred-wrap flag a full-width line leaves behind (cursor on the last column,
/// the wrap not yet taken). The replica must keep it, or the next printed character overwrites the
/// last column instead of wrapping and every Ink "cursor up N" after it lands a row off (Claude's
/// input box drew over its own bottom rule). Printing the cell's own character again, in its own
/// style, sets the flag without changing the screen; then the cursor style is put back.
fn pending_wrap_suffix(term: &Terminal, x: u16, y: u16) -> Vec<u8> {
    if !term.is_cursor_pending_wrap().unwrap_or(false) {
        return Vec::new();
    }
    let point = Point::Active(PointCoordinate { x, y: y as u32 });
    let Ok(cell_ref) = term.grid_ref(point) else { return Vec::new() };
    let Ok(cell) = cell_ref.cell() else { return Vec::new() };
    if cell.wide().map(|w| w != CellWide::Narrow).unwrap_or(true) {
        return Vec::new();
    }
    let mut chars = ['\0'; 16];
    let n = cell_ref.graphemes(&mut chars).unwrap_or(0);
    let text: String = if n == 0 { " ".into() } else { chars[..n].iter().collect() };
    let cell_style = cell_ref.style().unwrap_or_default();
    let cursor_style = term.cursor_style().unwrap_or_default();
    let mut out = sgr(&cell_style).into_bytes();
    out.extend_from_slice(text.as_bytes());
    out.extend_from_slice(sgr(&cursor_style).as_bytes());
    out
}

/// A full SGR sequence for `st`: reset, then every attribute that is set.
fn sgr(st: &style::Style) -> String {
    let mut p: Vec<String> = vec!["0".into()];
    for (on, code) in [
        (st.bold, "1"),
        (st.faint, "2"),
        (st.italic, "3"),
        (st.blink, "5"),
        (st.inverse, "7"),
        (st.invisible, "8"),
        (st.strikethrough, "9"),
        (st.overline, "53"),
    ] {
        if on {
            p.push(code.into());
        }
    }
    match st.underline {
        style::Underline::None => {}
        style::Underline::Single => p.push("4".into()),
        style::Underline::Double => p.push("4:2".into()),
        style::Underline::Curly => p.push("4:3".into()),
        style::Underline::Dotted => p.push("4:4".into()),
        style::Underline::Dashed => p.push("4:5".into()),
        _ => {}
    }
    let color = |c: style::StyleColor, ext: &str, p: &mut Vec<String>| match c {
        style::StyleColor::None => {}
        style::StyleColor::Palette(i) => p.push(format!("{ext};5;{}", i.0)),
        style::StyleColor::Rgb(c) => p.push(format!("{ext};2;{};{};{}", c.r, c.g, c.b)),
    };
    color(st.fg_color, "38", &mut p);
    color(st.bg_color, "48", &mut p);
    color(st.underline_color, "58", &mut p);
    format!("\x1b[{}m", p.join(";"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn term(cols: u16, rows: u16) -> Terminal<'static, 'static> {
        Terminal::new(Options { cols, rows, max_scrollback: 10_000 }).expect("terminal")
    }

    fn cursor(t: &Terminal) -> (u16, u16) {
        (t.cursor_y().unwrap(), t.cursor_x().unwrap())
    }

    /// Replaying the attach snapshot into a fresh terminal lands the cursor where the source's is,
    /// custom tab stops or not (they used to drag it to the last stop).
    #[test]
    fn the_snapshot_leaves_the_cursor_where_the_source_has_it() {
        for script in [
            // default tab stops, cursor mid-screen
            "hello\r\nworld\x1b[2;4H",
            // custom tab stops (clear all, set at 5/20/37), cursor before them
            "\x1b[3g\x1b[1;6H\x1bH\x1b[1;21H\x1bH\x1b[1;38H\x1bH\x1b[3;7Hxyz\x1b[3;2H",
            // styled text, cursor after it
            "\x1b[1;31mred\x1b[0m plain\x1b[5;10H",
        ] {
            let mut src = term(80, 24);
            src.vt_write(script.as_bytes());
            let snap = snapshot(&src);
            let mut replica = term(80, 24);
            replica.vt_write(&snap);
            assert_eq!(cursor(&replica), cursor(&src), "script {script:?}");
        }
    }

    /// Claude's input box: a full-width rule leaves the cursor in the deferred-wrap state. A replica
    /// attached from the snapshot must behave exactly like the source for whatever comes next, or
    /// an Ink redraw (cursor up N, erase line) lands one row off.
    #[test]
    fn the_snapshot_keeps_the_pending_wrap_state() {
        for style in ["", "\x1b[2;38;5;240m", "\x1b[1;48;2;10;20;30m"] {
        let rule = format!("{style}{}\x1b[0m", "\u{2500}".repeat(40));
        let script = format!("{rule}\r\n\u{276f} \r\n{rule}\x1b[2A\x1b[2K\r{rule}");
        let mut src = term(40, 10);
        src.vt_write(script.as_bytes());
        let snap = snapshot(&src);
        let mut replica = term(40, 10);
        replica.vt_write(&snap);
        assert_eq!(cursor(&replica), cursor(&src));
        for next in ["x", "\r\nx", "\u{131}\u{11f}\u{fc}"] {
            src.vt_write(next.as_bytes());
            replica.vt_write(next.as_bytes());
            assert_eq!(cursor(&replica), cursor(&src), "after {next:?}");
        }
        }
    }
}

fn mods_from(bits: u16) -> key::Mods {
    let mut m = key::Mods::empty();
    if bits & muya_proto::MOD_SHIFT != 0 {
        m |= key::Mods::SHIFT;
    }
    if bits & muya_proto::MOD_ALT != 0 {
        m |= key::Mods::ALT;
    }
    if bits & muya_proto::MOD_CTRL != 0 {
        m |= key::Mods::CTRL;
    }
    if bits & muya_proto::MOD_SUPER != 0 {
        m |= key::Mods::SUPER;
    }
    m
}

fn key_from(name: &str) -> Option<(key::Key, Option<char>)> {
    use key::Key as K;
    let k = match name {
        "enter" => K::Enter,
        "tab" => K::Tab,
        "backspace" => K::Backspace,
        "escape" => K::Escape,
        "space" => K::Space,
        "up" => K::ArrowUp,
        "down" => K::ArrowDown,
        "left" => K::ArrowLeft,
        "right" => K::ArrowRight,
        "home" => K::Home,
        "end" => K::End,
        "page_up" => K::PageUp,
        "page_down" => K::PageDown,
        "delete" => K::Delete,
        "insert" => K::Insert,
        "f1" => K::F1,
        "f2" => K::F2,
        "f3" => K::F3,
        "f4" => K::F4,
        "f5" => K::F5,
        "f6" => K::F6,
        "f7" => K::F7,
        "f8" => K::F8,
        "f9" => K::F9,
        "f10" => K::F10,
        "f11" => K::F11,
        "f12" => K::F12,
        _ => {
            let mut chars = name.chars();
            let c = chars.next()?;
            if chars.next().is_some() {
                return None;
            }
            let k = match c.to_ascii_lowercase() {
                'a'..='z' => {
                    let i = (c.to_ascii_lowercase() as u8 - b'a') as usize;
                    [
                        K::A,
                        K::B,
                        K::C,
                        K::D,
                        K::E,
                        K::F,
                        K::G,
                        K::H,
                        K::I,
                        K::J,
                        K::K,
                        K::L,
                        K::M,
                        K::N,
                        K::O,
                        K::P,
                        K::Q,
                        K::R,
                        K::S,
                        K::T,
                        K::U,
                        K::V,
                        K::W,
                        K::X,
                        K::Y,
                        K::Z,
                    ][i]
                }
                _ => K::Unidentified,
            };
            return Some((k, Some(c)));
        }
    };
    Some((k, None))
}

fn encode_key(term: &Terminal, name: &str, mods: u16, text: Option<&str>) -> Vec<u8> {
    let Some((k, ch)) = key_from(name) else {
        return text.map(|t| t.as_bytes().to_vec()).unwrap_or_default();
    };
    let (Ok(mut enc), Ok(mut ev)) = (key::Encoder::new(), key::Event::new()) else {
        return Vec::new();
    };
    enc.set_options_from_terminal(term);
    ev.set_action(key::Action::Press)
        .set_key(k)
        .set_mods(mods_from(mods));
    if let Some(c) = ch {
        ev.set_unshifted_codepoint(c.to_ascii_lowercase());
    }
    let utf8 = text.map(str::to_owned).or_else(|| {
        ch.filter(|_| mods & (muya_proto::MOD_CTRL | muya_proto::MOD_SUPER) == 0)
            .map(String::from)
    });
    ev.set_utf8(utf8);
    let mut out = Vec::new();
    let _ = enc.encode_to_vec(&ev, &mut out);
    out
}

#[allow(clippy::too_many_arguments)]
fn encode_mouse(
    term: &Terminal,
    cols: u16,
    rows: u16,
    col: u16,
    row: u16,
    button: &str,
    action: &str,
    mods: u16,
) -> Vec<u8> {
    // Cells are addressed in a virtual 10x20 px grid; only the cell matters for the encoding.
    let (cw, ch) = (10u32, 20u32);
    let (Ok(mut enc), Ok(mut ev)) = (mouse::Encoder::new(), mouse::Event::new()) else {
        return Vec::new();
    };
    enc.set_options_from_terminal(term);
    enc.set_size(mouse::EncoderSize {
        screen_width: cols as u32 * cw,
        screen_height: rows as u32 * ch,
        cell_width: cw,
        cell_height: ch,
        padding_top: 0,
        padding_bottom: 0,
        padding_right: 0,
        padding_left: 0,
    });
    let action = match action {
        "release" => mouse::Action::Release,
        "motion" => mouse::Action::Motion,
        _ => mouse::Action::Press,
    };
    let button = match button {
        "left" => Some(mouse::Button::Left),
        "middle" => Some(mouse::Button::Middle),
        "right" => Some(mouse::Button::Right),
        "wheel_up" => Some(mouse::Button::Four),
        "wheel_down" => Some(mouse::Button::Five),
        _ => None,
    };
    ev.set_action(action)
        .set_button(button)
        .set_mods(mods_from(mods))
        .set_position(mouse::Position {
            x: (col as u32 * cw + cw / 2) as f32,
            y: (row as u32 * ch + ch / 2) as f32,
        });
    let mut out = Vec::new();
    let _ = enc.encode_to_vec(&ev, &mut out);
    out
}

/// The visible rows as text, right-trimmed (what `readScreenLines` gives the TypeScript parser).
fn visible_lines(term: &Terminal) -> Vec<String> {
    use libghostty_vt::render::{CellIterator, RenderState, RowIterator};
    let mut out = Vec::new();
    let (Ok(mut st), Ok(mut rows), Ok(mut cells)) =
        (RenderState::new(), RowIterator::new(), CellIterator::new())
    else {
        return out;
    };
    let Ok(snap) = st.update(term) else {
        return out;
    };
    let Ok(mut it) = rows.update(&snap) else {
        return out;
    };
    while let Some(row) = it.next() {
        let mut line = String::new();
        if let Ok(mut ci) = cells.update(row) {
            while let Some(c) = ci.next() {
                let g = c.graphemes().unwrap_or_default();
                if g.is_empty() {
                    line.push(' ');
                } else {
                    line.extend(g);
                }
            }
        }
        out.push(line.trim_end().to_owned());
    }
    out
}

/// Fingerprint of the visible screen (cells: text, colors, style; cursor) for tests and
/// `muyactl doctor`.
fn fingerprint(term: &Terminal) -> String {
    use libghostty_vt::render::{CellIterator, RenderState, RowIterator};
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    let (Ok(mut st), Ok(mut rows), Ok(mut cells)) =
        (RenderState::new(), RowIterator::new(), CellIterator::new())
    else {
        return String::new();
    };
    let Ok(snap) = st.update(term) else {
        return String::new();
    };
    format!(
        "{:?}",
        snap.cursor_viewport().ok().flatten().map(|c| (c.x, c.y))
    )
    .hash(&mut h);
    let Ok(mut it) = rows.update(&snap) else {
        return String::new();
    };
    while let Some(row) = it.next() {
        let Ok(mut ci) = cells.update(row) else { break };
        while let Some(c) = ci.next() {
            c.graphemes().unwrap_or_default().hash(&mut h);
            format!(
                "{:?}{:?}{:?}",
                c.fg_color().ok().flatten(),
                c.bg_color().ok().flatten(),
                c.style().ok()
            )
            .hash(&mut h);
        }
    }
    format!("{:016x}", h.finish())
}

/// Shared slot for the actor's channel; dropped sessions leave `None`.
pub type Handle = Arc<Mutex<Sender<Cmd>>>;

//! Faz 0 S4 (PRD `docs/prd-native-rewrite.md` §5, AC2): crash isolation between `muya-ptyd`
//! (owns PTYs, a 1 MB memory-only ring per session, a mode tracker) and `muyad` (libghostty-vt
//! state per session, rebuilt from ring + modes when it restarts).
//!
//! Wire format on the ptyd socket: one request line; `attach` replies with one header line and
//! then length-prefixed frames (u32 big-endian length + bytes) for the ring and live output.

use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

pub const RING_BYTES: usize = 1 << 20;

/// Bounded output history in one fixed 1 MB allocation (a growable deque doubled its capacity on
/// overflow: 2 MB per session, measured in S9); `start` is the sequence number of the first byte.
pub struct Ring {
    buf: Box<[u8]>,
    head: usize, // next write position
    len: usize,
    pub start: u64,
}

impl Default for Ring {
    fn default() -> Self {
        Self { buf: vec![0; RING_BYTES].into_boxed_slice(), head: 0, len: 0, start: 0 }
    }
}

impl Ring {
    pub fn push(&mut self, mut data: &[u8]) {
        if data.len() > RING_BYTES {
            self.start += (self.len + data.len() - RING_BYTES) as u64;
            self.len = 0;
            data = &data[data.len() - RING_BYTES..];
        }
        let n = data.len();
        let first = n.min(RING_BYTES - self.head);
        self.buf[self.head..self.head + first].copy_from_slice(&data[..first]);
        self.buf[..n - first].copy_from_slice(&data[first..]);
        self.head = (self.head + n) % RING_BYTES;
        let overflow = (self.len + n).saturating_sub(RING_BYTES);
        self.start += overflow as u64;
        self.len = (self.len + n).min(RING_BYTES);
    }
    pub fn end(&self) -> u64 {
        self.start + self.len as u64
    }
    pub fn contents(&self) -> Vec<u8> {
        let tail = (self.head + RING_BYTES - self.len) % RING_BYTES;
        let mut out = Vec::with_capacity(self.len);
        if tail + self.len <= RING_BYTES {
            out.extend_from_slice(&self.buf[tail..tail + self.len]);
        } else {
            out.extend_from_slice(&self.buf[tail..]);
            out.extend_from_slice(&self.buf[..self.head]);
        }
        out
    }
}

/// The modes input encoding depends on, kept even after the bytes that set them leave the ring
/// (PRD §5, A1): DEC private modes, Kitty keyboard flag stack per screen. Sequences may be split
/// across reads.
#[derive(Default)]
pub struct ModeTracker {
    dec: std::collections::BTreeMap<u16, bool>,
    kitty_main: Vec<u32>,
    kitty_alt: Vec<u32>,
    state: u8, // 0 ground, 1 ESC, 2 CSI
    csi: Vec<u8>,
}

const TRACKED: [u16; 9] = [1, 25, 1000, 1002, 1003, 1004, 1006, 1049, 2004];

impl ModeTracker {
    pub fn feed(&mut self, data: &[u8]) {
        for &b in data {
            match self.state {
                0 => {
                    if b == 0x1b {
                        self.state = 1
                    }
                }
                1 => {
                    self.state = if b == b'[' { 2 } else { 0 };
                    self.csi.clear();
                    if b == b'c' {
                        *self = Self::default(); // RIS
                    }
                }
                _ => {
                    if (0x40..=0x7e).contains(&b) {
                        self.csi_done(b);
                        self.state = 0;
                    } else if self.csi.len() < 64 {
                        self.csi.push(b);
                    } else {
                        self.state = 0;
                    }
                }
            }
        }
    }

    fn csi_done(&mut self, fin: u8) {
        let p = std::str::from_utf8(&self.csi).unwrap_or("");
        let alt = self.dec.get(&1049).copied().unwrap_or(false);
        match (p.chars().next(), fin) {
            (Some('?'), b'h' | b'l') => {
                for n in p[1..].split(';').filter_map(|s| s.parse::<u16>().ok()) {
                    if TRACKED.contains(&n) {
                        self.dec.insert(n, fin == b'h');
                    }
                }
            }
            (Some('>'), b'u') => {
                let f = p[1..].parse().unwrap_or(0);
                let stack = if alt {
                    &mut self.kitty_alt
                } else {
                    &mut self.kitty_main
                };
                if stack.len() >= 8 {
                    stack.remove(0);
                }
                stack.push(f);
            }
            (Some('<'), b'u') => {
                let n = p[1..].parse().unwrap_or(1).max(1);
                let stack = if alt {
                    &mut self.kitty_alt
                } else {
                    &mut self.kitty_main
                };
                let keep = stack.len().saturating_sub(n);
                stack.truncate(keep);
            }
            (Some('!'), b'p') => *self = Self::default(), // DECSTR
            _ => {}
        }
    }

    pub fn kitty_flags(&self) -> u32 {
        let alt = self.dec.get(&1049).copied().unwrap_or(false);
        let stack = if alt {
            &self.kitty_alt
        } else {
            &self.kitty_main
        };
        stack.last().copied().unwrap_or(0)
    }

    /// "2004=1,1000=1,...;kitty=1" — the header muyad applies after replaying the ring.
    pub fn encode(&self) -> String {
        let dec: Vec<String> = self
            .dec
            .iter()
            .map(|(k, v)| format!("{k}={}", *v as u8))
            .collect();
        format!("{};kitty={}", dec.join(","), self.kitty_flags())
    }
}

/// Length prefix and payload in one vectored write (two writes per client per read cost ptyd
/// ~40 % CPU at 100 sessions, measured in S9).
pub fn write_frame(w: &mut impl Write, data: &[u8]) -> io::Result<()> {
    let len = (data.len() as u32).to_be_bytes();
    let mut bufs = [io::IoSlice::new(&len), io::IoSlice::new(data)];
    let mut slices: &mut [io::IoSlice] = &mut bufs;
    while !slices.is_empty() {
        let n = w.write_vectored(slices)?;
        if n == 0 {
            return Err(io::ErrorKind::WriteZero.into());
        }
        io::IoSlice::advance_slices(&mut slices, n);
    }
    Ok(())
}

pub fn read_frame(r: &mut impl Read, buf: &mut Vec<u8>) -> io::Result<()> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len)?;
    buf.resize(u32::from_be_bytes(len) as usize, 0);
    r.read_exact(buf)
}

pub struct Child {
    pub master: OwnedFd,
    pub pid: libc::pid_t,
}

/// Starts `argv` as the leader of a new session on a fresh PTY (IUTF8 on).
pub fn spawn_pty(argv: &[&str], cols: u16, rows: u16) -> io::Result<Child> {
    use std::os::unix::process::CommandExt;
    let (mut m, mut s) = (0, 0);
    let mut ws = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    if unsafe {
        libc::openpty(
            &mut m,
            &mut s,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut ws,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    let (master, slave) = unsafe { (OwnedFd::from_raw_fd(m), OwnedFd::from_raw_fd(s)) };
    let mut t: libc::termios = unsafe { std::mem::zeroed() };
    unsafe {
        libc::tcgetattr(slave.as_raw_fd(), &mut t);
        if std::env::var_os("SPIKE_NO_IUTF8").is_none() {
            t.c_iflag |= libc::IUTF8;
        }
        libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &t);
    }
    let mut cmd = std::process::Command::new(argv[0]);
    cmd.args(&argv[1..])
        .env("TERM", "xterm-256color")
        .stdin(slave.try_clone()?)
        .stdout(slave.try_clone()?)
        .stderr(slave);
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 || libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = cmd.spawn()?;
    Ok(Child {
        master,
        pid: child.id() as libc::pid_t,
    })
}

pub fn rss_mb(pid: u32) -> f64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output();
    out.ok()
        .and_then(|o| {
            String::from_utf8_lossy(&o.stdout)
                .trim()
                .parse::<f64>()
                .ok()
        })
        .map(|kb| kb / 1024.0)
        .unwrap_or(-1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_keeps_last_megabyte_and_counts_sequence() {
        let mut r = Ring::default();
        r.push(&vec![b'a'; RING_BYTES]);
        r.push(b"xyz");
        assert_eq!(r.start, 3);
        assert_eq!(r.end(), RING_BYTES as u64 + 3);
        assert_eq!(&r.contents()[RING_BYTES - 3..], b"xyz");
    }

    #[test]
    fn ring_wraps_and_matches_a_reference_on_random_pushes() {
        let mut r = Ring::default();
        let mut all = Vec::new();
        let mut seed = 7u64;
        for _ in 0..3000 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let n = (seed >> 33) as usize % 4000 + if seed % 97 == 0 { RING_BYTES } else { 0 };
            let chunk: Vec<u8> = (0..n).map(|i| (i as u64 ^ seed) as u8).collect();
            r.push(&chunk);
            all.extend_from_slice(&chunk);
        }
        let keep = all.len().min(RING_BYTES);
        assert_eq!(r.contents(), &all[all.len() - keep..]);
        assert_eq!(r.end(), all.len() as u64);
        assert_eq!(r.start, (all.len() - keep) as u64);
    }

    #[test]
    fn tracker_split_sequences_and_kitty_stack_per_screen() {
        let mut t = ModeTracker::default();
        t.feed(b"\x1b[?20");
        t.feed(b"04h\x1b[?1000;1006h\x1b[>1u");
        assert_eq!(t.kitty_flags(), 1);
        t.feed(b"\x1b[?1049h");
        assert_eq!(t.kitty_flags(), 0, "alt screen has its own stack");
        t.feed(b"\x1b[>3u\x1b[?1049l");
        assert_eq!(t.kitty_flags(), 1);
        assert_eq!(t.encode(), "1000=1,1006=1,1049=0,2004=1;kitty=1");
        t.feed(b"\x1b[<u\x1b[!p");
        assert_eq!(t.encode(), ";kitty=0");
    }

    /// Differential check against libghostty-vt (PRD: the tracker is fuzzed against it).
    #[test]
    fn tracker_matches_libghostty_on_random_mode_streams() {
        use libghostty_vt::terminal::{Mode, Options, Terminal};
        let pieces: [&[u8]; 10] = [
            b"\x1b[?2004h",
            b"\x1b[?2004l",
            b"\x1b[?1000h",
            b"\x1b[?1000l",
            b"\x1b[>1u",
            b"\x1b[>5u",
            b"\x1b[<u",
            b"\x1b[?1049h",
            b"\x1b[?1049l",
            b"hello\r\n",
        ];
        let mut seed = 0x9e3779b97f4a7c15u64;
        for _ in 0..200 {
            let mut t = ModeTracker::default();
            let mut g = Terminal::new(Options {
                cols: 80,
                rows: 24,
                max_scrollback: 0,
            })
            .unwrap();
            let mut stream = Vec::new();
            for _ in 0..40 {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                stream.extend_from_slice(pieces[(seed % pieces.len() as u64) as usize]);
            }
            // Feed in random-sized chunks so sequences split across reads.
            let mut i = 0;
            while i < stream.len() {
                let n = 1 + (seed as usize + i) % 7;
                let end = (i + n).min(stream.len());
                t.feed(&stream[i..end]);
                g.vt_write(&stream[i..end]);
                i = end;
            }
            assert_eq!(
                t.dec.get(&2004).copied().unwrap_or(false),
                g.mode(Mode::BRACKETED_PASTE).unwrap()
            );
            assert_eq!(
                t.kitty_flags() != 0,
                !g.kitty_keyboard_flags().unwrap().is_empty()
            );
        }
    }
}

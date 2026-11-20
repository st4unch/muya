//! Mode tracker (PRD §5, A1): a few hundred bytes per session recording the state input encoding
//! and repainting depend on, kept after the bytes that set it have left the ring. After a
//! re-adopt muyad replays the ring, then applies [`ModeTracker::restore_sequence`].
//!
//! Tracks DEC private modes (incl. DECOM origin mode), the scroll region (DECSTBM; Faz 0 S4: a
//! repaint after resync scrolls the wrong region without it), Kitty keyboard flag stacks per
//! screen, XTSAVE/XTRESTORE and RIS, mirroring libghostty-vt (which ignores DECSTR). Sequences
//! may be split across reads.

use std::collections::BTreeMap;

/// DEC private modes that change input encoding or screen addressing.
const TRACKED: [u16; 13] = [
    1, 6, 7, 25, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1049, 2004,
];
const KITTY_STACK_MAX: usize = 8;

#[derive(Default, Clone, Debug, PartialEq, Eq)]
pub struct ModeTracker {
    dec: BTreeMap<u16, bool>,
    saved: BTreeMap<u16, bool>,
    kitty_main: Vec<u32>,
    kitty_alt: Vec<u32>,
    /// DECSTBM top/bottom (1-based); `None` = full screen.
    region: Option<(u16, u16)>,
    state: State,
    params: Vec<u8>,
}

#[derive(Default, Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    #[default]
    Ground,
    Esc,
    Csi,
    /// Inside a string (OSC/DCS/APC/PM/SOS): skip until BEL or ST.
    Str,
    StrEsc,
}

impl ModeTracker {
    pub fn feed(&mut self, data: &[u8]) {
        for &b in data {
            self.byte(b);
        }
    }

    fn byte(&mut self, b: u8) {
        self.state = match self.state {
            State::Ground => {
                if b == 0x1b {
                    State::Esc
                } else {
                    State::Ground
                }
            }
            State::Esc => match b {
                b'[' => {
                    self.params.clear();
                    State::Csi
                }
                b']' | b'P' | b'_' | b'^' | b'X' => State::Str,
                b'c' => {
                    *self = Self::default(); // RIS
                    State::Ground
                }
                0x1b => State::Esc,
                _ => State::Ground,
            },
            State::Csi => {
                if (0x40..=0x7e).contains(&b) {
                    self.csi(b);
                    State::Ground
                } else if b == 0x1b {
                    State::Esc
                } else if self.params.len() < 64 {
                    self.params.push(b);
                    State::Csi
                } else {
                    State::Ground
                }
            }
            State::Str => match b {
                0x07 => State::Ground,
                0x1b => State::StrEsc,
                _ => State::Str,
            },
            // ESC inside a string ends it (DEC parser, as libghostty-vt does): ESC \ is ST, any
            // other byte starts a new escape sequence — "ESC [?2004h" there takes effect.
            State::StrEsc => {
                if b == b'\\' {
                    State::Ground
                } else {
                    self.state = State::Esc;
                    self.byte(b);
                    return;
                }
            }
        };
    }

    fn alt(&self) -> bool {
        self.dec.get(&1049).copied().unwrap_or(false)
    }

    fn csi(&mut self, fin: u8) {
        let p = std::str::from_utf8(&self.params).unwrap_or("");
        let nums = |s: &str| -> Vec<u16> { s.split(';').filter_map(|x| x.parse().ok()).collect() };
        match (p.as_bytes().first().copied(), fin) {
            (Some(b'?'), b'h' | b'l') => {
                for n in nums(&p[1..]) {
                    if TRACKED.contains(&n) {
                        self.dec.insert(n, fin == b'h');
                    }
                }
            }
            (Some(b'?'), b's') => {
                for n in nums(&p[1..]) {
                    if let Some(v) = self.dec.get(&n) {
                        self.saved.insert(n, *v);
                    }
                }
            }
            (Some(b'?'), b'r') => {
                for n in nums(&p[1..]) {
                    if let Some(v) = self.saved.get(&n).copied() {
                        self.dec.insert(n, v);
                    }
                }
            }
            (Some(b'>'), b'u') => {
                let f = p[1..].parse().unwrap_or(0);
                let alt = self.alt();
                let stack = if alt {
                    &mut self.kitty_alt
                } else {
                    &mut self.kitty_main
                };
                if stack.len() >= KITTY_STACK_MAX {
                    stack.remove(0);
                }
                stack.push(f);
            }
            (Some(b'<'), b'u') => {
                let n = p[1..].parse::<usize>().unwrap_or(1).max(1);
                let alt = self.alt();
                let stack = if alt {
                    &mut self.kitty_alt
                } else {
                    &mut self.kitty_main
                };
                stack.truncate(stack.len().saturating_sub(n));
            }
            (Some(b'='), b'u') => {
                // CSI = flags ; mode u — 1 set, 2 or, 3 and-not.
                let v = nums(&p[1..]);
                let (flags, mode) = (u32::from(*v.first().unwrap_or(&0)), *v.get(1).unwrap_or(&1));
                let alt = self.alt();
                let stack = if alt {
                    &mut self.kitty_alt
                } else {
                    &mut self.kitty_main
                };
                let cur = stack.last().copied().unwrap_or(0);
                let new = match mode {
                    2 => cur | flags,
                    3 => cur & !flags,
                    _ => flags,
                };
                match stack.last_mut() {
                    Some(top) => *top = new,
                    None => stack.push(new),
                }
            }
            // DECSTR (CSI ! p) is not implemented by libghostty-vt, the authoritative state, so it is
            // ignored here too (the differential test caught the mismatch).
            (_, b'r') if p.bytes().all(|c| c.is_ascii_digit() || c == b';') => {
                let v = nums(p);
                self.region = match (v.first(), v.get(1)) {
                    (Some(&t), Some(&b)) if t >= 1 && b > t => Some((t, b)),
                    _ => None,
                };
            }
            _ => {}
        }
    }

    pub fn kitty_flags(&self) -> u32 {
        let stack = if self.alt() {
            &self.kitty_alt
        } else {
            &self.kitty_main
        };
        stack.last().copied().unwrap_or(0)
    }

    pub fn mode(&self, n: u16) -> Option<bool> {
        self.dec.get(&n).copied()
    }

    pub fn region(&self) -> Option<(u16, u16)> {
        self.region
    }

    /// Escape sequence that puts a terminal (after ring replay) into the tracked state. Leaves
    /// the alternate screen alone: switching would blank replayed content; muyad asks for a
    /// repaint (resync) instead.
    pub fn restore_sequence(&self) -> String {
        let mut out = String::new();
        for (n, on) in &self.dec {
            if *n != 1049 {
                out += &format!("\x1b[?{n}{}", if *on { 'h' } else { 'l' });
            }
        }
        if let Some((t, b)) = self.region {
            // DECSTBM homes the cursor; save and restore it around the region.
            out += &format!("\x1b7\x1b[{t};{b}r\x1b8");
        }
        // Set (not push) the current Kitty flags: applying the restore twice must not grow the stack.
        out += &format!("\x1b[={};1u", self.kitty_flags());
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_sequences_kitty_per_screen_and_reset() {
        let mut t = ModeTracker::default();
        t.feed(b"\x1b[?20");
        t.feed(b"04h\x1b[?1000;1006h\x1b[>1u");
        assert_eq!(
            (t.mode(2004), t.mode(1000), t.kitty_flags()),
            (Some(true), Some(true), 1)
        );
        t.feed(b"\x1b[?1049h");
        assert_eq!(t.kitty_flags(), 0, "alt screen has its own stack");
        t.feed(b"\x1b[>3u\x1b[?1049l");
        assert_eq!(t.kitty_flags(), 1);
        t.feed(b"\x1b[!p");
        assert_eq!(t.kitty_flags(), 1, "DECSTR is ignored, like libghostty-vt");
        t.feed(b"\x1bc");
        assert_eq!(t, ModeTracker::default(), "RIS resets everything");
    }

    #[test]
    fn scroll_region_origin_mode_and_xtsave() {
        let mut t = ModeTracker::default();
        t.feed(b"\x1b[3;30r\x1b[?6h");
        assert_eq!((t.region(), t.mode(6)), (Some((3, 30)), Some(true)));
        t.feed(b"\x1b[r");
        assert_eq!(t.region(), None);
        t.feed(b"\x1b[?2004h\x1b[?2004s\x1b[?2004l");
        assert_eq!(t.mode(2004), Some(false));
        t.feed(b"\x1b[?2004r");
        assert_eq!(t.mode(2004), Some(true));
    }

    #[test]
    fn strings_end_like_the_dec_parser() {
        let mut t = ModeTracker::default();
        // Plain text in an OSC title is ignored...
        t.feed(b"\x1b]0;title [?2004h fake\x07\x1b]8;;http://x\x1b\\");
        assert_eq!(t.mode(2004), None);
        // ...but ESC inside it ends the string and the CSI that follows takes effect.
        t.feed(b"\x1b]0;t\x1b[?2004h\x07");
        assert_eq!(t.mode(2004), Some(true));
    }

    #[test]
    fn kitty_set_or_and_not_and_stack_cap() {
        let mut t = ModeTracker::default();
        t.feed(b"\x1b[=1;1u\x1b[=4;2u");
        assert_eq!(t.kitty_flags(), 5);
        t.feed(b"\x1b[=1;3u");
        assert_eq!(t.kitty_flags(), 4);
        for _ in 0..5000 {
            t.feed(b"\x1b[>1u"); // a program that keeps pushing must not grow memory or crash
        }
        assert!(t.kitty_main.len() <= KITTY_STACK_MAX);
    }

    #[test]
    fn restore_sequence_skips_alt_screen_and_keeps_region() {
        let mut t = ModeTracker::default();
        t.feed(b"\x1b[?2004h\x1b[?1049h\x1b[2;20r\x1b[>1u");
        let s = t.restore_sequence();
        assert!(
            s.contains("\x1b[?2004h")
                && !s.contains("1049")
                && s.contains("\x1b[2;20r")
                && s.ends_with("\x1b[=1;1u"),
            "{s:?}"
        );
    }

    /// Differential check against libghostty-vt on random mode streams split at random points
    /// (PRD §5: the tracker is fuzzed against libghostty-vt's mode state).
    #[test]
    fn matches_libghostty_on_random_streams() {
        use libghostty_vt::terminal::{Mode, Options, Terminal};
        let pieces: [&[u8]; 14] = [
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
            b"\x1b[=4;2u",
            b"\x1b]0;t\x1b[?2004h\x07",
            b"\x1b[!p",
            b"\x1b[?2004s",
        ];
        let mut seed = 0x9e3779b97f4a7c15u64;
        let mut rnd = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        for _ in 0..500 {
            let mut t = ModeTracker::default();
            let mut g = Terminal::new(Options {
                cols: 80,
                rows: 24,
                max_scrollback: 0,
            })
            .unwrap();
            let mut stream = Vec::new();
            for _ in 0..40 {
                stream.extend_from_slice(pieces[(rnd() % pieces.len() as u64) as usize]);
            }
            let mut i = 0;
            while i < stream.len() {
                let end = (i + 1 + (rnd() as usize) % 7).min(stream.len());
                t.feed(&stream[i..end]);
                g.vt_write(&stream[i..end]);
                i = end;
            }
            let ctx = String::from_utf8_lossy(&stream).into_owned();
            assert_eq!(
                t.mode(2004).unwrap_or(false),
                g.mode(Mode::BRACKETED_PASTE).unwrap(),
                "bracketed paste: {ctx:?}"
            );
            assert_eq!(
                t.kitty_flags() as u8,
                g.kitty_keyboard_flags().unwrap().bits(),
                "kitty flags: {ctx:?}"
            );
        }
    }
}

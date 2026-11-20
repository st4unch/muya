//! Faz 0, task 1 (PRD `docs/prd-native-rewrite.md`): prove libghostty-vt builds with the
//! pinned Zig, links into Rust, and tracks the terminal modes the ptyd mode tracker and
//! muyad depend on.

#[cfg(test)]
mod tests {
    use libghostty_vt::terminal::{Mode, Options, Terminal};

    fn term() -> Terminal<'static, 'static> {
        Terminal::new(Options {
            cols: 120,
            rows: 40,
            max_scrollback: 5000,
        })
        .expect("terminal")
    }

    #[test]
    fn tracks_bracketed_paste_and_alt_screen() {
        let mut t = term();
        assert!(!t.mode(Mode::BRACKETED_PASTE).unwrap());
        t.vt_write(b"\x1b[?2004h\x1b[?1049h");
        assert!(t.mode(Mode::BRACKETED_PASTE).unwrap());
        assert!(t.mode(Mode::ALT_SCREEN_SAVE).unwrap());
        t.vt_write(b"\x1b[?2004l");
        assert!(!t.mode(Mode::BRACKETED_PASTE).unwrap());
    }

    // ptyd reads in 32 KB chunks, so a sequence can arrive in two writes.
    #[test]
    fn sequence_split_across_writes() {
        let mut t = term();
        t.vt_write(b"\x1b[?20");
        t.vt_write(b"04h");
        assert!(t.mode(Mode::BRACKETED_PASTE).unwrap());
    }

    #[test]
    fn kitty_keyboard_push_pop() {
        let mut t = term();
        let none = t.kitty_keyboard_flags().unwrap();
        t.vt_write(b"\x1b[>1u");
        assert_ne!(t.kitty_keyboard_flags().unwrap(), none);
        t.vt_write(b"\x1b[<u");
        assert_eq!(t.kitty_keyboard_flags().unwrap(), none);
    }

    /// A program that keeps pushing Kitty keyboard modes must not crash the engine
    /// (alacritty_terminal 0.26.0 panics here; native/spikes/vt-fallback).
    #[test]
    fn kitty_keyboard_overflow_does_not_panic() {
        let mut t = term();
        for _ in 0..5000 {
            t.vt_write(b"\x1b[>1u");
        }
        assert!(t.kitty_keyboard_flags().is_ok());
    }

    #[test]
    fn mouse_tracking_and_cursor() {
        let mut t = term();
        t.vt_write(b"\x1b[?1000h");
        assert!(t.is_mouse_tracking().unwrap());
        t.vt_write(b"\x1b[5;10H");
        assert_eq!((t.cursor_y().unwrap(), t.cursor_x().unwrap()), (4, 9));
    }

    fn rss_kb() -> u64 {
        let out = std::process::Command::new("ps")
            .args(["-o", "rss=", "-p", &std::process::id().to_string()])
            .output()
            .expect("ps");
        String::from_utf8_lossy(&out.stdout)
            .trim()
            .parse()
            .expect("rss")
    }

    /// Memory budget per terminal: `VT_SB=<max_scrollback bytes> VT_TERMS=<n> VT_LINES=<per terminal>`,
    /// one configuration per process so RSS is not polluted by an earlier run.
    #[test]
    #[ignore]
    fn memory_budget() {
        let env = |k: &str, d: usize| {
            std::env::var(k)
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(d)
        };
        let (sb, terms, lines) = (env("VT_SB", 5000), env("VT_TERMS", 1), env("VT_LINES", 200_000));
        let line = "\x1b[38;5;75m*\x1b[0m Read \x1b[1msrc/components/Terminal.tsx\x1b[0m lorem ipsum dolor sit amet, consectetur adipiscing elit 0123456789\r\n";
        let base = rss_kb();
        let mut all: Vec<Terminal> = (0..terms)
            .map(|_| {
                Terminal::new(Options {
                    cols: 120,
                    rows: 40,
                    max_scrollback: sb,
                })
                .expect("terminal")
            })
            .collect();
        let empty = rss_kb();
        let start = std::time::Instant::now();
        for t in &mut all {
            for _ in 0..lines {
                t.vt_write(line.as_bytes());
            }
        }
        let secs = start.elapsed().as_secs_f64();
        let full = rss_kb();
        println!(
            "SB={sb} terms={terms} lines={lines}: scrollback_rows={} empty={:.1} MB/term full={:.1} MB/term {:.0} MB/s",
            all[0].scrollback_rows().unwrap(),
            (empty - base) as f64 / 1024.0 / terms as f64,
            (full - base) as f64 / 1024.0 / terms as f64,
            (terms * lines * line.len()) as f64 / 1e6 / secs,
        );
    }

    /// Throughput of Claude-like output (`cargo test --release -- --ignored --nocapture`).
    #[test]
    #[ignore]
    fn throughput() {
        let mut t = term();
        let mut chunk = Vec::new();
        for i in 0..400 {
            chunk.extend_from_slice(
                format!("\r\n\x1b[38;5;{}m*\x1b[0m Read \x1b[1msrc/File{i}.tsx\x1b[0m lorem ipsum dolor sit amet lorem ipsum", 16 + i % 200)
                    .as_bytes(),
            );
        }
        let total = 64 * 1024 * 1024;
        let start = std::time::Instant::now();
        let mut n = 0;
        while n < total {
            t.vt_write(&chunk);
            n += chunk.len();
        }
        let secs = start.elapsed().as_secs_f64();
        println!(
            "libghostty-vt: {:.0} MB/s ({} MB in {:.2} s), scrollback rows {}",
            n as f64 / 1e6 / secs,
            n / 1_000_000,
            secs,
            t.scrollback_rows().unwrap()
        );
    }
}

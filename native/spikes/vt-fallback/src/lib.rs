//! Faz 0 S2 extended (PRD `docs/prd-native-rewrite.md` §10): the fallback engine
//! (alacritty_terminal, risk R1) must pass the Kitty keyboard checks libghostty-vt passes.

#[cfg(test)]
mod tests {
    use alacritty_terminal::event::{Event, EventListener};
    use alacritty_terminal::term::test::TermSize;
    use alacritty_terminal::term::{Config, Term, TermMode};
    use alacritty_terminal::vte::ansi::Processor;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct Replies(Arc<Mutex<Vec<String>>>);

    impl EventListener for Replies {
        fn send_event(&self, event: Event) {
            if let Event::PtyWrite(text) = event {
                self.0.lock().unwrap().push(text);
            }
        }
    }

    struct Vt {
        term: Term<Replies>,
        parser: Processor,
        replies: Replies,
    }

    impl Vt {
        fn new() -> Self {
            let replies = Replies::default();
            let config = Config {
                kitty_keyboard: true,
                ..Config::default()
            };
            let term = Term::new(config, &TermSize::new(120, 40), replies.clone());
            Self {
                term,
                parser: Processor::new(),
                replies,
            }
        }
        fn write(&mut self, bytes: &[u8]) {
            self.parser.advance(&mut self.term, bytes);
        }
        fn kitty(&self) -> TermMode {
            *self.term.mode() & TermMode::KITTY_KEYBOARD_PROTOCOL
        }
        fn last_reply(&self) -> Option<String> {
            self.replies.0.lock().unwrap().last().cloned()
        }
    }

    #[test]
    fn kitty_push_query_pop() {
        let mut vt = Vt::new();
        assert!(vt.kitty().is_empty());
        vt.write(b"\x1b[>1u");
        assert_eq!(vt.kitty(), TermMode::DISAMBIGUATE_ESC_CODES);
        vt.write(b"\x1b[?u");
        assert_eq!(vt.last_reply().as_deref(), Some("\x1b[?1u"));
        vt.write(b"\x1b[<u");
        assert!(vt.kitty().is_empty());
    }

    #[test]
    fn kitty_sequence_split_across_writes() {
        let mut vt = Vt::new();
        vt.write(b"\x1b[>");
        vt.write(b"1u");
        assert_eq!(vt.kitty(), TermMode::DISAMBIGUATE_ESC_CODES);
    }

    /// The Kitty spec keeps one stack per screen.
    #[test]
    fn kitty_stack_per_screen() {
        let mut vt = Vt::new();
        vt.write(b"\x1b[>1u\x1b[?1049h");
        assert!(
            vt.kitty().is_empty(),
            "alt screen starts with its own empty stack"
        );
        vt.write(b"\x1b[>3u");
        vt.write(b"\x1b[?1049l");
        assert_eq!(
            vt.kitty(),
            TermMode::DISAMBIGUATE_ESC_CODES,
            "main screen mode restored"
        );
    }

    /// A program that keeps pushing must not be able to crash the engine.
    #[test]
    fn kitty_stack_overflow_does_not_panic() {
        let result = std::panic::catch_unwind(|| {
            let mut vt = Vt::new();
            for _ in 0..5000 {
                vt.write(b"\x1b[>1u");
            }
            vt.kitty()
        });
        assert!(result.is_ok(), "pushing past the stack limit panicked");
    }
}

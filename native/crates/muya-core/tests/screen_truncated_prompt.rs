//! A prompt the TUI could not draw in full. Claude puts its own line under the options
//! ("↑ 8 more lines", "ctrl+o to expand description"); the prompt is still live and must
//! still be answerable from Muya. Operator report, 2026-11-26 (images/59.webp).
use muya_core::screen::parse_claude_screen;

fn l(s: &str) -> Vec<String> {
    s.lines().map(str::to_owned).collect()
}

/// The screen as the operator photographed it: a tool-description box, the question, three
/// options, then Claude's own "↑ 8 more lines" between the last option and the footer.
fn operator_screen() -> Vec<String> {
    let dash = "╌".repeat(70);
    l(&format!(
        "    limit: 50\n  }}\n{dash}\n About the murat-personal-access — Osiris Run Tool Tool:\n  Dispatch to any tool available to this agent, including built-in platform tools…\n (ctrl+o to expand description)\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, and don't ask again for murat-personal-access — Osiris Run Tool commands in /tmp/x\n   3. No\n ↑ 8 more lines\n Esc to cancel · Tab to amend · ctrl+x ctrl+k twice to stop background agents"
    ))
}

#[test]
fn a_prompt_with_a_more_lines_marker_is_still_a_prompt() {
    let st = parse_claude_screen(&operator_screen());
    let p = st.permission.expect("the prompt must be seen even when the TUI truncated it");
    assert_eq!(p.options.len(), 3, "all three visible options are offered");
    assert_eq!(p.options[0].key, "1");
}

fn screen_with(above: &str, between: &str, after: &str) -> Vec<String> {
    let dash = "╌".repeat(70);
    l(&format!(
        "{dash}\n About the Tool:\n  a description\n{above} Do you want to proceed?\n ❯ 1. Yes\n{between}   2. No\n{after} Esc to cancel"
    ))
}

#[test]
fn marker_above_the_question_is_skipped() {
    let p = parse_claude_screen(&screen_with(" (ctrl+o to expand description)\n\n", "", "")).permission.expect("prompt");
    assert!(p.truncated);
    assert_eq!(p.options.len(), 2);
}

#[test]
fn marker_between_options_is_skipped() {
    for m in [" ↑ 8 more lines\n", " ↓ 2 more lines\n", " … 5 more lines\n", " +4 more\n"] {
        let p = parse_claude_screen(&screen_with("\n", m, "")).permission.unwrap_or_else(|| panic!("{m:?}"));
        assert!(p.truncated, "{m:?}");
        assert_eq!(p.options.len(), 2);
    }
}

#[test]
fn ordinary_prose_in_the_option_block_is_still_rejected() {
    let st = parse_claude_screen(&screen_with("\n", "", " Some other sentence here\n"));
    assert!(st.permission.is_none());
    let st = parse_claude_screen(&screen_with("\n", " 8 more lines of notes\n", ""));
    assert!(st.permission.is_none());
}

#[test]
fn a_normal_prompt_is_not_truncated() {
    let p = parse_claude_screen(&screen_with("\n", "", "")).permission.expect("prompt");
    assert!(!p.truncated);
}

#[test]
fn the_selected_row_is_the_one_with_the_marker() {
    let p = parse_claude_screen(&screen_with("\n", "", "")).permission.expect("prompt");
    assert_eq!(p.selected, 0);
    let dash = "╌".repeat(70);
    let moved = l(&format!("{dash}\n About the Tool:\n Do you want to proceed?\n   1. Yes\n ❯ 2. Yes, and don't ask again\n   3. No\n Esc to cancel"));
    let p = parse_claude_screen(&moved).permission.expect("prompt");
    assert_eq!(p.selected, 1);
    assert_eq!(p.options[1].key, "2");
    assert_eq!(p.options[1].label, "Yes, and don't ask again");
}

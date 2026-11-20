//! Background agents running while Claude's own spinner is absent: the session is still working.
use muya_core::screen::{parse_claude_screen, parse_subagents};

fn l(s: &str) -> Vec<String> {
    s.lines().map(str::to_owned).collect()
}

const FOOTER: &str = "  ⏵⏵ bypass permissions on (shift+tab to cycle)";

#[test]
fn waiting_for_background_agents_counts() {
    let s = l(&format!("✻ Waiting for 2 background agents to finish\n\n> \n{FOOTER}"));
    assert_eq!(parse_claude_screen(&s).subagents, Some(2));
}

#[test]
fn agent_tree_rows_count_but_main_does_not() {
    let s = l(&format!(
        "> \n  ● main\n  ○ general-purpose  Running tests…  1m 15s · ↓ 104.9k tokens\n  ○ general-purpose  Marking …\n{FOOTER}"
    ));
    assert_eq!(parse_subagents(&s), 2);
}

#[test]
fn finished_agents_do_not_keep_it_working() {
    let s = l(&format!(
        "> \n  ● main\n  ✓ general-purpose  Done  2m 3s · ↓ 90k tokens\n  ✓ general-purpose  Completed\n{FOOTER}"
    ));
    assert_eq!(parse_claude_screen(&s).subagents, None);
}

#[test]
fn permission_prompt_wins() {
    let sep = "─".repeat(60);
    let dash = "╌".repeat(60);
    let s = l(&format!(
        "  ○ general-purpose  Running …\n{sep}\n Bash command\n Make a file\n{dash}\n touch x\n{dash}\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Esc to cancel · Tab to amend"
    ));
    let st = parse_claude_screen(&s);
    assert!(st.permission.is_some());
    assert_eq!(st.subagents, None);
}

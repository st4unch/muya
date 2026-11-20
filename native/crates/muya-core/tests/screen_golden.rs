//! PRD AC3: the Rust screen parser's JSON equals the TypeScript parser's on every captured
//! screen. Regenerate the golden file with `node native/tools/screen-golden.mjs`.

use muya_core::screen::{parse_busy, parse_claude_screen};

#[test]
fn rust_parser_matches_typescript_on_every_captured_screen() {
    let golden: serde_json::Value = serde_json::from_str(include_str!("screen-golden.json")).unwrap();
    let cases = golden.as_array().unwrap();
    assert!(!cases.is_empty());
    let mut failures = Vec::new();
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let lines: Vec<String> = case["lines"].as_array().unwrap().iter().map(|l| l.as_str().unwrap().to_owned()).collect();
        let got = serde_json::to_value(parse_claude_screen(&lines)).unwrap();
        if got != case["state"] {
            failures.push(format!("{name}:\n  ts:   {}\n  rust: {got}", case["state"]));
        }
        if parse_busy(&lines) != case["busy"].as_bool().unwrap() {
            failures.push(format!("{name}: parseBusy differs"));
        }
    }
    assert!(failures.is_empty(), "{} of {} screens differ:\n{}", failures.len(), cases.len(), failures.join("\n"));
}

//! What the user actually sees on a Claude Code screen: mode, activity (spinner), permission
//! dialog, busy footer. A line-for-line port of `src/lib/screenState.ts` (PRD AC3); the JSON form
//! is identical to the TypeScript output and `tests/screen_golden.rs` holds them equal on every
//! captured screen. Pure and conservative: unknown or ambiguous layouts yield `None`.

use regex::Regex;
use serde::Serialize;
use std::sync::LazyLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum ScreenMode {
    #[serde(rename = "bypass")]
    Bypass,
    #[serde(rename = "acceptEdits")]
    AcceptEdits,
    #[serde(rename = "plan")]
    Plan,
    #[serde(rename = "auto")]
    Auto,
    #[serde(rename = "default")]
    Default,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ScreenActivity {
    pub verb: String,
    pub glyph: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub elapsed: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tokens: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thought: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum PermissionKind {
    #[serde(rename = "approve")]
    Approve,
    #[serde(rename = "approveAlways")]
    ApproveAlways,
    #[serde(rename = "deny")]
    Deny,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PermissionOption {
    pub key: String,
    pub label: String,
    pub kind: PermissionKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ScreenPermission {
    pub tool: String,
    pub target: String,
    pub question: String,
    pub options: Vec<PermissionOption>,
}

/// Field order matches the TypeScript object spread: activity, busy, mode, modeDetected,
/// permission.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenState {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub activity: Option<ScreenActivity>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub busy: Option<bool>,
    pub mode: ScreenMode,
    /// true only when a mode footer was actually seen (dialogs hide the footer).
    pub mode_detected: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub permission: Option<ScreenPermission>,
}

const FOOTER_WINDOW: usize = 5;

fn re(p: &str) -> Regex {
    Regex::new(p).expect("valid regex")
}

static ACTIVITY_RE: LazyLock<Regex> =
    LazyLock::new(|| re(r"^\s*([·✢✳✶✻✽*])\s+(\p{Lu}[\p{L}-]*…)\s*(?:\((.*)\))?\s*$"));
static MODE_RE: LazyLock<Regex> = LazyLock::new(|| {
    re(r"^\s*(?:⏵⏵|⏸)\s+(bypass permissions|accept edits|plan mode|auto mode|manual mode) on\b")
});
static QUESTION_RE: LazyLock<Regex> = LazyLock::new(|| re(r"^\s*(Do you want to .+\?)\s*$"));
static OPTION_RE: LazyLock<Regex> = LazyLock::new(|| re(r"^\s*(?:❯\s*)?(\d{1,2})\.\s+(\S.*?)\s*$"));
static SEPARATOR_RE: LazyLock<Regex> = LazyLock::new(|| re(r"^\s*[─╌]{10,}\s*$"));
static SOLID_SEPARATOR_RE: LazyLock<Regex> = LazyLock::new(|| re(r"^\s*─{10,}\s*$"));
static ELAPSED_RE: LazyLock<Regex> = LazyLock::new(|| re(r"^(?:\d+h\s+)?(?:\d+m\s+)?\d+s$"));
static TOKENS_RE: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)^[↑↓]\s*([\d.,]+k?)\s*tokens?$"));
static THOUGHT_RE: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)^thought for (.+)$"));
static THINKING_RE: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)^thinking$"));
static WRAPPED_RE: LazyLock<Regex> = LazyLock::new(|| re(r"^\s{4,}\S"));
static FOOTER_MARK_RE: LazyLock<Regex> =
    LazyLock::new(|| re(r"^\s*(?:⏸|⏵⏵|⏵)\s|\bmode on\b|\bpermissions on\b"));
static ESC_INTERRUPT_RE: LazyLock<Regex> = LazyLock::new(|| re(r"\besc to interrupt\b"));

/// JavaScript's `String.prototype.trim` (Unicode White_Space), which `str::trim` matches.
fn js_trim(s: &str) -> &str {
    s.trim()
}

fn tail_non_empty(lines: &[String], n: usize) -> Vec<&str> {
    lines
        .iter()
        .rev()
        .map(String::as_str)
        .filter(|l| !js_trim(l).is_empty())
        .take(n)
        .collect()
}

fn parse_mode(lines: &[String]) -> Option<ScreenMode> {
    for l in tail_non_empty(lines, FOOTER_WINDOW) {
        if let Some(m) = MODE_RE.captures(l) {
            return Some(match &m[1] {
                "bypass permissions" => ScreenMode::Bypass,
                "accept edits" => ScreenMode::AcceptEdits,
                "plan mode" => ScreenMode::Plan,
                "auto mode" => ScreenMode::Auto,
                _ => ScreenMode::Default,
            });
        }
    }
    None
}

fn parse_activity(lines: &[String]) -> Option<ScreenActivity> {
    let footer_busy = tail_non_empty(lines, FOOTER_WINDOW)
        .iter()
        .any(|l| l.contains("esc to interrupt"));
    for line in lines.iter().rev() {
        let Some(m) = ACTIVITY_RE.captures(line) else {
            continue;
        };
        let mut act = ScreenActivity {
            verb: m[2].to_owned(),
            glyph: m[1].to_owned(),
            elapsed: None,
            tokens: None,
            thought: None,
            thinking: None,
        };
        let mut has_metric = false;
        if let Some(meta) = m.get(3).map(|x| x.as_str()).filter(|s| !s.is_empty()) {
            for seg in meta.split(" · ").map(js_trim) {
                if ELAPSED_RE.is_match(seg) {
                    act.elapsed = Some(seg.to_owned());
                    has_metric = true;
                } else if let Some(t) = TOKENS_RE.captures(seg) {
                    act.tokens = Some(t[1].to_owned());
                    has_metric = true;
                } else if let Some(t) = THOUGHT_RE.captures(seg) {
                    act.thought = Some(t[1].to_owned());
                    has_metric = true;
                } else if THINKING_RE.is_match(seg) {
                    act.thinking = Some(true);
                    has_metric = true;
                }
            }
        }
        // Guard against bullet-list prose: need a busy footer or spinner metrics.
        if !footer_busy && !has_metric {
            continue;
        }
        return Some(act);
    }
    None
}

fn classify(label: &str) -> Option<PermissionKind> {
    static NO: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)^No\b"));
    static YES: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)^Yes\b"));
    static YES_AND: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)^Yes,\s+and\b"));
    static ALWAYS: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)don't ask again|for this session"));
    if NO.is_match(label) {
        return Some(PermissionKind::Deny);
    }
    if YES.is_match(label) {
        if YES_AND.is_match(label) || ALWAYS.is_match(label) {
            return Some(PermissionKind::ApproveAlways);
        }
        return Some(PermissionKind::Approve);
    }
    None
}

fn tool_from_title(title: &str) -> String {
    match title.to_lowercase().as_str() {
        "bash command" => "Bash".into(),
        "create file" => "Write".into(),
        "edit file" | "update file" => "Edit".into(),
        "read file" => "Read".into(),
        _ => title.to_owned(),
    }
}

fn parse_permission(lines: &[String]) -> Option<ScreenPermission> {
    static TIP: LazyLock<Regex> = LazyLock::new(|| re(r"^Tip:"));
    for q in (0..lines.len()).rev() {
        let Some(qm) = QUESTION_RE.captures(&lines[q]) else {
            continue;
        };
        // Options directly under the question; wrapped labels continue on indented lines.
        let mut options: Vec<PermissionOption> = Vec::new();
        let mut saw_esc = false;
        let mut i = q + 1;
        while i < lines.len() {
            let l = &lines[i];
            if js_trim(l).is_empty() {
                break;
            }
            if l.contains("Esc to cancel") {
                saw_esc = true;
                break;
            }
            if let Some(om) = OPTION_RE.captures(l) {
                let kind = classify(&om[2])?;
                options.push(PermissionOption {
                    key: om[1].to_owned(),
                    label: om[2].to_owned(),
                    kind,
                });
            } else if !options.is_empty() && WRAPPED_RE.is_match(l) {
                let last = options.last_mut().unwrap();
                last.label.push(' ');
                last.label.push_str(js_trim(l));
            } else {
                return None;
            }
            i += 1;
        }
        if !saw_esc {
            // Allow the footer one blank line below the options.
            let next = lines
                .iter()
                .skip(i)
                .take(3)
                .any(|l| l.contains("Esc to cancel"));
            if !next {
                continue;
            }
        }
        if options.len() < 2 {
            continue;
        }
        if options[0].key != "1" || options[0].kind != PermissionKind::Approve {
            continue;
        }
        if options.last().unwrap().kind != PermissionKind::Deny {
            continue;
        }
        if !options
            .iter()
            .enumerate()
            .all(|(idx, o)| o.key == (idx + 1).to_string())
        {
            continue;
        }
        // Find the dialog's top separator, then read title + target below it.
        let sep = (0..q)
            .rev()
            .find(|&j| SEPARATOR_RE.is_match(&lines[j]) && SOLID_SEPARATOR_RE.is_match(&lines[j]));
        let (mut tool, mut target) = (String::new(), String::new());
        if let Some(sep) = sep {
            let body: Vec<&str> = lines[sep + 1..q].iter().map(|l| js_trim(l)).collect();
            let title = body.iter().copied().find(|l| !l.is_empty()).unwrap_or("");
            tool = tool_from_title(title);
            let start = body
                .iter()
                .position(|l| *l == title)
                .map(|p| p + 1)
                .unwrap_or(0);
            target = body[start..]
                .iter()
                .copied()
                .find(|l| !l.is_empty() && !TIP.is_match(l) && !SEPARATOR_RE.is_match(l))
                .unwrap_or("")
                .to_owned();
        }
        return Some(ScreenPermission {
            tool,
            target,
            question: qm[1].to_owned(),
            options,
        });
    }
    None
}

/// True only when Claude's own footer line — one of the last few lines, carrying the mode
/// indicator — says "esc to interrupt"; the same words elsewhere (a quoted answer) do not count.
pub fn parse_busy(lines: &[String]) -> bool {
    let tail: Vec<&str> = lines
        .iter()
        .map(|l| l.trim_end())
        .filter(|l| !l.is_empty())
        .collect();
    tail[tail.len().saturating_sub(4)..]
        .iter()
        .any(|l| FOOTER_MARK_RE.is_match(l) && ESC_INTERRUPT_RE.is_match(l))
}

pub fn parse_claude_screen(lines: &[String]) -> ScreenState {
    let detected = parse_mode(lines);
    let permission = parse_permission(lines);
    let activity = if permission.is_some() {
        None
    } else {
        parse_activity(lines)
    };
    let busy = permission.is_none() && parse_busy(lines);
    ScreenState {
        activity,
        busy: busy.then_some(true),
        mode: detected.unwrap_or(ScreenMode::Default),
        mode_detected: detected.is_some(),
        permission,
    }
}

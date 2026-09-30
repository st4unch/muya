// Created by Claude — Classification: INTERNAL
//
// Slash commands that live on disk (custom commands + skills) for the composer's
// "/ Commands" popover. Built-in commands are captured statically on the frontend;
// this module only reads what the user/project added. Read-only and bounded:
// max MAX_ENTRIES results, max MAX_FILE_BYTES read per file, missing dirs -> empty,
// symlinks are never followed out of the scanned directory.

use serde::Serialize;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

const MAX_ENTRIES: usize = 500;
const MAX_FILE_BYTES: u64 = 64 * 1024;
const MAX_DEPTH: usize = 6;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct SlashCommand {
    pub name: String,
    pub description: String,
    /// "project" | "user" | "skill"
    pub source: String,
}

/// Read at most MAX_FILE_BYTES of a regular file (never a symlink) as lossy UTF-8.
fn read_capped(path: &Path) -> Option<String> {
    let meta = fs::symlink_metadata(path).ok()?;
    if !meta.is_file() {
        return None;
    }
    let f = fs::File::open(path).ok()?;
    let mut buf = Vec::new();
    f.take(MAX_FILE_BYTES).read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

fn unquote(v: &str) -> String {
    let v = v.trim();
    let b = v.as_bytes();
    if b.len() >= 2
        && ((b[0] == b'"' && b[b.len() - 1] == b'"') || (b[0] == b'\'' && b[b.len() - 1] == b'\''))
    {
        v[1..v.len() - 1].to_string()
    } else {
        v.to_string()
    }
}

/// Parse the leading `---` YAML frontmatter block into (name, description) and
/// return the remaining body. Only flat `key: value` scalars (plus `>`/`|` block
/// scalars and indented continuation lines) are understood — enough for these two keys.
fn parse_frontmatter(text: &str) -> (Option<String>, Option<String>, &str) {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut lines = text.split_inclusive('\n');
    match lines.next() {
        Some(first) if first.trim_end() == "---" => {}
        _ => return (None, None, text),
    }
    let mut consumed = text.split_inclusive('\n').next().map(str::len).unwrap_or(0);
    let mut name = None;
    let mut desc = None;
    let mut cur: Option<&'static str> = None;
    let mut cur_val = String::new();
    let mut folded = false;
    let mut closed = false;

    fn flush(
        cur: &mut Option<&'static str>,
        val: &mut String,
        name: &mut Option<String>,
        desc: &mut Option<String>,
    ) {
        if let Some(k) = cur.take() {
            let v = val.trim().to_string();
            if !v.is_empty() {
                if k == "name" {
                    *name = Some(v);
                } else {
                    *desc = Some(v);
                }
            }
        }
        val.clear();
    }

    for line in lines {
        consumed += line.len();
        let l = line.trim_end_matches(['\r', '\n']);
        if l.trim_end() == "---" {
            closed = true;
            break;
        }
        let indented = l.starts_with(' ') || l.starts_with('\t');
        if indented && cur.is_some() {
            if !cur_val.is_empty() && folded {
                cur_val.push(' ');
            } else if !cur_val.is_empty() {
                cur_val.push('\n');
            }
            cur_val.push_str(l.trim());
            continue;
        }
        flush(&mut cur, &mut cur_val, &mut name, &mut desc);
        if let Some((k, v)) = l.split_once(':') {
            let k = k.trim();
            let key: Option<&'static str> = match k {
                "name" => Some("name"),
                "description" => Some("description"),
                _ => None,
            };
            if let Some(key) = key {
                cur = Some(key);
                let v = v.trim();
                if matches!(v, ">" | ">-" | ">+" | "|" | "|-" | "|+") {
                    folded = v.starts_with('>');
                } else {
                    folded = true;
                    cur_val = unquote(v);
                }
            }
        }
    }
    flush(&mut cur, &mut cur_val, &mut name, &mut desc);
    if !closed {
        // Unterminated frontmatter: treat the whole thing as body, no metadata.
        return (None, None, text);
    }
    (name, desc, &text[consumed.min(text.len())..])
}

fn first_line(body: &str) -> String {
    body.lines()
        .map(|l| l.trim().trim_start_matches('#').trim())
        .find(|l| !l.is_empty())
        .unwrap_or("")
        .to_string()
}

/// Single-line, trimmed description (the UI truncates; keep the payload small).
fn tidy(s: &str) -> String {
    let one: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    one.chars().take(300).collect()
}

/// Collect `*.md` files under `root` (recursively up to MAX_DEPTH when `recursive`).
/// Name = relative path without `.md`, path components joined with `sep`.
/// Symlinks whose target escapes `root` are skipped.
fn scan_commands(
    root: &Path,
    source: &str,
    sep: &str,
    recursive: bool,
    out: &mut Vec<SlashCommand>,
) {
    let Ok(canon_root) = fs::canonicalize(root) else {
        return;
    };
    let mut stack: Vec<(PathBuf, Vec<String>, usize)> = vec![(canon_root.clone(), vec![], 0)];
    while let Some((dir, prefix, depth)) = stack.pop() {
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        let mut entries: Vec<_> = rd.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        let mut subdirs = Vec::new();
        for e in entries {
            if out.len() >= MAX_ENTRIES {
                return;
            }
            let path = e.path();
            let fname = e.file_name().to_string_lossy().into_owned();
            if fname.starts_with('.') {
                continue;
            }
            // Resolve links and require the target to stay inside the scanned root.
            let Ok(real) = fs::canonicalize(&path) else {
                continue;
            };
            if !real.starts_with(&canon_root) {
                continue;
            }
            let Ok(meta) = fs::metadata(&real) else {
                continue;
            };
            if meta.is_dir() {
                if recursive && depth < MAX_DEPTH {
                    let mut p = prefix.clone();
                    p.push(fname);
                    subdirs.push((real, p, depth + 1));
                }
            } else if meta.is_file() && fname.ends_with(".md") && fname.len() > 3 {
                let Some(text) = read_capped(&real) else {
                    continue;
                };
                let (_, desc, body) = parse_frontmatter(&text);
                let mut parts = prefix.clone();
                parts.push(fname[..fname.len() - 3].to_string());
                out.push(SlashCommand {
                    name: parts.join(sep),
                    description: tidy(&desc.unwrap_or_else(|| first_line(body))),
                    source: source.to_string(),
                });
            }
        }
        // Keep alphabetical order overall: push in reverse so pop() yields ascending.
        subdirs.reverse();
        stack.extend(subdirs);
    }
}

/// `<root>/*/SKILL.md`. A top-level skill directory may itself be a symlink (users
/// link skills in from other tools); SKILL.md must be a regular file inside it.
fn scan_skills(root: &Path, out: &mut Vec<SlashCommand>) {
    let Ok(rd) = fs::read_dir(root) else { return };
    let mut entries: Vec<_> = rd.flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        if out.len() >= MAX_ENTRIES {
            return;
        }
        let dirname = e.file_name().to_string_lossy().into_owned();
        if dirname.starts_with('.') {
            continue;
        }
        let dir = e.path();
        if !fs::metadata(&dir).map(|m| m.is_dir()).unwrap_or(false) {
            continue;
        }
        let Some(text) = read_capped(&dir.join("SKILL.md")) else {
            continue;
        };
        let (name, desc, body) = parse_frontmatter(&text);
        let name = name
            .filter(|n| !n.contains(char::is_whitespace) && !n.contains('/'))
            .unwrap_or(dirname);
        out.push(SlashCommand {
            name,
            description: tidy(&desc.unwrap_or_else(|| first_line(body))),
            source: "skill".to_string(),
        });
    }
}

fn dedupe_and_cap(mut v: Vec<SlashCommand>) -> Vec<SlashCommand> {
    // Same name from a higher-priority source (earlier in the vec) wins.
    let mut seen = std::collections::HashSet::new();
    v.retain(|c| seen.insert(c.name.clone()));
    v.truncate(MAX_ENTRIES);
    v
}

pub(crate) fn scan(agent: &str, cwd: Option<&Path>, home: Option<&Path>) -> Vec<SlashCommand> {
    let mut out = Vec::new();
    match agent {
        "claude" => {
            if let Some(c) = cwd {
                scan_commands(&c.join(".claude/commands"), "project", ":", true, &mut out);
            }
            if let Some(h) = home {
                scan_commands(&h.join(".claude/commands"), "user", ":", true, &mut out);
                scan_skills(&h.join(".claude/skills"), &mut out);
            }
        }
        "opencode" => {
            // opencode reads both the singular (`command`) and plural (`commands`) dir;
            // nested files become `dir/name`.
            for d in ["commands", "command"] {
                if let Some(c) = cwd {
                    scan_commands(&c.join(".opencode").join(d), "project", "/", true, &mut out);
                }
            }
            if let Some(h) = home {
                for d in ["commands", "command"] {
                    scan_commands(
                        &h.join(".config/opencode").join(d),
                        "user",
                        "/",
                        true,
                        &mut out,
                    );
                }
            }
        }
        _ => {}
    }
    dedupe_and_cap(out)
}

/// Custom slash commands + skills on disk for `agent` ("claude" | "opencode").
/// Never fails: unreadable/missing locations simply contribute nothing.
#[tauri::command(async)]
pub fn list_slash_commands(agent: String, cwd: Option<String>) -> Vec<SlashCommand> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let cwd = cwd.filter(|c| !c.is_empty()).map(PathBuf::from);
    scan(&agent, cwd.as_deref(), home.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(p: &Path, s: &str) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, s).unwrap();
    }

    #[test]
    fn frontmatter_plain_quoted_and_block() {
        let (n, d, body) =
            parse_frontmatter("---\nname: foo\ndescription: \"Does a thing\"\n---\nbody line\n");
        assert_eq!(n.as_deref(), Some("foo"));
        assert_eq!(d.as_deref(), Some("Does a thing"));
        assert_eq!(body, "body line\n");
        let (_, d, _) =
            parse_frontmatter("---\ndescription: >\n  first part\n  second part\nother: x\n---\nb");
        assert_eq!(d.as_deref(), Some("first part second part"));
        let (n, d, b) = parse_frontmatter("no frontmatter\nhere");
        assert!(n.is_none() && d.is_none());
        assert_eq!(b, "no frontmatter\nhere");
    }

    #[test]
    fn falls_back_to_first_non_empty_line() {
        let t = tempfile::tempdir().unwrap();
        write(
            &t.path().join("p/.claude/commands/plain.md"),
            "\n\n# Heading text\nmore\n",
        );
        let v = scan("claude", Some(&t.path().join("p")), None);
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].name, "plain");
        assert_eq!(v[0].description, "Heading text");
        assert_eq!(v[0].source, "project");
    }

    #[test]
    fn claude_nesting_uses_colon_and_opencode_slash() {
        let t = tempfile::tempdir().unwrap();
        write(
            &t.path().join(".claude/commands/grp/sub/tool.md"),
            "---\ndescription: d\n---\n",
        );
        write(
            &t.path().join(".opencode/command/grp/tool.md"),
            "---\ndescription: o\n---\n",
        );
        write(&t.path().join(".opencode/commands/top.md"), "x");
        let c = scan("claude", Some(t.path()), None);
        assert_eq!(c[0].name, "grp:sub:tool");
        let o = scan("opencode", Some(t.path()), None);
        let names: Vec<_> = o.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"grp/tool") && names.contains(&"top"));
    }

    #[test]
    fn skills_and_user_commands_from_home() {
        let t = tempfile::tempdir().unwrap();
        write(&t.path().join(".claude/commands/mine.md"), "hello");
        write(
            &t.path().join(".claude/skills/alpha/SKILL.md"),
            "---\nname: alpha-skill\ndescription: Alpha\n---\n",
        );
        write(
            &t.path().join(".claude/skills/beta/SKILL.md"),
            "Just text\n",
        );
        write(
            &t.path().join(".claude/skills/empty/README.md"),
            "no skill file",
        );
        let v = scan("claude", None, Some(t.path()));
        let got: Vec<_> = v
            .iter()
            .map(|c| (c.name.as_str(), c.source.as_str()))
            .collect();
        assert_eq!(
            got,
            vec![
                ("mine", "user"),
                ("alpha-skill", "skill"),
                ("beta", "skill")
            ]
        );
        assert_eq!(v[2].description, "Just text");
    }

    #[test]
    fn missing_dirs_and_unknown_agent_are_empty() {
        let t = tempfile::tempdir().unwrap();
        assert!(scan(
            "claude",
            Some(&t.path().join("nope")),
            Some(&t.path().join("nohome"))
        )
        .is_empty());
        assert!(scan("zsh", Some(t.path()), Some(t.path())).is_empty());
    }

    #[test]
    fn caps_entries_and_file_size() {
        let t = tempfile::tempdir().unwrap();
        for i in 0..520 {
            write(&t.path().join(format!(".claude/commands/c{i:04}.md")), "d");
        }
        assert_eq!(scan("claude", Some(t.path()), None).len(), MAX_ENTRIES);

        let big = tempfile::tempdir().unwrap();
        let mut s = String::from("---\ndescription: ok\n---\n");
        s.push_str(&"x".repeat(200_000));
        write(&big.path().join(".claude/commands/big.md"), &s);
        assert_eq!(scan("claude", Some(big.path()), None)[0].description, "ok");
        // Direct check that the read itself is bounded.
        let text = read_capped(&big.path().join(".claude/commands/big.md")).unwrap();
        assert!(text.len() as u64 <= MAX_FILE_BYTES);
    }

    #[cfg(unix)]
    #[test]
    fn symlink_escaping_the_root_is_ignored() {
        use std::os::unix::fs::symlink;
        let t = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        write(
            &outside.path().join("secret.md"),
            "---\ndescription: leak\n---\n",
        );
        write(&outside.path().join("dir/inner.md"), "leak");
        let cmds = t.path().join(".claude/commands");
        fs::create_dir_all(&cmds).unwrap();
        write(&cmds.join("ok.md"), "fine");
        symlink(outside.path().join("secret.md"), cmds.join("link.md")).unwrap();
        symlink(outside.path().join("dir"), cmds.join("linkdir")).unwrap();
        // A link that stays inside the root is fine.
        symlink(cmds.join("ok.md"), cmds.join("alias.md")).unwrap();
        let names: Vec<_> = scan("claude", Some(t.path()), None)
            .into_iter()
            .map(|c| c.name)
            .collect();
        assert_eq!(names, vec!["alias", "ok"]);
    }

    #[cfg(unix)]
    #[test]
    fn linked_skill_dir_is_read_but_symlinked_skill_file_is_not() {
        use std::os::unix::fs::symlink;
        let t = tempfile::tempdir().unwrap();
        let ext = tempfile::tempdir().unwrap();
        write(
            &ext.path().join("linked/SKILL.md"),
            "---\ndescription: L\n---\n",
        );
        write(&ext.path().join("f.md"), "secret");
        fs::create_dir_all(t.path().join(".claude/skills/evil")).unwrap();
        symlink(
            ext.path().join("f.md"),
            t.path().join(".claude/skills/evil/SKILL.md"),
        )
        .unwrap();
        symlink(
            ext.path().join("linked"),
            t.path().join(".claude/skills/linked"),
        )
        .unwrap();
        let v = scan("claude", None, Some(t.path()));
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].name, "linked");
    }

    #[test]
    fn project_wins_over_user_on_duplicate_names() {
        let t = tempfile::tempdir().unwrap();
        write(&t.path().join("p/.claude/commands/x.md"), "proj");
        write(&t.path().join("h/.claude/commands/x.md"), "user");
        let v = scan(
            "claude",
            Some(&t.path().join("p")),
            Some(&t.path().join("h")),
        );
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].source, "project");
    }
}

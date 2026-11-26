//! Secret placeholders: agents USE passwords without ever SEEING them.
//!
//! `get_secret` returns `{{muya-secret:<name>}}`. The agent puts that token into
//! `ssh_send` / `ssh_run` / `ssh_session_exec` / `send_terminal` text, and the daemon swaps
//! in the real value at injection time only. Real values are redacted from anything that
//! flows back (command output, transcripts).
//!
//! Exfil guard: a placeholder is typed ONLY into a terminal that is at a password prompt
//! (echo off) naming a host that is a configured server entry (`pty_state::secret_gate`), or into
//! the session of a server whose own credential it names. Never into a shell line, a command line
//! (`ssh_run` refuses placeholders) or an unverified caller's request. Agents may add, edit, rename
//! and group every secret; they still never see a value.

use zeroize::Zeroizing;

const OPEN: &str = "{{muya-secret:";
const CLOSE: &str = "}}";

/// What `get_secret` tells the agent about the placeholder (NAME is replaced by the secret's name). The text is
/// the answer to "I have the placeholder, now what": it is NOT the value, and a shell/curl line cannot use it.
pub const USAGE_HINT: &str = "This is a placeholder, NOT the secret. Your own tools (Bash, Write, a shell line or curl you run yourself) never substitute it: the literal text lands in the file or request (a key file written that way is garbage, `curl -H \"Authorization: Bearer {{muya-secret:NAME}}\"` fails with 401). Use one of these, where Muya swaps in the real value out of your sight and redacts it from the result:\n1. REST/HTTP call: tool `http_request` {method, url, headers: {\"Authorization\": \"Bearer {{muya-secret:NAME}}\"}, body}. Easiest.\n2. Any program: tool `run_with_secrets` {command: [\"sh\",\"-c\",\"curl -sS -H \\\"Authorization: Bearer $API_KEY\\\" https://host/path\"], cwd: \"/abs/dir\", env: {\"API_KEY\": \"{{muya-secret:NAME}}\"}}. The placeholder goes in env or stdin, never in command (arguments are visible to ps). Or feed a header from stdin: command [\"sh\",\"-c\",\"curl -sS -H @- https://host/path\"], stdin: \"Authorization: Bearer {{muya-secret:NAME}}\".\n   To write a key file you must not read: the same tool with command [\"sh\",\"-c\",\"umask 177; printf %s \\\"$KEY\\\" > \\\"$HOME/.config/tool/key\\\"\"] and env {\"KEY\": \"{{muya-secret:NAME}}\"}.\n3. From a session terminal: muyactl secret exec --env API_KEY=NAME -- sh -c 'curl -sS -H \"Authorization: Bearer $API_KEY\" https://host/path'.\n4. SSH password prompts: ssh_send / ssh_session_exec text (typed only at a password prompt of a configured server).";

pub fn placeholder(name: &str) -> String {
    format!("{OPEN}{name}{CLOSE}")
}

/// `{{muya-secret:x}}` or plain `x` -> `x`.
pub fn unwrap_name(s: &str) -> &str {
    let t = s.trim();
    t.strip_prefix(OPEN)
        .and_then(|r| r.strip_suffix(CLOSE))
        .map(str::trim)
        .unwrap_or(t)
}

/// Names of every placeholder in `text`, in order.
pub fn names_in(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(i) = rest.find(OPEN) {
        let after = &rest[i + OPEN.len()..];
        match after.find(CLOSE) {
            Some(j) => {
                out.push(after[..j].trim().to_string());
                rest = &after[j + CLOSE.len()..];
            }
            None => break,
        }
    }
    out
}

/// Replaces each placeholder with `resolve(name)`. The first failure aborts.
pub fn substitute(
    text: &str,
    resolve: &mut dyn FnMut(&str) -> Result<Zeroizing<String>, String>,
) -> Result<Zeroizing<String>, String> {
    let mut out = Zeroizing::new(String::with_capacity(text.len()));
    let mut rest = text;
    while let Some(i) = rest.find(OPEN) {
        let after = &rest[i + OPEN.len()..];
        let Some(j) = after.find(CLOSE) else { break };
        out.push_str(&rest[..i]);
        let value = resolve(after[..j].trim())?;
        out.push_str(&value);
        rest = &after[j + CLOSE.len()..];
    }
    out.push_str(rest);
    Ok(out)
}

/// Replaces every occurrence of a known secret value with its placeholder, in the raw form and in
/// the encodings a command can print it in: JSON-escaped, base64 (standard and URL-safe, whole
/// or its stable prefix, as `echo v | base64` leaves it), hex. Values shorter than 6 chars are
/// skipped (too many false positives).
pub fn redact(text: &str, secrets: &[(String, Zeroizing<String>)]) -> String {
    let mut out = text.to_string();
    for (name, value) in secrets {
        if value.len() < 6 {
            continue;
        }
        let ph = placeholder(name);
        for form in variants(value) {
            if !form.is_empty() && out.contains(form.as_str()) {
                out = out.replace(form.as_str(), &ph);
            }
        }
    }
    out
}

/// Redacts every string inside a JSON value (raw strings, before serialization escapes them).
pub fn redact_value(v: &mut serde_json::Value, secrets: &[(String, Zeroizing<String>)]) {
    match v {
        serde_json::Value::String(s) => *s = redact(s, secrets),
        serde_json::Value::Array(a) => a.iter_mut().for_each(|x| redact_value(x, secrets)),
        serde_json::Value::Object(o) => o.values_mut().for_each(|x| redact_value(x, secrets)),
        _ => {}
    }
}

/// Raw value first, then its encodings, longest first within each family.
fn variants(value: &str) -> Vec<String> {
    let mut v = vec![value.to_string()];
    if let Ok(j) = serde_json::to_string(value) {
        let inner = j[1..j.len() - 1].to_string();
        if inner != value {
            v.push(inner);
        }
    }
    let bytes = value.as_bytes();
    // `base64` of "value\n" shares the encoding of the first len/3*3 bytes with "value".
    let stable = &bytes[..bytes.len() / 3 * 3];
    for url in [false, true] {
        v.push(b64(bytes, url));
        v.push(b64(bytes, url).trim_end_matches('=').to_string());
        if stable.len() >= 6 {
            v.push(b64(stable, url));
        }
    }
    let enc = url_encode(value);
    if enc != value {
        v.push(enc);
    }
    v.push(hex(bytes, false));
    v.push(hex(bytes, true));
    v.dedup();
    v
}

fn b64(data: &[u8], url: bool) -> String {
    let abc: &[u8; 64] = if url {
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    } else {
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    };
    let mut out = String::new();
    for c in data.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= c.len() {
                out.push(abc[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Percent-encoding of every byte outside the unreserved set (RFC 3986).
fn url_encode(s: &str) -> String {
    let mut o = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            o.push(b as char);
        } else {
            o.push_str(&format!("%{b:02X}"));
        }
    }
    o
}

fn hex(data: &[u8], upper: bool) -> String {
    data.iter()
        .map(|b| {
            if upper {
                format!("{b:02X}")
            } else {
                format!("{b:02x}")
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_and_substitute() {
        assert_eq!(
            names_in("a {{muya-secret:db}} b {{muya-secret: x }}"),
            vec!["db", "x"]
        );
        let mut r = |n: &str| Ok(Zeroizing::new(format!("<{n}>")));
        let s = substitute("pw={{muya-secret:db}}!", &mut r).unwrap();
        assert_eq!(s.as_str(), "pw=<db>!");
        let mut bad = |_: &str| Err("no".to_string());
        assert!(substitute("{{muya-secret:z}}", &mut bad).is_err());
        assert_eq!(
            substitute("plain {{muya-secret:open", &mut r)
                .unwrap()
                .as_str(),
            "plain {{muya-secret:open"
        );
    }

    #[test]
    fn unwrap_accepts_both_forms() {
        assert_eq!(unwrap_name("{{muya-secret:prod}}"), "prod");
        assert_eq!(unwrap_name(" prod "), "prod");
    }

    #[test]
    fn redaction_replaces_values() {
        let s = vec![("db".to_string(), Zeroizing::new("hunter22".to_string()))];
        assert_eq!(
            redact("login hunter22 ok", &s),
            "login {{muya-secret:db}} ok"
        );
        let short = vec![("p".to_string(), Zeroizing::new("ab".to_string()))];
        assert_eq!(redact("abab", &short), "abab");
    }

    #[test]
    fn redaction_catches_encodings_and_escapes() {
        let pw = "p\"ss\\w0rd!x";
        let s = vec![("db".to_string(), Zeroizing::new(pw.to_string()))];
        let ph = "{{muya-secret:db}}";
        assert_eq!(redact(&format!("a {pw} b"), &s), format!("a {ph} b"));
        let json_form = serde_json::to_string(pw).unwrap();
        let json_form = &json_form[1..json_form.len() - 1];
        assert_eq!(redact(&format!("x{json_form}y"), &s), format!("x{ph}y"));
        let b = b64(pw.as_bytes(), false);
        assert_eq!(redact(&format!("out:{b}"), &s), format!("out:{ph}"));
        // `echo pw | base64` appends the newline: the stable prefix is still caught
        let nl = b64(format!("{pw}\n").as_bytes(), false);
        assert!(!redact(&nl, &s).contains(&b[..8]));
        assert_eq!(redact(&hex(pw.as_bytes(), false), &s), ph);
        assert_eq!(redact(&hex(pw.as_bytes(), true), &s), ph);
        assert_eq!(b64(b"Man", false), "TWFu");
        assert_eq!(b64(b"Ma", false), "TWE=");
    }

    #[test]
    fn redaction_catches_url_encoding() {
        let s = vec![("db".to_string(), Zeroizing::new("p@ss w0rd/x".to_string()))];
        assert_eq!(redact("q=p%40ss%20w0rd%2Fx", &s), "q={{muya-secret:db}}");
    }

    #[test]
    fn redact_value_works_on_raw_strings_before_serialization() {
        let pw = "pa\"ss\\word9";
        let s = vec![("db".to_string(), Zeroizing::new(pw.to_string()))];
        let mut v = serde_json::json!({"ok": true, "stdout": format!("pw={pw}"), "results": [{"stdout": pw}]});
        redact_value(&mut v, &s);
        let out = v.to_string();
        assert!(!out.contains("word9"), "{out}");
        assert_eq!(v["stdout"], "pw={{muya-secret:db}}");
        assert_eq!(v["results"][0]["stdout"], "{{muya-secret:db}}");
    }
}

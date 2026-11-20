//! `muyactl [--socket <muyad.sock>] status|sessions|doctor` and `muyactl secret exec --env VAR=name -- <cmd...>` — read-only (PRD §5): release builds
//! have no attach/dump, and muyad refuses anything but `List` from this role.

use muya_proto::{Control, Decoder, Frame, Role};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

fn request(sock: &PathBuf, c: Control) -> Result<(String, Control), String> {
    let mut s = UnixStream::connect(sock).map_err(|e| format!("cannot reach muyad at {}: {e}", sock.display()))?;
    s.set_read_timeout(Some(Duration::from_secs(5))).ok();
    s.write_all(&Frame::Control(muya_proto::hello(Role::Muyactl, env!("CARGO_PKG_VERSION"))).encode()).map_err(|e| e.to_string())?;
    s.write_all(&Frame::Control(c).encode()).map_err(|e| e.to_string())?;
    let mut dec = Decoder::default();
    let mut buf = [0u8; 65536];
    let mut replies = Vec::new();
    while replies.len() < 2 {
        let n = s.read(&mut buf).map_err(|e| format!("muyad did not answer: {e}"))?;
        if n == 0 {
            break;
        }
        dec.push(&buf[..n]);
        while let Ok(Some(Frame::Control(c))) = dec.next_frame() {
            replies.push(c);
        }
    }
    match replies.as_slice() {
        [Control::Welcome { server_build, .. }, reply] => Ok((server_build.clone(), reply.clone())),
        [Control::Error { message, .. }, ..] => Err(format!("refused: {message}")),
        other => Err(format!("unexpected reply: {other:?}")),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let sock = args
        .iter()
        .position(|a| a == "--socket")
        .and_then(|i| args.get(i + 1))
        .map(PathBuf::from)
        .unwrap_or_else(|| muya_peer::socket_dir().map(|d| d.join("muyad.sock")).unwrap_or_default());
    // Positional arguments: everything except `--socket <path>`.
    let mut positional = Vec::new();
    let mut it = args.iter().skip(1);
    while let Some(a) = it.next() {
        if a == "--socket" {
            it.next();
        } else {
            positional.push(a.as_str());
        }
    }
    let cmd = positional.first().copied().unwrap_or("status");
    let code = match cmd {
        "status" => match request(&sock, Control::List) {
            Ok((build, Control::Sessions { sessions })) => {
                let live = sessions.iter().filter(|s| s.exited.is_none()).count();
                println!("muyad {build}: {} sessions ({live} running)", sessions.len());
                0
            }
            Ok((_, other)) => {
                eprintln!("muyactl: unexpected reply {other:?}");
                1
            }
            Err(e) => {
                eprintln!("muyactl: {e}");
                1
            }
        },
        "sessions" => match request(&sock, Control::List) {
            Ok((_, Control::Sessions { sessions })) => {
                println!("{:>4} {:>7} {:>9} {:>12}  STATE", "ID", "PID", "SIZE", "OUTPUT");
                for s in sessions {
                    let state = s.exited.map(|c| format!("exited {c}")).unwrap_or_else(|| "running".into());
                    println!("{:>4} {:>7} {:>9} {:>12}  {state}", s.id, s.pid, format!("{}x{}", s.cols, s.rows), s.end_seq);
                }
                0
            }
            Ok((_, other)) => {
                eprintln!("muyactl: unexpected reply {other:?}");
                1
            }
            Err(e) => {
                eprintln!("muyactl: {e}");
                1
            }
        },
        "doctor" => doctor(&sock),
        "secret" => secret_exec(&positional[1..]),
        other => {
            eprintln!("usage: muyactl [--socket <path>] status|sessions|doctor (unknown: {other})");
            2
        }
    };
    std::process::exit(code);
}

/// `muyactl secret exec --env VAR=name [--env ...] [--cwd DIR] [--timeout SECS] -- <cmd...>`: runs the
/// command through the daemon's broker (`run_with_secrets`) with the secrets in its environment only.
/// The daemon verifies this process runs under a Muya Claude session, redacts every secret value from
/// the output and audit-logs the run (command + secret names). A placeholder in the command is refused.
fn secret_exec(args: &[&str]) -> i32 {
    use std::collections::BTreeMap;
    if args.first() != Some(&"exec") {
        eprintln!("usage: muyactl secret exec --env VAR=name [--cwd DIR] [--timeout SECS] -- <command...>");
        return 2;
    }
    let mut env = BTreeMap::new();
    let mut cwd = std::env::current_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    let mut timeout: Option<u64> = None;
    let mut command: Vec<String> = Vec::new();
    let mut it = args[1..].iter();
    while let Some(a) = it.next() {
        match *a {
            "--" => {
                command = it.by_ref().map(|s| s.to_string()).collect();
            }
            "--env" => {
                let Some((var, name)) = it.next().and_then(|kv| kv.split_once('=')) else {
                    eprintln!("muyactl: --env needs VAR=secret-name");
                    return 2;
                };
                let name = name.trim().trim_start_matches("{{muya-secret:").trim_end_matches("}}").trim();
                env.insert(var.to_string(), format!("{{{{muya-secret:{name}}}}}"));
            }
            "--cwd" => cwd = it.next().map(|s| s.to_string()).unwrap_or(cwd),
            "--timeout" => timeout = it.next().and_then(|s| s.parse().ok()),
            other => {
                eprintln!("muyactl: unexpected argument '{other}' (put the command after --)");
                return 2;
            }
        }
    }
    if command.is_empty() {
        eprintln!("muyactl: no command given (after --)");
        return 2;
    }
    let sock = match std::env::var("MUYA_SSH_BROKER_SOCK") {
        Ok(p) if !p.is_empty() => PathBuf::from(p),
        _ => match std::env::var("HOME") {
            Ok(h) => PathBuf::from(h).join(".claude").join("muya-ssh-broker.sock"),
            Err(_) => {
                eprintln!("muyactl: HOME is not set");
                return 1;
            }
        },
    };
    let mut req = serde_json::json!({ "op": "run_with_secrets", "argv": command, "cwd": cwd, "env": env });
    if let Some(t) = timeout {
        req["timeoutSecs"] = t.into();
    }
    let mut s = match UnixStream::connect(&sock) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("muyactl: cannot reach Muya's broker at {}: {e}", sock.display());
            return 1;
        }
    };
    s.set_read_timeout(Some(Duration::from_secs(timeout.unwrap_or(120).clamp(1, 3600) + 15))).ok();
    if s.write_all(format!("{req}\n").as_bytes()).is_err() {
        eprintln!("muyactl: could not send the request");
        return 1;
    }
    let mut line = String::new();
    if std::io::BufRead::read_line(&mut std::io::BufReader::new(&s), &mut line).is_err() || line.is_empty() {
        eprintln!("muyactl: the broker did not answer");
        return 1;
    }
    let v: serde_json::Value = serde_json::from_str(line.trim()).unwrap_or_default();
    if v["ok"] != true {
        eprintln!("muyactl: {}", v["error"].as_str().unwrap_or("request failed"));
        return 1;
    }
    print!("{}", v["stdout"].as_str().unwrap_or(""));
    eprint!("{}", v["stderr"].as_str().unwrap_or(""));
    if v["timedOut"] == true {
        eprintln!("muyactl: timed out");
        return 124;
    }
    v["exitCode"].as_i64().unwrap_or(1) as i32
}

/// Checks that need no privileges: socket dir ownership and mode, muyad reachable, signing.
fn doctor(sock: &PathBuf) -> i32 {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let mut failures = 0;
    let mut check = |name: &str, ok: bool, detail: String| {
        println!("{} {name}: {detail}", if ok { "ok  " } else { "FAIL" });
        if !ok {
            failures += 1;
        }
    };
    let dir = sock.parent().map(PathBuf::from).unwrap_or_default();
    match std::fs::metadata(&dir) {
        Ok(m) => check("socket dir", m.permissions().mode() & 0o077 == 0 && m.uid() == unsafe_uid(), format!("{} mode {:o}", dir.display(), m.permissions().mode() & 0o777)),
        Err(e) => check("socket dir", false, e.to_string()),
    }
    check("socket path length", sock.as_os_str().len() <= 103, format!("{} bytes (limit 103)", sock.as_os_str().len()));
    match request(sock, Control::List) {
        Ok((build, Control::Sessions { sessions })) => check("muyad", true, format!("build {build}, {} sessions", sessions.len())),
        Ok((_, other)) => check("muyad", false, format!("{other:?}")),
        Err(e) => check("muyad", false, e),
    }
    check("signing", true, match muya_peer::own_team() {
        Some(_) => "signed with a Team ID".into(),
        None => "unsigned development build".into(),
    });
    if failures == 0 { 0 } else { 1 }
}

fn unsafe_uid() -> u32 {
    // getuid never fails.
    unsafe extern "C" {
        fn getuid() -> u32;
    }
    unsafe { getuid() }
}

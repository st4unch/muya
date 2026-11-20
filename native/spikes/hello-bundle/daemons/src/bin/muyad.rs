//! Stub `muyad`: accepts only `Muya.app` on its client socket (and refuses peers inside ptyd's
//! PTY sessions), talks to ptyd as the one identifier ptyd accepts.
//!
//! Requests: `hello` (own hello plus ptyd's), `probe <socket>` (asks ptyd to connect to
//! `<socket>` from inside a PTY session; both sockets must refuse it).
//! `muyad --probe <socket>` is the probe itself.

use hello_daemons::*;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Some(code) = probe_main(&args) {
        std::process::exit(code);
    }
    let started = Instant::now();
    let listener = match listen("muyad") {
        Ok(l) => l,
        Err(e) => {
            log("muyad", &format!("cannot listen: {e}"));
            std::process::exit(1);
        }
    };
    log(
        "muyad",
        &format!(
            "listening after {} us, team={:?}",
            started.elapsed().as_micros(),
            own_team()
        ),
    );
    for stream in listener.incoming().flatten() {
        std::thread::spawn(move || handle(stream));
    }
}

/// Session ids ptyd owns; refusing everything if ptyd cannot be asked keeps the gate closed.
fn ptyd_sessions() -> Result<Vec<i32>, String> {
    let reply = request("ptyd", "sessions").map_err(|e| format!("ptyd unreachable: {e}"))?;
    let list = reply
        .strip_prefix('[')
        .and_then(|r| r.strip_suffix(']'))
        .ok_or(format!("ptyd said: {reply}"))?;
    Ok(list
        .split(',')
        .filter_map(|s| s.trim().parse().ok())
        .collect())
}

fn handle(mut stream: UnixStream) {
    let checked = ptyd_sessions().and_then(|sids| verify_peer(&stream, APP_ID, Some(&sids)));
    let peer = match checked {
        Ok(p) => p,
        Err(why) => {
            log("muyad", &format!("refused: {why}"));
            let _ = writeln!(stream, "refused: {why}");
            return;
        }
    };
    // One kept-open connection to ptyd per client connection, like the real keystroke path.
    let mut ptyd: Option<Conn> = None;
    serve_lines(&mut stream, |line| {
        match line.split_once(' ').unwrap_or((line, "")) {
            ("relay-ping", _) => {
                if ptyd.is_none() {
                    ptyd = Conn::open("ptyd").ok();
                }
                match ptyd.as_mut().map(|c| c.call("ping")) {
                    Some(Ok(r)) => r,
                    Some(Err(e)) => {
                        ptyd = None;
                        format!("error: {e}")
                    }
                    None => "error: ptyd unreachable".to_owned(),
                }
            }
            ("bench", n) => bench(n.parse().unwrap_or(1000)),
            ("hello", _) => {
                let t = Instant::now();
                let ptyd = request("ptyd", "hello").unwrap_or_else(|e| format!(r#""error: {e}""#));
                format!(
                    r#"{{"who":"muyad","version":"{VERSION}","pid":{},"peer_pid":{},"peer_check_us":{},"peak_rss_kb":{},"ptyd_roundtrip_us":{},"ptyd":{ptyd}}}"#,
                    std::process::id(),
                    peer.pid,
                    peer.check_us,
                    peak_rss_kb(),
                    t.elapsed().as_micros()
                )
            }
            ("probe", target) => request("ptyd", &format!("probe {target}"))
                .unwrap_or_else(|e| format!("error: {e}")),
            ("envprobe", _) => {
                request("ptyd", "envprobe").unwrap_or_else(|e| format!("error: {e}"))
            }
            _ => "error: unknown request".to_owned(),
        }
    });
}

/// `n` pings to ptyd over one connection; returns the round-trip distribution in us.
fn bench(n: usize) -> String {
    let mut conn = match Conn::open("ptyd") {
        Ok(c) => c,
        Err(e) => return format!("error: {e}"),
    };
    let mut us: Vec<u128> = Vec::with_capacity(n);
    for _ in 0..n {
        let t = Instant::now();
        if !matches!(conn.call("ping").as_deref(), Ok("pong")) {
            return "error: ping failed".to_owned();
        }
        us.push(t.elapsed().as_nanos());
    }
    us.sort_unstable();
    let q = |p: f64| us[((us.len() as f64 * p) as usize).min(us.len() - 1)] as f64 / 1000.0;
    format!(
        "n={n} us p50={:.1} p95={:.1} p99={:.1} max={:.1}",
        q(0.5),
        q(0.95),
        q(0.99),
        q(1.0)
    )
}

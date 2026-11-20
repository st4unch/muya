//! PRD AC22 (decision D8): muyad is the single schedule owner. Everything runs against a temp
//! HOME with a FAKE `claude` (HOME/.local/bin/claude) — the real CLI is never reachable: PATH is
//! `/usr/bin:/bin` and SHELL is a stub shell that knows no `claude`.
//!
//! The sidecar test needs `cd src-tauri && cargo build --bin muya-ssh-mcp` (skips otherwise).

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct Env {
    dir: PathBuf,
    home: PathBuf,
    work: PathBuf,
    children: Vec<Child>,
}

impl Drop for Env {
    fn drop(&mut self) {
        for c in self.children.iter_mut().rev() {
            let _ = c.kill();
            let _ = c.wait();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

fn script(path: &Path, body: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn wait_for(what: &str, timeout: Duration, mut ok: impl FnMut() -> bool) {
    let deadline = Instant::now() + timeout;
    while !ok() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn setup(tag: &str) -> Env {
    let dir = PathBuf::from(format!("/tmp/muya-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    let work = dir.join("work");
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    std::fs::create_dir_all(&work).unwrap();
    // Fake claude: answers the capability probe, otherwise logs one line per run in its cwd.
    script(
        &home.join(".local/bin/claude"),
        "#!/bin/sh\nif [ \"$1\" = agents ]; then echo '[]'; exit 0; fi\necho fired >> \"$PWD/fired.log\"\necho '{\"result\":\"ok\",\"is_error\":false,\"total_cost_usd\":0}'\n",
    );
    // Stub login shell: `-l [-i] -c CMD`; knows no claude, otherwise just runs CMD.
    script(
        &dir.join("fakeshell"),
        "#!/bin/sh\nwhile [ \"$1\" != -c ]; do shift; done\nshift\ncase \"$1\" in \"command -v\"*) exit 1;; esac\nexec /bin/sh -c \"$1\"\n",
    );
    let ptyd = Command::new(Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name("muya-ptyd"))
        .env("MUYA_PTYD_EXIT_WITH_PARENT", "1")
        .arg("--socket")
        .arg(dir.join("p.sock"))
        .spawn()
        .expect("cargo build --workspace first");
    let mut env = Env {
        dir,
        home,
        work,
        children: vec![ptyd],
    };
    let p = env.dir.join("p.sock");
    wait_for("ptyd socket", Duration::from_secs(10), || p.exists());
    env.children.truncate(1);
    env
}

/// Starts muyad (HOME = the temp home). `sock` names its own socket file; stderr goes to `<sock>.err`.
fn muyad(env: &mut Env, sock: &str, extra: &[&str]) -> usize {
    let err = std::fs::File::create(env.dir.join(format!("{sock}.err"))).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_muyad"))
        .env_clear()
        .env("HOME", &env.home)
        .env("PATH", "/usr/bin:/bin")
        .env("SHELL", env.dir.join("fakeshell"))
        .env("MUYA_SCHEDULE_TICK_MS", "200")
        .env("MUYA_SSH_BROKER_SOCK", env.dir.join("b.sock"))
        .arg("--socket")
        .arg(env.dir.join(sock))
        .arg("--ptyd")
        .arg(env.dir.join("p.sock"))
        .args(extra)
        .stderr(err)
        .spawn()
        .unwrap();
    env.children.push(child);
    let s = env.dir.join(sock);
    wait_for("muyad socket", Duration::from_secs(10), || s.exists());
    env.children.len() - 1
}

fn stderr_of(env: &Env, sock: &str) -> String {
    std::fs::read_to_string(env.dir.join(format!("{sock}.err"))).unwrap_or_default()
}

fn fired(env: &Env) -> usize {
    std::fs::read_to_string(env.work.join("fired.log"))
        .map(|s| s.lines().count())
        .unwrap_or(0)
}

fn runs(env: &Env, id: &str) -> Vec<serde_json::Value> {
    std::fs::read_to_string(
        env.home
            .join(format!(".claude/muya-schedule-runs/{id}.jsonl")),
    )
    .map(|s| {
        s.lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    })
    .unwrap_or_default()
}

#[test]
fn due_schedule_fires_once_survives_kill9_and_a_second_owner_is_refused() {
    let mut env = setup("ac22a");
    let now = now_ms();
    // A job that is due in ~2 s. The marker is how a restarted muyad learns the slot it waits for
    // (the interval floor is 5 minutes, so a real slot 2 s out cannot be created otherwise).
    std::fs::write(
        env.home.join(".claude/muya-schedules.json"),
        serde_json::json!({ "version": 1, "jobs": [{
            "id": "sac22", "name": "ac22", "prompt": "p", "folder": env.work, "schedule": { "kind": "interval", "minutes": 5 },
            "enabled": true, "timeoutMin": 1, "bypass": true, "chrome": false, "created": now, "updated": 7 }] })
        .to_string(),
    )
    .unwrap();
    std::fs::write(
        env.home.join(".claude/muya-schedules.fired.json"),
        serde_json::json!({ "jobs": { "sac22": { "lastFire": 0, "nextDue": now + 2000, "updated": 7 } } }).to_string(),
    )
    .unwrap();

    let first = muyad(&mut env, "m1.sock", &["--scheduler"]);
    wait_for("the 2 s slot to fire", Duration::from_secs(20), || {
        fired(&env) >= 1
    });
    std::thread::sleep(Duration::from_secs(3));
    assert_eq!(fired(&env), 1, "exactly one fire");
    wait_for("run history", Duration::from_secs(10), || {
        !runs(&env, "sac22").is_empty()
    });
    let r = runs(&env, "sac22");
    assert_eq!(
        (r.len(), r[0]["status"].as_str(), r[0]["trigger"].as_str()),
        (1, Some("success"), Some("schedule"))
    );
    assert!(
        stderr_of(&env, "m1.sock").contains("owning the schedule timers"),
        "{}",
        stderr_of(&env, "m1.sock")
    );

    // A second `--scheduler` muyad refuses to own while the first lives.
    muyad(&mut env, "m2.sock", &["--scheduler"]);
    assert!(
        stderr_of(&env, "m2.sock").contains("scheduler refused"),
        "{}",
        stderr_of(&env, "m2.sock")
    );
    std::thread::sleep(Duration::from_secs(1));
    assert_eq!(fired(&env), 1);

    // kill -9 the owner (and the refuser, so the restart takes the lock), restart: no second fire.
    let m2 = env.children.pop().unwrap();
    let mut m2 = m2;
    let _ = m2.kill();
    let _ = m2.wait();
    env.children[first].kill().unwrap(); // Child::kill is SIGKILL
    let _ = env.children[first].wait();
    muyad(&mut env, "m3.sock", &["--scheduler"]);
    wait_for("restart takes ownership", Duration::from_secs(10), || {
        stderr_of(&env, "m3.sock").contains("owning the schedule timers")
    });
    std::thread::sleep(Duration::from_secs(4));
    assert_eq!(fired(&env), 1, "a restart must not fire the slot again");
    assert_eq!(runs(&env, "sac22").len(), 1);
    let marker: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(env.home.join(".claude/muya-schedules.fired.json")).unwrap(),
    )
    .unwrap();
    assert!(
        marker["jobs"]["sac22"]["lastFire"].as_i64().unwrap() > now,
        "{marker}"
    );
    assert!(
        marker["jobs"]["sac22"]["nextDue"].as_i64().unwrap() > now + 60_000,
        "next slot moved on: {marker}"
    );
}

fn sidecar() -> Option<PathBuf> {
    let p =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../src-tauri/target/debug/muya-ssh-mcp");
    p.exists().then_some(p)
}

/// One sidecar session: sends each request line, returns the parsed `result` object of each call.
fn mcp(bin: &Path, sock: &Path, calls: &[(&str, serde_json::Value)]) -> Vec<serde_json::Value> {
    let mut child = Command::new(bin)
        .env("MUYA_SSH_BROKER_SOCK", sock)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());
    let mut results = Vec::new();
    for (i, (name, args)) in calls.iter().enumerate() {
        let req = serde_json::json!({ "jsonrpc": "2.0", "id": i + 1, "method": "tools/call", "params": { "name": name, "arguments": args } });
        writeln!(stdin, "{req}").unwrap();
        let mut line = String::new();
        out.read_line(&mut line).unwrap();
        let v: serde_json::Value =
            serde_json::from_str(&line).unwrap_or_else(|_| panic!("bad reply: {line}"));
        results.push(v["result"].clone());
    }
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();
    results
}

fn payload(r: &serde_json::Value) -> serde_json::Value {
    assert!(r["isError"].as_bool() != Some(true), "tool error: {r}");
    serde_json::from_str(r["content"][0]["text"].as_str().unwrap()).unwrap()
}

#[test]
fn schedule_tools_work_through_the_real_sidecar() {
    let Some(bin) = sidecar() else {
        eprintln!("SKIPPED: cd src-tauri && cargo build --bin muya-ssh-mcp");
        return;
    };
    let mut env = setup("ac22b");
    muyad(&mut env, "m.sock", &["--scheduler", "--broker"]);
    let sock = env.dir.join("b.sock");
    wait_for("broker socket", Duration::from_secs(10), || sock.exists());
    let folder = env.work.to_str().unwrap().to_string();

    let created = payload(
        &mcp(
            &bin,
            &sock,
            &[(
                "schedule_create",
                serde_json::json!({ "name": "Nightly", "prompt": "do it", "folder": folder, "schedule": { "kind": "daily", "time": "03:30" }, "chrome": false }),
            )],
        )[0],
    );
    let id = created["id"].as_str().unwrap().to_string();

    let list = payload(&mcp(&bin, &sock, &[("schedules_list", serde_json::json!({}))])[0]);
    assert_eq!(list["runner"], "here", "{list}");
    assert_eq!(list["timersActive"], true);
    assert_eq!(list["jobs"][0]["name"], "Nightly");
    assert!(list["jobs"][0]["nextRun"].as_i64().is_some(), "{list}");

    let upd = payload(
        &mcp(
            &bin,
            &sock,
            &[(
                "schedule_update",
                serde_json::json!({ "schedule_ref": "nightly", "timeoutMin": 5 }),
            )],
        )[0],
    );
    assert_eq!(upd["timeoutMin"], 5);

    let off = payload(
        &mcp(
            &bin,
            &sock,
            &[(
                "schedule_set_enabled",
                serde_json::json!({ "schedule_ref": id, "enabled": false }),
            )],
        )[0],
    );
    assert_eq!(off["enabled"], false);

    // Run now works while disabled; the fake claude logs one line; history shows the success.
    let started = payload(
        &mcp(
            &bin,
            &sock,
            &[(
                "schedule_run_now",
                serde_json::json!({ "schedule_ref": "Nightly" }),
            )],
        )[0],
    );
    assert_eq!(started["started"], id.as_str());
    wait_for("manual run", Duration::from_secs(20), || fired(&env) == 1);
    wait_for("history entry", Duration::from_secs(10), || {
        !runs(&env, &id).is_empty()
    });
    let hist = payload(
        &mcp(
            &bin,
            &sock,
            &[(
                "schedule_history",
                serde_json::json!({ "schedule_ref": id }),
            )],
        )[0],
    );
    assert_eq!(hist["totalRuns"], 1, "{hist}");
    assert_eq!(hist["runs"][0]["status"], "success");
    assert_eq!(hist["runs"][0]["trigger"], "manual");
    assert_eq!(hist["runs"][0]["output"], "ok");

    let del = payload(
        &mcp(
            &bin,
            &sock,
            &[("schedule_delete", serde_json::json!({ "schedule_ref": id }))],
        )[0],
    );
    assert_eq!(del["deleted"], id.as_str());
    let list = payload(&mcp(&bin, &sock, &[("schedules_list", serde_json::json!({}))])[0]);
    assert!(list["jobs"].as_array().unwrap().is_empty(), "{list}");
    assert_eq!(fired(&env), 1);
}

#[test]
fn a_broker_only_muyad_edits_the_store_and_run_now_goes_through_the_owner() {
    let Some(bin) = sidecar() else { return };
    let mut env = setup("ac22c");
    muyad(&mut env, "own.sock", &["--scheduler"]);
    // Second muyad: broker only (store client). Its run_now leaves a request the owner picks up.
    muyad(&mut env, "cli.sock", &["--broker"]);
    let sock = env.dir.join("b.sock");
    wait_for("broker socket", Duration::from_secs(10), || sock.exists());
    let folder = env.work.to_str().unwrap().to_string();
    let created = payload(
        &mcp(
            &bin,
            &sock,
            &[(
                "schedule_create",
                serde_json::json!({ "name": "viaclient", "prompt": "x", "folder": folder, "schedule": { "kind": "interval", "minutes": 60 }, "chrome": false }),
            )],
        )[0],
    );
    let id = created["id"].as_str().unwrap().to_string();
    let list = payload(&mcp(&bin, &sock, &[("schedules_list", serde_json::json!({}))])[0]);
    assert_eq!(
        list["timersActive"], false,
        "the client does not own the timers: {list}"
    );
    payload(
        &mcp(
            &bin,
            &sock,
            &[(
                "schedule_run_now",
                serde_json::json!({ "schedule_ref": id }),
            )],
        )[0],
    );
    wait_for(
        "the owner runs the request",
        Duration::from_secs(20),
        || fired(&env) == 1,
    );
    std::thread::sleep(Duration::from_secs(2));
    assert_eq!(fired(&env), 1);
}

#[test]
fn muyad_as_scheduler_owner_writes_the_service_heartbeat() {
    let mut env = setup("ac22d");
    let idx = muyad(&mut env, "own.sock", &["--scheduler"]);
    let pid = env.children[idx].id();
    let hb_path = env.home.join(".claude/muya-scheduler.heartbeat.json");
    let read = || -> Option<serde_json::Value> {
        serde_json::from_str(&std::fs::read_to_string(&hb_path).ok()?).ok()
    };
    wait_for("heartbeat file", Duration::from_secs(10), || read().is_some());
    let first = read().unwrap();
    assert_eq!(first["pid"], pid, "the heartbeat names muyad: {first}");
    assert!(first["version"].as_str().is_some_and(|v| !v.is_empty()), "{first}");
    // It keeps beating (tick = 200 ms here), and the window's freshness check accepts it.
    let t0 = first["ts"].as_i64().unwrap();
    wait_for("heartbeat advances", Duration::from_secs(10), || {
        read().is_some_and(|h| h["ts"].as_i64().unwrap() > t0)
    });
    let paths = muya_core::schedules::Paths::under(&env.home.join(".claude"));
    let hb = muya_core::schedules::heartbeat_at(&paths, now_ms())
        .expect("fresh heartbeat as the window reads it");
    assert_eq!(hb.pid, pid);
    // The owner does not yield to its own heartbeat: it keeps the timers.
    assert!(
        stderr_of(&env, "own.sock").is_empty()
            || !stderr_of(&env, "own.sock").contains("background service runs the timers"),
        "{}",
        stderr_of(&env, "own.sock")
    );
}

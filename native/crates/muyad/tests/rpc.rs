//! Protocol minor 2 (`Control::Rpc`): sessions history / search / export, schedules and preferences
//! against a real muyad in a temp HOME with synthetic transcripts and a fake `claude`.

use muya_proto::{Control, Decoder, Frame, Role};
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant};

struct Env {
    dir: PathBuf,
    home: PathBuf,
    kids: Vec<Child>,
}

impl Drop for Env {
    fn drop(&mut self) {
        for k in self.kids.iter_mut().rev() {
            let _ = k.kill();
            let _ = k.wait();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn wait_for(what: &str, mut ok: impl FnMut() -> bool) {
    let end = Instant::now() + Duration::from_secs(15);
    while !ok() {
        assert!(Instant::now() < end, "timed out: {what}");
        std::thread::sleep(Duration::from_millis(30));
    }
}

fn start(tag: &str) -> Env {
    start_with_idle(tag, "900")
}

/// `idle`: seconds until the password store locks itself (classic: 15 minutes).
fn start_with_idle(tag: &str, idle: &str) -> Env {
    let dir = PathBuf::from(format!("/tmp/muya-rpc-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    let proj = home.join(".claude/projects/-work-alpha");
    std::fs::create_dir_all(&proj).unwrap();
    std::fs::create_dir_all(dir.join("work")).unwrap();
    std::fs::write(
        proj.join("s-one.jsonl"),
        concat!(
            r#"{"type":"user","cwd":"/work/alpha","message":{"role":"user","content":"please refactor the zebra parser"}}"#, "\n",
            r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"zebra parser refactored"}]}}"#, "\n",
            r#"{"type":"custom-title","customTitle":"Zebra work"}"#, "\n",
        ),
    )
    .unwrap();
    std::fs::write(
        proj.join("s-two.jsonl"),
        concat!(r#"{"type":"user","cwd":"/work/alpha","message":{"role":"user","content":"nothing special here"}}"#, "\n"),
    )
    .unwrap();
    let fake = home.join(".local/bin/claude");
    std::fs::create_dir_all(fake.parent().unwrap()).unwrap();
    std::fs::write(&fake, "#!/bin/sh\nif [ \"$1\" = agents ]; then echo '[]'; exit 0; fi\necho '{\"result\":\"ok\",\"is_error\":false,\"total_cost_usd\":0}'\n").unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let ptyd = Command::new(Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name("muya-ptyd"))
        .env("MUYA_PTYD_EXIT_WITH_PARENT", "1")
        .arg("--socket")
        .arg(dir.join("p.sock"))
        .spawn()
        .expect("cargo build --workspace first");
    let mut env = Env { dir, home, kids: vec![ptyd] };
    let p = env.dir.join("p.sock");
    wait_for("ptyd", || p.exists());
    let muyad = Command::new(env!("CARGO_BIN_EXE_muyad"))
        .env_clear()
        .env("HOME", &env.home)
        .env("PATH", "/usr/bin:/bin")
        .env("MUYA_VAULT_IDLE_SECS", idle)
        .env("MUYA_SSH_BROKER_SOCK", env.dir.join("b.sock"))
        .arg("--socket")
        .arg(env.dir.join("m.sock"))
        .arg("--ptyd")
        .arg(&p)
        .arg("--scheduler")
        .spawn()
        .unwrap();
    env.kids.push(muyad);
    let m = env.dir.join("m.sock");
    wait_for("muyad", || m.exists());
    env
}

struct App {
    s: UnixStream,
    dec: Decoder,
    next: u64,
}

impl App {
    fn connect(sock: &Path) -> Self {
        let s = connect_retry(sock);
        s.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
        let mut a = Self { s, dec: Decoder::default(), next: 1 };
        a.send(Control::Hello { major: 1, minor: 2, role: Role::App, build: "rpc-test".into() });
        assert!(matches!(a.read_control(), Control::Welcome { minor: muya_proto::PROTO_MINOR, .. }));
        a
    }
    fn send(&mut self, c: Control) {
        self.s.write_all(&Frame::Control(c).encode()).unwrap();
    }
    fn read_control(&mut self) -> Control {
        loop {
            if let Some(Frame::Control(c)) = self.dec.next_frame().unwrap() {
                return c;
            }
            let mut buf = [0u8; 65536];
            let n = self.s.read(&mut buf).unwrap();
            assert!(n > 0, "muyad closed");
            self.dec.push(&buf[..n]);
        }
    }
    /// One call; Ok(result) or Err(message).
    fn rpc(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let req = self.next;
        self.next += 1;
        self.send(Control::Rpc { req, method: method.into(), params: params.to_string() });
        loop {
            if let Control::RpcReply { req: r, ok, result } = self.read_control() {
                assert_eq!(r, req);
                return if ok { Ok(serde_json::from_str(&result).unwrap()) } else { Err(result) };
            }
        }
    }
}

#[test]
fn sessions_history_search_export_work_over_rpc() {
    let env = start("hist");
    let mut app = App::connect(&env.dir.join("m.sock"));

    let hist = app.rpc("sessions.history", json!({})).unwrap();
    let hist = hist.as_array().unwrap();
    assert_eq!(hist.len(), 2, "{hist:?}");
    let one = hist.iter().find(|e| e["sessionId"] == "s-one").unwrap();
    assert_eq!(one["name"], "Zebra work");
    assert_eq!(one["cwd"], "/work/alpha");

    let refs: Vec<Value> = hist.iter().map(|e| json!({ "id": e["sessionId"], "cwd": e["cwd"], "path": e["path"] })).collect();
    let found = app.rpc("sessions.search", json!({ "query": "ZEBRA", "sessions": refs })).unwrap();
    let found = found.as_array().unwrap();
    assert_eq!(found.len(), 1);
    assert_eq!(found[0]["sessionId"], "s-one");
    assert_eq!(found[0]["matchCount"], 2);
    assert!(app.rpc("sessions.search", json!({ "query": "z", "sessions": refs })).unwrap().as_array().unwrap().is_empty(), "one character searches nothing");

    let dest = env.dir.join("out.md");
    app.rpc("sessions.export", json!({ "sessionId": "s-one", "cwd": "/work/alpha", "path": one["path"], "dest": dest })).unwrap();
    let md = std::fs::read_to_string(&dest).unwrap();
    assert!(md.starts_with("# Session `s-one`") && md.contains("## 👤 User") && md.contains("zebra parser refactored"), "{md}");
    // Never over the transcript itself, never a path outside ~/.claude/projects.
    assert!(app.rpc("sessions.export", json!({ "sessionId": "s-one", "cwd": "/work/alpha", "path": one["path"], "dest": one["path"] })).is_err());
    assert!(app.rpc("sessions.export", json!({ "sessionId": "x", "cwd": "/", "path": "/etc/hosts", "dest": env.dir.join("n.md") })).is_err());
    assert!(app.rpc("nope", json!({})).unwrap_err().contains("unknown method"));
}

#[test]
fn a_cancelled_search_stops_and_still_replies() {
    let env = start("cancel");
    let proj = env.home.join(".claude/projects/-big");
    std::fs::create_dir_all(&proj).unwrap();
    let line = format!("{{\"type\":\"user\",\"message\":{{\"role\":\"user\",\"content\":\"{}\"}}}}\n", "filler words ".repeat(40));
    let mut refs = Vec::new();
    for i in 0..60 {
        let p = proj.join(format!("b{i}.jsonl"));
        std::fs::write(&p, line.repeat(20_000)).unwrap(); // ~11 MB each
        refs.push(json!({ "id": format!("b{i}"), "cwd": "/big", "path": p }));
    }
    let mut app = App::connect(&env.dir.join("m.sock"));
    let t = Instant::now();
    app.send(Control::Rpc { req: 77, method: "sessions.search".into(), params: json!({ "query": "needle-not-present", "sessions": refs }).to_string() });
    std::thread::sleep(Duration::from_millis(150));
    app.send(Control::RpcCancel { req: 77 });
    let (mut ok_seen, mut reply) = (false, None);
    while !(ok_seen && reply.is_some()) {
        match app.read_control() {
            Control::Ok => ok_seen = true,
            Control::RpcReply { req: 77, ok, .. } => reply = Some(ok),
            other => panic!("{other:?}"),
        }
    }
    assert_eq!(reply, Some(true));
    assert!(t.elapsed() < Duration::from_secs(5), "cancel took {:?}", t.elapsed());
}

#[test]
fn schedules_and_prefs_work_over_rpc() {
    let env = start("sched");
    let mut app = App::connect(&env.dir.join("m.sock"));
    let work = env.dir.join("work");
    let job = |name: &str| {
        json!({ "name": name, "prompt": "say hi", "folder": work, "schedule": { "kind": "daily", "time": "09:30" },
                "enabled": true, "timeoutMin": 5, "bypass": true, "chrome": false })
    };
    // Validation messages are the ones the Tauri page shows.
    assert_eq!(app.rpc("schedules.save", json!({ "job": job("  ") })).unwrap_err(), "Give the schedule a name.");
    let mut bad = job("n");
    bad["schedule"] = json!({ "kind": "interval", "minutes": 1 });
    assert_eq!(app.rpc("schedules.save", json!({ "job": bad })).unwrap_err(), "Run at most every 5 minutes.");
    let mut bad = job("n");
    bad["folder"] = json!("/definitely/not/here");
    assert_eq!(app.rpc("schedules.validate", json!({ "job": bad })).unwrap_err(), "That folder doesn't exist.");

    let saved = app.rpc("schedules.save", json!({ "job": job("Nightly") })).unwrap();
    let id = saved["id"].as_str().unwrap().to_string();
    let list = app.rpc("schedules.list", json!({})).unwrap();
    assert_eq!(list["runner"], "service", "muyad --scheduler owns the timers: {list}");
    assert_eq!(list["jobs"].as_array().unwrap().len(), 1);
    assert_eq!(list["jobs"][0]["name"], "Nightly");
    assert!(list["jobs"][0]["nextRun"].is_i64());

    app.rpc("schedules.set_enabled", json!({ "id": id, "enabled": false })).unwrap();
    assert_eq!(app.rpc("schedules.list", json!({})).unwrap()["jobs"][0]["enabled"], false);

    app.rpc("schedules.run_now", json!({ "id": id })).unwrap();
    let mut runs = Value::Null;
    wait_for("the run to be recorded", || {
        runs = app.rpc("schedules.runs", json!({ "id": id })).unwrap();
        !runs.as_array().unwrap().is_empty()
    });
    assert_eq!(runs[0]["trigger"], "manual");
    assert_eq!(runs[0]["status"], "success");

    app.rpc("schedules.delete", json!({ "id": id })).unwrap();
    assert!(app.rpc("schedules.list", json!({})).unwrap()["jobs"].as_array().unwrap().is_empty());

    let p = app.rpc("prefs.get", json!({})).unwrap();
    assert_eq!(p["keepRunningInBackground"], true);
    let p = app.rpc("prefs.set", json!({ "keepRunningInBackground": false, "claudeCleanupDays": 60 })).unwrap();
    assert_eq!((&p["keepRunningInBackground"], &p["claudeCleanupDays"]), (&json!(false), &json!(60)));
    let d = app.rpc("debug_log.set", json!({ "enabled": true, "path": env.dir.join("dbg.log") })).unwrap();
    assert_eq!(d["enabled"], true);
    assert_eq!(app.rpc("debug_log.get", json!({})).unwrap()["path"], json!(env.dir.join("dbg.log")));
    app.rpc("debug_log.set", json!({ "enabled": false, "path": "" })).unwrap();
    let on_disk: Value = serde_json::from_str(&std::fs::read_to_string(env.home.join(".claude/muya-app.json")).unwrap()).unwrap();
    assert_eq!(on_disk["keepRunningInBackground"], false);
    let settings: Value = serde_json::from_str(&std::fs::read_to_string(env.home.join(".claude/settings.json")).unwrap()).unwrap();
    assert_eq!(settings["cleanupPeriodDays"], 60);
}

fn git(dir: &Path, args: &[&str]) {
    let st = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "-C"])
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .output()
        .unwrap();
    assert!(st.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&st.stderr));
}

#[test]
fn migrate_agents_transcript_ssh_vault_and_queue_work_over_rpc() {
    let env = start("misc");
    let mut app = App::connect(&env.dir.join("m.sock"));

    // migrate.run: nothing to migrate in a fresh HOME, then idempotent.
    assert_eq!(app.rpc("migrate.run", json!({})).unwrap()["outcome"], "nothing_to_migrate");
    assert_eq!(app.rpc("migrate.run", json!({})).unwrap()["outcome"], "already_done");

    // agents.list goes through the capability-resolved claude (the fake answers `[]`).
    assert!(app.rpc("agents.list", json!({})).unwrap().as_array().unwrap().is_empty());
    assert!(app.rpc("agents.list", json!({ "all": true })).unwrap().as_array().unwrap().is_empty());

    // sessions.transcript: bounded, no path tricks.
    let t = app.rpc("sessions.transcript", json!({ "sessionId": "s-one", "cwd": "/work/alpha", "limit": 1 })).unwrap();
    assert!(t["text"].as_str().unwrap().contains("zebra parser refactored"), "{t}");
    assert!(!t["text"].as_str().unwrap().contains("please refactor"), "limit 1 keeps only the last turn: {t}");
    assert_eq!(t["truncated"], false);
    assert!(app.rpc("sessions.transcript", json!({ "sessionId": "../s-one", "cwd": "/work/alpha" })).is_err());
    assert!(app.rpc("sessions.transcript", json!({ "sessionId": "x", "cwd": "relative" })).is_err());
    assert!(app.rpc("sessions.transcript", json!({ "sessionId": "nope", "cwd": "/work/alpha" })).unwrap_err().contains("no transcript"));

    // ssh servers + PSMP profiles: same validation as the Tauri commands.
    assert!(app.rpc("ssh.servers.list", json!({})).unwrap().as_array().unwrap().is_empty());
    let srv = |host: &str| json!({ "server": { "label": "web", "host": host, "port": 22, "username": "root", "connectionType": "direct" } });
    assert!(app.rpc("ssh.servers.save", srv("-oProxyCommand=x")).is_err());
    let sid = app.rpc("ssh.servers.save", srv("web.example.invalid")).unwrap()["id"].as_str().unwrap().to_string();
    assert_eq!(app.rpc("ssh.servers.list", json!({})).unwrap()[0]["host"], "web.example.invalid");
    app.rpc("ssh.servers.delete", json!({ "id": sid })).unwrap();
    assert!(app.rpc("ssh.servers.list", json!({})).unwrap().as_array().unwrap().is_empty());
    let prof = json!({ "profile": { "id": "", "label": "p", "vaultUser": "alice@bob", "psmpAddress": "psmp.example.invalid" } });
    assert!(app.rpc("ssh.psmp.save", prof).unwrap_err().contains("must not contain the user delimiter"));
    let prof = json!({ "profile": { "id": "", "label": "p", "vaultUser": "alice", "psmpAddress": "psmp.example.invalid" } });
    let pid = app.rpc("ssh.psmp.save", prof).unwrap()["id"].as_str().unwrap().to_string();
    assert_eq!(app.rpc("ssh.psmp.list", json!({})).unwrap().as_array().unwrap().len(), 1);
    app.rpc("ssh.psmp.delete", json!({ "id": pid })).unwrap();
    assert!(app.rpc("ssh.psmp.list", json!({})).unwrap().as_array().unwrap().is_empty());
    assert!(app.rpc("ssh.servers.delete", json!({ "id": "nope" })).unwrap_err().contains("not found"));

    // A locked store hands out nothing; `vault.unlock` / `vault.init` are tested in `vault_unlock_*`.
    const LOCKED: &str = "password store is locked — unlock it in the Password Store tab";
    assert_eq!(app.rpc("vault.list", json!({})).unwrap_err(), LOCKED);
    assert_eq!(app.rpc("vault.add", json!({ "label": "a", "secretKind": "password", "secret": "s3cret" })).unwrap_err(), LOCKED);
    assert_eq!(app.rpc("vault.update", json!({ "reference": "a", "secret": "s3cret" })).unwrap_err(), LOCKED);
    assert_eq!(app.rpc("vault.status", json!({})).unwrap()["unlocked"], false);
    assert_eq!(app.rpc("cyberark.accounts.search", json!({ "query": "root" })).unwrap_err(), LOCKED);

    assert_eq!(app.rpc("queue.run", json!({ "action": "push" })).unwrap_err(), "not enabled in this build");
}

#[test]
fn vault_unlock_says_what_went_wrong_and_works_with_the_right_password() {
    let env = start("vault");
    let mut app = App::connect(&env.dir.join("m.sock"));
    let st = app.rpc("vault.status", json!({})).unwrap();
    assert_eq!((st["initialized"].clone(), st["unlocked"].clone()), (json!(false), json!(false)));
    // No file yet: say so (not "was not completed" / "locked").
    let e = app.rpc("vault.unlock", json!({ "master": "pw" })).unwrap_err();
    assert!(e.contains("no password store"), "{e}");
    assert!(app.rpc("vault.init", json!({ "master": "  " })).unwrap_err().contains("master password"));
    app.rpc("vault.init", json!({ "master": "pw one" })).unwrap();
    assert_eq!(app.rpc("vault.status", json!({})).unwrap()["unlocked"], true); // init leaves it unlocked
    app.rpc("vault.add", json!({ "label": "web", "secretKind": "password", "secret": "s3cret" })).unwrap();
    assert!(app.rpc("vault.init", json!({ "master": "again" })).unwrap_err().contains("already exists"));
    app.rpc("vault.lock", json!({})).unwrap();
    assert_eq!(app.rpc("vault.list", json!({})).unwrap_err(), "password store is locked — unlock it in the Password Store tab");
    assert_eq!(app.rpc("vault.unlock", json!({ "master": "wrong" })).unwrap_err(), "Wrong master password.");
    assert_eq!(app.rpc("vault.unlock", json!({})).unwrap_err(), "Type the master password.");
    app.rpc("vault.unlock", json!({ "master": "pw one" })).unwrap();
    let list = app.rpc("vault.list", json!({})).unwrap();
    assert_eq!(list[0]["label"], "web");
    assert!(!list.to_string().contains("s3cret"), "no secret value over the socket");
    // Unlocking again is a no-op, a damaged file says so.
    app.rpc("vault.unlock", json!({ "master": "anything" })).unwrap();
    app.rpc("vault.lock", json!({})).unwrap();
    std::fs::write(env.home.join(".claude/muya-ssh-vault.enc"), "not a vault").unwrap();
    assert!(app.rpc("vault.unlock", json!({ "master": "pw one" })).unwrap_err().contains("damaged"));
}

#[test]
fn vault_locks_itself_after_idle_and_interaction_pings_keep_it_open() {
    let env = start_with_idle("idle", "4");
    let mut app = App::connect(&env.dir.join("m.sock"));
    app.rpc("vault.init", json!({ "master": "pw" })).unwrap();
    app.rpc("vault.add", json!({ "label": "web", "secretKind": "password", "secret": "s3cret" })).unwrap();
    // Pings (the app's mouse / key events) keep it open past the limit.
    for _ in 0..6 {
        std::thread::sleep(Duration::from_millis(1000));
        app.rpc("vault.activity", json!({})).unwrap();
    }
    assert_eq!(app.rpc("vault.status", json!({})).unwrap()["unlocked"], true, "pings must keep the store open");
    // No interaction: it locks, tells the UI, and secrets are gone from the daemon.
    let mut locked = false;
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(250));
        if app.rpc("vault.status", json!({})).unwrap()["unlocked"] == false { locked = true; break; }
    }
    assert!(locked, "the store never locked itself");
    assert_eq!(app.rpc("vault.list", json!({})).unwrap_err(), "password store is locked — unlock it in the Password Store tab");
    app.rpc("vault.unlock", json!({ "master": "pw" })).unwrap();
    assert_eq!(app.rpc("vault.list", json!({})).unwrap()[0]["label"], "web");
}

/// Run by `native/scripts/test-classic-vault.sh`: the vault file classic Muya's original code wrote opens in Native.
#[test]
fn vault_compat_a_classic_vault_opens_and_native_additions_read_back() {
    let Some(classic_home) = std::env::var_os("MUYA_CLASSIC_COMPAT_HOME").map(PathBuf::from) else { return };
    let master = std::env::var("MUYA_TEST_MASTER").expect("MUYA_TEST_MASTER");
    let env = start("compat");
    let mut app = App::connect(&env.dir.join("m.sock"));
    let theirs = classic_home.join(".claude/muya-ssh-vault.enc");
    let ours = env.home.join(".claude/muya-ssh-vault.enc");
    std::fs::copy(&theirs, &ours).unwrap();
    assert_eq!(app.rpc("vault.status", json!({})).unwrap()["initialized"], true);
    assert_eq!(app.rpc("vault.unlock", json!({ "master": "not it" })).unwrap_err(), "Wrong master password.");
    app.rpc("vault.unlock", json!({ "master": master })).unwrap();
    let list = app.rpc("vault.list", json!({})).unwrap();
    assert_eq!(list[0]["label"], "classic-prod", "{list}");
    app.rpc("vault.add", json!({ "label": "native-added", "secretKind": "password", "secret": "native-secret-value" })).unwrap();
    assert_eq!(app.rpc("vault.list", json!({})).unwrap().as_array().unwrap().len(), 2);
    std::fs::copy(&ours, &theirs).unwrap(); // classic reads the file Native wrote
}

#[test]
fn git_and_plan_methods_stay_inside_the_roots() {
    let env = start("git");
    let repo = std::fs::canonicalize(&env.dir).unwrap().join("repo");
    std::fs::create_dir_all(repo.join("docs")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("a.txt"), "one\n").unwrap();
    std::fs::write(repo.join("docs/prd-demo.md"), "# Demo\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    std::fs::write(repo.join("a.txt"), "one\ntwo\n").unwrap();
    std::fs::write(repo.join("b.txt"), "new\n").unwrap();
    git(&repo, &["worktree", "add", "-q", "-b", "side", repo.parent().unwrap().join("wt").to_str().unwrap()]);
    let wt = repo.parent().unwrap().join("wt");
    let cwd = repo.to_str().unwrap();

    let mut app = App::connect(&env.dir.join("m.sock"));
    // No roots yet: fail closed.
    assert!(app.rpc("git.status", json!({ "cwd": cwd })).unwrap_err().contains("not one of Muya's workspaces"));
    app.rpc("workspace.set_roots", json!({ "roots": [cwd] })).unwrap();

    let st = app.rpc("git.status", json!({ "cwd": cwd })).unwrap();
    assert_eq!(st["branch"], "main");
    let files = st["files"].as_array().unwrap();
    assert!(files.iter().any(|f| f["path"].as_str().unwrap().ends_with("a.txt") && f["status"] == "M"), "{st}");
    assert!(files.iter().any(|f| f["path"].as_str().unwrap().ends_with("b.txt") && f["status"] == "?"), "{st}");

    let d = app.rpc("git.diff", json!({ "cwd": cwd, "path": "a.txt" })).unwrap();
    assert!(d["diff"].as_str().unwrap().contains("+two") && d["truncated"] == false, "{d}");
    assert_eq!(app.rpc("git.diff", json!({ "cwd": cwd, "staged": true })).unwrap()["diff"], "");
    assert!(app.rpc("git.diff", json!({ "cwd": cwd, "path": "../../etc/hosts" })).is_err());
    assert!(app.rpc("git.diff", json!({ "cwd": cwd, "path": "/etc/hosts" })).is_err());

    let wts = app.rpc("git.worktrees", json!({ "cwd": cwd })).unwrap();
    let wts = wts.as_array().unwrap();
    assert_eq!(wts.len(), 2, "{wts:?}");
    assert!(wts.iter().any(|w| w["branch"] == "side" && w["path"].as_str().unwrap().ends_with("/wt")));
    // A linked worktree of a root is itself acceptable.
    assert!(app.rpc("git.log", json!({ "cwd": wt })).is_ok());

    let br = app.rpc("git.branches", json!({ "cwd": cwd })).unwrap();
    assert!(br.as_array().unwrap().iter().any(|b| b["name"] == "main"), "{br}");

    let log = app.rpc("git.log", json!({ "cwd": cwd, "limit": 5, "skip": 0 })).unwrap();
    assert_eq!(log[0]["subject"], "first");
    assert_eq!(log[0]["author"], "t");
    assert!(log[0]["hash"].as_str().unwrap().len() == 40 && log[0]["parents"].as_array().unwrap().is_empty());
    assert!(log[0]["refs"].as_array().unwrap().iter().any(|r| r.as_str().unwrap().contains("main")));
    assert!(app.rpc("git.log", json!({ "cwd": cwd, "skip": 1 })).unwrap().as_array().unwrap().is_empty());

    // Outside the roots, relative, missing, or a symlink out of the root: refused.
    for bad in ["/", "/tmp", "relative", "/definitely/not/here"] {
        assert!(app.rpc("git.log", json!({ "cwd": bad })).is_err(), "{bad}");
    }
    std::os::unix::fs::symlink("/", repo.join("escape")).unwrap();
    assert!(app.rpc("git.log", json!({ "cwd": repo.join("escape") })).unwrap_err().contains("not one of Muya's workspaces"));

    // Plans.
    let plans = app.rpc("plan.list", json!({ "cwd": cwd })).unwrap();
    assert_eq!(plans[0]["slug"], "demo");
    let r = app.rpc("plan.set_status", json!({ "cwd": cwd, "slug": "demo", "status": "done" })).unwrap();
    assert_eq!(r["status"], "done");
    let progress = std::fs::read_to_string(repo.join("docs/prd-demo.progress.md")).unwrap();
    assert!(progress.contains("status: done"), "{progress}");
    assert_eq!(std::fs::read_to_string(repo.join("docs/prd-demo.md")).unwrap(), "# Demo\n", "the PRD itself is never touched");
    assert_eq!(app.rpc("plan.list", json!({ "cwd": cwd })).unwrap()[0]["status"], "done");
    for (slug, status) in [("../x", "done"), ("demo", "nonsense"), ("missing", "done")] {
        assert!(app.rpc("plan.set_status", json!({ "cwd": cwd, "slug": slug, "status": status })).is_err(), "{slug}/{status}");
    }
}

/// Measurement, not a gate: `cargo test -p muyad --test rpc perf_ -- --ignored --nocapture`.
/// `git.log` over a 5,000-commit repo while `sessions.search` runs on 60 big transcripts.
#[test]
#[ignore]
fn perf_git_log_with_parallel_search() {
    let env = start("perf");
    let repo = std::fs::canonicalize(&env.dir).unwrap().join("big");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    let mut stream = String::new();
    for i in 0..5000 {
        stream += &format!("commit refs/heads/main\ncommitter t <t@example.invalid> {} +0000\ndata 7\nc{:06}\n{}M 100644 inline f.txt\ndata 7\nv{:06}\n\n", 1_700_000_000 + i, i, "", i);
    }
    let mut fi = Command::new("git").arg("-C").arg(&repo).args(["fast-import", "--quiet"]).stdin(std::process::Stdio::piped()).spawn().unwrap();
    fi.stdin.take().unwrap().write_all(stream.as_bytes()).unwrap();
    assert!(fi.wait().unwrap().success());

    let proj = env.home.join(".claude/projects/-big");
    std::fs::create_dir_all(&proj).unwrap();
    let line = format!("{{\"type\":\"user\",\"message\":{{\"role\":\"user\",\"content\":\"{}\"}}}}\n", "filler words ".repeat(40));
    let refs: Vec<Value> = (0..60)
        .map(|i| {
            let p = proj.join(format!("b{i}.jsonl"));
            std::fs::write(&p, line.repeat(20_000)).unwrap();
            json!({ "id": format!("b{i}"), "cwd": "/big", "path": p })
        })
        .collect();
    let pid = env.kids.last().unwrap().id();
    let sample = |what: &str| {
        let o = Command::new("ps").args(["-o", "rss=,time=", "-p", &pid.to_string()]).output().unwrap();
        eprintln!("muyad {what}: rss_kb,cpu_time = {}", String::from_utf8_lossy(&o.stdout).trim());
    };
    let sock = env.dir.join("m.sock");
    let mut app = App::connect(&sock);
    app.rpc("workspace.set_roots", json!({ "roots": [repo] })).unwrap();
    sample("idle");
    let mut searcher = App::connect(&sock);
    let t = Instant::now();
    searcher.send(Control::Rpc { req: 9, method: "sessions.search".into(), params: json!({ "query": "needle-not-present", "sessions": refs }).to_string() });
    let t_log = Instant::now();
    for skip in [0, 1000, 4000] {
        let log = app.rpc("git.log", json!({ "cwd": repo, "limit": 1000, "skip": skip })).unwrap();
        assert!(log.as_array().unwrap().len() >= 1000.min(5000 - skip));
    }
    eprintln!("3 x git.log(1000) while searching: {:?}", t_log.elapsed());
    sample("after git.log, search running");
    loop {
        if let Control::RpcReply { req: 9, .. } = searcher.read_control() {
            break;
        }
    }
    eprintln!("search of 60 x 11 MB finished after {:?}", t.elapsed());
    sample("after both");
}

#[test]
fn sessions_archive_and_restore_only_move_files_and_refuse_running_ones() {
    let env = start("arch");
    let mut app = App::connect(&env.dir.join("m.sock"));
    let proj = env.home.join(".claude/projects/-work-alpha");
    // A transcript used in the last 10 minutes is left alone; age s-one (with a side folder) and s-two by hand.
    let old = std::time::SystemTime::now() - Duration::from_secs(40 * 86_400);
    let side = proj.join("s-one/subagents");
    std::fs::create_dir_all(&side).unwrap();
    std::fs::write(side.join("a.jsonl"), b"{\"sub\":1}\n").unwrap();
    for n in ["s-one", "s-two"] {
        std::fs::File::options().write(true).open(proj.join(format!("{n}.jsonl"))).unwrap().set_modified(old).unwrap();
    }
    let one = proj.join("s-one.jsonl");
    let two = proj.join("s-two.jsonl");
    let before = std::fs::read(&one).unwrap();
    let before_side = std::fs::read(side.join("a.jsonl")).unwrap();
    let arch = |app: &mut App, paths: &[&Path], live: &[&str]| app.rpc("sessions.archive", json!({ "paths": paths, "liveIds": live })).unwrap();

    // Running session: refused, nothing moves.
    let r = arch(&mut app, &[&one], &["s-one"]);
    assert_eq!(r["done"], 0);
    assert!(r["skipped"][0][1].as_str().unwrap().contains("running"), "{r}");
    assert!(one.is_file());
    // A path outside ~/.claude/projects: refused.
    let r = arch(&mut app, &[Path::new("/etc/hosts")], &[]);
    assert_eq!(r["done"], 0, "{r}");
    assert!(app.rpc("sessions.archived", json!({})).unwrap().as_array().unwrap().is_empty());

    // Archive both: moved (never deleted) with the side folder, into session-archive under the same project folder.
    let r = arch(&mut app, &[&one, &two], &[]);
    assert_eq!(r["done"], 2, "{r}");
    assert!(!one.exists() && !two.exists() && !proj.join("s-one").exists());
    let root = env.home.join("Library/Application Support/com.staunch.muya/session-archive/-work-alpha");
    assert_eq!(std::fs::read(root.join("s-one.jsonl")).unwrap(), before);
    assert_eq!(std::fs::read(root.join("s-one/subagents/a.jsonl")).unwrap(), before_side);
    let listed = app.rpc("sessions.archived", json!({})).unwrap();
    let listed = listed.as_array().unwrap();
    assert_eq!(listed.len(), 2, "{listed:?}");
    assert!(app.rpc("sessions.history", json!({})).unwrap().as_array().unwrap().is_empty(), "archived sessions leave the history");

    // Restore puts both back, byte-identical; an archived session is not restored twice.
    let paths: Vec<String> = listed.iter().map(|e| e["path"].as_str().unwrap().to_string()).collect();
    let r = app.rpc("sessions.restore", json!({ "paths": paths })).unwrap();
    assert_eq!(r["done"], 2, "{r}");
    assert_eq!(std::fs::read(&one).unwrap(), before);
    assert_eq!(std::fs::read(side.join("a.jsonl")).unwrap(), before_side);
    assert!(two.is_file());
    assert!(app.rpc("sessions.archived", json!({})).unwrap().as_array().unwrap().is_empty());
    assert_eq!(app.rpc("sessions.restore", json!({ "paths": paths })).unwrap()["done"], 0);
    // Restore refuses a live transcript path (only archived ones may come back).
    assert_eq!(app.rpc("sessions.restore", json!({ "paths": [one] })).unwrap()["done"], 0);
}

/// The operator's "Command" dialog: `sessions.send_command` answers one result per terminal and types into none that is
/// not a Claude session (a shell, a terminal that is gone), and refuses empty input.
#[test]
fn send_command_reports_one_result_per_terminal_and_never_types_into_a_shell() {
    let env = start("sendcmd");
    let mut app = App::connect(&env.dir.join("m.sock"));
    app.send(Control::Spawn { argv: vec!["/bin/sh".into(), "-c".into(), "sleep 30".into()], cwd: "/tmp".into(), env: vec![], cols: 80, rows: 24 });
    let shell = loop {
        if let Control::Spawned { id, .. } = app.read_control() {
            break id;
        }
    };
    let r = app.rpc("sessions.send_command", json!({ "ids": [shell, 4242, shell], "text": "/compact" })).unwrap();
    let results = r["results"].as_array().unwrap();
    assert_eq!(results.len(), 2, "duplicate ids collapse: {r}");
    assert_eq!(results[0]["id"], shell);
    assert_eq!(results[0]["state"], "failed", "{r}");
    assert!(results[0]["reason"].as_str().unwrap().contains("no Claude session"), "{r}");
    assert_eq!(results[1]["id"], 4242);
    assert_eq!(results[1]["state"], "failed", "{r}");
    assert!(app.rpc("sessions.send_command", json!({ "ids": [shell], "text": "  " })).is_err());
    assert!(app.rpc("sessions.send_command", json!({ "ids": [], "text": "/cost" })).is_err());
}

/// Connects to a daemon that was just started: the socket file can exist before the daemon accepts (a busy machine), so a refused
/// connection is retried for up to 20 s instead of failing the test.
fn connect_retry(p: impl AsRef<std::path::Path>) -> std::os::unix::net::UnixStream {
    let end = std::time::Instant::now() + std::time::Duration::from_secs(20);
    loop {
        match std::os::unix::net::UnixStream::connect(p.as_ref()) {
            Ok(s) => return s,
            Err(e) if std::time::Instant::now() < end => {
                let _ = e;
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(e) => panic!("{}: {e}", p.as_ref().display()),
        }
    }
}

/// The exit panel's data: after the process exited (status 3) the last lines it printed are still available, until the session is closed.
#[test]
fn the_last_lines_stay_readable_after_the_process_exited() {
    let env = start("tail");
    let mut app = App::connect(&env.dir.join("m.sock"));
    app.send(Control::Spawn { argv: vec!["/bin/sh".into(), "-c".into(), "echo first; echo 'boom: library missing'; exit 3".into()], cwd: "/tmp".into(), env: vec![], cols: 80, rows: 24 });
    let id = loop {
        if let Control::Spawned { id, .. } = app.read_control() {
            break id;
        }
    };
    app.send(Control::Detach { id }); // a screen-only subscription: Exited keeps coming
    let end = std::time::Instant::now() + Duration::from_secs(15);
    loop {
        if let Control::Exited { id: i, status } = app.read_control() {
            if i == id {
                assert_eq!(status, 3);
                break;
            }
        }
        assert!(std::time::Instant::now() < end, "no exit");
    }
    let r = app.rpc("sessions.tail", json!({ "id": id, "lines": 20 })).unwrap();
    let lines: Vec<String> = r["lines"].as_array().unwrap().iter().map(|l| l.as_str().unwrap().to_string()).collect();
    assert!(lines.iter().any(|l| l == "boom: library missing"), "{lines:?}");
    assert!(lines.last().is_some_and(|l| !l.is_empty()), "no trailing blanks: {lines:?}");
    let r = app.rpc("sessions.tail", json!({ "id": id, "lines": 1 })).unwrap();
    assert_eq!(r["lines"].as_array().unwrap().len(), 1);
    assert!(app.rpc("sessions.tail", json!({ "id": 987654 })).is_err());
}

//! 5.0.2 secrets parity, against a real muyad in a temp HOME (TEST values only): the Password Store RPCs the app
//! uses (save / list / reveal / remove / lock) and what an agent can do with a secret through the broker
//! (get_secret usage text, http_request, run_with_secrets) without the value ever appearing in a result.
//! The harness issues `Control::Rpc` calls and records every `Control::Event` muyad sends it.

use muya_proto::{Control, Decoder, Frame, Role};
use serde_json::{json, Value};
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

fn script(path: &Path, body: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn start(tag: &str) -> Env {
    let dir = PathBuf::from(format!("/tmp/muya-sp-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let ptyd = Command::new(Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name("muya-ptyd"))
        .env("MUYA_PTYD_EXIT_WITH_PARENT", "1")
        .arg("--socket")
        .arg(dir.join("p.sock"))
        .spawn()
        .expect("cargo build --workspace first");
    let mut env = Env {
        dir,
        home,
        kids: vec![ptyd],
    };
    let p = env.dir.join("p.sock");
    wait_for("ptyd", || p.exists());
    // A stand-in `claude` whose session list says: this test process is a Claude session (what the daemon uses to
    // verify a terminal tool such as muyactl by its ancestry).
    script(&env.home.join("bin/claude"), &format!("#!/bin/sh\necho '[{{\"sessionId\":\"fake-sess\",\"pid\":{},\"kind\":\"interactive\",\"cwd\":\"/tmp\",\"status\":\"idle\"}}]'\n", std::process::id()));
    let muyad = Command::new(env!("CARGO_BIN_EXE_muyad"))
        .env_clear()
        .env("HOME", &env.home)
        .env("PATH", format!("{}:/usr/bin:/bin", env.home.join("bin").display()))
        .env("MUYA_SSH_BROKER_SOCK", env.dir.join("b.sock"))
        .arg("--socket")
        .arg(env.dir.join("m.sock"))
        .arg("--ptyd")
        .arg(&p)
        .arg("--broker")
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    env.kids.push(muyad);
    let (m, b) = (env.dir.join("m.sock"), env.dir.join("b.sock"));
    wait_for("muyad + broker sockets", || {
        m.exists() && b.exists() && UnixStream::connect(&b).is_ok()
    });
    env
}

struct App {
    s: UnixStream,
    dec: Decoder,
    next: u64,
    /// Every event seen so far, in order: (name, payload).
    events: Vec<(String, Value)>,
}

impl App {
    fn connect(sock: &Path) -> Self {
        let s = connect_retry(sock);
        s.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
        let mut a = Self {
            s,
            dec: Decoder::default(),
            next: 1,
            events: vec![],
        };
        a.send(muya_proto::hello(Role::App, "sp-test"));
        assert!(matches!(a.read_control(), Control::Welcome { .. }));
        a
    }
    fn send(&mut self, c: Control) {
        self.s.write_all(&Frame::Control(c).encode()).unwrap();
    }
    /// Next non-event control frame; events are recorded on the way.
    fn read_control(&mut self) -> Control {
        loop {
            while let Some(f) = self.dec.next_frame().unwrap() {
                if let Frame::Control(c) = f {
                    if let Control::Event { name, payload } = c {
                        self.events
                            .push((name, serde_json::from_str(&payload).unwrap()));
                        continue;
                    }
                    return c;
                }
            }
            let mut buf = [0u8; 65536];
            let n = self.s.read(&mut buf).unwrap();
            assert!(n > 0, "muyad closed");
            self.dec.push(&buf[..n]);
        }
    }
    fn rpc(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let req = self.next;
        self.next += 1;
        self.send(Control::Rpc {
            req,
            method: method.into(),
            params: params.to_string(),
        });
        loop {
            if let Control::RpcReply { req: r, ok, result } = self.read_control() {
                assert_eq!(r, req);
                return if ok {
                    Ok(serde_json::from_str(&result).unwrap())
                } else {
                    Err(result)
                };
            }
        }
    }
}


use std::io::{BufRead, BufReader};

fn broker(env: &Env, req: Value) -> Value {
    let mut s = connect_retry(env.dir.join("b.sock"));
    s.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    writeln!(s, "{req}").unwrap();
    let mut line = String::new();
    BufReader::new(s).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|_| panic!("not json: {line}"))
}

/// A tiny HTTP server: 200 + {"ok":true,"echo":<auth header>} when `Authorization: Bearer <want>`, else 401.
fn auth_server(want: &'static str, hits: usize) -> (u16, std::thread::JoinHandle<()>) {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    let t = std::thread::spawn(move || {
        for _ in 0..hits {
            let (mut c, _) = l.accept().unwrap();
            let mut buf = vec![0u8; 8192];
            let n = c.read(&mut buf).unwrap();
            let req = String::from_utf8_lossy(&buf[..n]).to_string();
            let auth = req.lines().find_map(|l| l.strip_prefix("authorization: ").or_else(|| l.strip_prefix("Authorization: "))).unwrap_or("").trim().to_string();
            let (code, body) = if auth == format!("Bearer {want}") { ("200 OK", format!("{{\"ok\":true,\"you_sent\":\"{auth}\"}}")) } else { ("401 Unauthorized", "{\"ok\":false}".to_string()) };
            let _ = write!(c, "HTTP/1.1 {code}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len());
        }
    });
    (port, t)
}

#[test]
fn password_store_rpcs_and_agent_use_of_secrets() {
    let env = start("e2e");
    let mut app = App::connect(&env.dir.join("m.sock"));

    // Password Store: create, add with user + group, list shows them, reveal, edit in place, delete, lock.
    app.rpc("vault.init", json!({"master": "correct horse battery staple"})).unwrap();
    let id = app
        .rpc("vault.save", json!({"label":"old-router","username":"admin","secretKind":"password","secret":"test-pass-AAA111","description":"Edge","group":"Lab"}))
        .unwrap();
    let id = id.as_str().unwrap().to_string();
    let list = app.rpc("vault.list", json!({})).unwrap();
    let e = &list.as_array().unwrap()[0];
    assert_eq!((e["id"].as_str(), e["username"].as_str(), e["group"].as_str(), e["secretKind"].as_str()), (Some(id.as_str()), Some("admin"), Some("Lab"), Some("password")), "{list}");
    assert!(!list.to_string().contains("AAA111"), "list must not carry values");
    assert_eq!(app.rpc("vault.reveal", json!({"id": id})).unwrap(), json!("test-pass-AAA111"));
    app.rpc("vault.save", json!({"id": id, "label":"old-router","username":"admin","secretKind":"password","secret":"test-pass-CCC333","description":"Edge","group":"Lab2"})).unwrap();
    assert_eq!(app.rpc("vault.reveal", json!({"id": id})).unwrap(), json!("test-pass-CCC333"));
    assert_eq!(app.rpc("vault.list", json!({})).unwrap().as_array().unwrap().len(), 1, "edit replaces in place");
    // add through the agent-facing op's RPC shape keeps working
    app.rpc("vault.add", json!({"label":"extra","description":"","secretKind":"api_key","secret":"test-extra-DDD444","username":"u","group":"G"})).unwrap();
    let list = app.rpc("vault.list", json!({})).unwrap();
    assert!(list.as_array().unwrap().iter().any(|m| m["label"] == "extra" && m["group"] == "G" && m["username"] == "u"), "{list}");
    let extra = list.as_array().unwrap().iter().find(|m| m["label"] == "extra").unwrap()["id"].as_str().unwrap().to_string();
    app.rpc("vault.remove", json!({"id": extra})).unwrap();
    assert_eq!(app.rpc("vault.list", json!({})).unwrap().as_array().unwrap().len(), 1);

    // Agent side: this process subscribes as session "e2e" (what the sidecar of a Claude session does), so its
    // later requests are a verified caller. add_secret -> get_secret gives a placeholder and the usage text, never the value.
    let mut sub = connect_retry(env.dir.join("b.sock"));
    sub.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    writeln!(sub, "{}", json!({"op":"subscribe","sessionId":"e2e"})).unwrap();
    let mut ack = String::new();
    BufReader::new(sub.try_clone().unwrap()).read_line(&mut ack).unwrap();
    assert!(ack.contains("\"ok\":true"), "{ack}");
    let (port, srv) = auth_server("test-token-XYZ789", 2);
    let r = broker(&env, json!({"op":"add_secret","caller":"e2e","name":"svc_api_key","value":"test-token-XYZ789","kind":"api_key"}));
    assert_eq!(r["ok"], true, "{r}");
    let g = broker(&env, json!({"op":"get_secret","caller":"e2e","name":"svc_api_key"}));
    assert_eq!(g["ok"], true, "{g}");
    let gs = g.to_string();
    assert!(g["value"] == "{{muya-secret:svc_api_key}}" && gs.contains("http_request") && gs.contains("run_with_secrets") && gs.contains("muyactl secret exec --env API_KEY=svc_api_key"), "{g}");
    assert!(!gs.contains("XYZ789"), "get_secret leaked: {gs}");

    // http_request: the daemon substitutes the header, the server says 200, nothing plaintext comes back.
    let h = broker(&env, json!({"op":"http_request","caller":"e2e","method":"GET","url":format!("http://127.0.0.1:{port}/v1/me"),
                               "headers":{"Authorization":"Bearer {{muya-secret:svc_api_key}}"}}));
    assert_eq!(h["ok"], true, "{h}");
    assert_eq!(h["status"], 200, "{h}");
    assert!(!h.to_string().contains("XYZ789"), "http_request leaked: {h}");
    assert!(h["body"].as_str().unwrap().contains("{{muya-secret:svc_api_key}}"), "{h}");
    // the way the agent failed in the field: the literal placeholder in its own header is a 401
    // run_with_secrets: curl reads the header from env, 200, redacted.
    let r = broker(&env, json!({"op":"run_with_secrets","caller":"e2e","cwd":"/tmp",
        "argv":["/usr/bin/curl","-sS","-H","@-",format!("http://127.0.0.1:{port}/v1/me")],
        "stdin":"Authorization: Bearer {{muya-secret:svc_api_key}}"}));
    assert_eq!(r["ok"], true, "{r}");
    assert!(r["stdout"].as_str().unwrap_or("").contains("\"ok\":true"), "run_with_secrets must reach 200: {r}");
    assert!(!r.to_string().contains("XYZ789"), "run_with_secrets leaked: {r}");
    srv.join().unwrap();

    // Lock: nothing is readable until unlocked again.
    app.rpc("vault.lock", json!({})).unwrap();
    assert!(app.rpc("vault.reveal", json!({"id": id})).is_err());
    // A call that names a secret needs the store open; one that names none does not (it must not depend on the network here).
    let g = broker(&env, json!({"op":"http_request","caller":"e2e","url":"https://example.com/",
        "headers":{"Authorization":"Bearer {{muya-secret:svc_api_key}}"}}));
    assert_eq!(g["ok"], false, "{g}");
    assert!(g["error"].as_str().unwrap_or("").contains("password store is locked"), "{g}");
}

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

/// A vault written by classic Muya's ORIGINAL credstore code (native/tools/classic-vault, built by
/// scripts/test-classic-vault.sh) opens in muyad and lists every entry with user name and group; values reveal.
#[test]
fn a_vault_made_by_classic_opens_and_shows_its_entries() {
    let helper = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tools/classic-vault/target/debug/classic-vault");
    if !helper.exists() {
        eprintln!("SKIPPED: bash native/scripts/test-classic-vault.sh builds the classic helper");
        return;
    }
    let env = start("classic");
    std::fs::create_dir_all(env.home.join(".claude")).unwrap();
    let run = |args: &[&str]| {
        let o = Command::new(&helper).env_clear().env("HOME", &env.home).env("MUYA_TEST_MASTER", "correct horse battery staple").args(args).output().unwrap();
        assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    };
    run(&["init"]);
    run(&["add", "old-router", "test-pass-AAA111", "Lab", "admin"]);
    run(&["add", "old-db", "test-pass-BBB222", "Production", "dba"]);
    let mut app = App::connect(&env.dir.join("m.sock"));
    assert_eq!(app.rpc("vault.status", json!({})).unwrap()["initialized"], true);
    app.rpc("vault.unlock", json!({"master": "correct horse battery staple"})).unwrap();
    let list = app.rpc("vault.list", json!({})).unwrap();
    let rows = list.as_array().unwrap();
    assert_eq!(rows.len(), 2, "{list}");
    let r = rows.iter().find(|m| m["label"] == "old-router").unwrap();
    assert_eq!((r["username"].as_str(), r["group"].as_str()), (Some("admin"), Some("Lab")), "{r}");
    assert!(!list.to_string().contains("AAA111"));
    assert_eq!(app.rpc("vault.reveal", json!({"id": r["id"]})).unwrap(), json!("test-pass-AAA111"));
}

/// `muyactl secret exec` from a "session terminal": the daemon ties muyactl to a Claude session through its parent chain,
/// substitutes the secret into the child's environment only, and redacts the output.
#[test]
fn muyactl_secret_exec_reaches_200_and_stays_redacted() {
    let muyactl = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/debug/muyactl");
    if !muyactl.exists() {
        eprintln!("SKIPPED: cargo build --workspace first");
        return;
    }
    let env = start("exec");
    let mut app = App::connect(&env.dir.join("m.sock"));
    app.rpc("vault.init", json!({"master": "correct horse battery staple"})).unwrap();
    app.rpc("vault.save", json!({"label":"svc_api_key","username":"","secretKind":"api_key","secret":"test-token-XYZ789"})).unwrap();
    let (port, srv) = auth_server("test-token-XYZ789", 1);
    let o = Command::new(&muyactl)
        .env_clear()
        .env("HOME", &env.home)
        .env("PATH", "/usr/bin:/bin")
        .env("MUYA_SSH_BROKER_SOCK", env.dir.join("b.sock"))
        .args(["secret", "exec", "--env", "API_KEY=svc_api_key", "--cwd", "/tmp", "--"])
        .args(["sh", "-c", &format!("curl -sS -H \"Authorization: Bearer $API_KEY\" http://127.0.0.1:{port}/v1/me")])
        .output()
        .unwrap();
    let out = format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
    srv.join().unwrap();
    assert!(out.contains("\"ok\":true"), "muyactl exec must reach 200: {out}");
    assert!(!out.contains("XYZ789"), "plaintext leaked: {out}");
}

/// Classic's Export backup / per-card Export / Import SSH key / Import credential, through the app's RPC.
#[test]
fn export_backup_export_card_and_imports_work() {
    use std::os::unix::fs::PermissionsExt;
    let env = start("xfer");
    let mut app = App::connect(&env.dir.join("m.sock"));
    app.rpc("vault.init", json!({"master": "correct horse battery staple"})).unwrap();
    let id = app.rpc("vault.save", json!({"label":"pw","username":"u","secretKind":"password","secret":"test-pass-EEE555"})).unwrap();
    let id = id.as_str().unwrap().to_string();
    // backup: the sealed file, never plaintext
    let bak = env.dir.join("backup.enc.bak");
    app.rpc("vault.export_backup", json!({"dest": bak})).unwrap();
    let bytes = std::fs::read(&bak).unwrap();
    assert!(!bytes.is_empty() && !String::from_utf8_lossy(&bytes).contains("EEE555"), "the backup must stay encrypted");
    assert!(String::from_utf8_lossy(&bytes[..16.min(bytes.len())]).contains("MUYA"), "classic's vault format");
    // classic's "Export master password": plain text in the picked file, owner-only
    let m = env.dir.join("master.txt");
    app.rpc("vault.export_master", json!({"dest": m, "master": "correct horse battery staple"})).unwrap();
    assert_eq!(std::fs::read_to_string(&m).unwrap(), "correct horse battery staple");
    assert_eq!(std::fs::metadata(&m).unwrap().permissions().mode() & 0o777, 0o600);
    // per-card export: the value, owner-only file
    let out = env.dir.join("pw.txt");
    app.rpc("vault.export_cred", json!({"id": id, "dest": out})).unwrap();
    assert_eq!(std::fs::read_to_string(&out).unwrap().trim_end(), "test-pass-EEE555");
    assert_eq!(std::fs::metadata(&out).unwrap().permissions().mode() & 0o777, 0o600);
    // imports
    let key = env.dir.join("id_test");
    std::fs::write(&key, "-----BEGIN TEST KEY-----\nabc\n-----END TEST KEY-----\n").unwrap();
    app.rpc("vault.import_key", json!({"label":"imported key","username":"deploy","srcPath": key})).unwrap();
    let tok = env.dir.join("token.txt");
    std::fs::write(&tok, "test-token-FFF666\n").unwrap();
    app.rpc("vault.import_secret", json!({"label":"imported token","secretKind":"token","description":"d","group":"Imp","srcPath": tok})).unwrap();
    let list = app.rpc("vault.list", json!({})).unwrap();
    let t = list.as_array().unwrap().iter().find(|m| m["label"] == "imported token").unwrap();
    assert_eq!((t["group"].as_str(), t["secretKind"].as_str()), (Some("Imp"), Some("token")), "{t}");
    assert_eq!(app.rpc("vault.reveal", json!({"id": t["id"]})).unwrap(), json!("test-token-FFF666"), "one trailing newline dropped");
    let k = list.as_array().unwrap().iter().find(|m| m["label"] == "imported key").unwrap();
    assert_eq!((k["username"].as_str(), k["secretKind"].as_str()), (Some("deploy"), Some("key")), "{k}");
}

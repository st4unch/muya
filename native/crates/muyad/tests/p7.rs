//! Parity package P7 — term_history.*, slash.list, statusline.*, resources.* (list, marketplaces, installers)
//! against a real muyad in a temp HOME. Installers run against fake `claude` / `git` binaries on a temp PATH.

//! that issues `Control::Rpc` calls and records every `Control::Event` muyad sends it.

use muya_proto::{Control, Decoder, Frame, Role};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
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

/// Knows `plugin` (and logs every call); the login-shell/`~/.local/bin` candidate.
const NEW_CLAUDE: &str = r#"#!/bin/sh
case "$1" in
  --version) echo "2.1.300 (Claude Code)";;
  agents) echo '[]';;
  plugin) if [ "$2" = "--help" ]; then exit 0; fi
          echo "$@" >> "$HOME/plugin.log"
          if [ "$2" = marketplace ] && [ -f "$HOME/already" ]; then echo "marketplace 'muya' already exists" >&2; exit 1; fi;;
  *) exit 1;;
esac
"#;
/// An older CLI that is first on PATH: answers `--version`, rejects `plugin`.
const OLD_CLAUDE: &str = r#"#!/bin/sh
case "$1" in
  --version) echo "2.1.78 (Claude Code)";;
  *) echo "unknown command" >&2; exit 1;;
esac
"#;
/// Logs its arguments instead of cloning anything.
const FAKE_GIT: &str = r##"#!/bin/sh
echo "$@" >> "$HOME/git.log"
for last; do :; done
mkdir -p "$last"
echo "# cloned" > "$last/SKILL.md"
"##;

fn script(path: &Path, body: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn start(tag: &str) -> Env {
    let dir = PathBuf::from(format!("/tmp/muya-p7-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    script(&home.join(".local/bin/claude"), NEW_CLAUDE);
    script(&dir.join("oldbin/claude"), OLD_CLAUDE);
    script(&dir.join("oldbin/git"), FAKE_GIT);
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
    let muyad = Command::new(env!("CARGO_BIN_EXE_muyad"))
        .env_clear()
        .env("HOME", &env.home)
        // env_clear drops TMPDIR too; the status-line capture folder must be where this process looks (std::env::temp_dir()).
        .env("TMPDIR", std::env::temp_dir())
        .env("PATH", format!("{}:/usr/bin:/bin", env.dir.join("oldbin").display()))
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
        a.send(muya_proto::hello(Role::App, "p7-test"));
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
    /// Waits until an event called `name` arrived (any time since the start); returns its payload.
    fn event(&mut self, name: &str) -> Value {
        let end = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some((_, p)) = self.events.iter().find(|(n, _)| n == name) {
                return p.clone();
            }
            assert!(
                Instant::now() < end,
                "no event {name}; saw {:?}",
                self.events
            );
            // A round trip pumps the socket so queued events are decoded.
            self.s
                .set_read_timeout(Some(Duration::from_millis(200)))
                .unwrap();
            let mut buf = [0u8; 65536];
            if let Ok(n) = self.s.read(&mut buf) {
                assert!(n > 0, "muyad closed");
                self.dec.push(&buf[..n]);
                while let Ok(Some(Frame::Control(Control::Event { name, payload }))) =
                    self.dec.next_frame()
                {
                    self.events
                        .push((name, serde_json::from_str(&payload).unwrap()));
                }
            }
        }
    }
}

fn hist_dir(home: &Path) -> PathBuf {
    home.join("Library/Application Support/com.staunch.muya/term-history")
}

#[test]
fn p7_term_history_list_full_export_delete_and_garbage() {
    let env = start("hist");
    let hd = hist_dir(&env.home);
    std::fs::create_dir_all(&hd).unwrap();
    std::fs::write(hd.join("tab-1.hist"), ": 1700000000:0;ls -la\n: 1700000005:0;git status\n").unwrap();
    std::fs::write(hd.join("tab-1.json"), r#"{"name":"build","cwd":"/work"}"#).unwrap();
    // A garbled file: binary junk, and a meta file that is not JSON.
    std::fs::write(hd.join("junk.hist"), [0xffu8, 0xfe, 0x00, 0x83, 0x0a, 0x80]).unwrap();
    std::fs::write(hd.join("junk.json"), "{{{ not json").unwrap();
    let mut app = App::connect(&env.dir.join("m.sock"));

    let list = app.rpc("term_history.entries", json!({})).unwrap();
    let rows = list.as_array().unwrap();
    let t1 = rows.iter().find(|r| r["key"] == "tab-1").expect("tab-1 listed");
    assert_eq!(t1["name"], "build");
    assert_eq!(t1["cwd"], "/work");
    assert_eq!(t1["total"], 2);
    assert_eq!(t1["entries"][0], json!({"ts": 1700000000u64, "cmd": "ls -la"}));
    assert!(rows.iter().any(|r| r["key"] == "junk"), "a garbled file is listed, not fatal");

    let full = app.rpc("term_history.full", json!({"key": "tab-1"})).unwrap();
    assert_eq!(full["entries"].as_array().unwrap().len(), 2);
    assert_eq!(app.rpc("term_history.full", json!({"key": "nope"})).unwrap(), Value::Null, "missing = null");
    app.rpc("term_history.full", json!({"key": "junk"})).unwrap();

    // Keys that could name another file are refused.
    for bad in ["../x", "/etc/passwd", ".hidden", "a/b", ""] {
        assert!(app.rpc("term_history.full", json!({"key": bad})).is_err(), "{bad}");
        assert!(app.rpc("term_history.delete", json!({"key": bad})).is_err(), "{bad}");
    }

    // Export: a .txt outside the history folder works (mode 0600); inside it, or another extension, is refused.
    let out = env.dir.join("export.txt");
    app.rpc("term_history.export", json!({"dest": out, "text": "ls -la\ngit status\n"})).unwrap();
    assert_eq!(std::fs::read_to_string(&out).unwrap(), "ls -la\ngit status\n");
    assert_eq!(std::fs::metadata(&out).unwrap().permissions().mode() & 0o777, 0o600);
    assert!(app.rpc("term_history.export", json!({"dest": hd.join("x.txt"), "text": "x"})).is_err());
    assert!(app.rpc("term_history.export", json!({"dest": env.dir.join("x.sh"), "text": "x"})).is_err());
    assert!(app.rpc("term_history.export", json!({"dest": "relative.txt", "text": "x"})).is_err());

    app.rpc("term_history.delete", json!({"key": "tab-1"})).unwrap();
    assert!(!hd.join("tab-1.hist").exists() && !hd.join("tab-1.json").exists());
    app.rpc("term_history.delete", json!({"key": "tab-1"})).unwrap(); // already gone: fine
}

#[test]
fn p7_term_history_with_no_folder_is_empty() {
    let env = start("histempty");
    let mut app = App::connect(&env.dir.join("m.sock"));
    assert_eq!(app.rpc("term_history.entries", json!({})).unwrap(), json!([]));
}

#[test]
fn p7_slash_commands_user_skills_and_roots() {
    let env = start("slash");
    let cmds = env.home.join(".claude/commands");
    std::fs::create_dir_all(&cmds).unwrap();
    std::fs::write(cmds.join("deploy.md"), "---\ndescription: Ship it\n---\nbody\n").unwrap();
    std::fs::create_dir_all(env.home.join(".claude/skills/review")).unwrap();
    std::fs::write(env.home.join(".claude/skills/review/SKILL.md"), "---\nname: review\ndescription: Review code\n---\n").unwrap();
    let mut app = App::connect(&env.dir.join("m.sock"));
    let r = app.rpc("slash.list", json!({"agent": "claude"})).unwrap();
    let rows = r.as_array().unwrap();
    let find = |n: &str| rows.iter().find(|c| c["name"] == n).cloned();
    assert_eq!(find("deploy").unwrap(), json!({"name": "deploy", "description": "Ship it", "source": "user"}));
    assert_eq!(find("review").unwrap()["source"], "skill");
    // A project folder outside Muya's roots is refused (the scan reads <cwd>/.claude/commands).
    let e = app.rpc("slash.list", json!({"agent": "claude", "cwd": "/etc"})).unwrap_err();
    assert!(e.contains("outside") || e.contains("not one of") || e.contains("folder"), "{e}");
}

#[test]
fn p7_statusline_methods() {
    let env = start("status");
    let muyad_pid = env.kids.last().unwrap().id();
    let mut app = App::connect(&env.dir.join("m.sock"));
    // With the footer switch on (the default) the tap lives in the user's own settings.json, so
    // there is no per-launch --settings file: the path is null, and the tap is in settings.json.
    assert_eq!(app.rpc("statusline.path", json!({})).unwrap(), Value::Null);
    let settings = std::fs::read_to_string(env.home.join(".claude/settings.json")).unwrap();
    assert!(settings.contains("statusLine"), "{settings}");
    assert_eq!(app.rpc("statusline.get", json!({"ptyId": "pty-7"})).unwrap(), Value::Null);
    assert!(app.rpc("statusline.get", json!({"ptyId": "../../etc/passwd"})).is_err());
    // A status file the tap wrote into the daemon's capture folder is returned as JSON.
    let dir = std::env::temp_dir().join(format!("muya-status-{muyad_pid}"));
    assert!(dir.is_dir(), "{}", dir.display());
    std::fs::write(dir.join("pty-42.json"), r#"{"model":{"display_name":"Opus"}}"#).unwrap();
    assert_eq!(app.rpc("statusline.get", json!({"ptyId": "pty-42"})).unwrap()["model"]["display_name"], "Opus");
}

#[test]
fn p7_resources_list_and_install_mcp_keep_other_config() {
    let env = start("res");
    std::fs::create_dir_all(env.home.join(".claude/skills/alpha")).unwrap();
    std::fs::write(env.home.join(".claude/skills/alpha/SKILL.md"), "---\nname: alpha\ndescription: First skill\n---\n").unwrap();
    std::fs::create_dir_all(env.home.join(".claude/agents")).unwrap();
    std::fs::write(env.home.join(".claude/agents/helper.md"), "---\nname: helper\ndescription: Helps\n---\n").unwrap();
    std::fs::write(env.home.join(".claude.json"), r#"{"theme":"dark","mcpServers":{"old":{"command":"x"}}}"#).unwrap();
    // The Resources list reads ~/.claude/.mcp.json (as the Tauri app does), not ~/.claude.json.
    std::fs::write(env.home.join(".claude/.mcp.json"), r#"{"mcpServers":{"listed":{"command":"y","description":"d"}}}"#).unwrap();
    let mut app = App::connect(&env.dir.join("m.sock"));
    let r = app.rpc("resources.list", json!({})).unwrap();
    assert!(r["skills"].as_array().unwrap().iter().any(|s| s["name"] == "alpha"), "{r}");
    assert!(r["agents"].as_array().unwrap().iter().any(|s| s["name"] == "helper"), "{r}");
    assert!(r["mcps"].as_array().unwrap().iter().any(|m| m["name"] == "listed" && m["command"] == "y" && m["agent"] == "claude"));

    app.rpc("resources.install_mcp", json!({"name": "files", "command": "npx", "args": ["-y", "srv"]})).unwrap();
    let cfg: Value = serde_json::from_str(&std::fs::read_to_string(env.home.join(".claude.json")).unwrap()).unwrap();
    assert_eq!(cfg["theme"], "dark", "other keys survive");
    assert_eq!(cfg["mcpServers"]["files"]["command"], "npx");
    assert_eq!(cfg["mcpServers"]["files"]["args"], json!(["-y", "srv"]));
    assert!(cfg["mcpServers"]["old"].is_object());
    // Bad names are refused, an unparseable config is never overwritten.
    assert!(app.rpc("resources.install_mcp", json!({"name": "", "command": "npx"})).is_err());
    std::fs::write(env.home.join(".claude.json"), "{ nope").unwrap();
    assert!(app.rpc("resources.install_mcp", json!({"name": "b", "command": "npx"})).is_err());
    assert_eq!(std::fs::read_to_string(env.home.join(".claude.json")).unwrap(), "{ nope");
}

#[test]
fn p7_install_skill_clones_into_the_temp_home_only() {
    let env = start("skill");
    let mut app = App::connect(&env.dir.join("m.sock"));
    for bad in [
        json!({"name": "s", "githubUrl": "file:///etc"}),
        json!({"name": "s", "githubUrl": "ext::sh -c id"}),
        json!({"name": "../s", "githubUrl": "https://github.com/a/b"}),
    ] {
        assert!(app.rpc("resources.install_skill", bad).is_err());
    }
    app.rpc("resources.install_skill", json!({"name": "nice", "githubUrl": "https://github.com/a/nice"})).unwrap();
    let log = std::fs::read_to_string(env.home.join("git.log")).unwrap();
    assert!(log.contains("clone --depth=1 -- https://github.com/a/nice"), "{log}");
    assert!(env.home.join(".claude/skills/nice/SKILL.md").is_file());
    let e = app.rpc("resources.install_skill", json!({"name": "nice", "githubUrl": "https://github.com/a/nice"})).unwrap_err();
    assert!(e.contains("already exists"), "{e}");
}

#[test]
fn p7_install_muya_plugin_uses_a_claude_that_knows_plugin() {
    let env = start("plugin");
    let mut app = App::connect(&env.dir.join("m.sock"));
    // The CLI first on PATH is old (no `plugin`); the installer must skip it and use the other.
    let r = app.rpc("resources.install_muya_plugin", json!({})).unwrap();
    assert_eq!(r, json!("muya-mcp plugin installed."));
    let log = std::fs::read_to_string(env.home.join("plugin.log")).unwrap();
    assert_eq!(log.lines().collect::<Vec<_>>(), ["plugin marketplace add st4unch/muya", "plugin install muya-mcp@muya"]);
    // "already added" is success (idempotent end state).
    std::fs::write(env.home.join("already"), "").unwrap();
    app.rpc("resources.install_muya_plugin", json!({})).unwrap();
}

#[test]
fn p7_install_muya_plugin_without_a_capable_claude_says_so() {
    // The resolver also tries the fixed Homebrew locations; a real CLI there would be used.
    if ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].iter().any(|p| Path::new(p).exists()) {
        eprintln!("skipped: a system claude exists");
        return;
    }
    let env = start("noplugin");
    std::fs::remove_file(env.home.join(".local/bin/claude")).unwrap();
    let mut app = App::connect(&env.dir.join("m.sock"));
    let e = app.rpc("resources.install_muya_plugin", json!({})).unwrap_err();
    assert!(e.contains("plugin support"), "{e}");
}

#[test]
fn p7_marketplaces_answer_with_the_right_shape_or_a_network_error() {
    let env = start("market");
    let mut app = App::connect(&env.dir.join("m.sock"));
    // Reaches the real services; offline it must be a clean error, never "unknown method".
    match app.rpc("resources.skills_market", json!({"query": "git"})) {
        Ok(v) => assert!(v.is_array()),
        Err(e) => assert!(!e.contains("unknown method"), "{e}"),
    }
    match app.rpc("resources.mcp_market", json!({"query": "git"})) {
        Ok(v) => assert!(v["items"].is_array() && v["openBrowser"].is_boolean(), "{v}"),
        Err(e) => assert!(!e.contains("unknown method"), "{e}"),
    }
}

#[test]
fn p7_spawned_terminals_get_their_own_history_and_a_status_capture_file() {
    let env = start("spawnenv");
    let mut app = App::connect(&env.dir.join("m.sock"));
    // A zsh gets a private history file (the term_history wrappers), listed by term_history.entries.
    app.send(Control::Spawn { argv: vec!["/bin/zsh".into(), "-i".into()], cwd: env.home.to_string_lossy().into(), env: vec![], cols: 80, rows: 24 });
    let zid = match app.read_control() {
        Control::Spawned { id, .. } => id,
        other => panic!("{other:?}"),
    };
    app.send(Control::Paste { id: zid, text: "echo p7-history-marker\n".into() });
    assert_eq!(app.read_control(), Control::Ok);
    wait_for("the typed command reaches the tab's history", || {
        app.rpc("term_history.entries", json!({})).ok().is_some_and(|l| l.to_string().contains("p7-history-marker"))
    });
    // Any shell gets MUYA_STATUS_FILE; statusline.session reads what the tap wrote there.
    app.send(Control::Spawn { argv: vec!["/bin/sh".into(), "-c".into(), "echo $MUYA_STATUS_FILE > $HOME/sf; sleep 20".into()], cwd: "/tmp".into(), env: vec![], cols: 80, rows: 24 });
    let sid = match app.read_control() {
        Control::Spawned { id, .. } => id,
        other => panic!("{other:?}"),
    };
    let sf = env.home.join("sf");
    wait_for("the status file name", || std::fs::read_to_string(&sf).is_ok_and(|s| s.trim().ends_with(".json")));
    let file = std::fs::read_to_string(&sf).unwrap().trim().to_string();
    assert!(file.contains("/muya-status-"), "{file}");
    assert_eq!(app.rpc("statusline.session", json!({"sid": sid})).unwrap(), Value::Null, "nothing written yet");
    std::fs::write(&file, r#"{"model":{"display_name":"Sonnet"}}"#).unwrap();
    assert_eq!(app.rpc("statusline.session", json!({"sid": sid})).unwrap()["model"]["display_name"], "Sonnet");
    assert_eq!(app.rpc("statusline.session", json!({"sid": 999_999})).unwrap(), Value::Null);
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

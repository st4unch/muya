//! PRD AC12 (daemon side): permission prompts with no app attached. A fake claude prints real
//! corpus screens into a real PTY (via ptyd); muyad notifies right away, auto-allows after 2 s
//! exactly once when the setting is on and the layout is known, never answers an unknown layout,
//! and stays silent while an app is attached.
//! Needs the ptyd binary: `cargo build --workspace`.

use muya_proto::{Control, Frame, Role};
use muyad::prompt_watch::{Notifier, PromptConfig, AUTO_ALLOW_DELAY};
use muyad::Muyad;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Default)]
struct Recorder(Mutex<Vec<(u64, String, Instant)>>);
impl Notifier for Recorder {
    fn notify(&self, session: u64, _title: &str, body: &str) {
        self.0
            .lock()
            .unwrap()
            .push((session, body.to_owned(), Instant::now()));
    }
}

struct Rig {
    dir: PathBuf,
    _ptyd: Child,
    muyad: Arc<Muyad>,
    rec: Arc<Recorder>,
}
impl Drop for Rig {
    fn drop(&mut self) {
        // ptyd is not killed here: muyad exits the process when its ptyd link closes. ptyd ends
        // with this test process (MUYA_PTYD_EXIT_WITH_PARENT).
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn corpus(name: &str) -> String {
    let p = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../corpus/claude-screens")
        .join(name);
    std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

fn rig(tag: &str, auto_allow: bool) -> Rig {
    rig_with(tag, auto_allow, true)
}

fn rig_with(tag: &str, auto_allow: bool, watch: bool) -> Rig {
    let ptyd_bin = Path::new(env!("CARGO_BIN_EXE_muyad")).with_file_name("muya-ptyd");
    assert!(ptyd_bin.exists(), "cargo build --workspace first");
    let dir = PathBuf::from(format!("/tmp/muya-ac12-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let sock = dir.join("p.sock");
    let ptyd = Command::new(ptyd_bin)
        .env("MUYA_PTYD_EXIT_WITH_PARENT", "1")
        .arg("--socket")
        .arg(&sock)
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let muyad = loop {
        match Muyad::connect(&sock, "ac12") {
            Ok(m) => break m,
            Err(_) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            Err(e) => panic!("ptyd never answered: {e}"),
        }
    };
    let prefs = dir.join("prefs.json");
    std::fs::write(&prefs, format!(r#"{{"autoApprove": {auto_allow}}}"#)).unwrap();
    let rec = Arc::new(Recorder::default());
    muyad.enable_prompt_watch(PromptConfig {
        notifier: rec.clone(),
        prefs_path: Some(prefs),
        delay: AUTO_ALLOW_DELAY,
    });
    Rig {
        dir,
        _ptyd: ptyd,
        muyad,
        rec,
    }
}

/// Starts a "claude" that shows `screen` and records every key it receives in `answers`.
fn show(rig: &Rig, screen: &str) -> (u64, Instant, PathBuf) {
    let screen_file = rig
        .dir
        .join(format!("screen-{}.txt", rig.muyad.sessions().len()));
    std::fs::write(&screen_file, screen).unwrap();
    let answers = rig
        .dir
        .join(format!("answers-{}", rig.muyad.sessions().len()));
    // $(cat) drops the final newline, so the 40th row does not scroll the screen.
    let script = format!(
        r#"printf '\033[2J\033[H'; printf %s "$(cat '{}')"; while IFS= read -r -n1 k; do printf %s "$k" >> '{}'; done"#,
        screen_file.display(),
        answers.display()
    );
    let t0 = Instant::now();
    let (id, _) = rig
        .muyad
        .spawn(
            vec!["/bin/bash".into(), "-c".into(), script],
            "/tmp".into(),
            vec![],
            120,
            40,
        )
        .unwrap();
    (id, t0, answers)
}

fn answered(p: &Path) -> String {
    std::fs::read_to_string(p).unwrap_or_default()
}

fn wait_notified(rig: &Rig, n: usize, within: Duration) -> bool {
    let end = Instant::now() + within;
    while Instant::now() < end {
        if rig.rec.0.lock().unwrap().len() >= n {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

#[test]
fn notifies_within_2s_and_auto_allows_once_after_2s_for_known_layouts() {
    let rig = rig("known", true);
    // Every tool kind in the corpus: Bash, Edit, Write, MCP ("Tool use").
    for name in ["bash", "edit", "write", "mcp"] {
        let n_before = rig.rec.0.lock().unwrap().len();
        let (id, t0, ans) = show(&rig, &corpus(&format!("{name}-v2.1.317-w120-dialog.txt")));
        assert!(
            wait_notified(&rig, n_before + 1, Duration::from_secs(2)),
            "{name}: no notification within 2 s"
        );
        let (sid, body, at) = rig.rec.0.lock().unwrap()[n_before].clone();
        let latency = at.duration_since(t0);
        eprintln!("{name}: notified after {latency:?}: {body}");
        assert_eq!(sid, id);
        assert!(
            latency < Duration::from_secs(2),
            "{name}: notification took {latency:?}"
        );
        assert!(body.contains("permission"), "{body}");
        // Not before 2 s since the prompt appeared...
        std::thread::sleep(Duration::from_millis(1200));
        assert_eq!(
            answered(&ans),
            "",
            "{name}: answered too early (after {:?})",
            t0.elapsed()
        );
        // ...then the Allow key, exactly once, and not again while the dialog stays up.
        let end = Instant::now() + Duration::from_secs(3);
        while answered(&ans).is_empty() && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(20));
        }
        let at = t0.elapsed();
        assert_eq!(answered(&ans), "1", "{name}: expected the Allow key");
        assert!(
            at >= Duration::from_millis(1900),
            "{name}: answered after {at:?}"
        );
        std::thread::sleep(Duration::from_secs(3));
        assert_eq!(answered(&ans), "1", "{name}: answered more than once");
        assert_eq!(
            rig.rec.0.lock().unwrap().len(),
            n_before + 1,
            "{name}: notified more than once"
        );
    }
}

#[test]
fn without_auto_allow_it_only_notifies() {
    let rig = rig("off", false);
    let (_, _, ans) = show(&rig, &corpus("bash-v2.1.317-w120-dialog.txt"));
    assert!(wait_notified(&rig, 1, Duration::from_secs(2)));
    std::thread::sleep(Duration::from_secs(3));
    assert_eq!(
        answered(&ans),
        "",
        "auto-allow is off, nothing may be typed"
    );
}

#[test]
fn an_unknown_layout_is_never_answered() {
    let rig = rig("unknown", true);
    // (a) the last option is not a "No": the parser refuses the dialog altogether.
    let a = corpus("bash-v2.1.317-w120-dialog.txt")
        .replace("4. No", "4. Maybe")
        .replace("3. No", "3. Maybe");
    assert_ne!(a, corpus("bash-v2.1.317-w120-dialog.txt"));
    let (_, _, ans_a) = show(&rig, &a);
    // (b) a dialog the parser reads but whose tool is not in the corpus.
    let b = corpus("mcp-v2.1.317-w120-dialog.txt").replace("Tool use", "Format disk");
    assert_ne!(b, corpus("mcp-v2.1.317-w120-dialog.txt"));
    let (_, _, ans_b) = show(&rig, &b);
    // (c) a dialog that does not start with "Do you want to".
    let c = corpus("bash-v2.1.317-w120-dialog.txt")
        .replace("Do you want to proceed?", "Ready to proceed?");
    let (_, _, ans_c) = show(&rig, &c);
    std::thread::sleep(Duration::from_secs(4));
    for (n, p) in [("a", &ans_a), ("b", &ans_b), ("c", &ans_c)] {
        assert_eq!(answered(p), "", "unknown layout {n} was answered");
    }
}

#[test]
fn with_an_app_attached_the_daemon_stays_silent() {
    let rig = rig("app", true);
    let (mine, theirs) = UnixStream::pair().unwrap();
    let m = rig.muyad.clone();
    std::thread::spawn(move || m.serve(theirs));
    let mut app = mine;
    app.write_all(&Frame::Control(muya_proto::hello(Role::App, "ac12")).encode())
        .unwrap();
    app.write_all(&Frame::Control(Control::List).encode())
        .unwrap();
    std::thread::sleep(Duration::from_millis(300)); // the hello is registered
    let (_, _, ans) = show(&rig, &corpus("bash-v2.1.317-w120-dialog.txt"));
    std::thread::sleep(Duration::from_secs(4));
    assert!(
        rig.rec.0.lock().unwrap().is_empty(),
        "no notification while the app is attached"
    );
    assert_eq!(answered(&ans), "", "no answer while the app is attached");
}

fn cpu_seconds() -> f64 {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    let tv = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    tv(ru.ru_utime) + tv(ru.ru_stime)
}

/// 25 idle Claude screens, 10 s each way: the prompt watcher must not add measurable CPU.
/// (CPU of this process = every muyad actor; ptyd is a separate process and unchanged.)
#[test]
fn the_prompt_watcher_adds_no_measurable_cpu_with_25_idle_sessions() {
    let mut per_core = Vec::new();
    for watch in [false, true] {
        let rig = rig_with(if watch { "cpu-on" } else { "cpu-off" }, true, watch);
        let idle = corpus("acceptedits-v2.1.317-w120-idle.txt");
        for _ in 0..25 {
            show(&rig, &idle);
        }
        std::thread::sleep(Duration::from_secs(3)); // screens parsed, settled
        let (c0, t0) = (cpu_seconds(), Instant::now());
        std::thread::sleep(Duration::from_secs(10));
        let used = (cpu_seconds() - c0) / t0.elapsed().as_secs_f64() * 100.0;
        eprintln!("watch={watch}: {used:.3} % of one core over 10 s, 25 idle sessions");
        per_core.push(used);
    }
    assert!(per_core[1] - per_core[0] < 0.5, "watcher adds {:.3} % CPU", per_core[1] - per_core[0]);
}

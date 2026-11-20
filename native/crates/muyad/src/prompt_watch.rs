//! Permission prompts while no app is attached (PRD AC12): a macOS notification right away, and
//! — with "Auto-allow permission prompts" on — the Allow key after 2 s, once per prompt, only for
//! dialog layouts the parser knows.
//!
//! No timers or polling: the watcher is a screen-only sink on every session's actor, so it runs
//! only when the screen state *changes* (the actor already parses it, at most every 100 ms, and
//! only while output arrives). A pending auto-answer is one sleeping thread per prompt.
//! While an app is attached the app does all of this itself (Model.evaluateAutoAllow); the daemon
//! stays silent so a prompt is never answered twice.

use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How long a prompt waits before auto-allow answers it (same as the app).
pub const AUTO_ALLOW_DELAY: Duration = Duration::from_secs(2);

/// Tools whose dialog layout is in the AC3 corpus; anything else is never answered by the daemon.
/// ("Tool use" is the MCP / generic tool dialog. An empty tool means the dialog's title was not
/// found, i.e. a layout the parser only half understands.)
const KNOWN_TOOLS: &[&str] = &["Bash", "Write", "Edit", "Read", "Tool use"];

/// Shows the operator that a session is waiting for permission.
pub trait Notifier: Send + Sync {
    fn notify(&self, session: u64, title: &str, body: &str);
}

/// `osascript display notification`: the last resort, for a Muya.app without its notifier helper (a bare dev build).
/// Works from a LaunchAgent binary (no bundle identity needed, ~0.1 s, measured on macOS 26), but the banner shows the
/// Script Editor icon and a click opens nothing. The text goes in as argv, never spliced into the script.
pub struct OsascriptNotifier {
    program: PathBuf,
}

impl Default for OsascriptNotifier {
    /// `MUYA_OSASCRIPT=<program>` replaces `/usr/bin/osascript` (tests).
    fn default() -> Self {
        Self {
            program: std::env::var_os("MUYA_OSASCRIPT")
                .map_or_else(|| PathBuf::from("/usr/bin/osascript"), PathBuf::from),
        }
    }
}

impl Notifier for OsascriptNotifier {
    fn notify(&self, _session: u64, title: &str, body: &str) {
        let _ = Command::new(&self.program)
            .args([
                "-e",
                "on run argv",
                "-e",
                "display notification (item 1 of argv) with title (item 2 of argv)",
                "-e",
                "end run",
                "--",
                body,
                title,
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

/// How the notifier helper (`Muya.app/Contents/Helpers/MuyaNotifier.app`) ended. Its exit status is the contract:
/// 0 posted, 2 the operator denied notifications for Muya, 3 permission not granted yet and not asked now.
#[derive(Debug, PartialEq, Eq)]
pub enum HelperOutcome {
    /// The notification is on screen.
    Posted,
    /// The operator said no (or has not said yes): showing the same text some other way would go around that choice.
    Declined,
    /// The helper could not run or failed: worth trying the next notifier.
    Failed,
}

pub fn classify_helper_exit(code: Option<i32>) -> HelperOutcome {
    match code {
        Some(0) => HelperOutcome::Posted,
        Some(2 | 3) => HelperOutcome::Declined,
        _ => HelperOutcome::Failed,
    }
}

/// The helper's executable next to this binary: `<Muya.app>/Contents/MacOS/muyad` -> `Contents/Helpers/MuyaNotifier.app`.
/// `MUYA_NOTIFIER_APP=<path to a MuyaNotifier.app>` overrides it (tests, dev stacks).
pub fn helper_executable(exe: &std::path::Path) -> Option<PathBuf> {
    let app = match std::env::var_os("MUYA_NOTIFIER_APP") {
        Some(p) => PathBuf::from(p),
        None => exe.parent()?.parent()?.join("Helpers/MuyaNotifier.app"),
    };
    let bin = app.join("Contents/MacOS/MuyaNotifier");
    bin.is_file().then_some(bin)
}

/// How long a first-ever notification may wait for the operator to answer macOS' permission dialog.
const HELPER_PATIENCE: Duration = Duration::from_secs(120);

/// Notifications with Muya's own icon through the helper app (it posts via `UNUserNotificationCenter`; clicking one opens
/// Muya). `osascript` only when the helper is absent or broke, never after the operator declined.
pub struct HelperNotifier {
    helper: Option<PathBuf>,
    fallback: Arc<dyn Notifier>,
}

impl HelperNotifier {
    pub fn new(helper: Option<PathBuf>, fallback: Arc<dyn Notifier>) -> Self {
        Self { helper, fallback }
    }

    /// The helper next to the running executable (if there is one), osascript behind it.
    pub fn detect() -> Self {
        let helper = std::env::current_exe()
            .ok()
            .and_then(|exe| helper_executable(&exe));
        Self::new(helper, Arc::new(OsascriptNotifier::default()))
    }

    fn run_helper(
        helper: &std::path::Path,
        session: u64,
        title: &str,
        body: &str,
    ) -> HelperOutcome {
        let spawned = Command::new(helper)
            .args([
                "--title",
                title,
                "--body",
                body,
                "--session",
                &session.to_string(),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        let Ok(mut child) = spawned else {
            return HelperOutcome::Failed;
        };
        let deadline = std::time::Instant::now() + HELPER_PATIENCE;
        loop {
            match child.try_wait() {
                Ok(Some(status)) => return classify_helper_exit(status.code()),
                Ok(None) if std::time::Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(50))
                }
                // Still waiting on the permission dialog: leave it, and do not show the text a second time.
                Ok(None) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return HelperOutcome::Declined;
                }
                Err(_) => return HelperOutcome::Failed,
            }
        }
    }
}

impl Notifier for HelperNotifier {
    fn notify(&self, session: u64, title: &str, body: &str) {
        if let Some(helper) = &self.helper {
            if Self::run_helper(helper, session, title, body) != HelperOutcome::Failed {
                return;
            }
        }
        self.fallback.notify(session, title, body);
    }
}
pub struct PromptConfig {
    pub notifier: Arc<dyn Notifier>,
    /// The app's `prefs.json` (key `autoApprove`). `None` = auto-allow off.
    pub prefs_path: Option<PathBuf>,
    pub delay: Duration,
}

impl PromptConfig {
    /// Notifications via the helper app (osascript behind it); prefs under `<home>/Library/Application Support/MuyaNative`.
    pub fn default_for(home: &std::path::Path) -> Self {
        Self {
            notifier: Arc::new(HelperNotifier::detect()),
            prefs_path: Some(home.join("Library/Application Support/MuyaNative/prefs.json")),
            delay: AUTO_ALLOW_DELAY,
        }
    }
}

struct Seen {
    key: String,
    answered: bool,
}

pub struct PromptWatch {
    cfg: PromptConfig,
    seen: Mutex<HashMap<u64, Seen>>,
    /// Types bytes into a session.
    answer: Box<dyn Fn(u64, Vec<u8>) + Send + Sync>,
    /// Whether an app client is attached right now.
    app_attached: Box<dyn Fn() -> bool + Send + Sync>,
}

impl PromptWatch {
    pub fn new(
        cfg: PromptConfig,
        answer: impl Fn(u64, Vec<u8>) + Send + Sync + 'static,
        app_attached: impl Fn() -> bool + Send + Sync + 'static,
    ) -> Arc<Self> {
        Arc::new(Self {
            cfg,
            seen: Mutex::default(),
            answer: Box::new(answer),
            app_attached: Box::new(app_attached),
        })
    }

    fn auto_allow_on(&self) -> bool {
        let Some(p) = &self.cfg.prefs_path else {
            return false;
        };
        std::fs::read_to_string(p)
            .ok()
            .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .and_then(|v| v.get("autoApprove").and_then(Value::as_bool))
            .unwrap_or(false)
    }

    /// A session's screen state changed (the JSON `muya_core::screen` produces).
    pub fn screen(self: &Arc<Self>, session: u64, state: &str) {
        let permission = serde_json::from_str::<Value>(state)
            .ok()
            .and_then(|v| v.get("permission").cloned())
            .filter(|p| p.is_object());
        let Some(p) = permission else {
            self.seen.lock().unwrap().remove(&session);
            return;
        };
        let text = |k: &str| p.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
        let (tool, target, question) = (text("tool"), text("target"), text("question"));
        let key = format!("{tool}|{target}|{question}");
        {
            let mut seen = self.seen.lock().unwrap();
            if seen.get(&session).is_some_and(|s| s.key == key) {
                return; // same prompt, already handled
            }
            seen.insert(
                session,
                Seen {
                    key: key.clone(),
                    answered: false,
                },
            );
        }
        if (self.app_attached)() {
            return; // the app notifies and auto-allows itself
        }

        let me = self.clone();
        let (t, tg) = (tool.clone(), target.clone());
        std::thread::spawn(move || {
            let what = if t.is_empty() || t == "Tool use" { "a tool".to_owned() } else { t };
            let mut body = format!("Claude is asking permission to use {what}");
            if !tg.is_empty() {
                body.push_str(": ");
                body.extend(tg.chars().take(80));
            }
            me.cfg
                .notifier
                .notify(session, "Muya: permission needed", &body);
        });

        // Answer only layouts the parser and the corpus know: a known tool, an "Allow" option
        // that is key 1, and the "Do you want to …?" question.
        let approve = p
            .get("options")
            .and_then(Value::as_array)
            .and_then(|o| o.first())
            .filter(|o| o.get("kind").and_then(Value::as_str) == Some("approve"))
            .and_then(|o| o.get("key").and_then(Value::as_str))
            .map(str::to_owned);
        let known = KNOWN_TOOLS.contains(&tool.as_str()) && question.starts_with("Do you want to ");
        let Some(approve) = approve.filter(|_| known) else {
            return;
        };
        if !self.auto_allow_on() {
            return;
        }
        let me = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(me.cfg.delay);
            // Still the same unanswered prompt, nobody (app) took over, setting still on?
            if (me.app_attached)() || !me.auto_allow_on() {
                return;
            }
            {
                let mut seen = me.seen.lock().unwrap();
                match seen.get_mut(&session) {
                    Some(s) if s.key == key && !s.answered => s.answered = true,
                    _ => return,
                }
            }
            (me.answer)(session, approve.into_bytes());
        });
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[derive(Default)]
    struct Recorder(Mutex<Vec<String>>);
    impl Notifier for Recorder {
        fn notify(&self, _session: u64, title: &str, body: &str) {
            self.0.lock().unwrap().push(format!("{title}|{body}"));
        }
    }

    /// A stand-in helper: writes its argv to `<dir>/argv` and exits with `code`.
    fn fake_helper(dir: &std::path::Path, code: i32) -> PathBuf {
        let bin = dir.join(format!("helper{code}"));
        let script = format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"{}/argv\"\nexit {code}\n",
            dir.display()
        );
        std::fs::write(&bin, script).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        bin
    }

    fn scratch(tag: &str) -> PathBuf {
        let d = PathBuf::from(format!("/tmp/muya-notifier-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn helper_exit_codes_map_to_outcomes() {
        assert_eq!(classify_helper_exit(Some(0)), HelperOutcome::Posted);
        assert_eq!(classify_helper_exit(Some(2)), HelperOutcome::Declined);
        assert_eq!(classify_helper_exit(Some(3)), HelperOutcome::Declined);
        assert_eq!(classify_helper_exit(Some(1)), HelperOutcome::Failed);
        assert_eq!(
            classify_helper_exit(None),
            HelperOutcome::Failed,
            "killed by a signal"
        );
    }

    #[test]
    fn helper_that_posts_means_no_osascript_and_gets_the_text_as_argv() {
        let dir = scratch("ok");
        let rec = Arc::new(Recorder::default());
        HelperNotifier::new(Some(fake_helper(&dir, 0)), rec.clone()).notify(
            7,
            "T",
            "a; echo `x` $(y)",
        );
        assert!(rec.0.lock().unwrap().is_empty());
        let argv = std::fs::read_to_string(dir.join("argv")).unwrap();
        assert_eq!(argv, "--title\nT\n--body\na; echo `x` $(y)\n--session\n7\n");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn denied_notifications_are_not_worked_around_with_osascript() {
        let dir = scratch("denied");
        for code in [2, 3] {
            let rec = Arc::new(Recorder::default());
            HelperNotifier::new(Some(fake_helper(&dir, code)), rec.clone()).notify(1, "T", "B");
            assert!(rec.0.lock().unwrap().is_empty(), "exit {code}");
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_broken_or_missing_helper_falls_back() {
        let dir = scratch("broken");
        let rec = Arc::new(Recorder::default());
        HelperNotifier::new(Some(fake_helper(&dir, 1)), rec.clone()).notify(1, "T", "B");
        HelperNotifier::new(Some(dir.join("does-not-exist")), rec.clone()).notify(2, "T2", "B2");
        HelperNotifier::new(None, rec.clone()).notify(3, "T3", "B3");
        assert_eq!(*rec.0.lock().unwrap(), vec!["T|B", "T2|B2", "T3|B3"]);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn helper_is_found_inside_the_bundle() {
        let dir = scratch("bundle");
        let bin =
            dir.join("Muya.app/Contents/Helpers/MuyaNotifier.app/Contents/MacOS/MuyaNotifier");
        std::fs::create_dir_all(bin.parent().unwrap()).unwrap();
        let exe = dir.join("Muya.app/Contents/MacOS/muyad");
        assert_eq!(helper_executable(&exe), None, "no helper yet");
        std::fs::write(&bin, "x").unwrap();
        assert_eq!(helper_executable(&exe), Some(bin));
        let _ = std::fs::remove_dir_all(dir);
    }
}

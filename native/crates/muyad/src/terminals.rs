//! The terminal tools of the MCP broker (`open_terminal`, `send_terminal`, `broadcast`;
//! docs/prd-native-mcp-terminal.md): list the PTY sessions with a name and kind, open a shell tab, and
//! type into one. The broker (`muya_core::broker`) does the target choice, the caps and the skipping;
//! this is only what needs muyad's sessions.

use crate::Muyad;
use crate::actor::Cmd;
use muya_core::broker::TerminalInfo;
use std::sync::Arc;
use std::time::Duration;

/// Size a broker-opened shell starts with; the app resizes it to its view when it shows the tab.
const COLS: u16 = 120;
const ROWS: u16 = 30;

impl Muyad {
    /// Every running session as the broker sees it: the name `open_terminal` gave, else the Claude
    /// session's own name, else the folder; "claude" when a Claude conversation runs in it.
    pub fn terminals(&self) -> Result<Vec<TerminalInfo>, String> {
        let infos: Vec<_> = self.sessions().into_iter().filter(|i| i.exited.is_none()).collect();
        // `claude agents` is missing on a machine without Claude: shells then still work.
        let agents = muya_core::agents::list_agent_sessions_fresh(None).unwrap_or_default();
        let mut out = Vec::new();
        for info in infos {
            // A process belongs to the session whose leader is its session id, however deep a shell started it.
            let agent = agents.iter().find(|a| {
                a.agent == "claude"
                    && !a.id.is_empty()
                    && a.parent_id.is_none()
                    && a.pid.and_then(|p| i32::try_from(p).ok()).is_some_and(|p| {
                        let sid = unsafe { libc::getsid(p) };
                        sid > 0 && sid == info.pid
                    })
            });
            let screen: Option<serde_json::Value> = self
                .ask(info.id, |reply| Cmd::Screen { reply })
                .and_then(|s| serde_json::from_str(&s).ok());
            let prompt = screen.as_ref().is_some_and(|s| !s["permission"].is_null());
            let waiting_for = if prompt {
                Some("permission prompt".to_string())
            } else {
                agent.and_then(|a| a.waiting_for.clone())
            };
            let cwd = if info.cwd.is_empty() { agent.map(|a| a.worktree.clone()).unwrap_or_default() } else { info.cwd.clone() };
            let named = self.term_names.lock().unwrap().get(&info.id).cloned();
            let name = named
                .or_else(|| agent.map(|a| a.name.clone()).filter(|n| !n.is_empty()))
                .unwrap_or_else(|| std::path::Path::new(&cwd).file_name().map_or_else(|| format!("terminal-{}", info.id), |f| f.to_string_lossy().into_owned()));
            out.push(TerminalInfo {
                id: info.id,
                name,
                cwd,
                kind: if agent.is_some() { "claude" } else { "shell" }.into(),
                claude_session_id: agent.map(|a| a.id.clone()),
                waiting_for,
            });
        }
        Ok(out)
    }

    /// Starts a shell session named `name` in `cwd` (the home folder when None), tells the attached apps so the tab appears,
    /// then types `command` + Enter when given. Works with no app attached: the app adopts the session when it connects.
    pub fn open_terminal(self: &Arc<Self>, name: &str, cwd: Option<&str>, command: Option<&str>) -> Result<u64, String> {
        let cwd = match cwd {
            Some(c) => c.to_string(),
            None => std::env::var("HOME").map_err(|_| "HOME is not set".to_string())?,
        };
        let (id, pid) = self.spawn(vec![], cwd.clone(), vec![], COLS, ROWS).map_err(|e| e.to_string())?;
        self.term_names.lock().unwrap().insert(id, name.to_string());
        let _ = self.emit_event(
            "muya://terminal-opened",
            &serde_json::json!({ "id": id, "pid": pid, "name": name, "cwd": cwd, "cols": COLS, "rows": ROWS }),
        );
        if let Some(c) = command {
            self.type_text(id, c, true, false)?;
        }
        Ok(id)
    }

    /// Types `text` into session `id` as a paste (control bytes neutralised, bracketed when the program asked for it), then
    /// Enter as its own key press. `agent`: wait a beat between the two, as a TUI takes a fast Enter for part of the paste.
    pub fn type_text(&self, id: u64, text: &str, enter: bool, agent: bool) -> Result<(), String> {
        match self.sessions.lock().unwrap().get(&id).map(|e| e.info.exited) {
            Some(None) => {}
            Some(Some(_)) => return Err(format!("terminal {id} has exited")),
            None => return Err(format!("no terminal {id}")),
        }
        let paste = self.ask(id, |reply| Cmd::Paste { text: text.to_string(), reply }).ok_or_else(|| format!("terminal {id} did not answer"))?;
        self.send_input(id, paste);
        if enter {
            if agent {
                std::thread::sleep(Duration::from_millis(150));
            }
            let key = self
                .ask(id, |reply| Cmd::Key { key: "enter".into(), mods: 0, text: None, reply })
                .ok_or_else(|| format!("terminal {id} did not answer"))?;
            self.send_input(id, key);
        }
        Ok(())
    }

    /// The visible screen lines of session `id`.
    pub fn screen_lines(&self, id: u64) -> Option<Vec<String>> {
        self.ask(id, |reply| Cmd::Lines { reply })
    }

    /// Whether the PTY of session `id` echoes typed characters (read from its termios, not the screen).
    pub fn pty_echo(&self, id: u64) -> Option<bool> {
        let pid = self.sessions.lock().unwrap().get(&id).filter(|e| e.info.exited.is_none()).map(|e| e.info.pid)?;
        muya_core::pty_state::echo_enabled(pid)
    }

    /// Sends `text` to session `id` byte for byte: Enter is `"\r"`, nothing is bracketed or neutralised.
    pub fn type_raw(&self, id: u64, text: &str) -> Result<(), String> {
        match self.sessions.lock().unwrap().get(&id).map(|e| e.info.exited) {
            Some(None) => {}
            Some(Some(_)) => return Err(format!("terminal {id} has exited")),
            None => return Err(format!("no terminal {id}")),
        }
        self.send_input(id, text.as_bytes().to_vec());
        Ok(())
    }
}

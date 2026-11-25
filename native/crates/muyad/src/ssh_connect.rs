//! Connect from the SSH page / the agent's `ssh_open`: the daemon spawns the `ssh` process itself as a terminal session and
//! injects the stored or CyberArk password into it. Same policy as classic `ssh::ssh_pty_connect` + `pty::spawn_process`
//! (and `muya_core::agent_ssh`): an ordinary password prompt is answered once, a PSMP typed challenge (OTP / RADIUS
//! passcode) is withheld so the person types it. The secret never leaves this process: it is not in argv, in an rpc
//! reply, in an event or in a log line.

use crate::actor::{Cmd, Sink};
use crate::Muyad;
use muya_core::{credstore, cyberark, inject, ssh};
use muya_proto::{Control, Frame};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};
use zeroize::Zeroizing;

const COLS: u16 = 120;
const ROWS: u16 = 30;

/// Sink keys of injectors live far above the app's connection keys.
static NEXT_KEY: AtomicUsize = AtomicUsize::new(usize::MAX - 1_000_000);

/// What an injector does with the output of a session (pure, so it is unit-tested without a PTY).
pub struct Injector {
    tail: String,
    is_psmp: bool,
    done: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Step {
    /// Nothing to do yet.
    Wait,
    /// Write the secret and a newline.
    Answer,
    /// A typed challenge: do not answer, stop watching (the person types it).
    Withhold,
}

impl Injector {
    pub fn new(is_psmp: bool) -> Self {
        Self {
            tail: String::new(),
            is_psmp,
            done: false,
        }
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Step {
        if self.done {
            return Step::Wait;
        }
        self.tail.push_str(&String::from_utf8_lossy(bytes));
        inject::trim_prompt_tail(&mut self.tail, 512);
        if self.is_psmp && inject::looks_like_challenge_prompt(&self.tail) {
            self.done = true;
            Step::Withhold
        } else if inject::looks_like_password_prompt(&self.tail) {
            self.done = true;
            Step::Answer
        } else {
            Step::Wait
        }
    }

    pub fn finished(&self) -> bool {
        self.done
    }
}

/// The secret a server's credential source names: `local` = the Password Store (by name or id), `cyberark` = fetched now,
/// `prompt` = none (the person types it). Error texts are classic's.
pub async fn resolve_secret(
    vault: &credstore::CredStore,
    cyber: &cyberark::CyberarkState,
    server: &ssh::Server,
) -> Result<Option<Zeroizing<String>>, String> {
    match server.credential_source.kind.as_str() {
        "local" => {
            let reference = server.credential_source.local_cred_id.as_deref().ok_or(
                "credential source is 'Local password store' but no credential is selected",
            )?;
            credstore::secret_for_ref(vault, reference).map(Some)
        }
        "cyberark" => {
            let acct = server
                .credential_source
                .cyberark_account_id
                .as_deref()
                .ok_or("credential source is 'CyberArk account' but no account is selected")?;
            cyberark::fetch_password(cyber, acct).await.map(Some)
        }
        _ => Ok(None),
    }
}

/// The `ssh` binary to run: the system one by absolute path (the session's PATH is minimal).
fn program_path(program: &str) -> String {
    if program == "ssh" && std::path::Path::new("/usr/bin/ssh").exists() {
        "/usr/bin/ssh".into()
    } else {
        program.into()
    }
}

impl Muyad {
    /// Starts an `ssh` terminal for `server_id`, named after the server, tells the attached apps so the tab appears, and arms
    /// the password injection when the credential needs one. Returns the session id.
    pub fn ssh_connect(
        self: &Arc<Self>,
        server_id: &str,
        secret: Option<Zeroizing<String>>,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<u64, String> {
        let cfg = ssh::load_config()?;
        let server = cfg
            .servers
            .iter()
            .find(|s| s.id == server_id)
            .ok_or("server not found")?
            .clone();
        let psmp = server
            .psmp_profile_id
            .as_ref()
            .and_then(|pid| cfg.psmp_profiles.iter().find(|p| &p.id == pid));
        let cmd = ssh::build_connect_command(&server, psmp)?;
        let is_psmp = server.connection_type == "psmp";
        // Metadata only: no secret is in argv.
        muya_core::debuglog::log(&format!(
            "ssh connect: server={} type={} args={:?} cred_source={} injection_armed={}",
            server.label,
            server.connection_type,
            cmd.args,
            server.credential_source.kind,
            secret.is_some()
        ));
        let mut argv = vec![program_path(&cmd.program)];
        argv.extend(cmd.args);
        let (cols, rows) = (cols.unwrap_or(COLS), rows.unwrap_or(ROWS));
        let cwd = std::env::var("HOME").map_err(|_| "HOME is not set".to_string())?;
        let (id, pid) = self
            .spawn(argv, cwd.clone(), vec![], cols, rows)
            .map_err(|e| e.to_string())?;
        let name = if server.label.trim().is_empty() {
            server.host.clone()
        } else {
            server.label.clone()
        };
        self.term_names.lock().unwrap().insert(id, name.clone());
        if let Some(secret) = secret {
            self.arm_injection(id, secret, is_psmp);
        }
        let _ = self.emit_event("muya://terminal-opened", &serde_json::json!({ "id": id, "pid": pid, "name": name, "cwd": cwd, "cols": cols, "rows": rows }));
        Ok(id)
    }

    /// Watches the session's output (the snapshot first, then live output) and answers the first password prompt.
    fn arm_injection(self: &Arc<Self>, id: u64, secret: Zeroizing<String>, is_psmp: bool) {
        let Some(tx) = self.actor(id) else { return };
        let me: Weak<Muyad> = Arc::downgrade(self);
        let state = Mutex::new((Injector::new(is_psmp), Some(secret)));
        let sink: Sink = Arc::new(move |f: &Frame| match f {
            Frame::Output { data, .. } => {
                let mut g = state.lock().unwrap();
                match g.0.feed(data) {
                    Step::Answer => {
                        if let (Some(sec), Some(m)) = (g.1.take(), me.upgrade()) {
                            let mut bytes = Zeroizing::new(sec.as_bytes().to_vec());
                            bytes.push(b'\n');
                            m.send_input(id, bytes.to_vec());
                        }
                    }
                    Step::Withhold => {
                        g.1 = None;
                    }
                    Step::Wait => {}
                }
                !g.0.finished()
            }
            Frame::Control(Control::Exited { .. }) => false,
            _ => true,
        });
        let key = NEXT_KEY.fetch_add(1, Ordering::Relaxed);
        let (reply, _) = std::sync::mpsc::channel();
        let _ = tx.send(Cmd::Subscribe { key, sink, reply });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direct_answers_a_password_prompt_once() {
        let mut i = Injector::new(false);
        assert_eq!(i.feed(b"Welcome\r\n"), Step::Wait);
        assert_eq!(i.feed(b"dba@host's password: "), Step::Answer);
        assert_eq!(i.feed(b"password: "), Step::Wait);
        assert!(i.finished());
    }

    #[test]
    fn psmp_withholds_a_typed_challenge() {
        let mut i = Injector::new(true);
        assert_eq!(i.feed(b"Enter your RADIUS passcode: "), Step::Withhold);
        assert!(i.finished());
    }

    #[test]
    fn psmp_answers_the_vault_password() {
        let mut i = Injector::new(true);
        assert_eq!(i.feed(b"Vault Password: "), Step::Answer);
    }

    #[test]
    fn prompt_split_across_chunks_is_seen() {
        let mut i = Injector::new(false);
        assert_eq!(i.feed(b"u@h's pass"), Step::Wait);
        assert_eq!(i.feed(b"word: "), Step::Answer);
    }

    #[test]
    fn ssh_is_resolved_to_an_absolute_path() {
        assert!(program_path("ssh").ends_with("ssh"));
        assert_eq!(program_path("/x/y"), "/x/y");
    }
}

//! What a PTY is waiting for, as far as the secret gate needs to know: is the program at a password
//! prompt (terminal echo OFF, prompt line asks for a password) and which host does the prompt name?
//!
//! An operator's secret may be typed ONLY at such a prompt (see `broker::substitute_for`). The echo
//! flag is read from the PTY's termios (`tcgetattr` on the slave device), not guessed from the
//! screen: a shell at a normal prompt has echo ON, so `echo {{secret}}` can never be substituted.

/// A terminal as the secret gate sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptState {
    /// The terminal echoes typed characters (a normal shell/program). A password prompt has it off.
    pub echo_on: bool,
    /// The last non-empty line on the screen (the prompt line).
    pub line: String,
}

/// Terminal echo flag of the PTY that `pid` (a process attached to it) runs on. `None` when it
/// cannot be read: the gate then refuses.
pub fn echo_enabled(pid: i32) -> Option<bool> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let rc = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        )
    };
    if rc != size || info.e_tdev == 0 || info.e_tdev == u32::MAX {
        return None;
    }
    unsafe extern "C" {
        fn devname_r(
            dev: libc::dev_t,
            mode: libc::mode_t,
            buf: *mut libc::c_char,
            len: libc::c_int,
        ) -> *mut libc::c_char;
    }
    let mut buf = [0 as libc::c_char; 64];
    let name = unsafe {
        devname_r(
            info.e_tdev as libc::dev_t,
            libc::S_IFCHR,
            buf.as_mut_ptr(),
            buf.len() as libc::c_int,
        )
    };
    if name.is_null() {
        return None;
    }
    let name = unsafe { std::ffi::CStr::from_ptr(buf.as_ptr()) }
        .to_str()
        .ok()?
        .to_string();
    let path = std::ffi::CString::new(format!("/dev/{name}")).ok()?;
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_NOCTTY | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        return None;
    }
    let mut t: libc::termios = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::tcgetattr(fd, &mut t) } == 0;
    unsafe { libc::close(fd) };
    ok.then_some(t.c_lflag & libc::ECHO != 0)
}

/// The prompt line of a screen: the last line with text.
pub fn prompt_line(lines: &[String]) -> String {
    lines
        .iter()
        .rev()
        .map(|l| l.trim())
        .find(|l| !l.is_empty())
        .unwrap_or("")
        .to_string()
}

/// True when `line` asks for a password / passphrase (`user@host's password:`, `Enter passphrase for key:`).
pub fn is_password_prompt(line: &str) -> bool {
    let l = line.trim().to_ascii_lowercase();
    (l.contains("password") || l.contains("passphrase"))
        && (l.ends_with(':') || l.ends_with("]:") || l.ends_with('?'))
}

fn host_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_'
}

/// True when `line` names `host` as a whole host token (`10.0.0.5` does not match `10.0.0.55`).
pub fn line_names_host(line: &str, host: &str) -> bool {
    let (l, h) = (line.to_ascii_lowercase(), host.trim().to_ascii_lowercase());
    if h.is_empty() {
        return false;
    }
    let mut from = 0;
    while let Some(i) = l[from..].find(&h) {
        let (s, e) = (from + i, from + i + h.len());
        let before_ok = l[..s].chars().next_back().is_none_or(|c| !host_char(c));
        let after_ok = l[e..].chars().next().is_none_or(|c| !host_char(c));
        if before_ok && after_ok {
            return true;
        }
        from = s + 1;
    }
    false
}

/// Whether a secret may be typed into a terminal in `state`: echo off, a password prompt, and the
/// prompt names one of `known_hosts` (every configured server entry).
pub fn secret_gate(
    name: &str,
    state: Option<&PromptState>,
    known_hosts: &[String],
) -> Result<(), String> {
    let hosts = if known_hosts.is_empty() {
        "no configured server".to_string()
    } else {
        "a configured server".to_string()
    };
    let refuse = |why: &str| {
        Err(format!(
            "secret '{name}' can only be typed into a password prompt for {hosts} ({why}); it is never substituted into a shell, a command line or any other terminal state"
        ))
    };
    let Some(s) = state else {
        return refuse("this terminal's state could not be read");
    };
    if s.echo_on {
        return refuse("the terminal echoes input, so it is not at a password prompt");
    }
    if !is_password_prompt(&s.line) {
        return refuse("the screen does not end in a password prompt");
    }
    if !known_hosts.iter().any(|h| line_names_host(&s.line, h)) {
        return refuse("the prompt does not name a configured server host");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn st(echo_on: bool, line: &str) -> PromptState {
        PromptState {
            echo_on,
            line: line.into(),
        }
    }
    fn hosts() -> Vec<String> {
        vec!["10.0.0.5".to_string(), "db.corp.example".to_string()]
    }

    #[test]
    fn password_prompt_on_bound_host_with_echo_off_passes() {
        assert!(secret_gate(
            "s",
            Some(&st(false, "alice@10.0.0.5's password:")),
            &hosts()
        )
        .is_ok());
        assert!(secret_gate(
            "s",
            Some(&st(false, "Password: for alice@DB.corp.example:")),
            &hosts()
        )
        .is_ok());
    }

    #[test]
    fn echo_on_is_refused() {
        let e = secret_gate("s", Some(&st(true, "alice@10.0.0.5's password:")), &hosts())
            .unwrap_err();
        assert!(e.contains("echoes input"), "{e}");
        let e =
            secret_gate("s", Some(&st(true, "$ echo {{x}} | rev")), &hosts()).unwrap_err();
        assert!(e.contains("password prompt for"), "{e}");
    }

    #[test]
    fn wrong_host_prompt_is_refused() {
        let e = secret_gate(
            "s",
            Some(&st(false, "root@evil.example's password:")),
            &hosts(),
        )
        .unwrap_err();
        assert!(e.contains("does not name"), "{e}");
        // 10.0.0.5 must not match 10.0.0.55
        assert!(
            secret_gate("s", Some(&st(false, "a@10.0.0.55's password:")), &hosts())
                .is_err()
        );
        // a shell line that merely mentions the host is not a prompt
        assert!(secret_gate("s", Some(&st(false, "ssh a@10.0.0.5")), &hosts()).is_err());
    }

    #[test]
    fn unreadable_state_fails_closed() {
        assert!(secret_gate("s", None, &hosts()).is_err());
    }

    #[test]
    fn prompt_line_is_last_non_empty() {
        let l = vec![
            "a".to_string(),
            "pw:".to_string(),
            "  ".to_string(),
            "".to_string(),
        ];
        assert_eq!(prompt_line(&l), "pw:");
    }

    #[test]
    fn echo_flag_is_read_from_a_real_pty() {
        use std::os::fd::AsRawFd;
        let (mut master, mut slave) = (0, 0);
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            },
            0
        );
        // A child that owns the PTY as its controlling terminal, like a shell in a tab.
        let mut child = unsafe {
            use std::os::unix::process::CommandExt;
            let s = slave;
            std::process::Command::new("/bin/sleep")
                .arg("5")
                .pre_exec(move || {
                    libc::setsid();
                    libc::ioctl(s, libc::TIOCSCTTY as _, 0);
                    Ok(())
                })
                .spawn()
                .unwrap()
        };
        std::thread::sleep(std::time::Duration::from_millis(300));
        let pid = child.id() as i32;
        let mut t: libc::termios = unsafe { std::mem::zeroed() };
        unsafe { libc::tcgetattr(slave.as_raw_fd(), &mut t) };
        t.c_lflag |= libc::ECHO;
        unsafe { libc::tcsetattr(slave, libc::TCSANOW, &t) };
        assert_eq!(echo_enabled(pid), Some(true));
        t.c_lflag &= !libc::ECHO;
        unsafe { libc::tcsetattr(slave, libc::TCSANOW, &t) };
        assert_eq!(echo_enabled(pid), Some(false));
        let _ = child.kill();
        unsafe {
            libc::close(master);
            libc::close(slave);
        }
    }
}

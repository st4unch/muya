//! Safe child-process spawning for daemons (PRD AC22).
//!
//! `posix_spawn` with POSIX_SPAWN_CLOEXEC_DEFAULT: the child gets exactly the descriptors named in
//! `stdio` (as 0, 1, 2) and nothing else. A fork-based spawn lets descriptors created concurrently
//! by other threads (sockets, PTY masters) leak into the child, because on macOS FD_CLOEXEC is set
//! only after a descriptor exists. Signal dispositions are reset and the mask cleared, so an
//! ignored SIGPIPE in the daemon does not survive exec.

use std::ffi::CString;
use std::io;
use std::os::fd::RawFd;
use std::time::{Duration, Instant};

unsafe extern "C" {
    fn posix_spawn_file_actions_addchdir_np(
        actions: *mut libc::posix_spawn_file_actions_t,
        path: *const libc::c_char,
    ) -> libc::c_int;
    fn posix_spawn_file_actions_addinherit_np(
        actions: *mut libc::posix_spawn_file_actions_t,
        fd: libc::c_int,
    ) -> libc::c_int;
}

/// What a child sees as one of its standard descriptors.
#[derive(Clone, Copy, Debug)]
pub enum Stdio {
    /// `/dev/null`.
    Null,
    /// A copy of this parent descriptor.
    Fd(RawFd),
}

/// Starts `argv`. `argv[0]` is resolved against the parent's PATH by posix_spawnp (not the child's
/// `env`), so pass an absolute path when the two differ. Returns the pid.
/// `new_group` puts the child in its own process group (pgid = pid), so a timeout can stop the
/// whole tree with `kill(-pid)`.
pub fn spawn_cloexec(
    argv: &[String],
    cwd: Option<&str>,
    env: &[(String, String)],
    stdio: [Stdio; 3],
    new_group: bool,
) -> io::Result<i32> {
    let cstr = |s: &str| CString::new(s).map_err(|_| io::Error::other("NUL in argument"));
    if argv.is_empty() {
        return Err(io::Error::other("empty argv"));
    }
    let argv_c: Vec<CString> = argv.iter().map(|a| cstr(a)).collect::<io::Result<_>>()?;
    let env_c: Vec<CString> = env
        .iter()
        .map(|(k, v)| cstr(&format!("{k}={v}")))
        .collect::<io::Result<_>>()?;
    let mut argv_p: Vec<*mut libc::c_char> = argv_c.iter().map(|c| c.as_ptr() as *mut _).collect();
    argv_p.push(std::ptr::null_mut());
    let mut env_p: Vec<*mut libc::c_char> = env_c.iter().map(|c| c.as_ptr() as *mut _).collect();
    env_p.push(std::ptr::null_mut());
    let cwd_c = cwd.map(cstr).transpose()?;
    let devnull = cstr("/dev/null")?;
    // SAFETY: the attr/actions objects are initialised before use and destroyed on every path; all
    // pointers handed to posix_spawnp stay alive (argv_c/env_c/cwd_c/devnull) until it returns.
    unsafe {
        let mut attr: libc::posix_spawnattr_t = std::ptr::null_mut();
        let mut acts: libc::posix_spawn_file_actions_t = std::ptr::null_mut();
        libc::posix_spawnattr_init(&mut attr);
        libc::posix_spawn_file_actions_init(&mut acts);
        let mut flags = libc::POSIX_SPAWN_CLOEXEC_DEFAULT
            | libc::POSIX_SPAWN_SETSIGDEF
            | libc::POSIX_SPAWN_SETSIGMASK;
        if new_group {
            flags |= libc::POSIX_SPAWN_SETPGROUP;
            libc::posix_spawnattr_setpgroup(&mut attr, 0);
        }
        libc::posix_spawnattr_setflags(&mut attr, flags as libc::c_short);
        let mut all: libc::sigset_t = std::mem::zeroed();
        libc::sigfillset(&mut all);
        libc::posix_spawnattr_setsigdefault(&mut attr, &all);
        let mut none: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut none);
        libc::posix_spawnattr_setsigmask(&mut attr, &none);
        // Wire the standard descriptors. Sources are duplicated onto a high scratch range first,
        // so that a source which is itself 0/1/2 (a daemon with closed stdio) is not overwritten
        // by an earlier action.
        let mut scratch: Vec<RawFd> = Vec::new();
        let result = (|| -> io::Result<i32> {
            for (target, s) in stdio.iter().enumerate() {
                let target = target as libc::c_int;
                match *s {
                    Stdio::Null => {
                        let flag = if target == 0 {
                            libc::O_RDONLY
                        } else {
                            libc::O_WRONLY
                        };
                        libc::posix_spawn_file_actions_addopen(
                            &mut acts,
                            target,
                            devnull.as_ptr(),
                            flag,
                            0,
                        );
                    }
                    Stdio::Fd(src) => {
                        let hi = libc::fcntl(src, libc::F_DUPFD_CLOEXEC, 64);
                        if hi < 0 {
                            return Err(io::Error::last_os_error());
                        }
                        scratch.push(hi);
                        libc::posix_spawn_file_actions_adddup2(&mut acts, hi, target);
                    }
                }
            }
            if let Some(c) = &cwd_c {
                posix_spawn_file_actions_addchdir_np(&mut acts, c.as_ptr());
            }
            let _ = posix_spawn_file_actions_addinherit_np; // dup2 onto 0-2 already clears CLOEXEC
            let mut pid: libc::pid_t = 0;
            let rc = libc::posix_spawnp(
                &mut pid,
                argv_c[0].as_ptr(),
                &acts,
                &attr,
                argv_p.as_ptr(),
                env_p.as_ptr(),
            );
            if rc != 0 {
                return Err(io::Error::from_raw_os_error(rc));
            }
            Ok(pid)
        })();
        for fd in scratch {
            libc::close(fd);
        }
        libc::posix_spawn_file_actions_destroy(&mut acts);
        libc::posix_spawnattr_destroy(&mut attr);
        result
    }
}

/// A pipe whose both ends are close-on-exec: `(read, write)`.
pub fn pipe_cloexec() -> io::Result<(RawFd, RawFd)> {
    let mut fds = [0 as libc::c_int; 2];
    // SAFETY: fds has room for the two descriptors pipe(2) writes.
    unsafe {
        if libc::pipe(fds.as_mut_ptr()) != 0 {
            return Err(io::Error::last_os_error());
        }
        for fd in fds {
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        }
    }
    Ok((fds[0], fds[1]))
}

/// Waits for `pid` for up to `limit` (None = forever). `Some(code)` once it exited — the exit
/// code, or `None` inside when a signal ended it; the outer `None` means still running at the limit.
pub fn wait_timeout(pid: i32, limit: Option<Duration>) -> Option<Option<i32>> {
    let deadline = limit.map(|d| Instant::now() + d);
    loop {
        let mut st: libc::c_int = 0;
        // SAFETY: plain waitpid(2) on our own child.
        let r = unsafe { libc::waitpid(pid, &mut st, libc::WNOHANG) };
        if r == pid {
            return Some(libc::WIFEXITED(st).then(|| libc::WEXITSTATUS(st)));
        }
        if r < 0 {
            return Some(None); // already reaped / not ours
        }
        if deadline.is_some_and(|d| Instant::now() >= d) {
            return None;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::os::fd::FromRawFd;

    #[test]
    fn child_sees_only_fds_0_1_2() {
        // A descriptor WITHOUT close-on-exec, as another thread's freshly created socket is.
        let leak = unsafe { libc::fcntl(0, libc::F_DUPFD, 40) }; // F_DUPFD: no close-on-exec
        assert!(leak >= 40);
        let (r, w) = pipe_cloexec().unwrap();
        let probe = "for i in 3 4 5 6 7 8 9 $(seq 12 99); do { : <&$i; } 2>/dev/null && echo open $i; done; echo done";
        let pid = spawn_cloexec(
            &["/bin/sh".into(), "-c".into(), probe.into()],
            Some("/"),
            &[("PATH".into(), "/usr/bin:/bin".into())],
            [Stdio::Null, Stdio::Fd(w), Stdio::Null],
            true,
        )
        .unwrap();
        unsafe { libc::close(w) };
        let mut out = String::new();
        unsafe { std::fs::File::from_raw_fd(r) }
            .read_to_string(&mut out)
            .unwrap();
        assert_eq!(
            wait_timeout(pid, Some(Duration::from_secs(10))),
            Some(Some(0))
        );
        unsafe { libc::close(leak) };
        assert_eq!(out.trim(), "done", "the child inherited descriptors: {out}");
    }

    #[test]
    fn stdout_cwd_env_and_pgroup() {
        let (r, w) = pipe_cloexec().unwrap();
        let pid = spawn_cloexec(
            &[
                "/bin/sh".into(),
                "-c".into(),
                "pwd; echo $FOO; ps -o pgid= -p $$".into(),
            ],
            Some("/tmp"),
            &[
                ("FOO".into(), "bar".into()),
                ("PATH".into(), "/usr/bin:/bin".into()),
            ],
            [Stdio::Null, Stdio::Fd(w), Stdio::Null],
            true,
        )
        .unwrap();
        unsafe { libc::close(w) };
        let mut out = String::new();
        unsafe { std::fs::File::from_raw_fd(r) }
            .read_to_string(&mut out)
            .unwrap();
        wait_timeout(pid, Some(Duration::from_secs(10))).unwrap();
        let lines: Vec<&str> = out.lines().map(str::trim).collect();
        assert!(lines[0].ends_with("tmp"), "{out}");
        assert_eq!(lines[1], "bar");
        assert_eq!(lines[2], pid.to_string(), "own process group");
    }

    #[test]
    fn wait_timeout_returns_none_while_running() {
        let pid = spawn_cloexec(
            &["/bin/sleep".into(), "5".into()],
            None,
            &[],
            [Stdio::Null; 3],
            true,
        )
        .unwrap();
        assert_eq!(wait_timeout(pid, Some(Duration::from_millis(100))), None);
        unsafe { libc::kill(pid, libc::SIGKILL) };
        assert_eq!(wait_timeout(pid, Some(Duration::from_secs(5))), Some(None));
    }
}

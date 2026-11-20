//! Per-socket peer gate (PRD §5 "Peer identity", D10; proven in Faz 0 S2).
//!
//! - Each socket accepts exactly one code-signing identifier, signed by our own Team ID, checked
//!   on the peer's audit token (no PID-reuse race).
//! - The ptyd and client sockets also refuse peers whose session id belongs to a PTY session
//!   ptyd owns (shells, `claude`, agents; survives double-forks). The broker socket must not use
//!   that rule: the `muya-mcp` sidecar legitimately runs inside a session.
//! - The signature check costs ~1.5 ms (S2), so it runs once per connection; connections stay open.
//!
//! Development builds: when this process itself carries no Team ID (unsigned `cargo build`), no
//! peer can be verified, so same-user peers are accepted instead and the result says so. A signed
//! build never takes that path.

use core_foundation::base::TCFType;
use core_foundation::data::CFData;
use core_foundation::dictionary::CFDictionaryRef;
use core_foundation::string::{CFString, CFStringRef};
use security_framework::os::macos::code_signing::{Flags, GuestAttributes, SecCode, SecRequirement};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::OnceLock;
use std::time::Instant;

pub const APP_ID: &str = "com.staunch.muya";
/// The beta / bridge app's id. Muya 5 itself connects as `APP_ID` (it has classic's identity); this one stays accepted for the published beta apps.
pub const APP_NATIVE_ID: &str = "com.staunch.muya.native";
pub const PTYD_ID: &str = "com.staunch.muya.ptyd";
pub const MUYAD_ID: &str = "com.staunch.muya.muyad";
pub const SIDECAR_ID: &str = "com.staunch.muya.mcp";
pub const MUYACTL_ID: &str = "com.staunch.muya.muyactl";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trust {
    /// Signature verified against our Team ID and the expected identifier.
    Signed,
    /// This build is unsigned; the peer was only checked to be the same user.
    DevSameUser,
}

#[derive(Debug, Clone)]
pub struct Peer {
    pub pid: i32,
    pub uid: u32,
    pub sid: i32,
    pub trust: Trust,
    pub check_us: u128,
}

/// Verifies the peer on `stream`. `identifiers` lists the signing identifiers this socket accepts;
/// peers whose session id is in `refused_sids` are refused (pass `None` on the broker socket).
pub fn verify(stream: &UnixStream, identifiers: &[&str], refused_sids: Option<&[i32]>) -> Result<Peer, String> {
    let start = Instant::now();
    let token = audit_token(stream).map_err(|e| format!("no peer audit token: {e}"))?;
    // audit_token_t is eight u32s: val[1] = euid, val[5] = pid.
    let word = |i: usize| u32::from_ne_bytes(token[i * 4..i * 4 + 4].try_into().unwrap());
    let (uid, pid) = (word(1), word(5) as i32);
    if uid != unsafe { libc::getuid() } {
        return Err(format!("peer pid {pid} belongs to another user"));
    }
    let sid = unsafe { libc::getsid(pid) };
    if let Some(sids) = refused_sids {
        // Fail closed: an unreadable session id means we cannot prove the peer is outside a PTY.
        if sid == -1 {
            return Err(format!("peer pid {pid}: session id unreadable, refusing"));
        }
        if let Some(why) = refuse_reason(pid, sids) {
            return Err(why);
        }
    }
    let Some(team) = own_team() else {
        return Ok(Peer { pid, uid, sid, trust: Trust::DevSameUser, check_us: start.elapsed().as_micros() });
    };
    let data = CFData::from_buffer(&token);
    let mut attrs = GuestAttributes::new();
    attrs.set_audit_token(data.as_concrete_TypeRef());
    let code = SecCode::copy_guest_with_attribues(None, &attrs, Flags::NONE).map_err(|e| format!("peer pid {pid} has no code object: {e}"))?;
    for id in identifiers {
        let req: SecRequirement = format!(r#"anchor apple generic and identifier "{id}" and certificate leaf[subject.OU] = "{team}""#)
            .parse()
            .map_err(|e| format!("bad requirement: {e}"))?;
        if code.check_validity(Flags::NONE, &req).is_ok() {
            return Ok(Peer { pid, uid, sid, trust: Trust::Signed, check_us: start.elapsed().as_micros() });
        }
    }
    Err(format!("peer pid {pid} is not one of {identifiers:?} signed by our team"))
}

/// Parent pid of `pid` (macOS `proc_pidinfo`), `None` when unreadable.
fn ppid_of(pid: i32) -> Option<i32> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let rc = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&mut info as *mut libc::proc_bsdinfo).cast(), size) };
    (rc == size).then_some(info.pbi_ppid as i32)
}

/// Walks `pid` and its ancestors; returns the first refused session id found. A child that called
/// `setsid()` gets a fresh session id, but its parent chain still reaches the PTY session, so the
/// ancestry walk catches it. An unreadable link in the chain ends the walk (it cannot be a PTY
/// descendant if launchd/our own daemons are reached first).
pub fn refused_by_ancestry(pid: i32, refused: &[i32]) -> Option<i32> {
    let mut cur = pid;
    for _ in 0..64 {
        if cur <= 1 {
            return None;
        }
        let sid = unsafe { libc::getsid(cur) };
        if sid != -1 && refused.contains(&sid) {
            return Some(sid);
        }
        if refused.contains(&cur) {
            return Some(cur);
        }
        // Fail closed: a broken link means the walk cannot prove the peer is outside a PTY.
        match ppid_of(cur) {
            Some(p) => cur = p,
            None => return Some(-1),
        }
    }
    // A chain longer than the cap is not something a legitimate peer produces.
    Some(-1)
}

/// True when `pid` has been reparented to launchd (or its parent is unreadable): a daemonised or
/// orphaned process, never a child of the shell/app that started it.
pub fn is_orphan(pid: i32) -> bool {
    ppid_of(pid).is_none_or(|p| p <= 1)
}

/// The kernel's "responsible process" of `pid` (the app the system attributes it to). Unlike the
/// parent pid it is inherited across fork, exec, setsid and reparenting, so a double-fork daemon keeps
/// pointing at whoever started the chain. A process that nobody started (launched by launchd, such as
/// the app from Finder) is responsible for itself. `None` when the call is unavailable or fails.
pub fn responsible_pid(pid: i32) -> Option<i32> {
    type Fn = unsafe extern "C" fn(libc::pid_t) -> libc::pid_t;
    static F: OnceLock<Option<Fn>> = OnceLock::new();
    let f = (*F.get_or_init(|| {
        let sym = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"responsibility_get_pid_responsible_for_pid".as_ptr()) };
        (!sym.is_null()).then(|| unsafe { std::mem::transmute::<*mut libc::c_void, Fn>(sym) })
    }))?;
    let r = unsafe { f(pid) };
    (r > 0).then_some(r)
}

/// Trust from the kernel, not from the parent chain (M9). Returns why `pid` must be refused, `None`
/// when it provably does not come from a PTY session of ours. Fails closed.
///
/// 1. Ancestry walk: catches ordinary descendants and a child that called `setsid()`.
/// 2. A launchd-parented (orphan) peer is only legitimate when it is responsible for itself (the app
///    started from Finder/`open`). A PTY child that double-forks and `setsid()`s is reparented to launchd
///    but stays attributed to the process that started the chain, so it is refused, even if it execs a
///    genuine signed Muya binary.
/// 3. Whatever its parentage, a peer attributed to this process (the daemon verifying it) or to a
///    session leader is a descendant of a session.
pub fn refuse_reason(pid: i32, refused: &[i32]) -> Option<String> {
    if let Some(bad) = refused_by_ancestry(pid, refused) {
        return Some(if bad == -1 {
            format!("peer pid {pid}: process chain unreadable, refusing")
        } else {
            format!("peer pid {pid} runs inside PTY session {bad}")
        });
    }
    let resp = responsible_pid(pid);
    if is_orphan(pid) && resp != Some(pid) {
        return Some(format!("peer pid {pid} is a launchd-parented process attributed to {resp:?}, not to itself: refusing"));
    }
    if let Some(r) = resp
        && r != pid
        && (r == std::process::id() as i32 || refused.contains(&r) || refused_by_ancestry(r, refused).is_some())
    {
        return Some(format!("peer pid {pid} is attributed to {r}, which belongs to a PTY session or this daemon: refusing"));
    }
    None
}

#[cfg(test)]
mod ancestry_tests {
    use super::*;
    #[test]
    fn detects_refused_session_through_ancestry() {
        let me = std::process::id() as i32;
        let my_sid = unsafe { libc::getsid(me) };
        assert_eq!(refused_by_ancestry(me, &[my_sid]), Some(my_sid));
        // A parent's session id is found even when the child differs.
        let ppid = ppid_of(me).expect("ppid");
        assert!(ppid > 0);
        assert_eq!(refused_by_ancestry(me, &[999_999]), None);
        // Child that setsid()s still caught via its parent (this process).
        let mut c = std::process::Command::new("/usr/bin/perl")
            .args(["-e", "use POSIX; POSIX::setsid(); sleep 5"]).spawn().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(300));
        let cpid = c.id() as i32;
        let csid = unsafe { libc::getsid(cpid) };
        assert_ne!(csid, my_sid);
        assert!(refused_by_ancestry(cpid, &[my_sid]).is_some());
        let _ = c.kill();
    }

    /// M9: fork, setsid, fork again, parent exits, grandchild execs a program. It is reparented to
    /// launchd with a fresh session, so the ancestry walk alone ends at pid 1 and misses it.
    #[test]
    fn double_fork_setsid_daemon_is_refused_but_the_real_process_is_not() {
        let me = std::process::id() as i32;
        let my_sid = unsafe { libc::getsid(me) };
        let out = std::env::temp_dir().join(format!("muya-peer-df-{me}"));
        let _ = std::fs::remove_file(&out);
        let script = format!(
            "use POSIX; if (fork()==0) {{ POSIX::setsid(); if (fork()==0) {{ open(F,'>{p}.tmp'); print F $$; close F; rename('{p}.tmp','{p}'); exec '/bin/sleep','6'; }} exit 0; }} wait();",
            p = out.display()
        );
        let status = std::process::Command::new("/usr/bin/perl").args(["-e", &script]).status().unwrap();
        assert!(status.success());
        let end = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !out.exists() && std::time::Instant::now() < end {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        let pid: i32 = std::fs::read_to_string(&out).expect("daemon pid").trim().parse().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(300));
        assert!(is_orphan(pid), "the grandchild should be reparented to launchd");
        assert_ne!(unsafe { libc::getsid(pid) }, my_sid, "it must not share our session");
        // The ancestry walk alone cannot see it...
        assert_eq!(refused_by_ancestry(pid, &[my_sid]), None);
        // ...the kernel attribution can.
        let why = refuse_reason(pid, &[my_sid]).expect("double-fork daemon must be refused");
        assert!(why.contains("launchd-parented"), "{why}");
        unsafe { libc::kill(pid, libc::SIGKILL) };
        let _ = std::fs::remove_file(&out);
        // A normal process (this one: not an orphan, outside any listed session) is accepted.
        assert_eq!(refuse_reason(me, &[999_999]), None);
    }

    #[test]
    fn orphans_and_broken_chains_are_flagged() {
        assert!(is_orphan(1));
        assert!(is_orphan(999_999)); // unreadable -> fail closed
        assert!(!is_orphan(std::process::id() as i32) || ppid_of(std::process::id() as i32) == Some(1));
        // A pid that does not exist cannot be proven outside a PTY.
        assert_eq!(refused_by_ancestry(999_999, &[1234]), Some(-1));
    }
}

fn audit_token(stream: &UnixStream) -> std::io::Result<[u8; 32]> {
    let mut token = [0u8; 32];
    let mut len = token.len() as libc::socklen_t;
    let rc = unsafe { libc::getsockopt(stream.as_raw_fd(), libc::SOL_LOCAL, libc::LOCAL_PEERTOKEN, token.as_mut_ptr().cast(), &mut len) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(token)
}

unsafe extern "C" {
    fn SecCodeCopySigningInformation(code: *const libc::c_void, flags: u32, info: *mut CFDictionaryRef) -> i32;
    static kSecCodeInfoTeamIdentifier: CFStringRef;
}
const K_SEC_CS_SIGNING_INFORMATION: u32 = 1 << 1;

/// Our own Team ID, read from our signature (nothing team-specific compiled in); `None` when
/// this binary is not signed with a Team ID (development build).
pub fn own_team() -> Option<String> {
    use core_foundation::dictionary::CFDictionary;
    static TEAM: OnceLock<Option<String>> = OnceLock::new();
    TEAM.get_or_init(|| {
        let me = SecCode::for_self(Flags::NONE).ok()?;
        let mut info: CFDictionaryRef = std::ptr::null();
        let rc = unsafe { SecCodeCopySigningInformation(me.as_CFTypeRef(), K_SEC_CS_SIGNING_INFORMATION, &mut info) };
        if rc != 0 || info.is_null() {
            return None;
        }
        let dict: CFDictionary<CFString, core_foundation::base::CFType> = unsafe { CFDictionary::wrap_under_create_rule(info) };
        let key = unsafe { CFString::wrap_under_get_rule(kSecCodeInfoTeamIdentifier) };
        dict.find(&key)?.downcast::<CFString>().map(|s| s.to_string())
    })
    .clone()
}

/// The directory for Muya's sockets: `~/Library/Application Support/Muya`, or the per-user
/// temporary directory when that path would not fit `sockaddr_un` (103 bytes) for the longest
/// socket name. Created 0700 and checked to be ours.
pub fn socket_dir() -> std::io::Result<std::path::PathBuf> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let longest = "/muyad-broker.sock".len();
    let home = std::env::var_os("HOME").ok_or_else(|| std::io::Error::other("HOME not set"))?;
    let mut dir = std::path::PathBuf::from(home).join("Library/Application Support/Muya");
    if dir.as_os_str().len() + longest > 103 {
        dir = user_temp_dir()?.join("muya");
    }
    std::fs::create_dir_all(&dir)?;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    let meta = std::fs::symlink_metadata(&dir)?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::getuid() } {
        return Err(std::io::Error::other(format!("{} is not our directory", dir.display())));
    }
    Ok(dir)
}

/// `confstr(_CS_DARWIN_USER_TEMP_DIR)`: per-user, 0700, short (/var/folders/..../T/).
fn user_temp_dir() -> std::io::Result<std::path::PathBuf> {
    const CS_DARWIN_USER_TEMP_DIR: libc::c_int = 65537;
    let mut buf = vec![0u8; 1024];
    let n = unsafe { libc::confstr(CS_DARWIN_USER_TEMP_DIR, buf.as_mut_ptr().cast(), buf.len()) };
    if n == 0 || n > buf.len() {
        return Err(std::io::Error::other("no per-user temp dir"));
    }
    buf.truncate(n - 1);
    Ok(std::path::PathBuf::from(String::from_utf8_lossy(&buf).into_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_user_peer_is_accepted_in_a_dev_build_and_session_rule_applies() {
        let (a, _b) = UnixStream::pair().unwrap();
        let peer = verify(&a, &[MUYAD_ID], None).unwrap();
        assert_eq!(peer.pid, std::process::id() as i32);
        assert_eq!(peer.trust, if own_team().is_some() { Trust::Signed } else { Trust::DevSameUser });
        let my_sid = unsafe { libc::getsid(0) };
        let err = verify(&a, &[MUYAD_ID], Some(&[my_sid])).unwrap_err();
        assert!(err.contains("inside PTY session"), "{err}");
    }

    #[test]
    fn socket_dir_is_private_and_fits_sun_path() {
        use std::os::unix::fs::PermissionsExt;
        let d = socket_dir().unwrap();
        assert!(d.as_os_str().len() + "/muyad-broker.sock".len() <= 103);
        assert_eq!(std::fs::metadata(&d).unwrap().permissions().mode() & 0o777, 0o700);
        assert!(user_temp_dir().unwrap().as_os_str().len() < 80);
    }
}

//! Faz 0 S2 (PRD `docs/prd-native-rewrite.md` §5, D10): stub `muya-ptyd` / `muyad` that prove
//! the signed nested-agent layout and the per-socket peer gate:
//! - each socket accepts exactly one code-signing identifier from our own Team ID, checked on
//!   the peer's audit token (no PID-reuse race);
//! - the ptyd and client sockets also refuse peers whose session id belongs to a PTY session
//!   ptyd owns (shells, `claude`, agents). The broker socket must NOT apply that rule: the
//!   `muya-mcp` sidecar legitimately runs inside a session.

use core_foundation::base::TCFType;
use core_foundation::data::CFData;
use core_foundation::dictionary::CFDictionaryRef;
use core_foundation::string::{CFString, CFStringRef};
use security_framework::os::macos::code_signing::{Flags, GuestAttributes, SecCode, SecRequirement};
use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::time::Instant;

pub const APP_ID: &str = "com.staunch.muya.spike";
pub const PTYD_ID: &str = "com.staunch.muya.spike.ptyd";
pub const MUYAD_ID: &str = "com.staunch.muya.spike.muyad";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// `sockaddr_un.sun_path` is 104 bytes including the NUL.
const SUN_PATH_MAX: usize = 103;

pub fn socket_dir() -> io::Result<PathBuf> {
    let home = std::env::var_os("HOME").ok_or_else(|| io::Error::other("HOME not set"))?;
    let dir = PathBuf::from(home).join("Library/Application Support/MuyaSpike");
    std::fs::create_dir_all(&dir)?;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    let meta = std::fs::symlink_metadata(&dir)?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::getuid() } {
        return Err(io::Error::other(format!("{} is not our directory", dir.display())));
    }
    Ok(dir)
}

pub fn socket_path(name: &str) -> io::Result<PathBuf> {
    let path = socket_dir()?.join(format!("{name}.sock"));
    if path.as_os_str().len() > SUN_PATH_MAX {
        return Err(io::Error::other(format!("socket path longer than {SUN_PATH_MAX} bytes: {}", path.display())));
    }
    Ok(path)
}

pub fn log(name: &str, msg: &str) {
    if let Ok(dir) = socket_dir()
        && let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join(format!("{name}.log")))
    {
        let _ = writeln!(f, "{} pid={} {msg}", unix_ms(), std::process::id());
    }
}

pub fn unix_ms() -> u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

pub fn listen(name: &str) -> io::Result<UnixListener> {
    let path = socket_path(name)?;
    if let Ok(meta) = std::fs::symlink_metadata(&path) {
        use std::os::unix::fs::FileTypeExt;
        if !meta.file_type().is_socket() {
            return Err(io::Error::other(format!("{} exists and is not a socket", path.display())));
        }
        std::fs::remove_file(&path)?;
    }
    let listener = UnixListener::bind(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

pub fn connect(name: &str) -> io::Result<UnixStream> {
    let stream = UnixStream::connect(socket_path(name)?)?;
    stream.set_read_timeout(Some(std::time::Duration::from_secs(10)))?;
    Ok(stream)
}

/// One request line, one reply line.
pub fn request(name: &str, line: &str) -> io::Result<String> {
    let mut stream = connect(name)?;
    writeln!(stream, "{line}")?;
    let mut reply = String::new();
    BufReader::new(stream).read_line(&mut reply)?;
    Ok(reply.trim_end().to_owned())
}

pub fn read_line(stream: &UnixStream) -> io::Result<String> {
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    Ok(line.trim_end().to_owned())
}

/// Serves request lines on one connection until EOF; each reply is one write.
pub fn serve_lines(stream: &mut UnixStream, mut reply: impl FnMut(&str) -> String) {
    let Ok(clone) = stream.try_clone() else { return };
    let mut reader = BufReader::new(clone);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let mut out = reply(line.trim_end());
        out.push('\n');
        if stream.write_all(out.as_bytes()).is_err() {
            return;
        }
    }
}

/// A kept-open request/reply connection.
pub struct Conn {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Conn {
    pub fn open(name: &str) -> io::Result<Self> {
        let stream = connect(name)?;
        let reader = BufReader::new(stream.try_clone()?);
        Ok(Self { stream, reader })
    }

    pub fn call(&mut self, line: &str) -> io::Result<String> {
        self.stream.write_all(format!("{line}\n").as_bytes())?;
        let mut reply = String::new();
        if self.reader.read_line(&mut reply)? == 0 {
            return Err(io::Error::other("connection closed"));
        }
        Ok(reply.trim_end().to_owned())
    }
}

pub struct Peer {
    pub pid: i32,
    pub sid: i32,
    /// Time spent validating the peer's signature.
    pub check_us: u128,
}

/// Accepts the peer only if it is signed by our Team ID with `identifier`, and (when
/// `refused_sids` is given) does not live in one of those sessions.
pub fn verify_peer(stream: &UnixStream, identifier: &str, refused_sids: Option<&[i32]>) -> Result<Peer, String> {
    let token = audit_token(stream).map_err(|e| format!("no peer audit token: {e}"))?;
    // audit_token_t is eight u32s; val[5] is the pid (audit_token_to_pid).
    let pid = u32::from_ne_bytes(token[20..24].try_into().unwrap()) as i32;
    let sid = unsafe { libc::getsid(pid) };
    if let Some(sids) = refused_sids
        && sids.contains(&sid)
    {
        return Err(format!("peer pid {pid} runs inside PTY session {sid}"));
    }
    let team = own_team().ok_or("this process is not signed with a Team ID")?;
    let start = Instant::now();
    let requirement: SecRequirement =
        format!(r#"anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}""#)
            .parse()
            .map_err(|e| format!("bad requirement: {e}"))?;
    let data = CFData::from_buffer(&token);
    let mut attrs = GuestAttributes::new();
    attrs.set_audit_token(data.as_concrete_TypeRef());
    let code = SecCode::copy_guest_with_attribues(None, &attrs, Flags::NONE)
        .map_err(|e| format!("peer pid {pid} has no code object: {e}"))?;
    code.check_validity(Flags::NONE, &requirement)
        .map_err(|e| format!("peer pid {pid} is not {identifier}: {e}"))?;
    Ok(Peer { pid, sid, check_us: start.elapsed().as_micros() })
}

fn audit_token(stream: &UnixStream) -> io::Result<[u8; 32]> {
    let mut token = [0u8; 32];
    let mut len = token.len() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERTOKEN,
            token.as_mut_ptr().cast(),
            &mut len,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(token)
}

unsafe extern "C" {
    fn SecCodeCopySigningInformation(code: *const libc::c_void, flags: u32, info: *mut CFDictionaryRef) -> i32;
    static kSecCodeInfoTeamIdentifier: CFStringRef;
}
const K_SEC_CS_SIGNING_INFORMATION: u32 = 1 << 1;

/// Our own Team ID, read from our signature, so nothing team-specific is compiled in.
pub fn own_team() -> Option<String> {
    use core_foundation::dictionary::CFDictionary;
    use std::sync::OnceLock;
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

pub fn peak_rss_kb() -> i64 {
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) };
    usage.ru_maxrss / 1024 // bytes on macOS
}

/// `muyad --probe <socket>`: connect from wherever we were started and print the reply.
pub fn probe_main(args: &[String]) -> Option<i32> {
    let i = args.iter().position(|a| a == "--probe")?;
    let target = args.get(i + 1).map(String::as_str).unwrap_or("ptyd");
    match request(target, "hello") {
        Ok(reply) => println!("{reply}"),
        Err(e) => println!("error: {e}"),
    }
    Some(0)
}

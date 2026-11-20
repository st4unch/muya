//! `muya-ptyd [--socket <path>]` — normally started by launchd (SMAppService LaunchAgent,
//! ProcessType=Interactive, ThrottleInterval=1; Faz 0 S2).

use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::UnixListener;

/// `muya-ptyd --exec-with-ctty <program> [args...]`: runs as the session leader the daemon just created, claims the PTY on
/// stdin as its controlling terminal and becomes the program (see `spawn_session`).
fn exec_with_ctty(args: &[String]) -> ! {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    unsafe { libc::ioctl(0, libc::TIOCSCTTY as _, 0) };
    let argv: Vec<CString> = args.iter().filter_map(|a| CString::new(a.as_bytes()).ok()).collect();
    if argv.is_empty() {
        std::process::exit(127);
    }
    let mut p: Vec<*const libc::c_char> = argv.iter().map(|c| c.as_ptr()).collect();
    p.push(std::ptr::null());
    unsafe { libc::execvp(p[0], p.as_ptr()) };
    let e = std::io::Error::last_os_error();
    eprintln!("muya-ptyd: exec {}: {e}", args[0]);
    std::process::exit(if e.kind() == std::io::ErrorKind::NotFound { 127 } else { 126 });
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--exec-with-ctty") {
        exec_with_ctty(&args[2..]);
    }
    let path = match args
        .iter()
        .position(|a| a == "--socket")
        .and_then(|i| args.get(i + 1))
    {
        Some(p) => std::path::PathBuf::from(p),
        None => match muya_peer::socket_dir() {
            Ok(d) => d.join("ptyd.sock"),
            Err(e) => {
                eprintln!("muya-ptyd: socket dir: {e}");
                std::process::exit(1);
            }
        },
    };
    if let Ok(meta) = std::fs::symlink_metadata(&path) {
        if !meta.file_type().is_socket() {
            eprintln!("muya-ptyd: {} exists and is not a socket", path.display());
            std::process::exit(1);
        }
        let _ = std::fs::remove_file(&path);
    }
    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("muya-ptyd: bind {}: {e}", path.display());
            std::process::exit(1);
        }
    };
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    // Tests start ptyd as a child; if the test process dies without cleaning up, ptyd must not
    // linger as an orphan with live sessions (launchd-started ptyd never sets this).
    if std::env::var_os("MUYA_PTYD_EXIT_WITH_PARENT").is_some() {
        let parent = unsafe { libc::getppid() };
        std::thread::spawn(move || loop {
            std::thread::sleep(std::time::Duration::from_millis(200));
            if unsafe { libc::getppid() } != parent {
                std::process::exit(0);
            }
        });
    }
    let daemon = muya_ptyd::Daemon::new(&muya_proto::build_id(env!("CARGO_PKG_VERSION"), option_env!("MUYA_PRODUCT_VERSION")));
    // After an `Upgrade` the new binary must run: exit and let launchd (or the test supervisor) start it.
    // A short pause lets the reply reach muyad first.
    let own_socket = path.clone();
    daemon.set_on_upgrade(move || {
        let socket = own_socket.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(150));
            let _ = std::fs::remove_file(&socket);
            std::process::exit(0);
        });
    });
    if muya_peer::own_team().is_none() {
        eprintln!("muya-ptyd: unsigned build — accepting same-user peers (development only)");
    }
    for stream in listener.incoming().flatten() {
        let sids = daemon.session_sids();
        match muya_peer::verify(
            &stream,
            &[muya_peer::MUYAD_ID, muya_peer::MUYACTL_ID],
            Some(&sids),
        ) {
            Ok(_) => {
                let d = daemon.clone();
                std::thread::spawn(move || d.serve(stream));
            }
            Err(why) => {
                let frame = muya_proto::Frame::Control(muya_proto::Control::Error {
                    code: muya_proto::ErrorCode::Refused,
                    message: why,
                    detail: None,
                });
                let mut s = stream;
                let _ = std::io::Write::write_all(&mut s, &frame.encode());
            }
        }
    }
}

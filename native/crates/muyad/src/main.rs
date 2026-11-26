//! `muyad [--socket <path>] [--ptyd <path>] [--broker] [--scheduler]` — normally started by launchd (SMAppService
//! LaunchAgent, ProcessType=Interactive, ThrottleInterval=1; Faz 0 S2).

use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::time::{Duration, Instant};

/// How long startup waits for ptyd before serving without it.
const PTYD_WAIT: Duration = Duration::from_secs(2);

fn arg(args: &[String], name: &str) -> Option<std::path::PathBuf> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .map(std::path::PathBuf::from)
}

fn fail(msg: String) -> ! {
    eprintln!("muyad: {msg}");
    std::process::exit(1);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    // One-shot mode, handled before anything binds a socket: the launcher restores classic when macOS is too old for Muya 5.
    if let Some(i) = args.iter().position(|a| a == "--return-classic") {
        let Some(app) = args.get(i + 1) else { fail("--return-classic needs the app bundle path".into()) };
        match muyad::switchover_host::return_classic_cli(app) {
            Ok(v) => {
                eprintln!("muyad: Muya Classic {v} restored");
                std::process::exit(0)
            }
            Err(e) => {
                eprintln!("muyad: could not restore Muya Classic: {e}");
                std::process::exit(1)
            }
        }
    }
    // The MCP helper that `~/.claude.json` and the plugin point at lives at a fixed per-user path, outside the app. An update
    // replaced the app but never that copy, so agents kept a sidecar from the day Muya was first run. launchd restarts muyad
    // after every update, so refreshing here is "on launch and after an update". No-op outside a bundle (dev, tests).
    if let Ok(exe) = std::env::current_exe() {
        match muya_core::app_location::stable_mcp_binary(&exe) {
            Ok(p) => eprintln!("muyad: MCP helper at {}", p.display()),
            Err(e) => eprintln!("muyad: MCP helper not refreshed: {e}"),
        }
    }
    let dir = || muya_peer::socket_dir().unwrap_or_else(|e| fail(format!("socket dir: {e}")));
    let socket = arg(&args, "--socket").unwrap_or_else(|| dir().join("muyad.sock"));
    let ptyd = arg(&args, "--ptyd").unwrap_or_else(|| dir().join("ptyd.sock"));

    // launchd may start muyad before ptyd is listening: give it a moment. If ptyd stays
    // unreachable (its LaunchAgent is not approved in Login Items, AC21) muyad does not exit: it
    // serves, answers every request that needs ptyd with a typed `NotApproved` error and links as
    // soon as ptyd appears (no restart).
    let muyad = muyad::Muyad::offline(&ptyd, &muya_proto::build_id(env!("CARGO_PKG_VERSION"), option_env!("MUYA_PRODUCT_VERSION")));
    let deadline = Instant::now() + PTYD_WAIT;
    loop {
        match muyad.ensure_link() {
            Ok(()) => break,
            Err(e) if muyad::is_ptyd_unavailable(&e) => {
                if Instant::now() >= deadline {
                    eprintln!("muyad: ptyd at {} is not reachable; serving without it ({e})", ptyd.display());
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(e) => fail(format!("ptyd at {}: {e}", ptyd.display())),
        }
    }
    if muyad.is_linked() {
        eprintln!(
            "muyad: re-adopted {} sessions in {} ms",
            muyad.sessions().len(),
            muyad.readopt_ms.lock().unwrap()
        );
    }

    // Opt-in during the transition: own the schedule timers (muya_core::schedules; the same lock
    // file as the Tauri window and the old `muya --scheduler` agent, so two can never both fire).
    let schedules = if args.iter().any(|a| a == "--scheduler") {
        let state = muya_core::schedules::ScheduleState::daemon();
        match muyad::scheduler_host::spawn(state.clone(), muyad.clone()) {
            Ok(true) => eprintln!("muyad: owning the schedule timers"),
            Ok(false) => eprintln!("muyad: scheduler refused: another live owner holds the schedule lock (retrying in the background)"),
            Err(e) => eprintln!("muyad: scheduler not started: {e}"),
        }
        state
    } else {
        muya_core::schedules::ScheduleState::client()
    };

    // The resume plan of "restart sessions now" (AC19) lives next to the socket unless told otherwise.
    let state_dir = arg(&args, "--state-dir").or_else(|| socket.parent().map(std::path::Path::to_path_buf));
    if let Some(dir) = &state_dir {
        muyad.set_state_dir(dir);
    }
    // After an `Upgrade`: exit so launchd starts the new build (ptyd was told the same).
    muyad.set_on_upgrade(|| std::process::exit(0));

    // AC12: a permission prompt while no app is attached notifies (and auto-allows when the
    // setting is on). Off when HOME is unknown.
    if let Some(home) = std::env::var_os("HOME") {
        muyad.enable_prompt_watch(muyad::prompt_watch::PromptConfig::default_for(std::path::Path::new(&home)));
    }

    // P10: the bridge, shared by the Rpc methods and the broker's bridge_* agent tools.
    let bridge = muyad::bridge_host::MuyadBridgeHost::new(std::sync::Arc::downgrade(&muyad)).unwrap_or_else(|e| fail(format!("bridge: {e}")));
    bridge.start_pollers();
    // One password store for `vault.*` and for the broker's secret tools.
    let vault = std::sync::Arc::new(muya_core::credstore::CredStore::default());
    let cyberark = std::sync::Arc::new(muya_core::cyberark::CyberarkState::default());
    let idle = muyad::vault_idle::IdleClock::new();
    muyad::vault_idle::spawn(vault.clone(), idle.clone(), muyad::vault_idle::configured_idle(), std::sync::Arc::downgrade(&muyad));
    muyad.set_rpc(muyad::rpc::Rpc::new(schedules.clone()).with_muyad(std::sync::Arc::downgrade(&muyad)).with_bridge(bridge.clone()).with_vault(vault.clone()).with_cyberark(cyberark.clone()).with_idle(idle));

    // Native beta self-update: only says "an update is available" (never installs by itself).
    muyad::switchover_host::spawn_poller(std::sync::Arc::downgrade(&muyad));

    // Opt-in during the transition: serve the MCP broker (muya_core::broker) from here. A live
    // broker socket (the Tauri app's) is left alone; muyad then runs without one.
    if args.iter().any(|a| a == "--broker") {
        match muyad::broker_host::MuyadBrokerHost::new(muyad.clone(), schedules).with_vault(vault).with_cyberark(cyberark).with_bridge(bridge).spawn() {
            Ok(()) => eprintln!("muyad: serving the MCP broker"),
            Err(e) => eprintln!("muyad: broker not started: {e}"),
        }
    }

    if let Ok(meta) = std::fs::symlink_metadata(&socket) {
        if !meta.file_type().is_socket() {
            fail(format!("{} exists and is not a socket", socket.display()));
        }
        let _ = std::fs::remove_file(&socket);
    }
    let listener = UnixListener::bind(&socket)
        .unwrap_or_else(|e| fail(format!("bind {}: {e}", socket.display())));
    let _ = std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600));
    // The app's release id (`com.staunch.muya`, also classic's) and the beta / bridge id are both accepted; the e2e build
    // (cargo feature `e2e`, never shipped) adds its throwaway ids.
    #[allow(unused_mut)]
    let mut accepted: Vec<String> = vec![muya_peer::APP_ID.into(), muya_peer::APP_NATIVE_ID.into(), muya_peer::MUYACTL_ID.into()];
    #[cfg(feature = "e2e")]
    {
        let ids = muya_switchover::v5::ids();
        accepted.push(ids.release);
        accepted.push(ids.legacy);
    }
    let accepted: Vec<&str> = accepted.iter().map(String::as_str).collect();
    for stream in listener.incoming().flatten() {
        let sids = muyad.session_sids();
        match muya_peer::verify(&stream, &accepted, Some(&sids)) {
            Ok(_) => {
                let m = muyad.clone();
                std::thread::spawn(move || m.serve(stream));
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

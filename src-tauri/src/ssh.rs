//! Tauri side of SSH: the command wrappers and the PTY connect path. Config, types and command
//! builders live in `muya_core::ssh` (native rewrite, strangler) and are re-exported here.

pub use muya_core::ssh::*;
use tauri::ipc::{Channel, InvokeResponseBody};
use tauri::State;
use zeroize::Zeroizing;

#[tauri::command]
pub fn ssh_build_connect_cmd(id: String) -> Result<ConnectCommand, String> {
    muya_core::ssh::ssh_build_connect_cmd(id)
}

#[tauri::command]
pub fn ssh_get_config() -> Result<SshConfig, String> {
    muya_core::ssh::ssh_get_config()
}

#[tauri::command]
pub fn ssh_list_servers() -> Result<Vec<Server>, String> {
    muya_core::ssh::ssh_list_servers()
}

#[tauri::command]
pub fn ssh_upsert_server(server: Server) -> Result<String, String> {
    muya_core::ssh::ssh_upsert_server(server)
}

#[tauri::command]
pub fn ssh_remove_server(id: String) -> Result<(), String> {
    muya_core::ssh::ssh_remove_server(id)
}

#[tauri::command]
pub fn ssh_upsert_psmp_profile(profile: PsmpProfile) -> Result<String, String> {
    muya_core::ssh::ssh_upsert_psmp_profile(profile)
}

#[tauri::command]
pub fn ssh_remove_psmp_profile(id: String) -> Result<(), String> {
    muya_core::ssh::ssh_remove_psmp_profile(id)
}

#[tauri::command]
pub fn ssh_set_cyberark_config(config: CyberarkConfig) -> Result<(), String> {
    muya_core::ssh::ssh_set_cyberark_config(config)
}

/// Open an SSH connection for `server_id` in a new PTY, streaming to `on_event`.
/// The command is built here; when the server's credential source is a stored
/// password or a CyberArk account, the secret is resolved IN RUST and injected
/// into the PTY at the password prompt — it never crosses into JS (§9). Returns
/// the PTY session id for pty_write/pty_resize/pty_kill.
#[tauri::command(async)]
pub async fn ssh_pty_connect(
    pty: State<'_, crate::pty::PtyManager>,
    cred: State<'_, crate::credstore::CredStore>,
    cyber: State<'_, crate::cyberark::CyberarkState>,
    on_event: Channel<InvokeResponseBody>,
    server_id: String,
    cols: Option<u16>,
    rows: Option<u16>,
) -> Result<String, String> {
    let cfg = load()?;
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
    let cmd = build_connect_command(&server, psmp)?;
    // The built argv carries NO secret (PSMP injects the credential; direct
    // password is injected into the PTY later) — safe to log verbatim.
    crate::debuglog::log(&format!(
        "ssh connect: server={} type={} program={} args={:?} cred_source={} injection_armed={}",
        server.label,
        server.connection_type,
        cmd.program,
        cmd.args,
        server.credential_source.kind,
        cmd.needs_password_injection
    ));

    // Resolve the injectable secret (Rust-only). "prompt" injects nothing — the
    // user types the password in the terminal.
    let secret: Option<Zeroizing<String>> = match server.credential_source.kind.as_str() {
        "local" => {
            // Resolve by REFERENCE (name OR id): the human UI picker stores an id,
            // while an agent-added server stores the secret NAME. `secret_for_ref`
            // matches either, so both paths work.
            let reference = server.credential_source.local_cred_id.as_deref().ok_or(
                "credential source is 'Local password store' but no credential is selected",
            )?;
            Some(crate::credstore::secret_for_ref(&cred, reference)?)
        }
        "cyberark" => {
            let acct = server
                .credential_source
                .cyberark_account_id
                .as_deref()
                .ok_or("credential source is 'CyberArk account' but no account is selected")?;
            crate::debuglog::log(&format!(
                "ssh connect: resolving CyberArk password for account={acct}"
            ));
            Some(crate::cyberark::fetch_password(&cyber, acct).await?)
        }
        _ => None,
    };
    // Metadata only — whether a secret was resolved, never the secret itself.
    crate::debuglog::log(&format!(
        "ssh connect: spawning PTY (program={}, secret_resolved={})",
        cmd.program,
        secret.is_some()
    ));

    crate::pty::spawn_process(
        pty.inner(),
        on_event,
        &cmd.program,
        &cmd.args,
        None,
        cols,
        rows,
        secret,
    )
}

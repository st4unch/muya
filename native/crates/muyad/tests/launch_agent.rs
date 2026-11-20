//! The LaunchAgent plist the release bundle ships decides how the real install starts muyad. It must pass `--broker`:
//! otherwise no broker socket exists, and the `muya-mcp` sidecar of every Claude session answers "Muya app not running".
use std::process::Command;

fn extract(plist: &str, key: &str) -> String {
    let fmt = if key == "BundleProgram" { "raw" } else { "json" };
    let p = format!("{}/../../scripts/bundle/LaunchAgents/{plist}", env!("CARGO_MANIFEST_DIR"));
    let out = Command::new("plutil").args(["-extract", key, fmt, "-o", "-", &p]).output().expect("plutil");
    assert!(out.status.success(), "{key} missing in {plist}");
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

#[test]
fn shipped_muyad_agent_serves_the_broker() {
    assert_eq!(extract("com.staunch.muya.muyad.plist", "ProgramArguments"), r#"["Contents\/MacOS\/muyad","--broker","--scheduler"]"#);
    assert_eq!(extract("com.staunch.muya.muyad.plist", "BundleProgram"), "Contents/MacOS/muyad");
}

#[test]
fn the_sidecar_and_the_broker_resolve_the_same_socket_by_default() {
    // Both sides read MUYA_SSH_BROKER_SOCK first and fall back to $HOME/.claude/muya-ssh-broker.sock.
    let sidecar = std::fs::read_to_string(format!("{}/../../../src-tauri/src/bin/muya_ssh_mcp.rs", env!("CARGO_MANIFEST_DIR"))).unwrap();
    assert!(sidecar.contains("MUYA_SSH_BROKER_SOCK") && sidecar.contains(".claude/muya-ssh-broker.sock"));
    assert!(muya_core::broker::socket_path().is_ok());
}

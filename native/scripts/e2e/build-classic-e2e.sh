#!/usr/bin/env bash
#
# build-classic-e2e.sh - build the classic 4.1.22 copy that scripts/e2e-v5.sh updates to Muya 5. A test tool, not shipped.
#
#   native/scripts/e2e/build-classic-e2e.sh <classic-worktree> <node_modules-dir>
#
# <classic-worktree> is a checkout of the classic release tag (git worktree add <dir> v4.1.22). The published 4.1.22 binary
# cannot be pointed at a local feed (its endpoint is compiled in and the updater refuses http outside debug builds), so the
# same source is built with `--features e2e` and a config override: id com.staunch.muya.e2e, endpoint
# http://127.0.0.1:38717/latest.json, dangerousInsecureTransportProtocol, the REAL updater public key. The only code added is
# `e2e_autoupdate` (feature e2e): with MUYA_E2E_AUTOUPDATE=1 it runs what the banner's "Restart" runs (the updater plugin's
# check -> download_and_install, then AppHandle::request_restart = the process plugin's relaunch); with =check it only looks.
# A headless run cannot click the banner. Everything else - extraction, bundle replacement, relaunch - is the shipped code path.
# Tauri signs the bundle with the Developer ID from tauri.conf.json; notarize it afterwards with notarize.sh.
set -euo pipefail
C=${1:?classic worktree at v4.1.22}; NM=${2:?node_modules dir}
cd "$C"
[ "$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' src-tauri/tauri.conf.json | head -1)" = 4.1.22 ] || { echo "not a 4.1.22 checkout" >&2; exit 1; }
ln -sfn "$NM" node_modules
mkdir -p src-tauri/binaries
[ -f src-tauri/binaries/muya-ssh-mcp-aarch64-apple-darwin ] || { echo "stage src-tauri/binaries/muya-ssh-mcp-aarch64-apple-darwin first (cargo build --bin muya-ssh-mcp)" >&2; exit 1; }

PUB=$(sed -n 's/.*"pubkey": "\([^"]*\)".*/\1/p' src-tauri/tauri.conf.json | head -1)
cat > src-tauri/tauri.e2e.conf.json <<EOF
{
  "identifier": "com.staunch.muya.e2e",
  "plugins": { "updater": { "endpoints": ["http://127.0.0.1:38717/latest.json"], "dangerousInsecureTransportProtocol": true, "pubkey": "$PUB" } }
}
EOF

python3 - <<'PY'
p = "src-tauri/src/switchover.rs"
s = open(p).read()
if "e2e_autoupdate" not in s:
    hook = '''/// e2e builds only (`--features e2e`), NEVER shipped. MUYA_E2E_AUTOUPDATE=1: the path the banner's Restart runs; =check: look only.
#[cfg(feature = "e2e")]
pub fn e2e_autoupdate(app: AppHandle) {
    let mode = std::env::var("MUYA_E2E_AUTOUPDATE").unwrap_or_default();
    if mode != "1" && mode != "check" {
        return;
    }
    tauri::async_runtime::spawn(async move {
        use tauri_plugin_updater::UpdaterExt;
        tokio::time::sleep(Duration::from_secs(6)).await;
        let log = |m: String| {
            if let Ok(h) = home() {
                use std::io::Write;
                if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(h.join("e2e-update.log")) {
                    let _ = writeln!(f, "{m}");
                }
            }
        };
        let up = match app.updater() {
            Ok(u) => u,
            Err(e) => return log(format!("updater error: {e}")),
        };
        match up.check().await {
            Ok(Some(update)) => {
                log(format!("update available: {}", update.version));
                if mode == "check" {
                    return;
                }
                match update.download_and_install(|_, _| {}, || {}).await {
                    Ok(()) => {
                        log("installed; restarting".into());
                        app.request_restart();
                    }
                    Err(e) => log(format!("install failed: {e}")),
                }
            }
            Ok(None) => log("no update".into()),
            Err(e) => log(format!("check failed: {e}")),
        }
    });
}

'''
    s = s.replace("#[cfg(test)]\nmod tests {", hook + "#[cfg(test)]\nmod tests {", 1)
    open(p, "w").write(s)
p = "src-tauri/src/lib.rs"
s = open(p).read()
call = "crate::switchover::e2e_autostart(app.handle().clone());"
if "e2e_autoupdate" not in s:
    s = s.replace(call, call + '\n            #[cfg(feature = "e2e")]\n            crate::switchover::e2e_autoupdate(app.handle().clone());', 1)
    open(p, "w").write(s)
PY

npx tauri build --features e2e --config src-tauri/tauri.e2e.conf.json --bundles app
echo "built: $C/src-tauri/target/release/bundle/macos/Muya.app (notarize it, then pass it as CLASSIC_E2E and its zip as CLASSIC_E2E_ZIP)"

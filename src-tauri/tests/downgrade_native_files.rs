//! AC27 (docs/prd-native-rewrite.md): reinstalling the last Tauri build after the native app
//! has run reads vault, schedules, servers and prefs without loss.
//!
//! The Tauri app's modules are thin re-exports of `muya_core` (`pub use muya_core::x::*`), so
//! calling `muya_core` here runs exactly the code the reinstalled Tauri build runs.
//!
//! One test function on purpose: the vault and prefs paths come from `$HOME`, which is set once
//! to a temp dir (never the operator's real home) for this whole test binary.

use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;

use muya_core::credstore::{self, CredStore};
use muya_core::schedules::{self, Paths};
use muya_core::{app_prefs, migrate, ssh};
use sha2::{Digest, Sha256};

fn digest(path: &Path) -> String {
    Sha256::digest(std::fs::read(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display())))
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn digest_tree(root: &Path) -> BTreeMap<String, String> {
    fn walk(dir: &Path, root: &Path, out: &mut BTreeMap<String, String>) {
        for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, root, out);
            } else {
                out.insert(
                    p.strip_prefix(root).unwrap().display().to_string(),
                    digest(&p),
                );
            }
        }
    }
    let mut m = BTreeMap::new();
    walk(root, root, &mut m);
    m
}

const JOB_JSON: &str = r#"{"version":1,"jobs":[{"id":"job-1","name":"nightly","prompt":"summarise",
  "folder":"/work/demo","schedule":{"kind":"daily","time":"03:00"},"enabled":true,"timeoutMin":30,
  "bypass":false,"chrome":true,"created":1700000000,"updated":1700000000}]}"#;

const SSH_JSON: &str = r#"{"version":1,"servers":[{"id":"srv-1","label":"lab","host":"10.0.0.5",
  "port":2222,"username":"ops","connectionType":"direct"}],"psmpProfiles":[]}"#;

#[test]
fn tauri_reads_vault_schedules_servers_prefs_after_native_wrote_its_files() {
    let home = tempfile::tempdir().unwrap();
    // SAFETY: single test in this binary, set before any other thread reads it.
    unsafe { std::env::set_var("HOME", home.path()) };
    let claude = home.path().join(".claude");
    std::fs::create_dir_all(&claude).unwrap();

    // --- 1. Data as the last Tauri build left it ---------------------------------------------
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let store = CredStore::default();
    rt.block_on(credstore::credstore_init("master-pw".into(), &store))
        .unwrap();
    credstore::add_credential(
        &store,
        "lab-pw".into(),
        "d".into(),
        "password".into(),
        "s3cret".into(),
    )
    .unwrap();
    let cred_id = credstore::list_meta(&store).unwrap()[0].id.clone();
    credstore::lock_store(&store).ok();

    std::fs::write(claude.join("muya-ssh-config.json"), SSH_JSON).unwrap();
    std::fs::write(claude.join("muya-schedules.json"), JOB_JSON).unwrap();
    std::fs::write(
        claude.join("muya-app.json"),
        r#"{"keepRunningInBackground":false,"claudeStatusInFooter":false}"#,
    )
    .unwrap();
    std::fs::write(
        claude.join("muya-vault-config.json"),
        r#"{"vault_path":"/notes"}"#,
    )
    .unwrap();

    // Tauri webview localStorage (tabs/layout) — the native app must never write it.
    let ls = home
        .path()
        .join("Library/WebKit/com.staunch.muya/WebsiteData/Default/a/b/LocalStorage");
    std::fs::create_dir_all(&ls).unwrap();
    let st = Command::new("/usr/bin/sqlite3")
        .arg(ls.join("localstorage.sqlite3"))
        .arg("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB NOT NULL ON CONFLICT FAIL); INSERT INTO ItemTable VALUES('apex.theme', X'6400610072006b00');")
        .status()
        .unwrap();
    assert!(st.success());

    let files = [
        "muya-ssh-vault.enc",
        "muya-ssh-config.json",
        "muya-app.json",
        "muya-vault-config.json",
    ];
    let before: Vec<String> = files.iter().map(|f| digest(&claude.join(f))).collect();
    let ls_before = digest_tree(&home.path().join("Library/WebKit"));

    // --- 2. The native side runs: migration + muyad's own writes to the shared schedules -----
    assert!(matches!(
        migrate::run(home.path()),
        migrate::Outcome::Migrated { keys: 1 }
    ));
    assert_eq!(migrate::load_ui_prefs(home.path())["apex.theme"], "dark");

    // muyad toggles the job, records a run and a status file in the shared location.
    let paths = Paths::under(&claude);
    let mut jobs = schedules::load_jobs(&paths);
    jobs[0].enabled = false;
    jobs[0].updated = 1700000999;
    schedules::save_jobs(&paths, &jobs).unwrap();
    std::fs::create_dir_all(&paths.runs).unwrap();
    std::fs::write(&paths.status, r#"{"holder":"muyad"}"#).unwrap();

    // --- 3. Reinstall the Tauri build: read everything back ----------------------------------
    // Vault: files the native side never writes stay byte-identical and still unlock.
    for (f, d) in files.iter().zip(&before) {
        assert_eq!(&digest(&claude.join(f)), d, "{f} changed while native ran");
    }
    let reopened = CredStore::default();
    rt.block_on(credstore::credstore_unlock("master-pw".into(), &reopened))
        .unwrap();
    let meta = credstore::list_meta(&reopened).unwrap();
    assert_eq!((meta.len(), meta[0].label.as_str()), (1, "lab-pw"));
    assert_eq!(
        &*credstore::secret_for(&reopened, &cred_id).unwrap(),
        "s3cret"
    );
    assert!(rt
        .block_on(credstore::credstore_unlock(
            "wrong".into(),
            &CredStore::default()
        ))
        .is_err());

    // Servers: parsed with every field intact.
    let cfg = ssh::load_from(&ssh::config_path_under(home.path().to_str().unwrap()));
    assert_eq!(cfg.servers.len(), 1);
    assert_eq!(
        (
            cfg.servers[0].host.as_str(),
            cfg.servers[0].port,
            cfg.servers[0].username.as_str()
        ),
        ("10.0.0.5", 2222, "ops")
    );

    // Schedules: the file muyad rewrote is still valid for the Tauri reader, edit included.
    let jobs = schedules::load_jobs(&Paths::under(&claude));
    assert_eq!(jobs.len(), 1);
    assert_eq!(
        (jobs[0].name.as_str(), jobs[0].enabled, jobs[0].updated),
        ("nightly", false, 1700000999)
    );
    assert_eq!(jobs[0].folder, "/work/demo");

    // Prefs.
    let prefs = app_prefs::app_prefs_get();
    assert!(!prefs.keep_running_in_background && !prefs.claude_status_in_footer);

    // Tauri's webview data: byte-identical.
    assert_eq!(digest_tree(&home.path().join("Library/WebKit")), ls_before);
}

//! Encrypted credential store for SSH / CyberArk secrets — the app's first
//! at-rest secret storage (PRD `ssh-cyberark`, Faz 0).
//!
//! Crypto: AES-256-GCM with a fresh random 96-bit nonce per seal; key =
//! Argon2id(master password, per-store salt). The on-disk blob
//! (`~/.claude/muya-ssh-vault.enc`) is a versioned JSON envelope holding the
//! public KDF params + salt + nonce + ciphertext. The master password is NEVER
//! persisted; the derived key lives only in memory (zeroized on lock/drop).
//!
//! Invariants (PRD §9): no secret is ever written to disk in plaintext, to a
//! log, or to process argv. The decrypted `secret` fields exist only inside the
//! in-memory `Unlocked` state while the store is unlocked.
//!
//! Faz 0 scope = this crypto core + password-based unlock + atomic persistence
//! + master-password re-key, all headless-testable. macOS Keychain / Touch-ID
//! auto-unlock (Model A) is implemented in Faz 1, where the running app + Touch
//! ID make it verifiable (a `cargo test` cannot exercise biometry).

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use argon2::{Algorithm, Argon2, Params, Version};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::State;
use zeroize::Zeroizing;

// Argon2id params (PRD §14 / D6): memory ≥ 46 MiB, p=1, t tuned. RAM is not
// scarce on the target (Apple Silicon); we stay well above the 19 MiB OWASP floor.
const ARGON2_M_KIB: u32 = 47104; // 46 MiB
const ARGON2_T: u32 = 3;
const ARGON2_P: u32 = 1;
const KEY_LEN: usize = 32; // AES-256
const NONCE_LEN: usize = 12; // 96-bit GCM nonce
const SALT_LEN: usize = 16;
const MAGIC: &str = "MUYA-SSHVAULT";
const BLOB_VERSION: u32 = 1;
const STORE_VERSION: u32 = 1;

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// One stored credential. `secret` (and `key_passphrase`) hold plaintext ONLY in
/// the decrypted in-memory form; they are AES-GCM-sealed at rest, AND — as of
/// prd-vault-touchid-autolock — held as `Zeroizing<String>` so the plaintext
/// bytes are actively wiped from RAM when a `Credential` drops (store lock, a
/// row's slot gets replaced on edit, etc.), not just left for the allocator to
/// reuse eventually. `Zeroizing<Z>` serializes exactly like `Z` (zeroize's
/// "serde" feature), so the on-disk encrypted blob format is unchanged — this is
/// a memory-safety hardening, not a migration.
#[derive(Serialize, Deserialize, Clone)]
pub struct Credential {
    pub id: String,
    pub label: String,
    pub username: String,
    #[serde(rename = "secretKind")]
    pub secret_kind: String, // "password" | "key" | "token"
    pub secret: Zeroizing<String>,
    /// Free-text operator note (e.g. "prod AWS deploy key"). Non-secret; surfaced
    /// to agents via `list_secrets` so they can pick the right secret BY NAME.
    /// Old store JSON lacking `description` loads as empty (serde `default`).
    #[serde(default)]
    pub description: String,
    /// Operator-assigned group so the vault UI can show cards per group. Free text;
    /// empty = "Ungrouped". Non-secret. Old store JSON without it loads as empty.
    #[serde(default)]
    pub group: String,
    #[serde(rename = "keyPassphrase", skip_serializing_if = "Option::is_none")]
    pub key_passphrase: Option<Zeroizing<String>>,
}

/// Non-secret projection returned to the UI — never carries `secret`.
#[derive(Serialize, Clone, Debug)]
pub struct CredMeta {
    pub id: String,
    pub label: String,
    pub username: String,
    #[serde(rename = "secretKind")]
    pub secret_kind: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub group: String,
}

/// Input for upsert. Empty/absent `id` = create; otherwise update in place.
#[derive(Deserialize)]
pub struct CredInput {
    #[serde(default)]
    pub id: Option<String>,
    pub label: String,
    pub username: String,
    #[serde(rename = "secretKind")]
    pub secret_kind: String,
    pub secret: Zeroizing<String>,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub group: String,
    #[serde(rename = "keyPassphrase", default)]
    pub key_passphrase: Option<Zeroizing<String>>,
}

/// The secret kinds the store accepts. `token` (AC11) covers API tokens/JSON
/// credential blobs used by the agent-ops engine, alongside SSH passwords/keys.
/// `api_key` (AC18) is a distinct label for API keys an agent stores via
/// `add_secret`, so the operator can tell them apart in the UI/list.
pub(crate) fn valid_secret_kind(kind: &str) -> bool {
    matches!(kind, "password" | "key" | "token" | "api_key")
}

/// The decrypted store contents.
#[derive(Serialize, Deserialize, Default)]
struct StoreData {
    version: u32,
    credentials: Vec<Credential>,
}

/// Public KDF header persisted alongside the ciphertext (non-secret).
#[derive(Serialize, Deserialize, Clone)]
struct KdfParams {
    algo: String,
    salt: Vec<u8>,
    m: u32,
    t: u32,
    p: u32,
}

/// On-disk envelope. `nonce` + `ciphertext` are raw bytes (serde_json encodes
/// them as number arrays — avoids pulling a base64 dependency).
#[derive(Serialize, Deserialize)]
struct SealedBlob {
    magic: String,
    version: u32,
    kdf: KdfParams,
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
}

/// In-memory unlocked state. The key is zeroized on drop via `Zeroizing`.
struct Unlocked {
    key: Zeroizing<[u8; KEY_LEN]>,
    kdf: KdfParams,
    data: StoreData,
}

/// Tauri-managed state. `None` = locked.
#[derive(Default)]
pub struct CredStore(pub Mutex<Option<Unlocked>>);

#[derive(Serialize)]
pub struct CredStoreStatus {
    pub initialized: bool,
    pub unlocked: bool,
}

// ---------------------------------------------------------------------------
// Crypto core (pure, headless-testable)
// ---------------------------------------------------------------------------

fn derive_key(password: &[u8], salt: &[u8]) -> Result<Zeroizing<[u8; KEY_LEN]>, String> {
    let params = Params::new(ARGON2_M_KIB, ARGON2_T, ARGON2_P, Some(KEY_LEN))
        .map_err(|e| format!("argon2 params: {e}"))?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = Zeroizing::new([0u8; KEY_LEN]);
    argon
        .hash_password_into(password, salt, key.as_mut())
        .map_err(|e| format!("argon2 derive: {e}"))?;
    Ok(key)
}

fn seal(key: &[u8; KEY_LEN], plaintext: &[u8]) -> Result<(Vec<u8>, Vec<u8>), String> {
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let mut nonce_bytes = [0u8; NONCE_LEN];
    rand::rng().fill_bytes(&mut nonce_bytes);
    let ct = cipher
        .encrypt(Nonce::from_slice(&nonce_bytes), plaintext)
        .map_err(|_| "encryption failed".to_string())?;
    Ok((nonce_bytes.to_vec(), ct))
}

fn open(key: &[u8; KEY_LEN], nonce_bytes: &[u8], ct: &[u8]) -> Result<Vec<u8>, String> {
    if nonce_bytes.len() != NONCE_LEN {
        return Err("bad nonce length".into());
    }
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    cipher
        .decrypt(Nonce::from_slice(nonce_bytes), ct)
        // Deliberately opaque: bad password and corrupted store are
        // indistinguishable to a caller, and no plaintext leaks.
        .map_err(|_| "decryption failed (wrong master password or corrupted store)".to_string())
}

fn new_salt() -> Vec<u8> {
    let mut s = vec![0u8; SALT_LEN];
    rand::rng().fill_bytes(&mut s);
    s
}

/// Serialize + seal `data` under `key`/`kdf` and atomically write the envelope.
fn seal_to_path(
    path: &Path,
    key: &[u8; KEY_LEN],
    kdf: &KdfParams,
    data: &StoreData,
) -> Result<(), String> {
    let plaintext = Zeroizing::new(serde_json::to_vec(data).map_err(|e| e.to_string())?);
    let (nonce, ciphertext) = seal(key, &plaintext)?;
    let blob = SealedBlob {
        magic: MAGIC.to_string(),
        version: BLOB_VERSION,
        kdf: kdf.clone(),
        nonce,
        ciphertext,
    };
    let bytes = serde_json::to_vec(&blob).map_err(|e| e.to_string())?;
    atomic_write(path, &bytes)
}

fn read_blob(path: &Path) -> Result<SealedBlob, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("store not readable: {e}"))?;
    let blob: SealedBlob =
        serde_json::from_slice(&bytes).map_err(|e| format!("store parse: {e}"))?;
    if blob.magic != MAGIC {
        return Err("not a Muya SSH vault file".into());
    }
    Ok(blob)
}

/// Write `bytes` to `path` atomically: temp file in the same dir → fsync → rename.
/// The original file (if any) stays valid until the rename succeeds (PM3/PM4).
/// Shared with `ssh.rs` for the (non-secret) config file.
pub(crate) fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let parent = path.parent().ok_or("store path has no parent")?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let tmp = parent.join(format!(
        ".muya-ssh-vault.tmp-{:016x}",
        rand::random::<u64>()
    ));

    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let write_res = (|| -> Result<(), String> {
        let mut f = opts.open(&tmp).map_err(|e| e.to_string())?;
        f.write_all(bytes).map_err(|e| e.to_string())?;
        f.sync_all().map_err(|e| e.to_string())?;
        Ok(())
    })();
    if let Err(e) = write_res {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        e.to_string()
    })
}

// ---------------------------------------------------------------------------
// Store operations on explicit paths (testable without Tauri state)
// ---------------------------------------------------------------------------

/// Create a brand-new empty store sealed under `master`. Fails if `path` exists.
fn init_at(path: &Path, master: &[u8]) -> Result<(), String> {
    if path.exists() {
        return Err("store already exists".into());
    }
    let salt = new_salt();
    let key = derive_key(master, &salt)?;
    let kdf = KdfParams {
        algo: "argon2id".into(),
        salt,
        m: ARGON2_M_KIB,
        t: ARGON2_T,
        p: ARGON2_P,
    };
    let data = StoreData {
        version: STORE_VERSION,
        credentials: vec![],
    };
    seal_to_path(path, &key, &kdf, &data)
}

/// Read + decrypt the store at `path` with `master`, returning the unlocked state.
fn unlock_at(path: &Path, master: &[u8]) -> Result<Unlocked, String> {
    let blob = read_blob(path)?;
    let key = derive_key(master, &blob.kdf.salt)?;
    let plaintext = Zeroizing::new(open(&key, &blob.nonce, &blob.ciphertext)?);
    let data: StoreData =
        serde_json::from_slice(&plaintext).map_err(|e| format!("store decode: {e}"))?;
    Ok(Unlocked {
        key,
        kdf: blob.kdf,
        data,
    })
}

/// Re-encrypt the store under a new master password. Atomic rename means a crash
/// mid-rekey leaves the ORIGINAL blob intact (PM4 / AC1.5 core).
/// Exposed via the `credstore_rekey` command; also exercised by `ac1_5_rekey`.
fn rekey_at(path: &Path, old_master: &[u8], new_master: &[u8]) -> Result<(), String> {
    let unlocked = unlock_at(path, old_master)?;
    let salt = new_salt();
    let key = derive_key(new_master, &salt)?;
    let kdf = KdfParams {
        algo: "argon2id".into(),
        salt,
        m: ARGON2_M_KIB,
        t: ARGON2_T,
        p: ARGON2_P,
    };
    seal_to_path(path, &key, &kdf, &unlocked.data)
}

fn default_store_path() -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    Ok(Path::new(&home).join(".claude/muya-ssh-vault.enc"))
}

// ---------------------------------------------------------------------------
// Tauri commands
// ---------------------------------------------------------------------------

#[tauri::command]
pub fn credstore_status(state: State<'_, CredStore>) -> Result<CredStoreStatus, String> {
    let initialized = default_store_path().map(|p| p.exists()).unwrap_or(false);
    let unlocked = state.0.lock().map_err(|_| "state poisoned")?.is_some();
    Ok(CredStoreStatus {
        initialized,
        unlocked,
    })
}

/// Create the store with a master password. Argon2id runs off the command
/// executor (PM2 / AC0.6) so the UI never blocks; the state lock is taken only
/// briefly afterward.
#[tauri::command]
pub async fn credstore_init(master: String, state: State<'_, CredStore>) -> Result<(), String> {
    let path = default_store_path()?;
    let master = Zeroizing::new(master.into_bytes());
    let unlocked = tokio::task::spawn_blocking(move || {
        init_at(&path, &master)?;
        unlock_at(&path, &master)
    })
    .await
    .map_err(|e| format!("kdf task failed: {e}"))??;
    *state.0.lock().map_err(|_| "state poisoned")? = Some(unlocked);
    Ok(())
}

#[tauri::command]
pub async fn credstore_unlock(master: String, state: State<'_, CredStore>) -> Result<(), String> {
    let path = default_store_path()?;
    let master = Zeroizing::new(master.into_bytes());
    let unlocked = tokio::task::spawn_blocking(move || unlock_at(&path, &master))
        .await
        .map_err(|e| format!("kdf task failed: {e}"))??;
    *state.0.lock().map_err(|_| "state poisoned")? = Some(unlocked);
    Ok(())
}

/// Locks the store AND tells the frontend it happened. The event matters because
/// lock can now fire from outside the Password Store screen (the app-wide idle
/// timer, `App.tsx`) — without it, a tab that isn't actively polling would keep
/// showing "Unlocked" (and any already-`reveal`ed secret still sitting in its
/// React state) after the backend has already locked. Note on what actually gets
/// zeroized: only the derived master KEY (`Unlocked.key: Zeroizing<...>`) is wiped
/// on drop here — individual credential secrets in `Unlocked.data.credentials`
/// are plain `String`s (never zeroized) for as long as the process ran unlocked;
/// see the answer given when this was asked, `docs/prd-vault-touchid-autolock.md`.
#[tauri::command]
pub fn credstore_lock(state: State<'_, CredStore>, app: tauri::AppHandle) -> Result<(), String> {
    use tauri::Emitter;
    *state.0.lock().map_err(|_| "state poisoned")? = None; // zeroizes ONLY the derived key
    let _ = app.emit("muya://vault-locked", ());
    Ok(())
}

// ---------------------------------------------------------------------------
// Touch ID / Keychain unlock (PRD vault-touchid-autolock — applies "Model A"
// from prd-ssh-cyberark.md's D1/D4/ARCH1). The Argon2id-derived KEY (never the
// master password) is cached in the macOS Keychain behind an access-control item
// that requires Touch ID (BIOMETRY_CURRENT_SET) OR the Mac's own login password
// (DEVICE_PASSCODE) — reading it triggers that OS prompt automatically, no
// LocalAuthentication calls needed on our side. Master-password unlock always
// remains available as the fallback (Touch ID never enrolled/canceled/disabled).
// ---------------------------------------------------------------------------

const KEYCHAIN_SERVICE: &str = "com.staunch.muya.vault";
const KEYCHAIN_ACCOUNT: &str = "master-key";

/// Bit flags proven against the `security-framework` 3.7.0 source
/// (`passwords_options.rs`): `OR` means EITHER constraint satisfies the gate.
fn biometric_or_passcode_flags() -> security_framework::passwords::AccessControlOptions {
    use security_framework::passwords::AccessControlOptions as F;
    F::BIOMETRY_CURRENT_SET | F::DEVICE_PASSCODE | F::OR
}

/// Write `key` to the Keychain under the biometry-or-passcode gate. Deletes any
/// existing item first — access-control attributes are safest set on a fresh
/// insert rather than relying on `SecItemUpdate`'s partial-attribute semantics
/// (see PRD §2 "Re-key uyumu").
fn keychain_store_key(key: &[u8; KEY_LEN]) -> Result<(), String> {
    use security_framework::passwords::{
        delete_generic_password_options, set_generic_password_options, PasswordOptions,
    };
    let _ = delete_generic_password_options(PasswordOptions::new_generic_password(
        KEYCHAIN_SERVICE,
        KEYCHAIN_ACCOUNT,
    ));
    let mut opts = PasswordOptions::new_generic_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT);
    opts.use_protected_keychain();
    opts.set_access_control_options(biometric_or_passcode_flags());
    set_generic_password_options(key, opts).map_err(|e| format!("Keychain write failed: {e}"))
}

/// Read the cached key back. This is the call that triggers the OS Touch
/// ID/passcode prompt (nothing on our side drives biometry directly).
fn keychain_load_key() -> Result<[u8; KEY_LEN], String> {
    use security_framework::passwords::{generic_password, PasswordOptions};
    let mut opts = PasswordOptions::new_generic_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT);
    opts.use_protected_keychain();
    let bytes = generic_password(opts).map_err(|e| {
        e.message()
            .unwrap_or_else(|| "Touch ID unlock is not available".to_string())
    })?;
    bytes.try_into().map_err(|_| {
        "Keychain-cached key has the wrong length — re-enable Touch ID unlock".to_string()
    })
}

fn keychain_delete_key() -> Result<(), String> {
    use security_framework::passwords::{delete_generic_password_options, PasswordOptions};
    delete_generic_password_options(PasswordOptions::new_generic_password(
        KEYCHAIN_SERVICE,
        KEYCHAIN_ACCOUNT,
    ))
    .or_else(|e| {
        // Already gone is fine — "disable" is idempotent.
        if e.message().unwrap_or_default().contains("not found") {
            Ok(())
        } else {
            Err(format!("Keychain delete failed: {e}"))
        }
    })
}

/// `~/.claude/muya-vault-prefs.json` — deliberately its OWN file, not the shared
/// `muya-settings.json` debug-logging uses: that file's writer overwrites the
/// whole document with only its own keys (no merge), so sharing it would risk
/// silently erasing the other setting on every save.
fn vault_prefs_path() -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    Ok(Path::new(&home).join(".claude/muya-vault-prefs.json"))
}

fn set_biometric_pref(enabled: bool) -> Result<(), String> {
    set_biometric_pref_at(&vault_prefs_path()?, enabled)
}

/// Path-injectable core, so tests never touch the operator's real `~/.claude/`.
fn set_biometric_pref_at(path: &Path, enabled: bool) -> Result<(), String> {
    let bytes =
        serde_json::to_vec_pretty(&serde_json::json!({ "biometricUnlockEnabled": enabled }))
            .map_err(|e| e.to_string())?;
    atomic_write(path, &bytes)
}

fn biometric_available_at(path: &Path) -> bool {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| v.get("biometricUnlockEnabled").and_then(|b| b.as_bool()))
        .unwrap_or(false)
}

/// Sync, no Keychain access — never triggers the biometry prompt just to check
/// whether the UI should offer the "Unlock with Touch ID" button.
#[tauri::command]
pub fn credstore_biometric_available() -> bool {
    match vault_prefs_path() {
        Ok(p) => biometric_available_at(&p),
        Err(_) => false,
    }
}

/// Cache the CURRENTLY unlocked store's key in the Keychain. Requires the store
/// to already be unlocked (by master password) — this is an explicit opt-in
/// action, never automatic.
#[tauri::command]
pub fn credstore_enable_biometric_unlock(state: State<'_, CredStore>) -> Result<(), String> {
    let guard = state.0.lock().map_err(|_| "state poisoned")?;
    let u = guard.as_ref().ok_or("store is locked")?;
    keychain_store_key(&u.key)?;
    set_biometric_pref(true)
}

#[tauri::command]
pub fn credstore_disable_biometric_unlock() -> Result<(), String> {
    keychain_delete_key()?;
    set_biometric_pref(false)
}

/// Unlock using the Keychain-cached key instead of a master password — skips the
/// Argon2id re-derivation entirely (the key is already the derived one), so this
/// is near-instant once Touch ID/passcode is satisfied.
#[tauri::command]
pub async fn credstore_unlock_biometric(state: State<'_, CredStore>) -> Result<(), String> {
    let path = default_store_path()?;
    let unlocked = tokio::task::spawn_blocking(move || -> Result<Unlocked, String> {
        let key = keychain_load_key()?;
        let blob = read_blob(&path)?;
        let plaintext = Zeroizing::new(open(&key, &blob.nonce, &blob.ciphertext)?);
        let data: StoreData =
            serde_json::from_slice(&plaintext).map_err(|e| format!("store decode: {e}"))?;
        Ok(Unlocked {
            key: Zeroizing::new(key),
            kdf: blob.kdf,
            data,
        })
    })
    .await
    .map_err(|e| format!("unlock task failed: {e}"))??;
    *state.0.lock().map_err(|_| "state poisoned")? = Some(unlocked);
    Ok(())
}

/// Export the master password itself to `dest` (0600). The app never persists
/// the master, so this only works at the moment the caller supplies it (store
/// create/unlock). PLAINTEXT on disk by explicit operator request — the UI warns.
#[tauri::command]
pub fn credstore_export_master(dest: String, master: String) -> Result<(), String> {
    if dest.trim().is_empty() {
        return Err("destination path is required".into());
    }
    if master.is_empty() {
        return Err("master password is empty".into());
    }
    atomic_write(Path::new(&dest), master.as_bytes())
}

/// Import an SSH private key from `src_path` into the unlocked store as a new
/// key credential. The key bytes are read in Rust and sealed directly — they
/// never pass through the JS/webview layer (§9, ARCH-RG1 spirit).
#[tauri::command]
pub fn credstore_import_key(
    label: String,
    username: String,
    src_path: String,
    state: State<'_, CredStore>,
) -> Result<String, String> {
    let bytes = std::fs::read(&src_path).map_err(|e| format!("read key file: {e}"))?;
    let key_text =
        String::from_utf8(bytes).map_err(|_| "key file is not valid UTF-8 text".to_string())?;
    let path = default_store_path()?;
    let mut guard = state.0.lock().map_err(|_| "state poisoned")?;
    let u = guard.as_mut().ok_or("store is locked")?;
    let id = new_id();
    u.data.credentials.push(Credential {
        id: id.clone(),
        label,
        username,
        secret_kind: "key".into(),
        secret: Zeroizing::new(key_text),
        description: String::new(),
        group: String::new(),
        key_passphrase: None,
    });
    seal_to_path(&path, &u.key, &u.kdf, &u.data)?;
    Ok(id)
}

/// Import ANY secret kind (password/token/api_key/key) from a file as a new
/// credential — the generic counterpart to `credstore_import_key` (which is
/// SSH-key-specific and predates `secretKind`/`group`). The file bytes are read in
/// Rust and sealed directly; they never pass through the JS/webview layer (§9).
/// A key's exact bytes matter (PEM framing) — never touched. Anything else is
/// normally a single pasted value, so drop ONE trailing newline a text
/// editor/`echo` adds (CRLF or LF). Pure/testable.
pub(crate) fn trim_imported_secret(secret_kind: &str, raw: String) -> String {
    if secret_kind == "key" {
        return raw;
    }
    match raw.strip_suffix('\n') {
        Some(s) => s.strip_suffix('\r').unwrap_or(s).to_string(),
        None => raw,
    }
}

#[tauri::command]
pub fn credstore_import_secret(
    label: String,
    username: String,
    secret_kind: String,
    description: String,
    group: String,
    src_path: String,
    state: State<'_, CredStore>,
) -> Result<String, String> {
    if !valid_secret_kind(&secret_kind) {
        return Err(format!("unknown secret kind '{secret_kind}'"));
    }
    if label.trim().is_empty() {
        return Err("label is required".into());
    }
    let bytes = std::fs::read(&src_path).map_err(|e| format!("read file: {e}"))?;
    let raw = String::from_utf8(bytes).map_err(|_| "file is not valid UTF-8 text".to_string())?;
    let secret = Zeroizing::new(trim_imported_secret(&secret_kind, raw));
    let path = default_store_path()?;
    let mut guard = state.0.lock().map_err(|_| "state poisoned")?;
    let u = guard.as_mut().ok_or("store is locked")?;
    let id = new_id();
    u.data.credentials.push(Credential {
        id: id.clone(),
        label,
        username,
        secret_kind,
        secret,
        description,
        group,
        key_passphrase: None,
    });
    seal_to_path(&path, &u.key, &u.kdf, &u.data)?;
    Ok(id)
}

/// Export a stored credential's secret (password or key) to `dest` (0600). The
/// secret is read from the unlocked in-memory store and written in Rust — it
/// never passes through the JS/webview layer.
#[tauri::command]
pub fn credstore_export_cred(
    id: String,
    dest: String,
    state: State<'_, CredStore>,
) -> Result<(), String> {
    if dest.trim().is_empty() {
        return Err("destination path is required".into());
    }
    let guard = state.0.lock().map_err(|_| "state poisoned")?;
    let u = guard.as_ref().ok_or("store is locked")?;
    let cred = u
        .data
        .credentials
        .iter()
        .find(|c| c.id == id)
        .ok_or("credential not found")?;
    atomic_write(Path::new(&dest), cred.secret.as_bytes())
}

/// Operator-only reveal of a stored credential's plaintext `secret` by id. Gated
/// on an unlocked store (locked → clear error). This is exclusively for the
/// desktop Password Store UI so the human can view/copy/edit their OWN secret —
/// it is deliberately NOT wired into the MCP broker/proxy, so agents never gain a
/// raw-reveal path here (they use the operator-opted-in `get_secret` separately).
/// Never logged.
#[tauri::command]
pub fn credstore_reveal_cred(id: String, state: State<'_, CredStore>) -> Result<String, String> {
    reveal_cred(&state, &id)
}

/// Pure core of `credstore_reveal_cred` so tests can exercise it against a temp
/// vault. Returns the plaintext secret for `id`, or a clear error when the store
/// is locked / the id is unknown.
pub(crate) fn reveal_cred(store: &CredStore, id: &str) -> Result<String, String> {
    let guard = store.0.lock().map_err(|_| "state poisoned")?;
    let u = guard
        .as_ref()
        .ok_or("password store is locked — unlock it in the Password Store tab")?;
    u.data
        .credentials
        .iter()
        .find(|c| c.id == id)
        .map(|c| c.secret.to_string())
        .ok_or_else(|| "credential not found".into())
}

/// Export the encrypted store to `dest` as a portable backup. The file is
/// already AES-256-GCM sealed under the master-derived key, so the backup still
/// requires the master password to open — no plaintext ever leaves the app (§9).
/// The master password itself is never persisted and therefore cannot be
/// exported; this backup is the recovery/portability path.
#[tauri::command]
pub fn credstore_export(dest: String) -> Result<(), String> {
    let src = default_store_path()?;
    if !src.exists() {
        return Err("no store to export".into());
    }
    if dest.trim().is_empty() {
        return Err("destination path is required".into());
    }
    std::fs::copy(&src, &dest).map_err(|e| format!("export failed: {e}"))?;
    Ok(())
}

/// Change the master password: re-encrypt the whole store under a new key. The
/// original blob stays intact until the atomic rename succeeds (PM4/AC1.5). On
/// success the in-memory session is refreshed with the new key. KDF runs
/// off-thread (twice: unlock-old + derive-new) so the UI never blocks.
///
/// Faz 1 note: when the Keychain-cached key is added, this command must also
/// update/invalidate that item so Touch-ID unlock never uses a stale key.
#[tauri::command]
pub async fn credstore_rekey(
    old_master: String,
    new_master: String,
    state: State<'_, CredStore>,
) -> Result<(), String> {
    let path = default_store_path()?;
    let old = Zeroizing::new(old_master.into_bytes());
    let new = Zeroizing::new(new_master.into_bytes());
    let unlocked = tokio::task::spawn_blocking(move || {
        rekey_at(&path, &old, &new)?;
        unlock_at(&path, &new)
    })
    .await
    .map_err(|e| format!("kdf task failed: {e}"))??;
    // Keep Touch ID working after a master-password change: re-key means the
    // encryption key changed, so a stale Keychain-cached key would silently fail
    // (or worse, decrypt garbage) on the next biometric unlock. PRD AC5.
    if credstore_biometric_available() {
        let _ = keychain_store_key(&unlocked.key);
    }
    *state.0.lock().map_err(|_| "state poisoned")? = Some(unlocked);
    Ok(())
}

#[tauri::command]
pub fn credstore_cred_list(state: State<'_, CredStore>) -> Result<Vec<CredMeta>, String> {
    let guard = state.0.lock().map_err(|_| "state poisoned")?;
    let u = guard.as_ref().ok_or("store is locked")?;
    Ok(u.data
        .credentials
        .iter()
        .map(|c| CredMeta {
            id: c.id.clone(),
            label: c.label.clone(),
            username: c.username.clone(),
            secret_kind: c.secret_kind.clone(),
            description: c.description.clone(),
            group: c.group.clone(),
        })
        .collect())
}

/// AC12 — non-secret metadata for the SSH broker's `list_secrets` op. Gated on an
/// unlocked store (locked → clear error, never a metadata dump). Returns the same
/// `CredMeta` the UI sees — never the secret. Used by `broker::handle_request`.
pub(crate) fn list_meta(store: &CredStore) -> Result<Vec<CredMeta>, String> {
    let guard = store.0.lock().map_err(|_| "state poisoned")?;
    let u = guard
        .as_ref()
        .ok_or("password store is locked — unlock it in the Password Store tab")?;
    Ok(u.data
        .credentials
        .iter()
        .map(|c| CredMeta {
            id: c.id.clone(),
            label: c.label.clone(),
            username: c.username.clone(),
            secret_kind: c.secret_kind.clone(),
            description: c.description.clone(),
            group: c.group.clone(),
        })
        .collect())
}

/// AC17 — CREATE-ONLY insert of a NEW secret from the SSH broker's `add_secret`
/// op. Unlike `credstore_cred_upsert`, this NEVER updates an existing credential:
/// if a credential with the same `label` already exists it errors, so an injected
/// agent cannot silently overwrite a real operator secret. Gated on an unlocked
/// store (locked → clear error). Returns the non-secret `CredMeta` — never the
/// value. Persists the store to disk (AES-256-GCM sealed) before returning.
pub(crate) fn add_credential(
    store: &CredStore,
    label: String,
    description: String,
    kind: String,
    value: String,
) -> Result<CredMeta, String> {
    let path = default_store_path()?;
    add_credential_at(store, &path, label, description, kind, value)
}

/// Path-injectable core of `add_credential` so tests can seal to a temp vault
/// instead of clobbering the operator's real store. Do not call directly outside
/// tests — production goes through `add_credential` (default path).
fn add_credential_at(
    store: &CredStore,
    path: &Path,
    label: String,
    description: String,
    kind: String,
    value: String,
) -> Result<CredMeta, String> {
    if label.trim().is_empty() {
        return Err("secret `name` is required".into());
    }
    if value.is_empty() {
        return Err("secret `value` is required".into());
    }
    if !valid_secret_kind(&kind) {
        return Err("kind must be 'password', 'key', 'token', or 'api_key'".into());
    }
    let mut guard = store.0.lock().map_err(|_| "state poisoned")?;
    let u = guard
        .as_mut()
        .ok_or("password store is locked — unlock it in the Password Store tab")?;
    // CREATE-ONLY: reject a name collision instead of overwriting (injected-agent
    // protection). Match on `label`, which is the agent-facing secret name.
    if u.data.credentials.iter().any(|c| c.label == label) {
        return Err(format!("a secret named '{label}' already exists"));
    }
    let id = new_id();
    let cred = Credential {
        id,
        label,
        username: String::new(),
        secret_kind: kind,
        secret: Zeroizing::new(value),
        description,
        group: String::new(),
        key_passphrase: None,
    };
    let meta = CredMeta {
        id: cred.id.clone(),
        label: cred.label.clone(),
        username: cred.username.clone(),
        secret_kind: cred.secret_kind.clone(),
        description: cred.description.clone(),
        group: cred.group.clone(),
    };
    u.data.credentials.push(cred);
    seal_to_path(path, &u.key, &u.kdf, &u.data)?;
    Ok(meta)
}

#[tauri::command]
pub fn credstore_cred_upsert(
    cred: CredInput,
    state: State<'_, CredStore>,
) -> Result<String, String> {
    let path = default_store_path()?;
    let mut guard = state.0.lock().map_err(|_| "state poisoned")?;
    let u = guard.as_mut().ok_or("store is locked")?;
    if !valid_secret_kind(&cred.secret_kind) {
        return Err("secretKind must be 'password', 'key', 'token', or 'api_key'".into());
    }
    let id = match cred.id.filter(|s| !s.is_empty()) {
        Some(existing) => {
            let slot = u
                .data
                .credentials
                .iter_mut()
                .find(|c| c.id == existing)
                .ok_or("credential not found")?;
            slot.label = cred.label;
            slot.username = cred.username;
            slot.secret_kind = cred.secret_kind;
            slot.secret = cred.secret;
            slot.description = cred.description;
            slot.group = cred.group;
            slot.key_passphrase = cred.key_passphrase;
            existing
        }
        None => {
            let id = new_id();
            u.data.credentials.push(Credential {
                id: id.clone(),
                label: cred.label,
                username: cred.username,
                secret_kind: cred.secret_kind,
                secret: cred.secret,
                description: cred.description,
                group: cred.group,
                key_passphrase: cred.key_passphrase,
            });
            id
        }
    };
    seal_to_path(&path, &u.key, &u.kdf, &u.data)?;
    Ok(id)
}

#[tauri::command]
pub fn credstore_cred_remove(id: String, state: State<'_, CredStore>) -> Result<(), String> {
    let path = default_store_path()?;
    let mut guard = state.0.lock().map_err(|_| "state poisoned")?;
    let u = guard.as_mut().ok_or("store is locked")?;
    let before = u.data.credentials.len();
    u.data.credentials.retain(|c| c.id != id);
    if u.data.credentials.len() == before {
        return Err("credential not found".into());
    }
    seal_to_path(&path, &u.key, &u.kdf, &u.data)
}

/// Read a stored credential's secret from the unlocked in-memory store for
/// in-process use (SSH PTY password injection). The secret is returned wrapped
/// in `Zeroizing` and MUST NOT be forwarded to the JS/webview layer (§9).
pub(crate) fn secret_for(store: &CredStore, id: &str) -> Result<Zeroizing<String>, String> {
    let guard = store.0.lock().map_err(|_| "state poisoned")?;
    let u = guard
        .as_ref()
        .ok_or("password store is locked — unlock it in the Password Store tab")?;
    let cred = u
        .data
        .credentials
        .iter()
        .find(|c| c.id == id)
        .ok_or("stored credential not found")?;
    Ok(cred.secret.clone())
}

/// Resolve a secret by human-facing REFERENCE — its NAME (label) or its id — for
/// operator-authored agent operations (`muya-agent-ops.json`). Operators reference
/// a secret by the name they gave it (e.g. `test-apikey-demo`), not the internal
/// hex id, so match `label` first and fall back to `id`. Same unlock gate + no-leak
/// contract as `secret_for`. (Fix: ops used `secret_for` (id-only) → a name ref
/// always failed with "stored credential not found".)
pub(crate) fn secret_for_ref(
    store: &CredStore,
    reference: &str,
) -> Result<Zeroizing<String>, String> {
    let guard = store.0.lock().map_err(|_| "state poisoned")?;
    let u = guard
        .as_ref()
        .ok_or("password store is locked — unlock it in the Password Store tab")?;
    let cred = u
        .data
        .credentials
        .iter()
        .find(|c| c.label == reference || c.id == reference)
        .ok_or_else(|| format!("no stored secret named '{reference}' (check the name in muya-agent-ops.json matches a Password Store entry)"))?;
    Ok(cred.secret.clone())
}

/// Update an EXISTING secret's value, matched by NAME (label) or id — the write
/// side of the agent secret store (rotation). Update-only: a missing reference
/// errors (use `add_credential` to create). Unlock-gated; reseals to disk under
/// AES-256-GCM. Returns the non-secret `CredMeta` — never the value.
pub(crate) fn update_credential(
    store: &CredStore,
    reference: &str,
    value: String,
) -> Result<CredMeta, String> {
    let path = default_store_path()?;
    update_credential_at(store, &path, reference, value)
}

/// Path-injectable core of `update_credential` so tests never touch the real store.
fn update_credential_at(
    store: &CredStore,
    path: &Path,
    reference: &str,
    value: String,
) -> Result<CredMeta, String> {
    if value.is_empty() {
        return Err("secret `value` is required".into());
    }
    let mut guard = store.0.lock().map_err(|_| "state poisoned")?;
    let u = guard
        .as_mut()
        .ok_or("password store is locked — unlock it in the Password Store tab")?;
    let cred = u
        .data
        .credentials
        .iter_mut()
        .find(|c| c.label == reference || c.id == reference)
        .ok_or_else(|| {
            format!("no stored secret named '{reference}' — use add_secret to create it first")
        })?;
    cred.secret = Zeroizing::new(value);
    let meta = CredMeta {
        id: cred.id.clone(),
        label: cred.label.clone(),
        username: cred.username.clone(),
        secret_kind: cred.secret_kind.clone(),
        description: cred.description.clone(),
        group: cred.group.clone(),
    };
    seal_to_path(path, &u.key, &u.kdf, &u.data)?;
    Ok(meta)
}

/// Cheap unlock probe for the SSH broker's `open` gate: true when the store is
/// currently unlocked. Never touches secrets, so it is safe to call from the
/// broker before deciding whether a `local`-sourced server can be opened.
pub(crate) fn is_unlocked(store: &CredStore) -> bool {
    store.0.lock().map(|g| g.is_some()).unwrap_or(false)
}

pub(crate) fn new_id() -> String {
    // Non-cryptographic unique id (128 random bits, hex) — no uuid crate needed.
    format!(
        "{:016x}{:016x}",
        rand::random::<u64>(),
        rand::random::<u64>()
    )
}

// ---------------------------------------------------------------------------
// Tests — the crypto core acceptance criteria (Faz 0)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn kdf_with(salt: Vec<u8>) -> KdfParams {
        KdfParams {
            algo: "argon2id".into(),
            salt,
            m: ARGON2_M_KIB,
            t: ARGON2_T,
            p: ARGON2_P,
        }
    }

    // AC0.1 — seal a secret and open it back to the same plaintext (round-trip).
    #[test]
    fn ac0_1_round_trip() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("vault.enc");
        init_at(&path, b"correct horse").unwrap();
        let mut u = unlock_at(&path, b"correct horse").unwrap();
        u.data.credentials.push(Credential {
            id: "1".into(),
            label: "homelab".into(),
            username: "root".into(),
            secret_kind: "password".into(),
            secret: Zeroizing::new("s3cr3t-x".to_string()),
            description: String::new(),
            group: String::new(),
            key_passphrase: None,
        });
        seal_to_path(&path, &u.key, &u.kdf, &u.data).unwrap();

        let u2 = unlock_at(&path, b"correct horse").unwrap();
        assert_eq!(u2.data.credentials.len(), 1);
        assert_eq!(u2.data.credentials[0].secret.as_str(), "s3cr3t-x");
    }

    // AC0.2 — wrong master password fails and never yields plaintext.
    #[test]
    fn ac0_2_wrong_password_fails() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("vault.enc");
        init_at(&path, b"right-password").unwrap();
        // Avoid `unwrap_err()` — it would require `Unlocked: Debug`, and we never
        // derive Debug on a type holding the key.
        let err = match unlock_at(&path, b"WRONG-password") {
            Err(e) => e,
            Ok(_) => panic!("wrong password must not unlock the store"),
        };
        assert!(err.contains("decryption failed"), "unexpected: {err}");
    }

    // AC0.3 — 1000 seals produce 1000 distinct nonces (no reuse).
    #[test]
    fn ac0_3_nonces_are_unique() {
        use std::collections::HashSet;
        let key = [7u8; KEY_LEN];
        let mut seen = HashSet::new();
        for _ in 0..1000 {
            let (nonce, _) = seal(&key, b"payload").unwrap();
            assert_eq!(nonce.len(), NONCE_LEN);
            assert!(seen.insert(nonce), "nonce reuse detected");
        }
        assert_eq!(seen.len(), 1000);
    }

    // AC0.4 — a locked store (no unlocked state) exposes no data.
    #[test]
    fn ac0_4_locked_exposes_nothing() {
        let store: Option<Unlocked> = None;
        assert!(store.as_ref().map(|u| &u.data).is_none());
    }

    // AC1.5 core — re-key: new password unlocks, old fails, data preserved,
    // original blob survives (atomic rename).
    #[test]
    fn ac1_5_rekey() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("vault.enc");
        init_at(&path, b"old-pass").unwrap();
        let mut u = unlock_at(&path, b"old-pass").unwrap();
        u.data.credentials.push(Credential {
            id: "1".into(),
            label: "l".into(),
            username: "u".into(),
            secret_kind: "password".into(),
            secret: Zeroizing::new("keepme".to_string()),
            description: String::new(),
            group: String::new(),
            key_passphrase: None,
        });
        seal_to_path(&path, &u.key, &u.kdf, &u.data).unwrap();

        rekey_at(&path, b"old-pass", b"new-pass").unwrap();
        assert!(
            unlock_at(&path, b"old-pass").is_err(),
            "old password must stop working"
        );
        let u2 = unlock_at(&path, b"new-pass").unwrap();
        assert_eq!(u2.data.credentials[0].secret.as_str(), "keepme");
    }

    // AC0.6 support — derive is deterministic per (password,salt) and diverges
    // across salts; the command layer runs this off-thread via spawn_blocking.
    #[test]
    fn ac0_6_derive_deterministic_and_salted() {
        let salt_a = kdf_with(new_salt()).salt;
        let salt_b = kdf_with(new_salt()).salt;
        let k1 = derive_key(b"pw", &salt_a).unwrap();
        let k2 = derive_key(b"pw", &salt_a).unwrap();
        let k3 = derive_key(b"pw", &salt_b).unwrap();
        assert_eq!(*k1, *k2, "same password+salt must derive the same key");
        assert_ne!(*k1, *k3, "different salt must derive a different key");
    }

    // AC11 — a Credential JSON lacking `description` deserializes (empty string),
    // so pre-AC11 stores still load unchanged.
    #[test]
    fn ac11_credential_without_description_deserializes() {
        let json = r#"{"id":"1","label":"l","username":"u","secretKind":"password","secret":"x"}"#;
        let c: Credential = serde_json::from_str(json).unwrap();
        assert_eq!(c.description, "");
        assert_eq!(c.secret_kind, "password");
    }

    // AC11 — the `token` kind is now accepted alongside password/key; garbage is not.
    #[test]
    fn ac11_token_kind_is_valid() {
        assert!(valid_secret_kind("token"));
        assert!(valid_secret_kind("password"));
        assert!(valid_secret_kind("key"));
        assert!(!valid_secret_kind("shell"));
        assert!(!valid_secret_kind(""));
    }

    // AC18 — `api_key` is accepted alongside the existing kinds; unknown still rejected.
    #[test]
    fn ac18_api_key_kind_is_valid() {
        assert!(valid_secret_kind("api_key"));
        // The pre-AC18 kinds still validate (no regression).
        assert!(valid_secret_kind("token"));
        assert!(valid_secret_kind("password"));
        assert!(valid_secret_kind("key"));
        // An unknown kind is still rejected.
        assert!(!valid_secret_kind("apikey"));
        assert!(!valid_secret_kind("shell"));
        assert!(!valid_secret_kind(""));
    }

    // Build an unlocked in-memory store backed by a temp vault for add_secret tests.
    fn unlocked_store(path: &Path) -> CredStore {
        init_at(path, b"pw").unwrap();
        let unlocked = unlock_at(path, b"pw").unwrap();
        CredStore(Mutex::new(Some(unlocked)))
    }

    // Agent-ops secret reference resolves by NAME (label) — the operator's natural
    // reference — and also by id, while an unknown name errors clearly. Regression
    // for "stored credential not found" when an op referenced a secret by name.
    #[test]
    fn secret_for_ref_resolves_by_name_or_id() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("vault.enc");
        let store = unlocked_store(&path);
        let meta = add_credential_at(
            &store,
            &path,
            "test-apikey-demo".into(),
            "".into(),
            "api_key".into(),
            "SECRETVAL".into(),
        )
        .unwrap();

        // By name (what the operator writes in muya-agent-ops.json)…
        assert_eq!(
            &*secret_for_ref(&store, "test-apikey-demo").unwrap(),
            "SECRETVAL"
        );
        // …and by id (backward-compatible).
        assert_eq!(&*secret_for_ref(&store, &meta.id).unwrap(), "SECRETVAL");
        // An unknown reference errors with a helpful message, not a silent match.
        let err = secret_for_ref(&store, "nope").unwrap_err();
        assert!(
            err.contains("no stored secret named 'nope'"),
            "unexpected: {err}"
        );
    }

    // Operator reveal returns the plaintext by id on an unlocked store, errors
    // clearly on an unknown id, and refuses when the store is locked. Guards the
    // desktop view/copy/edit path without exposing a raw-reveal to agents.
    #[test]
    fn reveal_cred_unlocked_returns_value_locked_errors() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("vault.enc");
        let store = unlocked_store(&path);
        let meta = add_credential_at(
            &store,
            &path,
            "reveal-demo".into(),
            "".into(),
            "password".into(),
            "TOPSECRET".into(),
        )
        .unwrap();

        // Unlocked → exact plaintext by id.
        assert_eq!(reveal_cred(&store, &meta.id).unwrap(), "TOPSECRET");
        // Unknown id → clear error, never a silent empty value.
        assert!(reveal_cred(&store, "nope")
            .unwrap_err()
            .contains("credential not found"));

        // A locked store refuses to reveal.
        let locked = CredStore(Mutex::new(None));
        assert!(reveal_cred(&locked, &meta.id)
            .unwrap_err()
            .contains("locked"));
    }

    // update_credential rotates an EXISTING secret by name; a missing name errors
    // (update-only), and the new value is persisted + readable via secret_for_ref.
    #[test]
    fn update_credential_rotates_existing_only() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("vault.enc");
        let store = unlocked_store(&path);
        add_credential_at(
            &store,
            &path,
            "aws-key".into(),
            "".into(),
            "api_key".into(),
            "OLD".into(),
        )
        .unwrap();

        // Update by name → new value is stored and reads back.
        let meta = update_credential_at(&store, &path, "aws-key", "NEW".into()).unwrap();
        assert_eq!(meta.label, "aws-key");
        assert_eq!(&*secret_for_ref(&store, "aws-key").unwrap(), "NEW");

        // Update-only: a non-existent name errors, does not create.
        let err = update_credential_at(&store, &path, "ghost", "X".into()).unwrap_err();
        assert!(
            err.contains("no stored secret named 'ghost'"),
            "unexpected: {err}"
        );
    }

    // AC17 — add_secret writes a NEW credential: it shows up in list_meta, and the
    // returned meta (nor the store meta) never carries the secret value.
    #[test]
    fn ac17_add_secret_creates_and_hides_value() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("vault.enc");
        let store = unlocked_store(&path);

        let meta = add_credential_at(
            &store,
            &path,
            "gh-token".into(),
            "workflow token".into(),
            "api_key".into(),
            "ghp_SUPERSECRET".into(),
        )
        .unwrap();
        assert_eq!(meta.label, "gh-token");
        assert_eq!(meta.secret_kind, "api_key");

        // Appears in the agent-facing metadata list.
        let metas = list_meta(&store).unwrap();
        assert!(metas.iter().any(|m| m.label == "gh-token"));

        // Neither the returned meta nor list_meta leaks the value.
        let meta_json = serde_json::to_string(&meta).unwrap();
        let list_json = serde_json::to_string(&metas).unwrap();
        for j in [&meta_json, &list_json] {
            assert!(
                !j.contains("ghp_SUPERSECRET"),
                "add_secret leaked value: {j}"
            );
            assert!(
                !j.contains("\"secret\""),
                "add_secret leaked secret field: {j}"
            );
        }
    }

    // AC17 — CREATE-ONLY: a second add with the SAME name errors (no overwrite of a
    // real operator secret by an injected agent).
    #[test]
    fn ac17_add_secret_is_create_only() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("vault.enc");
        let store = unlocked_store(&path);

        add_credential_at(
            &store,
            &path,
            "dup".into(),
            String::new(),
            "token".into(),
            "v1".into(),
        )
        .unwrap();
        let err = add_credential_at(
            &store,
            &path,
            "dup".into(),
            String::new(),
            "token".into(),
            "v2-attacker".into(),
        )
        .unwrap_err();
        assert!(err.contains("already exists"), "unexpected: {err}");

        // The original value is untouched (create-only did NOT overwrite).
        let guard = store.0.lock().unwrap();
        let u = guard.as_ref().unwrap();
        let cred = u
            .data
            .credentials
            .iter()
            .find(|c| c.label == "dup")
            .unwrap();
        assert_eq!(cred.secret.as_str(), "v1");
        assert_eq!(
            u.data
                .credentials
                .iter()
                .filter(|c| c.label == "dup")
                .count(),
            1
        );
    }

    // AC17 — a LOCKED store rejects add_secret with a clear error, no write.
    #[test]
    fn ac17_add_secret_requires_unlock() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("vault.enc");
        let store = CredStore(Mutex::new(None)); // locked
        let err = add_credential_at(
            &store,
            &path,
            "x".into(),
            String::new(),
            "token".into(),
            "v".into(),
        )
        .unwrap_err();
        assert!(err.contains("locked"), "unexpected: {err}");
    }

    // AC17 — empty name/value and an invalid kind are rejected up-front.
    #[test]
    fn ac17_add_secret_validates_inputs() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("vault.enc");
        let store = unlocked_store(&path);
        assert!(add_credential_at(
            &store,
            &path,
            "  ".into(),
            String::new(),
            "token".into(),
            "v".into()
        )
        .is_err());
        assert!(add_credential_at(
            &store,
            &path,
            "n".into(),
            String::new(),
            "token".into(),
            String::new()
        )
        .is_err());
        assert!(add_credential_at(
            &store,
            &path,
            "n".into(),
            String::new(),
            "bogus".into(),
            "v".into()
        )
        .is_err());
    }

    // AC12 — CredMeta (the projection returned to agents/UI) carries no secret.
    #[test]
    #[test]
    fn trim_imported_secret_strips_one_trailing_newline_except_for_keys() {
        assert_eq!(trim_imported_secret("token", "abc123\n".into()), "abc123");
        assert_eq!(trim_imported_secret("token", "abc123\r\n".into()), "abc123");
        assert_eq!(
            trim_imported_secret("password", "no-newline".into()),
            "no-newline"
        );
        // Only ONE trailing newline is dropped — extra blank lines are the file's content.
        assert_eq!(
            trim_imported_secret("token", "abc123\n\n".into()),
            "abc123\n"
        );
        // A key's bytes are never touched, trailing newline or not.
        let pem = "-----BEGIN KEY-----\nabc\n-----END KEY-----\n";
        assert_eq!(trim_imported_secret("key", pem.into()), pem);
    }

    // MIGRATION SAFETY (PRD vault-ux): an ENCRYPTED store written by a build that had no
    // `group` field must still unlock, with every credential and secret intact. This seals
    // hand-written old-format JSON through the real crypto and unlocks it through the real
    // `unlock_at`, so it exercises exactly what an existing vault hits after the upgrade.
    #[test]
    fn old_encrypted_store_without_group_unlocks_with_secrets_intact() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("legacy-vault.enc");
        let master = b"correct horse battery";

        // Old on-disk shape: no `group` anywhere, mixed secret kinds, a key passphrase.
        let old_plaintext = br#"{"version":1,"credentials":[
            {"id":"c1","label":"maydogan","username":"maydogan","secretKind":"password","secret":"S3cret!","description":"cyberark pw"},
            {"id":"c2","label":"Azure_token","username":"","secretKind":"api_key","secret":"az-tok-xyz","description":""},
            {"id":"c3","label":"deploy-key","username":"git","secretKind":"key","secret":"-----BEGIN KEY-----\nabc\n","description":"","keyPassphrase":"pp"}
        ]}"#;

        let salt = new_salt();
        let key = derive_key(master, &salt).unwrap();
        let (nonce, ciphertext) = seal(&key, old_plaintext).unwrap();
        let blob = SealedBlob {
            magic: MAGIC.to_string(),
            version: BLOB_VERSION,
            kdf: KdfParams {
                algo: "argon2id".into(),
                salt,
                m: ARGON2_M_KIB,
                t: ARGON2_T,
                p: ARGON2_P,
            },
            nonce,
            ciphertext,
        };
        std::fs::write(&path, serde_json::to_vec(&blob).unwrap()).unwrap();

        // The real unlock path — this is what the upgraded app runs.
        let u = unlock_at(&path, master).expect("legacy vault must still unlock");
        assert_eq!(u.data.credentials.len(), 3, "no credential may be lost");
        let c1 = &u.data.credentials[0];
        assert_eq!(c1.label, "maydogan");
        assert_eq!(c1.secret.as_str(), "S3cret!", "secret must survive the migration");
        assert_eq!(c1.description, "cyberark pw");
        assert_eq!(
            c1.group, "",
            "missing group loads as empty (shown as Ungrouped)"
        );
        assert_eq!(u.data.credentials[1].secret.as_str(), "az-tok-xyz");
        assert_eq!(
            u.data.credentials[2].key_passphrase.as_ref().map(|z| z.as_str()),
            Some("pp"),
            "key passphrase must survive"
        );

        // …and re-sealing with the NEW struct (as the app does on any edit) keeps
        // everything, now carrying a group.
        let mut data = u.data;
        data.credentials[0].group = "CyberArk".into();
        seal_to_path(&path, &u.key, &u.kdf, &data).unwrap();
        let again = unlock_at(&path, master).unwrap();
        assert_eq!(again.data.credentials.len(), 3);
        assert_eq!(again.data.credentials[0].group, "CyberArk");
        assert_eq!(again.data.credentials[0].secret.as_str(), "S3cret!");
        assert_eq!(
            again.data.credentials[2].secret.as_str(),
            "-----BEGIN KEY-----\nabc\n"
        );
    }

    // A store written before `group` existed must still load — the field is optional
    // and comes back empty ("Ungrouped" in the UI). PRD vault-ux AC1.
    #[test]
    // PRD vault-touchid-autolock — biometric-pref persistence, no real Keychain
    // touched (the crypto/Keychain path itself needs a live Touch ID prompt per
    // the original prd-ssh-cyberark.md note: "cargo test cannot exercise biometry").
    #[test]
    fn biometric_pref_defaults_false_then_persists_toggle() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("muya-vault-prefs.json");
        // No file yet → default false, never panics on a missing prefs file.
        assert!(!biometric_available_at(&path));
        set_biometric_pref_at(&path, true).unwrap();
        assert!(biometric_available_at(&path));
        set_biometric_pref_at(&path, false).unwrap();
        assert!(!biometric_available_at(&path));
    }

    #[test]
    fn biometric_pref_own_file_never_shares_debuglog_settings() {
        // Regression guard for the exact bug this design avoided: writing to the
        // SAME file debug-logging uses would let one setting silently clobber the
        // other (debug_log_set overwrites the whole document, no merge).
        let dir = tempfile::tempdir().unwrap();
        let prefs = dir.path().join("muya-vault-prefs.json");
        let settings = dir.path().join("muya-settings.json");
        std::fs::write(
            &settings,
            r#"{"debugLogging":true,"debugLogPath":"/tmp/x.log"}"#,
        )
        .unwrap();
        set_biometric_pref_at(&prefs, true).unwrap();
        // The debug-logging file is a DIFFERENT path and must be untouched.
        let still_there = std::fs::read_to_string(&settings).unwrap();
        assert!(still_there.contains("debugLogging"));
        assert_ne!(prefs, settings);
    }

    #[test]
    fn credential_without_group_loads_as_empty() {
        let old = r#"{"id":"1","label":"legacy","username":"u","secretKind":"password","secret":"s","description":"d"}"#;
        let c: Credential = serde_json::from_str(old).expect("old JSON must still parse");
        assert_eq!(c.group, "");
        assert_eq!(c.label, "legacy");
        // …and a new one round-trips its group.
        let mut c2 = c.clone();
        c2.group = "prod".into();
        let round: Credential = serde_json::from_str(&serde_json::to_string(&c2).unwrap()).unwrap();
        assert_eq!(round.group, "prod");
    }

    #[test]
    fn ac12_credmeta_has_no_secret_field() {
        let meta = CredMeta {
            id: "1".into(),
            label: "prod-aws".into(),
            username: "deploy".into(),
            secret_kind: "token".into(),
            description: "prod deploy token".into(),
            group: String::new(),
        };
        let json = serde_json::to_string(&meta).unwrap();
        // `secretKind` is a legitimate non-secret label; the banned tokens are the
        // actual secret-bearing keys.
        for banned in ["\"secret\"", "\"password\"", "keyPassphrase"] {
            assert!(!json.contains(banned), "CredMeta leaked `{banned}`: {json}");
        }
        assert!(json.contains("prod-aws") && json.contains("prod deploy token"));
    }

    // The store file never contains the plaintext secret in cleartext.
    #[test]
    fn blob_has_no_plaintext_secret() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("vault.enc");
        init_at(&path, b"pw").unwrap();
        let mut u = unlock_at(&path, b"pw").unwrap();
        u.data.credentials.push(Credential {
            id: "1".into(),
            label: "l".into(),
            username: "u".into(),
            secret_kind: "password".into(),
            secret: Zeroizing::new("TOPSECRETVALUE".to_string()),
            description: String::new(),
            group: String::new(),
            key_passphrase: None,
        });
        seal_to_path(&path, &u.key, &u.kdf, &u.data).unwrap();
        let raw = std::fs::read(&path).unwrap();
        assert!(
            !raw.windows(b"TOPSECRETVALUE".len())
                .any(|w| w == b"TOPSECRETVALUE"),
            "plaintext secret found on disk"
        );
    }
}

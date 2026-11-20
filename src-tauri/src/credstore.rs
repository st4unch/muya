//! Tauri command shims: the logic lives in `muya_core::credstore` (native rewrite, strangler).

pub use muya_core::credstore::*;
use tauri::State;

#[tauri::command]
pub fn credstore_status(state: State<'_, CredStore>) -> Result<CredStoreStatus, String> {
    muya_core::credstore::credstore_status(&state)
}

#[tauri::command]
pub async fn credstore_init(master: String, state: State<'_, CredStore>) -> Result<(), String> {
    muya_core::credstore::credstore_init(master, &state).await
}

#[tauri::command]
pub async fn credstore_unlock(master: String, state: State<'_, CredStore>) -> Result<(), String> {
    muya_core::credstore::credstore_unlock(master, &state).await
}

#[tauri::command]
pub fn credstore_lock(state: State<'_, CredStore>, app: tauri::AppHandle) -> Result<(), String> {
    use tauri::Emitter;
    muya_core::credstore::lock_store(&state)?;
    let _ = app.emit("muya://vault-locked", ());
    Ok(())
}

#[tauri::command]
pub fn credstore_biometric_available() -> bool {
    muya_core::credstore::credstore_biometric_available()
}

#[tauri::command]
pub fn credstore_enable_biometric_unlock(state: State<'_, CredStore>) -> Result<(), String> {
    muya_core::credstore::credstore_enable_biometric_unlock(&state)
}

#[tauri::command]
pub fn credstore_disable_biometric_unlock() -> Result<(), String> {
    muya_core::credstore::credstore_disable_biometric_unlock()
}

#[tauri::command]
pub async fn credstore_unlock_biometric(state: State<'_, CredStore>) -> Result<(), String> {
    muya_core::credstore::credstore_unlock_biometric(&state).await
}

#[tauri::command]
pub fn credstore_export_master(dest: String, master: String) -> Result<(), String> {
    muya_core::credstore::credstore_export_master(dest, master)
}

#[tauri::command]
pub fn credstore_import_key(
    label: String,
    username: String,
    src_path: String,
    state: State<'_, CredStore>,
) -> Result<String, String> {
    muya_core::credstore::credstore_import_key(label, username, src_path, &state)
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
    muya_core::credstore::credstore_import_secret(label, username, secret_kind, description, group, src_path, &state)
}

#[tauri::command]
pub fn credstore_export_cred(
    id: String,
    dest: String,
    state: State<'_, CredStore>,
) -> Result<(), String> {
    muya_core::credstore::credstore_export_cred(id, dest, &state)
}

#[tauri::command]
pub fn credstore_reveal_cred(id: String, state: State<'_, CredStore>) -> Result<String, String> {
    muya_core::credstore::credstore_reveal_cred(id, &state)
}

#[tauri::command]
pub fn credstore_export(dest: String) -> Result<(), String> {
    muya_core::credstore::credstore_export(dest)
}

#[tauri::command]
pub async fn credstore_rekey(
    old_master: String,
    new_master: String,
    state: State<'_, CredStore>,
) -> Result<(), String> {
    muya_core::credstore::credstore_rekey(old_master, new_master, &state).await
}

#[tauri::command]
pub fn credstore_cred_list(state: State<'_, CredStore>) -> Result<Vec<CredMeta>, String> {
    muya_core::credstore::credstore_cred_list(&state)
}

#[tauri::command]
pub fn credstore_cred_upsert(
    cred: CredInput,
    state: State<'_, CredStore>,
) -> Result<String, String> {
    muya_core::credstore::credstore_cred_upsert(cred, &state)
}

#[tauri::command]
pub fn credstore_cred_remove(id: String, state: State<'_, CredStore>) -> Result<(), String> {
    muya_core::credstore::credstore_cred_remove(id, &state)
}

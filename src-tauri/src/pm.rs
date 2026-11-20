//! Tauri command shims: the logic lives in `muya_core::pm` (native rewrite, strangler).

pub use muya_core::pm::*;

#[tauri::command(async)]
pub async fn pm_status(paths: Vec<String>) -> Vec<ProjectStatus> {
    muya_core::pm::pm_status(paths).await
}

#[tauri::command(async)]
pub fn pm_check_merge(repo: String, branch: String) -> Result<MergeCheck, String> {
    muya_core::pm::pm_check_merge(repo, branch)
}

#[tauri::command(async)]
pub fn pm_merge(repo: String, branch: String) -> Result<String, String> {
    muya_core::pm::pm_merge(repo, branch)
}

#[tauri::command(async)]
pub fn pm_push(repo: String, branch: String) -> Result<String, String> {
    muya_core::pm::pm_push(repo, branch)
}

#[tauri::command(async)]
pub async fn pm_collisions(paths: Vec<String>) -> CollisionReport {
    muya_core::pm::pm_collisions(paths).await
}

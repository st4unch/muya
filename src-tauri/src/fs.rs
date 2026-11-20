//! Tauri command shims: the logic lives in `muya_core::fs` (native rewrite, strangler).

pub use muya_core::fs::*;

#[tauri::command(async)]
pub fn list_dir(path: String) -> Result<Vec<DirEntry>, String> {
    muya_core::fs::list_dir(path)
}

#[tauri::command(async)]
pub fn read_file(path: String) -> Result<String, String> {
    muya_core::fs::read_file(path)
}

#[tauri::command(async)]
pub fn read_file_bytes(path: String) -> Result<tauri::ipc::Response, String> {
    muya_core::fs::read_file_bytes(path).map(tauri::ipc::Response::new)
}

#[tauri::command(async)]
pub fn write_file(path: String, content: String) -> Result<(), String> {
    muya_core::fs::write_file(path, content)
}

#[tauri::command(async)]
pub fn create_file(path: String) -> Result<(), String> {
    muya_core::fs::create_file(path)
}

#[tauri::command(async)]
pub fn path_kind(path: String) -> String {
    muya_core::fs::path_kind(path)
}

#[tauri::command(async)]
pub fn create_dir(path: String) -> Result<(), String> {
    muya_core::fs::create_dir(path)
}

#[tauri::command(async)]
pub fn read_head_file(path: String) -> Result<String, String> {
    muya_core::fs::read_head_file(path)
}

#[tauri::command(async)]
pub fn create_worktree(repo: String, branch: String) -> Result<String, String> {
    muya_core::fs::create_worktree(repo, branch)
}

#[tauri::command(async)]
pub async fn list_branches(repo: String) -> Result<Vec<GitBranchState>, String> {
    muya_core::fs::list_branches(repo).await
}

#[tauri::command(async)]
pub fn branch_detail(repo: String, branch: String) -> Result<BranchDetail, String> {
    muya_core::fs::branch_detail(repo, branch)
}

#[tauri::command(async)]
pub fn git_branch_file_pair(
    repo: String,
    base: String,
    branch: String,
    path: String,
) -> Result<(String, String), String> {
    muya_core::fs::git_branch_file_pair(repo, base, branch, path)
}

#[tauri::command(async)]
pub fn remove_worktree(worktree: String) -> Result<String, String> {
    muya_core::fs::remove_worktree(worktree)
}

#[tauri::command(async)]
pub async fn git_status(root: String) -> Result<Vec<(String, String)>, String> {
    muya_core::fs::git_status(root).await
}

#[tauri::command(async)]
pub fn resolve_path_kind(path: String, cwd: Option<String>) -> PathKind {
    muya_core::fs::resolve_path_kind(path, cwd)
}

#[tauri::command(async)]
pub fn local_ip() -> Result<String, String> {
    muya_core::fs::local_ip()
}

#[tauri::command(async)]
pub fn allow_asset_path(path: String, app: tauri::AppHandle) -> Result<(), String> {
    use tauri::Manager;
    app.asset_protocol_scope()
        .allow_file(&path)
        .map_err(|e| format!("failed to allow asset path: {e}"))
}

#[tauri::command(async)]
pub fn file_access_status(probe: bool) -> FileAccessStatus {
    muya_core::fs::file_access_status(probe)
}

#[tauri::command]
pub fn relaunch_in_place(app: tauri::AppHandle) -> Result<(), String> {
    muya_core::fs::spawn_relauncher()?;
    app.exit(0);
    Ok(())
}

#[tauri::command(async)]
pub fn open_privacy_settings() -> Result<(), String> {
    muya_core::fs::open_privacy_settings()
}

#[tauri::command(async)]
pub fn reveal_in_finder(path: String) -> Result<(), String> {
    muya_core::fs::reveal_in_finder(path)
}

#[tauri::command(async)]
pub fn rename_entry(old_path: String, new_name: String) -> Result<(), String> {
    muya_core::fs::rename_entry(old_path, new_name)
}

#[tauri::command(async)]
pub fn delete_entry(path: String) -> Result<(), String> {
    muya_core::fs::delete_entry(path)
}

#[tauri::command(async)]
pub fn list_claude_resources() -> Result<ClaudeResources, String> {
    muya_core::fs::list_claude_resources()
}

#[tauri::command(async)]
pub async fn fetch_skill_marketplace(query: String) -> Result<Vec<MarketSkill>, String> {
    muya_core::fs::fetch_skill_marketplace(query).await
}

#[tauri::command(async)]
pub async fn fetch_mcp_marketplace(query: String) -> Result<MarketResult, String> {
    muya_core::fs::fetch_mcp_marketplace(query).await
}

#[tauri::command(async)]
pub fn install_skill(name: String, github_url: String) -> Result<(), String> {
    muya_core::fs::install_skill(name, github_url)
}

#[tauri::command(async)]
pub fn install_mcp(name: String, command: String, args: Vec<String>) -> Result<(), String> {
    muya_core::fs::install_mcp(name, command, args)
}

#[tauri::command(async)]
pub async fn install_muya_plugin() -> Result<String, String> {
    muya_core::fs::install_muya_plugin().await
}

#[tauri::command(async)]
pub fn scan_prd_docs(dirs: Vec<String>) -> Vec<PrdDoc> {
    muya_core::fs::scan_prd_docs(dirs)
}

// Large-file probe for the classic web viewers (kept for the classic code in this tree; Native has its own editor tiers).
use std::path::Path;
/// What the viewers need to know BEFORE loading a file (docs/prd-large-file-open.md):
/// its size and whether it looks binary. Reads at most 8 KB.
#[derive(serde::Serialize, Debug, PartialEq)]
pub struct FileProbe {
    pub size: u64,
    /// A NUL byte in the first 8 KB — not text.
    pub binary: bool,
}

fn probe_file(p: &Path) -> Result<FileProbe, String> {
    use std::io::Read;
    let denied = |e: std::io::Error| {
        if e.kind() == std::io::ErrorKind::PermissionDenied {
            format!("macOS did not let Muya open {}", p.display())
        } else {
            format!("cannot open {}: {e}", p.display())
        }
    };
    let meta = std::fs::metadata(p).map_err(denied)?;
    if !meta.is_file() {
        return Err(format!("{} is not a file", p.display()));
    }
    let mut head = [0u8; 8192];
    let n = std::fs::File::open(p)
        .and_then(|mut f| f.read(&mut head))
        .map_err(denied)?;
    Ok(FileProbe { size: meta.len(), binary: head[..n].contains(&0) })
}

#[tauri::command(async)]
pub fn file_probe(path: String) -> Result<FileProbe, String> {
    probe_file(Path::new(&path))
}

/// First `max` bytes of a text file (cut back to a character boundary), lossy for
/// invalid UTF-8. For the read-only "Open anyway" view of a file too big to load whole.
fn read_prefix(p: &Path, max: u64) -> Result<String, String> {
    use std::io::Read;
    let mut buf = Vec::new();
    std::fs::File::open(p)
        .and_then(|f| f.take(max).read_to_end(&mut buf))
        .map_err(|e| format!("read failed: {e}"))?;
    // A multi-byte character may be cut at the end: drop the incomplete tail only.
    if let Err(e) = std::str::from_utf8(&buf) {
        if e.error_len().is_none() {
            buf.truncate(e.valid_up_to());
        }
    }
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

#[tauri::command(async)]
pub fn read_file_prefix(path: String, max_bytes: u64) -> Result<String, String> {
    // Hard ceiling regardless of what the webview asks for.
    read_prefix(Path::new(&path), max_bytes.min(16 * 1024 * 1024))
}


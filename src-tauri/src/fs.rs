//! Scoped filesystem reads for the workspace file tree. Custom commands over
//! `std::fs` (not the fs plugin) so we own the security check: directory listing is
//! only ever lazy and read-only. The frontend feeds these from user-picked workspace
//! roots.

use std::path::Path;
use std::process::Command;

use serde::Serialize;

/// A single directory entry for the file tree.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirEntry {
    pub name: String,
    pub path: String,
    pub is_directory: bool,
}

/// List the immediate children of a directory. Directories first, then files, each
/// alphabetical. Hidden entries (dotfiles) and heavy build dirs are included but the
/// frontend may choose to fold them. Errors (missing dir, permission) return Err.
#[tauri::command(async)]
pub fn list_dir(path: String) -> Result<Vec<DirEntry>, String> {
    let p = Path::new(&path);
    if !p.is_dir() {
        return Err(format!("not a directory: {path}"));
    }
    let mut entries: Vec<DirEntry> = std::fs::read_dir(p)
        .map_err(|e| format!("read_dir failed: {e}"))?
        .filter_map(|res| res.ok())
        .map(|e| {
            let is_directory = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
            DirEntry {
                name: e.file_name().to_string_lossy().into_owned(),
                path: e.path().to_string_lossy().into_owned(),
                is_directory,
            }
        })
        .collect();
    entries.sort_by(|a, b| {
        b.is_directory
            .cmp(&a.is_directory)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(entries)
}

/// Read a UTF-8 text file for the editor. Rejects very large files to keep the
/// editor responsive.
#[tauri::command(async)]
pub fn read_file(path: String) -> Result<String, String> {
    let p = Path::new(&path);
    let meta = std::fs::metadata(p).map_err(|e| format!("stat failed: {e}"))?;
    if meta.len() > 5_000_000 {
        return Err("file too large (>5MB) to open in the editor".into());
    }
    std::fs::read_to_string(p).map_err(|e| format!("read failed: {e}"))
}

/// Write text back to a file (editor save).
#[tauri::command(async)]
pub fn write_file(path: String, content: String) -> Result<(), String> {
    std::fs::write(Path::new(&path), content).map_err(|e| format!("write failed: {e}"))
}

/// Create a new, empty file (File > New File). Never truncates: if the path already
/// exists it's left untouched (the caller just opens it). Parent dirs are created.
#[tauri::command(async)]
pub fn create_file(path: String) -> Result<(), String> {
    let p = Path::new(&path);
    if p.exists() {
        return Ok(()); // open the existing file rather than overwrite it
    }
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir failed: {e}"))?;
    }
    std::fs::write(p, "").map_err(|e| format!("create failed: {e}"))
}

/// Read a file's committed (HEAD) version for diffing against the working tree.
/// Returns the HEAD content, or an empty string if the file is untracked/new (so the
/// diff shows it as fully added). Errors only if the path isn't inside a git repo.
#[tauri::command(async)]
pub fn read_head_file(path: String) -> Result<String, String> {
    // Canonicalize so it matches git's (also-canonical) toplevel even when the path
    // contains symlinks (e.g. macOS /var → /private/var).
    let canon = Path::new(&path).canonicalize().ok();
    let p = canon.as_deref().unwrap_or_else(|| Path::new(&path));
    let dir = p.parent().ok_or("invalid path")?;
    let root_out = Command::new("git")
        .args(["-C"])
        .arg(dir)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .map_err(|e| format!("git not found: {e}"))?;
    if !root_out.status.success() {
        return Err("not inside a git repository".into());
    }
    let root = String::from_utf8_lossy(&root_out.stdout).trim().to_string();
    let rel = p
        .strip_prefix(&root)
        .map(|r| r.to_string_lossy().into_owned())
        .map_err(|_| "file outside repo root".to_string())?;
    let show = Command::new("git")
        .args(["-C", &root, "show", &format!("HEAD:{rel}")])
        .output()
        .map_err(|e| format!("git show failed: {e}"))?;
    if !show.status.success() {
        // Untracked / new file → no HEAD version; diff against empty.
        return Ok(String::new());
    }
    Ok(String::from_utf8_lossy(&show.stdout).into_owned())
}

/// Create an isolated git worktree for a new agent branch and copy gitignored env
/// files into it. Returns the worktree path. Requires `repo` to be inside a git repo.
#[tauri::command(async)]
pub fn create_worktree(repo: String, branch: String) -> Result<String, String> {
    let branch = branch.trim();
    if branch.is_empty() {
        return Err("branch name required".into());
    }
    let root_out = Command::new("git")
        .args(["-C", &repo, "rev-parse", "--show-toplevel"])
        .output()
        .map_err(|e| format!("git not found: {e}"))?;
    if !root_out.status.success() {
        return Err("workspace is not a git repository".into());
    }
    let root = String::from_utf8_lossy(&root_out.stdout).trim().to_string();
    let root_path = Path::new(&root);
    let repo_name = root_path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "repo".into());
    let safe_branch = branch.replace('/', "-");
    let wt = root_path
        .parent()
        .ok_or("repo has no parent dir")?
        .join(format!("{repo_name}-worktrees"))
        .join(&safe_branch);
    let wt_str = wt.to_string_lossy().into_owned();

    // Try creating a new branch; if it already exists, attach to it without -b.
    let add = Command::new("git")
        .args(["-C", &root, "worktree", "add", "-b", branch, &wt_str])
        .output()
        .map_err(|e| format!("git worktree add failed: {e}"))?;
    if !add.status.success() {
        let retry = Command::new("git")
            .args(["-C", &root, "worktree", "add", &wt_str, branch])
            .output()
            .map_err(|e| format!("git worktree add failed: {e}"))?;
        if !retry.status.success() {
            return Err(format!(
                "git worktree add failed: {}",
                String::from_utf8_lossy(&add.stderr)
            ));
        }
    }

    // Copy gitignored env files the new worktree won't get from git.
    for f in [".env", ".env.local"] {
        let src = root_path.join(f);
        if src.exists() {
            let _ = std::fs::copy(&src, wt.join(f));
        }
    }
    Ok(wt_str)
}

/// A git branch mapped onto the frontend `GitBranchState` contract.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitBranchState {
    pub name: String,
    /// PRD (main/release) | WIP (feature/fix) | OPEN (everything else)
    #[serde(rename = "type")]
    pub kind: String,
    pub last_commit: String,
    pub author: String,
    /// synced | ahead | diverged
    pub status: String,
    /// Branch this most likely forked from (closest divergence); None for the root.
    pub parent: Option<String>,
}

fn branch_kind(name: &str) -> &'static str {
    if name == "main" || name == "master" || name.starts_with("release/") {
        "PRD"
    } else if name.starts_with("feature/")
        || name.starts_with("fix/")
        || name.starts_with("bugfix/")
        || name.starts_with("hotfix/")
    {
        "WIP"
    } else {
        "OPEN"
    }
}

fn track_to_status(track: &str) -> &'static str {
    let ahead = track.contains("ahead");
    let behind = track.contains("behind");
    if ahead && behind {
        "diverged"
    } else if ahead {
        "ahead"
    } else {
        "synced"
    }
}

/// List local branches of a repo for the topology view. Returns empty if not a git
/// repo (UI just shows nothing rather than erroring).
#[tauri::command(async)]
pub fn list_branches(repo: String) -> Result<Vec<GitBranchState>, String> {
    let fmt = "%(refname:short)\x1f%(upstream:track)\x1f%(authorname)\x1f%(subject)";
    let out = Command::new("git")
        .args(["-C", &repo, "for-each-ref", "--format", fmt, "refs/heads/"])
        .output()
        .map_err(|e| format!("git not found: {e}"))?;
    if !out.status.success() {
        return Ok(vec![]); // not a git repo
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let mut branches = Vec::new();
    for line in text.lines().filter(|l| !l.is_empty()) {
        let parts: Vec<&str> = line.split('\x1f').collect();
        let name = parts.first().copied().unwrap_or("").to_string();
        if name.is_empty() {
            continue;
        }
        let track = parts.get(1).copied().unwrap_or("");
        branches.push(GitBranchState {
            kind: branch_kind(&name).to_string(),
            status: track_to_status(track).to_string(),
            author: parts.get(2).copied().unwrap_or("").to_string(),
            last_commit: parts.get(3).copied().unwrap_or("").to_string(),
            name,
            parent: None,
        });
    }
    compute_parents(&repo, &mut branches);
    Ok(branches)
}

/// One commit row for the branch-detail card.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BranchCommit {
    pub hash: String,
    pub subject: String,
    pub author: String,
    pub rel_date: String,
}

/// Branch detail relative to the repo base (main/master): ahead/behind counts, recent
/// commits unique to the branch, and the files it changed. Powers the Queue page card.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BranchDetail {
    pub name: String,
    pub base: String,
    pub ahead: u32,
    pub behind: u32,
    pub commits: Vec<BranchCommit>,
    pub changed_files: Vec<String>,
}

#[tauri::command(async)]
pub fn branch_detail(repo: String, branch: String) -> Result<BranchDetail, String> {
    // Validate the branch is a real local ref before feeding it to git. This both
    // surfaces a clear error for a bad repo/branch (instead of a silently empty card)
    // and closes git option-injection: every ref below is the fully-qualified
    // `refs/heads/<name>` form, which can never be parsed as a `-`-leading option.
    let bref = format!("refs/heads/{branch}");
    if git_capture(&repo, &["rev-parse", "--verify", "--quiet", &bref]).is_none() {
        return Err(format!("unknown branch: {branch}"));
    }

    // Compare against main, else master — but never the branch itself.
    let base = ["main", "master"]
        .iter()
        .copied()
        .find(|&b| {
            b != branch.as_str()
                && git_capture(
                    &repo,
                    &[
                        "rev-parse",
                        "--verify",
                        "--quiet",
                        &format!("refs/heads/{b}"),
                    ],
                )
                .is_some()
        })
        .map(str::to_string)
        .unwrap_or_default();
    let baseref = format!("refs/heads/{base}");

    // ahead/behind via the symmetric range base...branch (left = base-only = behind,
    // right = branch-only = ahead). With no base (e.g. inspecting main itself) a branch
    // has nothing ahead of itself → leave both at 0.
    let (mut ahead, mut behind) = (0u32, 0u32);
    if !base.is_empty() {
        if let Some(counts) = git_capture(
            &repo,
            &[
                "rev-list",
                "--left-right",
                "--count",
                &format!("{baseref}...{bref}"),
            ],
        ) {
            let mut it = counts.split_whitespace();
            behind = it.next().and_then(|s| s.parse().ok()).unwrap_or(0);
            ahead = it.next().and_then(|s| s.parse().ok()).unwrap_or(0);
        }
    }

    // Up to 20 commits unique to the branch (or its newest commits when there's no base).
    let range = if base.is_empty() {
        bref.clone()
    } else {
        format!("{baseref}..{bref}")
    };
    let log = git_capture(
        &repo,
        &["log", "-n", "20", "--format=%h\x1f%s\x1f%an\x1f%cr", &range],
    )
    .unwrap_or_default();
    let commits = log
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| {
            let p: Vec<&str> = l.split('\x1f').collect();
            BranchCommit {
                hash: p.first().copied().unwrap_or("").to_string(),
                subject: p.get(1).copied().unwrap_or("").to_string(),
                author: p.get(2).copied().unwrap_or("").to_string(),
                rel_date: p.get(3).copied().unwrap_or("").to_string(),
            }
        })
        .collect();

    // Files changed vs the merge-base with the base branch.
    let changed_files = if base.is_empty() {
        vec![]
    } else {
        git_capture(
            &repo,
            &["diff", "--name-only", &format!("{baseref}...{bref}")],
        )
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(|s| s.to_string())
        .collect()
    };

    Ok(BranchDetail {
        name: branch,
        base,
        ahead,
        behind,
        commits,
        changed_files,
    })
}

fn git_capture(repo: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Real lineage: for each branch, parent = the other branch it most recently diverged
/// from (fewest commits on this branch since their merge-base), preferring the base
/// branch on ties. Capped for cost on big repos.
fn compute_parents(repo: &str, branches: &mut [GitBranchState]) {
    if branches.len() > 40 {
        return;
    }
    let names: Vec<String> = branches.iter().map(|b| b.name.clone()).collect();
    let base = names
        .iter()
        .find(|n| n.as_str() == "main")
        .or_else(|| names.iter().find(|n| n.as_str() == "master"))
        .cloned();
    for b in branches.iter_mut() {
        if Some(&b.name) == base.as_ref() {
            continue;
        }
        let mut best: Option<(String, u32)> = None;
        for cand in &names {
            if cand == &b.name {
                continue;
            }
            let Some(mb) = git_capture(repo, &["merge-base", &b.name, cand]) else {
                continue;
            };
            let count = git_capture(repo, &["rev-list", "--count", &format!("{mb}..{}", b.name)])
                .and_then(|s| s.parse::<u32>().ok())
                .unwrap_or(u32::MAX);
            // count == 0 means this branch's tip IS the merge-base → the candidate is a
            // descendant (child), not a parent. Skip it.
            if count == 0 {
                continue;
            }
            let cand_is_base = Some(cand) == base.as_ref();
            let better = match &best {
                None => true,
                Some((bn, bc)) => {
                    count < *bc || (count == *bc && cand_is_base && Some(bn) != base.as_ref())
                }
            };
            if better {
                best = Some((cand.clone(), count));
            }
        }
        b.parent = best.map(|(n, _)| n);
    }
}

/// Remove a git worktree (and its directory). Destructive — operator-confirmed in UI.
/// Runs from the main repo so it can remove a linked worktree by path.
#[tauri::command(async)]
pub fn remove_worktree(worktree: String) -> Result<String, String> {
    // The shared git dir lives in the main repo; derive the main worktree from it.
    let common = Command::new("git")
        .args([
            "-C",
            &worktree,
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ])
        .output()
        .map_err(|e| format!("git not found: {e}"))?;
    if !common.status.success() {
        return Err("not inside a git repository".into());
    }
    let common_dir = String::from_utf8_lossy(&common.stdout).trim().to_string();
    let main_repo = Path::new(&common_dir)
        .parent()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|| worktree.clone());
    let out = Command::new("git")
        .args(["-C", &main_repo, "worktree", "remove", "--force", &worktree])
        .output()
        .map_err(|e| format!("git worktree remove failed: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(format!("removed worktree {worktree}"))
}

// ── Claude Resources Viewer ──────────────────────────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeSkill {
    pub name: String,
    pub path: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeAgent {
    pub name: String,
    pub path: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeHook {
    pub name: String,
    pub path: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeMcp {
    pub name: String,
    pub command: String,
    pub description: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeResources {
    pub skills: Vec<ClaudeSkill>,
    pub agents: Vec<ClaudeAgent>,
    pub hooks: Vec<ClaudeHook>,
    pub mcps: Vec<ClaudeMcp>,
}

/// Scan `~/.claude/{skills,agents,hooks}` and merge MCP JSON configs.
/// Returns a snapshot for the Resources Viewer tab.
#[tauri::command(async)]
pub fn list_claude_resources() -> Result<ClaudeResources, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    let claude = Path::new(&home).join(".claude");

    // --- Skills: immediate subdirectories of ~/.claude/skills/ ---
    let mut skills = Vec::new();
    let skills_dir = claude.join("skills");
    if let Ok(rd) = std::fs::read_dir(&skills_dir) {
        let mut entries: Vec<_> = rd.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let path = entry.path();
            if path.is_dir() {
                skills.push(ClaudeSkill {
                    name: entry.file_name().to_string_lossy().into_owned(),
                    path: path.to_string_lossy().into_owned(),
                });
            }
        }
    }

    // --- Agents: ~/.claude/agents/*.md ---
    let mut agents = Vec::new();
    let agents_dir = claude.join("agents");
    if let Ok(rd) = std::fs::read_dir(&agents_dir) {
        let mut entries: Vec<_> = rd
            .flatten()
            .filter(|e| e.path().extension().map(|x| x == "md").unwrap_or(false))
            .collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let path = entry.path();
            let name = path
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
            agents.push(ClaudeAgent {
                name,
                path: path.to_string_lossy().into_owned(),
            });
        }
    }

    // --- Hooks: ~/.claude/hooks/*.{sh,py,mjs} ---
    let mut hooks = Vec::new();
    let hooks_dir = claude.join("hooks");
    if let Ok(rd) = std::fs::read_dir(&hooks_dir) {
        let mut entries: Vec<_> = rd
            .flatten()
            .filter(|e| {
                let p = e.path();
                if !p.is_file() {
                    return false;
                }
                matches!(
                    p.extension().and_then(|x| x.to_str()),
                    Some("sh") | Some("py") | Some("mjs")
                )
            })
            .collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let path = entry.path();
            hooks.push(ClaudeHook {
                name: entry.file_name().to_string_lossy().into_owned(),
                path: path.to_string_lossy().into_owned(),
            });
        }
    }

    // --- MCPs: merge ~/.claude/.mcp.json + ~/.claude/claude-config/mcp.json ---
    let mcp_paths = [
        claude.join(".mcp.json"),
        claude.join("claude-config").join("mcp.json"),
    ];
    let mut mcps: Vec<ClaudeMcp> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for mcp_path in &mcp_paths {
        if let Ok(content) = std::fs::read_to_string(mcp_path) {
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                if let Some(servers) = val["mcpServers"].as_object() {
                    let mut sorted: Vec<_> = servers.iter().collect();
                    sorted.sort_by_key(|(k, _)| k.as_str());
                    for (name, cfg) in sorted {
                        if seen.contains(name) {
                            continue;
                        }
                        seen.insert(name.clone());
                        let command = cfg["command"]
                            .as_str()
                            .or_else(|| cfg["url"].as_str())
                            .unwrap_or("")
                            .to_string();
                        let description = cfg["description"].as_str().unwrap_or("").to_string();
                        mcps.push(ClaudeMcp {
                            name: name.clone(),
                            command,
                            description,
                        });
                    }
                }
            }
        }
    }

    Ok(ClaudeResources {
        skills,
        agents,
        hooks,
        mcps,
    })
}

// ── Marketplace ───────────────────────────────────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarketSkill {
    pub name: String,
    pub description: String,
    pub stars: String,
    pub author: String,
    pub github_url: String,
    pub featured: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarketMcp {
    pub name: String,
    pub description: String,
    pub command: String,
    pub args: Vec<String>,
    pub source: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarketResult {
    pub items: Vec<MarketMcp>,
    pub open_browser: bool,
}

/// Fetch skill listings from skillsmp.com.
/// Always prepends @st4unch featured skills at top, then adds query results (deduped).
#[tauri::command(async)]
pub async fn fetch_skill_marketplace(query: String) -> Result<Vec<MarketSkill>, String> {
    let client = reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36")
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;

    // 1. Always fetch @st4unch featured skills at top
    let featured_html = fetch_skillsmp_page(&client, "st4unch").await;
    let featured = parse_skillsmp_html(&featured_html, true);
    let featured_names: std::collections::HashSet<String> =
        featured.iter().map(|s| s.name.clone()).collect();

    // 2. Fetch query-specific skills (skip if identical to "st4unch")
    let mut skills = featured;
    if !query.is_empty() && query.to_lowercase() != "st4unch" {
        let query_html = fetch_skillsmp_page(&client, &query).await;
        for s in parse_skillsmp_html(&query_html, false) {
            if !featured_names.contains(&s.name) {
                skills.push(s);
            }
        }
    }

    Ok(skills)
}

async fn fetch_skillsmp_page(client: &reqwest::Client, q: &str) -> String {
    match client
        .get("https://skillsmp.com/search")
        .query(&[("q", q)])
        .send()
        .await
    {
        Ok(resp) => resp.text().await.unwrap_or_default(),
        Err(_) => String::new(),
    }
}

fn parse_skillsmp_html(html: &str, featured: bool) -> Vec<MarketSkill> {
    use scraper::{Html, Selector};
    let doc = Html::parse_document(html);
    let card_sel = Selector::parse("a[href*='/creators/']").unwrap();
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for card in doc.select(&card_sel) {
        let href = card.value().attr("href").unwrap_or("").to_string();
        if href.is_empty() || seen.contains(&href) {
            continue;
        }
        seen.insert(href.clone());
        let text: String = card
            .text()
            .collect::<Vec<_>>()
            .join(" ")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        if text.is_empty() {
            continue;
        }
        let parts: Vec<&str> = href.trim_matches('/').split('/').collect();
        let name = parts.last().copied().unwrap_or("unknown").to_string();
        let author = parts.get(1).copied().unwrap_or("").to_string();
        let github_url = if parts.len() >= 4 {
            format!("https://github.com/{}/{}", parts[2], parts[3])
        } else {
            String::new()
        };
        let stars = text
            .split_whitespace()
            .find(|t| {
                (t.ends_with('k') && t[..t.len() - 1].parse::<f64>().is_ok())
                    || t.parse::<u64>().is_ok()
            })
            .unwrap_or("—")
            .to_string();
        let description = text
            .trim_start_matches(name.as_str())
            .trim_start_matches(author.as_str())
            .trim_start_matches(stars.as_str())
            .trim()
            .chars()
            .take(120)
            .collect::<String>();
        out.push(MarketSkill {
            name,
            description,
            stars,
            author,
            github_url,
            featured,
        });
        if out.len() >= 50 {
            break;
        }
    }
    out
}

/// Fetch MCP listings from glama.ai public JSON API.
/// Returns items with name/description/source (glama page URL).
/// command/args are empty — user opens source link to get install instructions.
#[tauri::command(async)]
pub async fn fetch_mcp_marketplace(query: String) -> Result<MarketResult, String> {
    let client = reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36")
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;

    let mut req = client
        .get("https://glama.ai/api/mcp/v1/servers")
        .query(&[("first", "40")]);
    if !query.is_empty() {
        req = req.query(&[("search", &query)]);
    }

    if let Ok(resp) = req.send().await {
        if resp.status().is_success() {
            if let Ok(body) = resp.text().await {
                if let Ok(json) = serde_json::from_str::<serde_json::Value>(&body) {
                    let items = parse_glama_mcp_json(&json);
                    if !items.is_empty() {
                        return Ok(MarketResult {
                            items,
                            open_browser: false,
                        });
                    }
                }
            }
        }
    }

    Ok(MarketResult {
        items: Vec::new(),
        open_browser: true,
    })
}

fn parse_glama_mcp_json(json: &serde_json::Value) -> Vec<MarketMcp> {
    let mut items = Vec::new();
    if let Some(arr) = json["servers"].as_array() {
        for item in arr.iter().take(50) {
            let name = item["name"].as_str().unwrap_or("").to_string();
            if name.is_empty() {
                continue;
            }
            let description = item["description"].as_str().unwrap_or("").to_string();
            let source = item["url"]
                .as_str()
                .unwrap_or("https://glama.ai/mcp/servers")
                .to_string();
            items.push(MarketMcp {
                name,
                description,
                command: String::new(),
                args: Vec::new(),
                source,
            });
        }
    }
    items
}

/// Clone a skill from GitHub into ~/.claude/skills/<name>/.
#[tauri::command(async)]
pub fn install_skill(name: String, github_url: String) -> Result<(), String> {
    if name.is_empty() || github_url.is_empty() {
        return Err("name and github_url are required".into());
    }
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    let dest = Path::new(&home).join(".claude").join("skills").join(&name);
    if dest.exists() {
        return Err(format!("~/.claude/skills/{name} already exists"));
    }
    let out = Command::new("git")
        .args(["clone", "--depth=1", &github_url, &dest.to_string_lossy()])
        .output()
        .map_err(|e| format!("git not found: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(())
}

/// Merge an MCP entry into ~/.claude/.mcp.json (user-scope, deduped by name).
#[tauri::command(async)]
pub fn install_mcp(name: String, command: String, args: Vec<String>) -> Result<(), String> {
    if name.is_empty() {
        return Err("name is required".into());
    }
    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    let mcp_path = Path::new(&home).join(".claude").join(".mcp.json");

    let mut root: serde_json::Value = if mcp_path.exists() {
        let content = std::fs::read_to_string(&mcp_path).map_err(|e| e.to_string())?;
        serde_json::from_str(&content).unwrap_or_else(|_| serde_json::json!({ "mcpServers": {} }))
    } else {
        serde_json::json!({ "mcpServers": {} })
    };

    let servers = root
        .as_object_mut()
        .and_then(|m| m.get_mut("mcpServers"))
        .and_then(|v| v.as_object_mut())
        .ok_or("malformed .mcp.json")?;

    let args_json: Vec<serde_json::Value> = args.iter().map(|a| serde_json::json!(a)).collect();
    servers.insert(
        name,
        serde_json::json!({ "command": command, "args": args_json }),
    );

    let out = serde_json::to_string_pretty(&root).map_err(|e| e.to_string())?;
    std::fs::write(&mcp_path, out).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    // ----- pure-function unit tests (no I/O) -----

    #[test]
    fn branch_kind_classifies() {
        assert_eq!(branch_kind("main"), "PRD");
        assert_eq!(branch_kind("release/1.0"), "PRD");
        assert_eq!(branch_kind("feature/x"), "WIP");
        assert_eq!(branch_kind("fix/y"), "WIP");
        assert_eq!(branch_kind("random"), "OPEN");
    }

    #[test]
    fn track_to_status_maps() {
        assert_eq!(track_to_status(""), "synced");
        assert_eq!(track_to_status("[ahead 2]"), "ahead");
        assert_eq!(track_to_status("[behind 1]"), "synced");
        assert_eq!(track_to_status("[ahead 1, behind 3]"), "diverged");
    }

    // ----- hermetic git integration tests (temp repos) -----

    #[test]
    fn list_dir_sorts_dirs_first() {
        let r = init_repo();
        std::fs::create_dir(Path::new(&r.path).join("zdir")).unwrap();
        put_file(&r.path, "afile.txt", "x");
        let entries = list_dir(r.path.clone()).unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert!(names.contains(&"zdir") && names.contains(&"afile.txt"));
        let first_file = entries.iter().position(|e| !e.is_directory).unwrap();
        let dirs_before = entries[..first_file].iter().all(|e| e.is_directory);
        assert!(dirs_before, "dirs should precede files: {names:?}");
    }

    #[test]
    fn list_branches_and_parents() {
        let r = init_repo();
        // main → feature/a (1 commit) → feature/b (1 commit)
        run_git(&r.path, &["switch", "-c", "feature/a"]);
        commit_file(&r.path, "a.txt", "a", "a1");
        run_git(&r.path, &["switch", "-c", "feature/b"]);
        commit_file(&r.path, "b.txt", "b", "b1");
        run_git(&r.path, &["switch", "main"]);

        let bs = list_branches(r.path.clone()).unwrap();
        let by = |n: &str| bs.iter().find(|b| b.name == n).unwrap();
        assert_eq!(bs.len(), 3);
        assert_eq!(by("feature/a").kind, "WIP");
        assert_eq!(by("main").parent, None);
        assert_eq!(by("feature/a").parent.as_deref(), Some("main"));
        assert_eq!(by("feature/b").parent.as_deref(), Some("feature/a"));
    }

    #[test]
    fn read_head_file_returns_committed_then_empty_for_untracked() {
        let r = init_repo();
        commit_file(&r.path, "f.txt", "committed\n", "c");
        put_file(&r.path, "f.txt", "working changes\n"); // dirty
        let head =
            read_head_file(Path::new(&r.path).join("f.txt").to_string_lossy().into()).unwrap();
        assert_eq!(head, "committed\n");
        // untracked file → empty HEAD
        put_file(&r.path, "new.txt", "x");
        let none =
            read_head_file(Path::new(&r.path).join("new.txt").to_string_lossy().into()).unwrap();
        assert_eq!(none, "");
    }

    #[test]
    fn create_and_remove_worktree() {
        let r = init_repo();
        let wt = create_worktree(r.path.clone(), "feature/wt".into()).unwrap();
        assert!(Path::new(&wt).exists(), "worktree dir exists");
        // listed by git
        let list = Command::new("git")
            .args(["-C", &r.path, "worktree", "list"])
            .output()
            .unwrap();
        assert!(String::from_utf8_lossy(&list.stdout).contains(&wt));
        remove_worktree(wt.clone()).unwrap();
        assert!(!Path::new(&wt).exists(), "worktree dir removed");
    }

    #[test]
    fn create_file_makes_empty_then_preserves_existing() {
        let r = init_repo();
        let f = Path::new(&r.path)
            .join("sub/new.txt")
            .to_string_lossy()
            .into_owned();
        create_file(f.clone()).unwrap();
        assert!(Path::new(&f).exists(), "new file created");
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "");
        // Re-creating over an existing file must NOT truncate it.
        std::fs::write(&f, "keep").unwrap();
        create_file(f.clone()).unwrap();
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "keep");
    }

    #[test]
    fn branch_detail_reports_commits_and_diff() {
        let r = init_repo();
        run_git(&r.path, &["switch", "-c", "feature/x"]);
        commit_file(&r.path, "x.txt", "x", "add x");
        run_git(&r.path, &["switch", "main"]);

        let d = branch_detail(r.path.clone(), "feature/x".into()).unwrap();
        assert_eq!(d.base, "main");
        assert_eq!(d.ahead, 1);
        assert_eq!(d.behind, 0);
        assert_eq!(d.commits.len(), 1);
        assert_eq!(d.commits[0].subject, "add x");
        assert!(d.changed_files.contains(&"x.txt".to_string()));
    }

    #[test]
    fn branch_detail_base_branch_has_nothing_ahead_and_errors_on_unknown() {
        let r = init_repo();
        commit_file(&r.path, "a.txt", "a", "c1");
        commit_file(&r.path, "b.txt", "b", "c2");
        // Inspecting main itself (no base above it) must not report its whole history
        // as "ahead".
        let d = branch_detail(r.path.clone(), "main".into()).unwrap();
        assert_eq!(d.base, "");
        assert_eq!(d.ahead, 0);
        assert_eq!(d.behind, 0);
        assert!(d.changed_files.is_empty());
        // Unknown branch → explicit error, not a silently empty card.
        assert!(branch_detail(r.path.clone(), "does-not-exist".into()).is_err());
    }
}

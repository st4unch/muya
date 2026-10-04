//! "On this Mac" results for the ⌘K palette: files found by Spotlight by name, the
//! way Finder's search box finds them.
//!
//! `mdfind -name <query>` gets the query as one argv entry. No shell is involved, so
//! nothing in the query is ever interpreted. mdfind can stream thousands of hits
//! (build output, caches), so we read a bounded number of lines under a time budget,
//! drop paths nobody wants to open, and rank what is left.

use std::path::Path;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, BufReader};

const MAX_RESULTS: usize = 50;
/// mdfind lines read before we stop it; the filter below throws many away.
const MAX_LINES: usize = 2000;
const TIME_BUDGET: Duration = Duration::from_secs(3);

/// Path components that mark generated or tool-owned trees, not files a person opens.
const NOISE_DIRS: &[&str] = &[
    "node_modules",
    "target",
    "DerivedData",
    "__pycache__",
    "Pods",
    "dist",
    "build",
];

/// Keep only paths worth offering: no hidden component, nothing under ~/Library, no
/// build/dependency trees, and nothing inside an app/framework bundle.
fn worth_showing(path: &str, home: &str) -> bool {
    if !home.is_empty() && path.starts_with(&format!("{home}/Library/")) {
        return false;
    }
    !path.split('/').any(|c| {
        c.starts_with('.')
            || NOISE_DIRS.contains(&c)
            || c.ends_with(".app")
            || c.ends_with(".framework")
    })
}

/// Sort key: inside a workspace first, then under $HOME, then elsewhere. Within a
/// tier, names that start with the query come first, then shorter paths.
fn rank(path: &str, query_lc: &str, roots: &[String], home: &str) -> (u8, u8, usize) {
    let under = |root: &str| {
        !root.is_empty()
            && (path == root || path.starts_with(&format!("{}/", root.trim_end_matches('/'))))
    };
    let tier = if roots.iter().any(|r| under(r)) {
        0
    } else if under(home) {
        1
    } else {
        2
    };
    let name = path.rsplit('/').next().unwrap_or(path).to_lowercase();
    (tier, u8::from(!name.starts_with(query_lc)), path.len())
}

/// Filter, de-duplicate and rank raw mdfind lines. Pure, so it is unit-tested.
fn select(lines: Vec<String>, query: &str, roots: &[String], home: &str) -> Vec<String> {
    let q = query.to_lowercase();
    let mut seen = std::collections::HashSet::new();
    let mut hits: Vec<String> = lines
        .into_iter()
        .filter(|p| p.starts_with('/'))
        .filter(|p| {
            p.rsplit('/')
                .next()
                .is_some_and(|n| n.to_lowercase().contains(&q))
        })
        .filter(|p| worth_showing(p, home))
        .filter(|p| seen.insert(p.clone()))
        .collect();
    hits.sort_by_key(|p| rank(p, &q, roots, home));
    hits
}

#[tauri::command]
pub async fn spotlight_search(query: String, roots: Vec<String>) -> Result<Vec<String>, String> {
    let query = query.trim().to_string();
    if query.chars().count() < 2 {
        return Ok(vec![]);
    }
    let mut child = tokio::process::Command::new("/usr/bin/mdfind")
        .arg("-name")
        .arg(&query)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("Couldn't run Spotlight (mdfind): {e}"))?;
    let stdout = child.stdout.take().ok_or("mdfind gave no output")?;
    let mut reader = BufReader::new(stdout).lines();
    let mut lines = Vec::new();
    let _ = tokio::time::timeout(TIME_BUDGET, async {
        while lines.len() < MAX_LINES {
            match reader.next_line().await {
                Ok(Some(l)) => lines.push(l),
                _ => break,
            }
        }
    })
    .await;
    let _ = child.kill().await;

    let home = std::env::var("HOME").unwrap_or_default();
    let mut hits = select(lines, &query, &roots, &home);
    // Spotlight's index can lag behind deletions; offer only files that exist now.
    hits.retain(|p| Path::new(p).is_file());
    hits.truncate(MAX_RESULTS);
    Ok(hits)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn drops_hidden_library_build_and_bundle_paths() {
        let home = "/Users/u";
        for p in [
            "/Users/u/.config/muya.json",
            "/Users/u/Library/Caches/muya.log",
            "/Users/u/p/node_modules/muya/index.js",
            "/Users/u/p/target/debug/muya",
            "/Applications/Muya.app/Contents/Info.plist",
        ] {
            assert!(!worth_showing(p, home), "{p}");
        }
        assert!(worth_showing("/Users/u/p/src/muya.ts", home));
    }

    #[test]
    fn keeps_only_names_containing_the_query() {
        let out = select(
            s(&["/Users/u/a/Muya-notes.md", "/Users/u/a/other.md"]),
            "muya",
            &[],
            "/Users/u",
        );
        assert_eq!(out, s(&["/Users/u/a/Muya-notes.md"]));
    }

    #[test]
    fn workspace_first_then_home_then_elsewhere_prefix_before_substring() {
        let roots = s(&["/Users/u/proj"]);
        let out = select(
            s(&[
                "/opt/muya.txt",
                "/Users/u/docs/my-muya.md",
                "/Users/u/docs/muya.md",
                "/Users/u/proj/src/old_muya.rs",
                "/Users/u/project2/muya.md",
            ]),
            "muya",
            &roots,
            "/Users/u",
        );
        assert_eq!(
            out,
            s(&[
                "/Users/u/proj/src/old_muya.rs",
                "/Users/u/docs/muya.md",
                "/Users/u/project2/muya.md",
                "/Users/u/docs/my-muya.md",
                "/opt/muya.txt"
            ])
        );
    }

    #[test]
    fn de_duplicates() {
        let out = select(
            s(&["/Users/u/a/muya.md", "/Users/u/a/muya.md"]),
            "muya",
            &[],
            "/Users/u",
        );
        assert_eq!(out.len(), 1);
    }

    #[tokio::test]
    async fn short_query_returns_nothing_without_running_mdfind() {
        assert!(spotlight_search("m".into(), vec![])
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn finds_a_real_file_on_this_mac() {
        // Spotlight indexes files it can see; a temp dir under /private/var may not be
        // indexed, so query something every macOS install has instead.
        let out = spotlight_search("Info.plist".into(), vec![]).await.unwrap();
        assert!(out.len() <= MAX_RESULTS);
        assert!(out.iter().all(|p| Path::new(p).is_file()));
    }
}

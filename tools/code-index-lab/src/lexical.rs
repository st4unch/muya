// Keyword-side retrieval: tokenizer, BM25, symbol map, grep baseline.
use crate::chunk::Chunk;
use std::collections::{HashMap, HashSet};

const STOP: &[&str] = &[
    "the",
    "a",
    "an",
    "is",
    "are",
    "where",
    "what",
    "how",
    "which",
    "does",
    "do",
    "of",
    "to",
    "in",
    "for",
    "and",
    "or",
    "on",
    "it",
    "its",
    "this",
    "that",
    "when",
    "with",
    "from",
    "by",
    "be",
    "as",
    "at",
    "get",
    "set",
    "app",
    "code",
    "defined",
    "handled",
    "happens",
    "file",
    "function",
    "find",
    "there",
    "into",
    "who",
    "why",
    "i",
    "we",
    "can",
    "after",
    "before",
    // Turkish
    "nerede",
    "nasıl",
    "ne",
    "hangi",
    "mi",
    "mı",
    "mu",
    "mü",
    "ve",
    "ile",
    "bir",
    "bu",
    "şu",
    "için",
    "da",
    "de",
    "ki",
    "olan",
    "oluyor",
    "yapılıyor",
    "yerde",
    "nereye",
    "neresi",
    "kim",
    "zaman",
];

/// Split identifiers and words: `credstore_lock` -> credstore, lock, credstore_lock;
/// `useTerminalPrefs` -> use, terminal, prefs, useterminalprefs.
pub fn tokenize(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    for raw in s.split(|c: char| !(c.is_alphanumeric() || c == '_')) {
        if raw.is_empty() {
            continue;
        }
        let whole = raw.to_lowercase();
        let mut parts = Vec::new();
        for seg in raw.split('_') {
            let mut cur = String::new();
            let cs: Vec<char> = seg.chars().collect();
            for (i, &c) in cs.iter().enumerate() {
                let boundary = c.is_uppercase()
                    && i > 0
                    && (cs[i - 1].is_lowercase()
                        || (i + 1 < cs.len()
                            && cs[i + 1].is_lowercase()
                            && cs[i - 1].is_uppercase()));
                if boundary && !cur.is_empty() {
                    parts.push(std::mem::take(&mut cur));
                }
                cur.extend(c.to_lowercase());
            }
            if !cur.is_empty() {
                parts.push(cur);
            }
        }
        if parts.len() > 1 {
            out.push(whole);
        }
        out.extend(parts);
    }
    out.into_iter()
        .filter(|t| {
            t.chars().count() >= 2
                && !STOP.contains(&t.as_str())
                && !t.chars().all(|c| c.is_ascii_digit())
        })
        .map(|t| stem(&t))
        .collect()
}

fn stem(t: &str) -> String {
    // Tiny English plural trim so "sessions" meets "session".
    if t.len() > 4 && t.ends_with('s') && !t.ends_with("ss") {
        t[..t.len() - 1].to_string()
    } else {
        t.to_string()
    }
}

pub struct Bm25 {
    docs: Vec<HashMap<String, f32>>,
    len: Vec<f32>,
    avg: f32,
    df: HashMap<String, f32>,
}

impl Bm25 {
    pub fn build(chunks: &[Chunk]) -> Self {
        let mut docs = Vec::new();
        let mut len = Vec::new();
        let mut df: HashMap<String, f32> = HashMap::new();
        for c in chunks {
            // path and symbol words count too: "credstore.rs" says a lot about the chunk
            let toks = tokenize(&format!("{} {} {}", c.path, c.symbol, c.text));
            let mut tf: HashMap<String, f32> = HashMap::new();
            for t in &toks {
                *tf.entry(t.clone()).or_default() += 1.0;
            }
            for t in tf.keys() {
                *df.entry(t.clone()).or_default() += 1.0;
            }
            len.push(toks.len() as f32);
            docs.push(tf);
        }
        let avg = len.iter().sum::<f32>() / len.len().max(1) as f32;
        Bm25 { docs, len, avg, df }
    }

    pub fn search(&self, q: &str) -> Vec<(usize, f32)> {
        let (k1, b) = (1.2f32, 0.75f32);
        let n = self.docs.len() as f32;
        let qt: HashSet<String> = tokenize(q).into_iter().collect();
        let mut res: Vec<(usize, f32)> = self
            .docs
            .iter()
            .enumerate()
            .map(|(i, d)| {
                let mut s = 0.0;
                for t in &qt {
                    if let Some(&f) = d.get(t) {
                        let df = self.df[t];
                        let idf = ((n - df + 0.5) / (df + 0.5) + 1.0).ln();
                        s += idf * f * (k1 + 1.0)
                            / (f + k1 * (1.0 - b + b * self.len[i] / self.avg));
                    }
                }
                (i, s)
            })
            .filter(|(_, s)| *s > 0.0)
            .collect();
        res.sort_by(|a, b| b.1.total_cmp(&a.1));
        res
    }
}

/// Symbol map: match query words against definition names only.
pub fn symbol_search(chunks: &[Chunk], q: &str) -> Vec<(usize, f32)> {
    let qt: HashSet<String> = tokenize(q).into_iter().collect();
    let qraw = q.to_lowercase();
    let mut res: Vec<(usize, f32)> = chunks
        .iter()
        .enumerate()
        .filter(|(_, c)| !c.symbol.is_empty())
        .filter_map(|(i, c)| {
            let leaf = c.symbol.rsplit("::").next().unwrap_or(&c.symbol);
            let parts: Vec<String> = tokenize(leaf);
            if parts.is_empty() {
                return None;
            }
            let hit = parts.iter().filter(|p| qt.contains(*p)).count() as f32;
            if hit == 0.0 {
                return None;
            }
            let exact = if qraw.contains(&leaf.to_lowercase()) {
                2.0
            } else {
                0.0
            };
            Some((i, exact + hit / parts.len() as f32 + 0.1 * hit))
        })
        .collect();
    res.sort_by(|a, b| b.1.total_cmp(&a.1));
    res
}

/// Grep baseline at file level: files ranked by how many distinct query words they
/// contain (case-insensitive substring), then by total hits. Mimics an agent's first
/// `rg -l word1|word2` pass.
pub fn grep_files(files: &[(String, String)], q: &str) -> Vec<String> {
    let words: Vec<String> = q
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .map(|w| w.to_lowercase())
        .filter(|w| w.chars().count() >= 3 && !STOP.contains(&w.as_str()))
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    let mut scored: Vec<(String, usize, usize)> = files
        .iter()
        .filter_map(|(p, text)| {
            let lower = text.to_lowercase();
            let mut distinct = 0;
            let mut total = 0;
            for w in &words {
                let n = lower.matches(w.as_str()).count();
                if n > 0 {
                    distinct += 1;
                    total += n;
                }
            }
            (distinct > 0).then(|| (p.clone(), distinct, total))
        })
        .collect();
    scored.sort_by(|a, b| b.1.cmp(&a.1).then(b.2.cmp(&a.2)));
    scored.into_iter().map(|s| s.0).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn splits_identifiers() {
        let t = tokenize("credstore_lock useTerminalPrefs PTYSession");
        for w in [
            "credstore",
            "lock",
            "credstore_lock",
            "use",
            "terminal",
            "pref",
            "useterminalpref",
            "pty",
            "session",
        ] {
            assert!(t.contains(&w.to_string()), "{w} missing from {t:?}");
        }
    }
}

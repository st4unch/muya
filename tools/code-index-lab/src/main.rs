// code-index-lab — measures how well different code-search methods find the right
// place in this repo for a fixed question set. See docs/exp-code-index.md.
//
//   cargo run --release -- chunk                 # out/chunks.json
//   cargo run --release -- embed <model>         # out/emb-<model>.bin
//   cargo run --release -- eval [flags]          # metrics table + out/results.json
mod chunk;
mod lexical;

use anyhow::{bail, Context, Result};
use chunk::Chunk;
use fastembed::{
    EmbeddingModel, RerankInitOptions, RerankerModel, TextEmbedding, TextInitOptions, TextRerank,
};
use serde::Deserialize;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Instant;

const DIRS: &[&str] = &["src", "src-tauri/src"];

fn repo_root() -> PathBuf {
    let here = Path::new(env!("CARGO_MANIFEST_DIR"));
    here.parent().unwrap().parent().unwrap().to_path_buf()
}
fn out_dir() -> PathBuf {
    let d = Path::new(env!("CARGO_MANIFEST_DIR")).join("out");
    std::fs::create_dir_all(&d).ok();
    d
}

// ---------- embedding models ----------

struct Spec {
    model: EmbeddingModel,
    q_prefix: &'static str,
    d_prefix: &'static str,
}

fn spec(key: &str) -> Result<Spec> {
    Ok(match key {
        "jina-code" => Spec {
            model: EmbeddingModel::JinaEmbeddingsV2BaseCode,
            q_prefix: "",
            d_prefix: "",
        },
        "gemma" => Spec {
            model: EmbeddingModel::EmbeddingGemma300MQ,
            q_prefix: "task: code retrieval | query: ",
            d_prefix: "title: none | text: ",
        },
        "e5-small" => Spec {
            model: EmbeddingModel::MultilingualE5Small,
            q_prefix: "query: ",
            d_prefix: "passage: ",
        },
        "e5-base" => Spec {
            model: EmbeddingModel::MultilingualE5Base,
            q_prefix: "query: ",
            d_prefix: "passage: ",
        },
        "bge-small" => Spec {
            model: EmbeddingModel::BGESmallENV15,
            q_prefix: "Represent this sentence for searching relevant passages: ",
            d_prefix: "",
        },
        _ => bail!("unknown embedding model {key}"),
    })
}

fn doc_text(c: &Chunk) -> String {
    format!("{} {}\n{}", c.path, c.symbol, c.text)
}

fn load_model(key: &str) -> Result<TextEmbedding> {
    let s = spec(key)?;
    TextEmbedding::try_new(
        TextInitOptions::new(s.model)
            .with_max_length(512)
            .with_cache_dir(out_dir().join("models"))
            .with_show_download_progress(true),
    )
    .map_err(Into::into)
}

fn load_reranker(rk: &str) -> Result<TextRerank> {
    let model = match rk {
        "jina-v2-ml" => RerankerModel::JINARerankerV2BaseMultiligual,
        "bge-m3" => RerankerModel::BGERerankerV2M3,
        "jina-v1-en" => RerankerModel::JINARerankerV1TurboEn,
        _ => bail!("unknown reranker {rk}"),
    };
    TextRerank::try_new(
        RerankInitOptions::new(model)
            .with_max_length(512)
            .with_cache_dir(out_dir().join("models"))
            .with_show_download_progress(true),
    )
    .map_err(Into::into)
}

fn write_vecs(path: &Path, v: &[Vec<f32>]) -> Result<()> {
    let dim = v.first().map(|x| x.len()).unwrap_or(0);
    let mut buf = Vec::with_capacity(8 + v.len() * dim * 4);
    buf.extend((v.len() as u32).to_le_bytes());
    buf.extend((dim as u32).to_le_bytes());
    for row in v {
        for x in row {
            buf.extend(x.to_le_bytes());
        }
    }
    std::fs::write(path, buf)?;
    Ok(())
}

fn read_vecs(path: &Path) -> Result<Vec<Vec<f32>>> {
    let b = std::fs::read(path).with_context(|| format!("read {}", path.display()))?;
    let n = u32::from_le_bytes(b[0..4].try_into()?) as usize;
    let dim = u32::from_le_bytes(b[4..8].try_into()?) as usize;
    let f: Vec<f32> = b[8..]
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
        .collect();
    Ok((0..n)
        .map(|i| normalize(f[i * dim..(i + 1) * dim].to_vec()))
        .collect())
}

fn normalize(mut v: Vec<f32>) -> Vec<f32> {
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-9);
    v.iter_mut().for_each(|x| *x /= n);
    v
}

fn cosine_rank(q: &[f32], docs: &[Vec<f32>]) -> Vec<(usize, f32)> {
    let mut r: Vec<(usize, f32)> = docs
        .iter()
        .enumerate()
        .map(|(i, d)| (i, d.iter().zip(q).map(|(a, b)| a * b).sum()))
        .collect();
    r.sort_by(|a, b| b.1.total_cmp(&a.1));
    r
}

// ---------- questions & metrics ----------

#[derive(Deserialize)]
struct QFile {
    questions: Vec<Question>,
}
#[derive(Deserialize, Clone)]
struct Question {
    id: String,
    lang: String,
    #[serde(rename = "type")]
    kind: String,
    q: String,
    gold: Vec<Gold>,
}
#[derive(Deserialize, Clone)]
struct Gold {
    path: String,
    start: usize,
    end: usize,
    #[serde(default)]
    primary: bool,
}

fn files_in_order(chunks: &[Chunk], ranked: &[usize]) -> Vec<String> {
    let mut seen = HashSet::new();
    ranked
        .iter()
        .filter_map(|&i| {
            seen.insert(chunks[i].path.clone())
                .then(|| chunks[i].path.clone())
        })
        .collect()
}

#[derive(Default, Clone)]
struct Score {
    f1: f32,
    f5: f32,
    f10: f32,
    mrr: f32,
    c5: f32,
    c10: f32,
    all10: f32,
}

fn score(q: &Question, files: &[String], top_chunks: Option<&[&Chunk]>) -> Score {
    let primary = q.gold.iter().find(|g| g.primary).unwrap_or(&q.gold[0]);
    let pos = files.iter().position(|f| *f == primary.path);
    let at = |k: usize| pos.map(|p| (p < k) as u8 as f32).unwrap_or(0.0);
    let overlap = |c: &Chunk| {
        q.gold
            .iter()
            .any(|g| g.path == c.path && c.start <= g.end && g.start <= c.end)
    };
    let (c5, c10) = match top_chunks {
        Some(tc) => (
            tc.iter().take(5).any(|c| overlap(c)) as u8 as f32,
            tc.iter().take(10).any(|c| overlap(c)) as u8 as f32,
        ),
        None => (f32::NAN, f32::NAN),
    };
    let gold_files: HashSet<&str> = q.gold.iter().map(|g| g.path.as_str()).collect();
    let top10: HashSet<&str> = files.iter().take(10).map(|s| s.as_str()).collect();
    Score {
        f1: at(1),
        f5: at(5),
        f10: at(10),
        mrr: pos.map(|p| 1.0 / (p as f32 + 1.0)).unwrap_or(0.0),
        c5,
        c10,
        all10: gold_files.iter().all(|f| top10.contains(f)) as u8 as f32,
    }
}

fn rrf(lists: &[&[(usize, f32)]], k: f32) -> Vec<(usize, f32)> {
    let mut m: HashMap<usize, f32> = HashMap::new();
    for l in lists {
        for (rank, (i, _)) in l.iter().take(200).enumerate() {
            *m.entry(*i).or_default() += 1.0 / (k + rank as f32 + 1.0);
        }
    }
    let mut v: Vec<_> = m.into_iter().collect();
    v.sort_by(|a, b| b.1.total_cmp(&a.1));
    v
}

// ---------- commands ----------

fn cmd_chunk() -> Result<()> {
    let t = Instant::now();
    let chunks = chunk::chunk_repo(&repo_root(), DIRS)?;
    let files: HashSet<&str> = chunks.iter().map(|c| c.path.as_str()).collect();
    let mut kinds: HashMap<&str, usize> = HashMap::new();
    for c in &chunks {
        *kinds.entry(c.kind.as_str()).or_default() += 1;
    }
    std::fs::write(out_dir().join("chunks.json"), serde_json::to_vec(&chunks)?)?;
    println!(
        "{} chunks from {} files in {:?}",
        chunks.len(),
        files.len(),
        t.elapsed()
    );
    println!("by kind: {kinds:?}");
    let mut sizes: Vec<usize> = chunks.iter().map(|c| c.end - c.start + 1).collect();
    sizes.sort();
    println!(
        "lines per chunk: p50={} p90={} max={}",
        sizes[sizes.len() / 2],
        sizes[sizes.len() * 9 / 10],
        sizes.last().unwrap()
    );
    Ok(())
}

fn load_chunks() -> Result<Vec<Chunk>> {
    Ok(serde_json::from_slice(
        &std::fs::read(out_dir().join("chunks.json")).context("run `chunk` first")?,
    )?)
}

fn cmd_embed(key: &str) -> Result<()> {
    let chunks = load_chunks()?;
    let s = spec(key)?;
    let t = Instant::now();
    let mut m = load_model(key)?;
    println!("model load {:?}", t.elapsed());
    let texts: Vec<String> = chunks
        .iter()
        .map(|c| format!("{}{}", s.d_prefix, doc_text(c)))
        .collect();
    let t = Instant::now();
    // Dynamically quantized models (gemma Q) can't batch: one text at a time.
    let v = if key == "gemma" {
        let mut v = Vec::with_capacity(texts.len());
        for t in &texts {
            v.push(m.embed(&[t.as_str()], Some(1))?.remove(0));
        }
        v
    } else {
        m.embed(&texts, Some(16))?
    };
    let el = t.elapsed();
    write_vecs(&out_dir().join(format!("emb-{key}.bin")), &v)?;
    println!(
        "{key}: {} chunks, dim {}, {:?} ({:.1} chunks/s)",
        v.len(),
        v[0].len(),
        el,
        v.len() as f64 / el.as_secs_f64()
    );
    Ok(())
}

struct EvalOpts {
    embeds: Vec<String>,
    rerankers: Vec<String>,
    rewrite: Option<PathBuf>,
    apple: bool,
}

fn cmd_eval(o: EvalOpts) -> Result<()> {
    let root = repo_root();
    let chunks = load_chunks()?;
    let qf: QFile = serde_json::from_slice(&std::fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("questions.json"),
    )?)?;
    // Gold outside the indexed dirs (e.g. scripts/*.sh) can't be found by any method:
    // drop those ranges, and the question when nothing indexed is left.
    let indexed: HashSet<&str> = chunks.iter().map(|c| c.path.as_str()).collect();
    let mut qs = vec![];
    for mut q in qf.questions {
        q.gold.retain(|g| indexed.contains(g.path.as_str()));
        if q.gold.is_empty() {
            println!("skip {}: no gold answer inside the index", q.id);
            continue;
        }
        if !q.gold.iter().any(|g| g.primary) {
            q.gold[0].primary = true;
        }
        qs.push(q);
    }
    let mut file_text: Vec<(String, String)> = Vec::new();
    for f in indexed.iter() {
        file_text.push((f.to_string(), std::fs::read_to_string(root.join(f))?));
    }
    file_text.sort();

    let t = Instant::now();
    let bm = lexical::Bm25::build(&chunks);
    println!("BM25 build {:?} over {} chunks", t.elapsed(), chunks.len());

    let rewrite: HashMap<String, String> = match &o.rewrite {
        Some(p) => serde_json::from_slice(&std::fs::read(p)?)?,
        None => HashMap::new(),
    };

    // method -> per-question (score, chunk ranking, latency ms)
    let mut table: Vec<(String, Vec<Score>, Vec<f64>)> = Vec::new();
    let mut per_q: HashMap<String, serde_json::Value> = HashMap::new();
    let record = |name: &str,
                  scores: Vec<Score>,
                  lat: Vec<f64>,
                  table: &mut Vec<(String, Vec<Score>, Vec<f64>)>| {
        table.push((name.to_string(), scores, lat));
    };

    // G — grep baseline
    let mut sc = vec![];
    let mut lat = vec![];
    for q in &qs {
        let t = Instant::now();
        let files = lexical::grep_files(&file_text, &q.q);
        lat.push(t.elapsed().as_secs_f64() * 1e3);
        sc.push(score(q, &files, None));
    }
    record("G grep", sc, lat, &mut table);

    let run_lists = |lists_for: &dyn Fn(&Question) -> (Vec<(usize, f32)>, f64)| -> (Vec<Score>, Vec<f64>, Vec<Vec<usize>>) {
        let mut sc = vec![];
        let mut lat = vec![];
        let mut ranks = vec![];
        for q in &qs {
            let (r, ms) = lists_for(q);
            let idx: Vec<usize> = r.iter().map(|x| x.0).collect();
            let files = files_in_order(&chunks, &idx);
            let top: Vec<&Chunk> = idx.iter().take(10).map(|&i| &chunks[i]).collect();
            sc.push(score(q, &files, Some(&top)));
            lat.push(ms);
            ranks.push(idx.into_iter().take(30).collect());
        }
        (sc, lat, ranks)
    };

    let timed = |f: &dyn Fn() -> Vec<(usize, f32)>| {
        let t = Instant::now();
        let r = f();
        (r, t.elapsed().as_secs_f64() * 1e3)
    };

    let (s, l, _) = run_lists(&|q| timed(&|| bm.search(&q.q)));
    record("B bm25", s, l, &mut table);
    let (s, l, _) = run_lists(&|q| timed(&|| lexical::symbol_search(&chunks, &q.q)));
    record("S symbols", s, l, &mut table);
    let (s, l, _) = run_lists(&|q| {
        timed(&|| {
            rrf(
                &[&bm.search(&q.q), &lexical::symbol_search(&chunks, &q.q)],
                60.0,
            )
        })
    });
    record("B+S", s, l, &mut table);

    // Same lexical methods fed the rewritten keyword query (what an agent would type).
    if !rewrite.is_empty() {
        let rq = |q: &Question| rewrite.get(&q.id).cloned().unwrap_or_else(|| q.q.clone());
        let mut sc = vec![];
        let mut lat = vec![];
        for q in &qs {
            let t = Instant::now();
            let files = lexical::grep_files(&file_text, &rq(q));
            lat.push(t.elapsed().as_secs_f64() * 1e3);
            sc.push(score(q, &files, None));
        }
        record("G' grep rewritten", sc, lat, &mut table);
        let (s, l, _) = run_lists(&|q| timed(&|| bm.search(&rq(q))));
        record("B' bm25 rewritten", s, l, &mut table);
        let (s, l, _) = run_lists(&|q| {
            let qq = rq(q);
            timed(&|| {
                rrf(
                    &[&bm.search(&qq), &lexical::symbol_search(&chunks, &qq)],
                    60.0,
                )
            })
        });
        record("B'+S' rewritten", s, l, &mut table);
        // Agent keywords -> BM25 top 30 -> cross-encoder judged against the original question.
        for rk in &o.rerankers {
            let mut rr = load_reranker(rk)?;
            let mut sc = vec![];
            let mut lat = vec![];
            for q in &qs {
                let t = Instant::now();
                let cand: Vec<usize> = bm.search(&rq(q)).iter().take(30).map(|x| x.0).collect();
                let docs: Vec<String> = cand
                    .iter()
                    .map(|&i| doc_text(&chunks[i]).chars().take(2000).collect())
                    .collect();
                let idx: Vec<usize> = if docs.is_empty() {
                    vec![]
                } else {
                    rr.rerank(q.q.clone(), docs, false, Some(30))?.iter().map(|r| cand[r.index]).collect()
                };
                lat.push(t.elapsed().as_secs_f64() * 1e3);
                let files = files_in_order(&chunks, &idx);
                let top: Vec<&Chunk> = idx.iter().take(10).map(|&i| &chunks[i]).collect();
                sc.push(score(q, &files, Some(&top)));
            }
            record(&format!("R' {rk} on B' rewritten"), sc, lat, &mut table);
        }
    }

    // Embeddings: query vectors computed now (latency counted), doc vectors from disk.
    let mut emb_rank: HashMap<String, Vec<(Vec<(usize, f32)>, f64)>> = HashMap::new();
    for key in &o.embeds {
        let docs = read_vecs(&out_dir().join(format!("emb-{key}.bin")))?;
        if docs.len() != chunks.len() {
            bail!(
                "emb-{key}.bin has {} rows, chunks.json has {} — re-run embed",
                docs.len(),
                chunks.len()
            );
        }
        let s = spec(key)?;
        let mut m = load_model(key)?;
        let mut rows = vec![];
        for q in &qs {
            let t = Instant::now();
            let qv = normalize(
                m.embed(&[format!("{}{}", s.q_prefix, q.q)], None)?
                    .remove(0),
            );
            let r = cosine_rank(&qv, &docs);
            rows.push((r, t.elapsed().as_secs_f64() * 1e3));
        }
        emb_rank.insert(key.clone(), rows);
    }
    if o.apple {
        let docs = read_vecs(&out_dir().join("emb-apple.bin"))?;
        let qv = read_vecs(&out_dir().join("qemb-apple.bin"))?;
        let qlat: Vec<f64> =
            serde_json::from_slice(&std::fs::read(out_dir().join("qemb-apple-ms.json"))?)?;
        let rows = qs.iter().enumerate().map(|(i, _)| {
            let t = Instant::now();
            let r = cosine_rank(&qv[i], &docs);
            (r, qlat[i] + t.elapsed().as_secs_f64() * 1e3)
        });
        emb_rank.insert("apple".into(), rows.collect());
    }
    let mut keys: Vec<String> = emb_rank.keys().cloned().collect();
    keys.sort();
    for key in &keys {
        let rows = &emb_rank[key];
        let qi = |q: &Question| qs.iter().position(|x| x.id == q.id).unwrap();
        let (s, l, _) = run_lists(&|q| rows[qi(q)].clone());
        record(&format!("E {key}"), s, l, &mut table);
        let (s, l, ranks) = run_lists(&|q| {
            let (e, ems) = &rows[qi(q)];
            let (r, ms) = timed(&|| {
                rrf(
                    &[&bm.search(&q.q), &lexical::symbol_search(&chunks, &q.q), e],
                    60.0,
                )
            });
            (r, ms + ems)
        });
        record(&format!("H B+S+{key}"), s, l, &mut table);
        for (q, r) in qs.iter().zip(&ranks) {
            per_q
                .entry(q.id.clone())
                .or_insert_with(|| json!({}))
                .as_object_mut()
                .unwrap()
                .insert(
                    format!("H {key}"),
                    json!(r
                        .iter()
                        .take(10)
                        .map(|&i| format!(
                            "{}:{}-{}",
                            chunks[i].path, chunks[i].start, chunks[i].end
                        ))
                        .collect::<Vec<_>>()),
                );
        }
        if !rewrite.is_empty() {
            let (s, l, _) = run_lists(&|q| {
                let (e, ems) = &rows[qi(q)];
                let qq = format!(
                    "{} {}",
                    q.q,
                    rewrite.get(&q.id).map(|s| s.as_str()).unwrap_or("")
                );
                let (r, ms) = timed(&|| {
                    rrf(
                        &[&bm.search(&qq), &lexical::symbol_search(&chunks, &qq), e],
                        60.0,
                    )
                });
                (r, ms + ems)
            });
            record(&format!("A rewrite+B+S+{key}"), s, l, &mut table);
        }
        // Rerank the hybrid top 30.
        for rk in &o.rerankers {
            let mut rr = load_reranker(rk)?;
            let mut sc = vec![];
            let mut lat = vec![];
            for (qn, q) in qs.iter().enumerate() {
                let (e, ems) = &rows[qn];
                let t = Instant::now();
                let h = rrf(
                    &[&bm.search(&q.q), &lexical::symbol_search(&chunks, &q.q), e],
                    60.0,
                );
                let cand: Vec<usize> = h.iter().take(30).map(|x| x.0).collect();
                let docs: Vec<String> = cand
                    .iter()
                    .map(|&i| doc_text(&chunks[i]).chars().take(2000).collect())
                    .collect();
                let res = rr.rerank(q.q.clone(), docs, false, Some(30))?;
                let idx: Vec<usize> = res.iter().map(|r| cand[r.index]).collect();
                lat.push(t.elapsed().as_secs_f64() * 1e3 + ems);
                let files = files_in_order(&chunks, &idx);
                let top: Vec<&Chunk> = idx.iter().take(10).map(|&i| &chunks[i]).collect();
                sc.push(score(q, &files, Some(&top)));
            }
            record(&format!("R {rk} on H {key}"), sc, lat, &mut table);
        }
    }

    // ---- report ----
    let groups: Vec<(&str, Box<dyn Fn(&Question) -> bool>)> = vec![
        ("all", Box::new(|_| true)),
        ("en", Box::new(|q| q.lang == "en")),
        ("tr", Box::new(|q| q.lang == "tr")),
        ("identifier", Box::new(|q| q.kind == "identifier")),
        ("concept", Box::new(|q| q.kind == "concept")),
        ("cross", Box::new(|q| q.kind == "cross")),
    ];
    println!("\n{} questions\n", qs.len());
    println!("| method | File@1 | File@5 | File@10 | MRR | Chunk@5 | Chunk@10 | AllGold@10 | p50 ms | p95 ms |");
    println!("|---|---|---|---|---|---|---|---|---|---|");
    let mean = |v: &[f32]| {
        if v.is_empty() {
            f32::NAN
        } else {
            v.iter().sum::<f32>() / v.len() as f32
        }
    };
    let pct = |l: &[f64], p: f64| {
        let mut s = l.to_vec();
        s.sort_by(|a, b| a.total_cmp(b));
        s[((s.len() as f64 - 1.0) * p).round() as usize]
    };
    let mut summary = vec![];
    for (name, s, l) in &table {
        let col = |f: fn(&Score) -> f32| mean(&s.iter().map(f).collect::<Vec<_>>());
        println!(
            "| {name} | {:.2} | {:.2} | {:.2} | {:.2} | {:.2} | {:.2} | {:.2} | {:.1} | {:.1} |",
            col(|x| x.f1),
            col(|x| x.f5),
            col(|x| x.f10),
            col(|x| x.mrr),
            col(|x| x.c5),
            col(|x| x.c10),
            col(|x| x.all10),
            pct(l, 0.5),
            pct(l, 0.95)
        );
        let mut g = serde_json::Map::new();
        for (gn, pred) in &groups {
            let sel: Vec<&Score> = qs
                .iter()
                .zip(s)
                .filter(|(q, _)| pred(q))
                .map(|x| x.1)
                .collect();
            g.insert(
                gn.to_string(),
                json!({
                    "n": sel.len(),
                    "file5": mean(&sel.iter().map(|x| x.f5).collect::<Vec<_>>()),
                    "chunk5": mean(&sel.iter().map(|x| x.c5).collect::<Vec<_>>()),
                    "mrr": mean(&sel.iter().map(|x| x.mrr).collect::<Vec<_>>()),
                }),
            );
        }
        let hits: Vec<_> = qs
            .iter()
            .zip(s)
            .map(|(q, x)| json!({"id": q.id, "f5": x.f5, "c5": x.c5, "mrr": x.mrr}))
            .collect();
        summary.push(json!({"method": name, "groups": g, "per_question": hits, "p50_ms": pct(l, 0.5), "p95_ms": pct(l, 0.95)}));
    }
    println!("\nFile@5 by group:\n");
    print!("| method |");
    for (gn, _) in &groups {
        print!(" {gn} |");
    }
    println!("\n|---|{}", "---|".repeat(groups.len()));
    for row in &summary {
        print!("| {} |", row["method"].as_str().unwrap());
        for (gn, _) in &groups {
            print!(
                " {:.2} |",
                row["groups"][*gn]["file5"].as_f64().unwrap_or(f64::NAN)
            );
        }
        println!();
    }
    std::fs::write(
        out_dir().join("results.json"),
        serde_json::to_vec_pretty(&json!({"methods": summary, "hybrid_top10": per_q}))?,
    )?;
    Ok(())
}

fn main() -> Result<()> {
    let a: Vec<String> = std::env::args().skip(1).collect();
    match a.first().map(|s| s.as_str()) {
        Some("chunk") => cmd_chunk(),
        Some("embed") => cmd_embed(a.get(1).context("embed <model>")?),
        Some("eval") => {
            let mut o = EvalOpts { embeds: vec![], rerankers: vec![], rewrite: None, apple: false };
            let mut it = a[1..].iter();
            while let Some(f) = it.next() {
                match f.as_str() {
                    "--embed" => o.embeds = it.next().context("--embed a,b")?.split(',').map(String::from).collect(),
                    "--rerank" => o.rerankers = it.next().context("--rerank a,b")?.split(',').map(String::from).collect(),
                    "--rewrite" => o.rewrite = Some(PathBuf::from(it.next().context("--rewrite file")?)),
                    "--apple" => o.apple = true,
                    x => bail!("unknown flag {x}"),
                }
            }
            cmd_eval(o)
        }
        _ => bail!("usage: chunk | embed <model> | eval [--embed a,b] [--rerank a,b] [--rewrite f] [--apple]"),
    }
}

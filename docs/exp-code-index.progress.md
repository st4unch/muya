---
status: done
prd: docs/exp-code-index.md
started: 2026-10-06
---

## Phase Outputs
- Corpus: 183 files, 3438 chunks (tree-sitter defs + 60-line gap windows), chunked in 0.16 s. BM25 build 85 ms.
- Question set: 40 (20 en / 20 tr; 12 identifier, 20 concept, 8 cross), written blind by a separate agent, gold ranges spot-checked.
  q27 skipped (its only gold is `scripts/publish-release.sh`, outside the index) → 39 scored.
- "Rewritten" = a separate agent turned each question into English code keywords without seeing the code
  (stands in for Claude writing the tool query). Apple FoundationModels could not run: Apple Intelligence is off on this Mac.
- Full table: `tools/code-index-lab/out/report.md` (not committed; re-run `eval`). Key rows (File@5 / Chunk@5 / p95 ms):

| Method | File@5 | Chunk@5 | p95 ms |
|---|---|---|---|
| G grep, raw question | 0.69 | – | 14 |
| G' grep, rewritten | 0.85 | – | 12 |
| **B' BM25, rewritten** | **0.97** | **0.72** | **0.6** |
| R' B' + jina-v2 reranker | 0.92 | 0.79 | 1958 |
| E gemma-300m (best embedding, raw) | 0.77 | 0.72 | 40 |
| H BM25+symbols+gemma, raw | 0.85 | 0.56 | 42 |
| A rewrite+BM25+symbols+gemma | 0.90 | 0.74 | 42 |
| E Apple NLContextualEmbedding | 0.13 | 0.05 | 33 |

- Models: bge-small 129 MB, e5-small 481 MB, gemma-300m Q 326 MB, jina-code 627 MB; embedding the repo took 66–196 s.
- Answer files average 1184 lines (median 857); a chunk averages 16 lines.

## Decision (rule from §5)
- vs raw grep: +0.28 File@5 ✅. vs grep fed the same keywords (fair): +0.12 ❌ (< 0.15). Latency ✅ (0.6 ms), model 0 MB ✅.
- Embeddings / reranker / Apple: none beats B' (each costs ≥ 0.05 less or the same). Not kept.
- The win that the rule doesn't measure: B' points to the block (Chunk@5 0.72), grep only to a ~860-line file.
- Recommendation: if anything, a BM25-only `code_search` muya-mcp tool (no models). Operator decides.

## Changes
| Date | File | What changed | AC |
|-------|-------|-----------|-----|
| 2026-10-06 | tools/code-index-lab/ | standalone lab crate (chunker, BM25, symbols, grep, fastembed, RRF, reranker, eval) + Swift Apple helper | §2–§4 |
| 2026-10-06 | tools/code-index-lab/questions.json | 40-question gold set | §2 |

## Decisions
- Own BM25 instead of Tantivy for the lab: 100 lines, full control over code tokenization. A product would use Tantivy.
- Symbol map hurts when fused (B'+S' 0.79 < B' 0.97): name matches crowd out the real block.

## Lessons
- Limits: 39 questions, one repo; questions and rewrites are LLM-written; gold judged by one agent.

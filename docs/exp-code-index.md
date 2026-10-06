# Experiment — Code index for Muya (T5)

Not a feature. A lab run on this repo to decide whether a local code index is worth
shipping as a muya-mcp tool, and which parts of it earn their cost.

## 1. Question
When an agent asks "where is X handled?" about a workspace, does an index find the right
code better or cheaper than what Claude does today (grep for keywords, then read)?
Which parts help: keyword search (BM25), a symbol map, embeddings, a reranker, Apple's
on-device models?

## 2. Setup
- Corpus: this repo's `src/` and `src-tauri/src/` (Rust, TS, TSX; ~184 files, ~52k lines).
  Tests are included; `node_modules`, `target`, `dist`, `vendor` are not.
- Chunks: tree-sitter definitions (Rust fn/impl/struct/enum/trait; TS function, class,
  arrow-function const, interface, type). Code outside definitions falls back to
  60-line windows. Each chunk keeps path, line range and symbol name.
- Question set: written by a separate agent that never sees the retrieval code. Each
  question has gold `file:line-range` answers checked by grep. English and Turkish,
  identifier-style and plain-language ("where does the vault lock itself?").
- Prototype: `tools/code-index-lab/` (standalone Rust crate, not part of the app) plus a
  small Swift helper for Apple's models.

## 3. Methods compared
| ID | Method | Stands in for |
|---|---|---|
| G | grep baseline: rank files by how many query words they contain | today's agent search, first step |
| B | BM25 over chunks, code-aware tokens (camelCase / snake_case split) | Tantivy-style keyword index |
| S | symbol map: definition names matched against query words | "go to definition" |
| E1 | embeddings, open code model (ONNX, local) | Cursor-style semantic search |
| E2 | embeddings, Apple NLContextualEmbedding (mean-pooled) | "system model" option |
| H | hybrid: B + S + best E fused with reciprocal rank fusion | the likely product shape |
| R | H + cross-encoder reranker on the top 30 | reranker option |
| A | H + Apple FoundationModels (on-device LLM) rewriting the query or reranking | "system one model" option |

## 4. Metrics
- File-level Recall@5, Recall@10 and MRR against the gold answers, per language and per
  question type.
- Query latency (p50/p95), index build time, index size on disk, model size and RAM.
- Everything runs offline after the one-time model download.

## 5. Decision rule (binary)
- Ship-worthy if the best method beats G by ≥ 0.15 Recall@5 overall **and** answers a
  query in < 300 ms p95 on this Mac, with a model ≤ 500 MB.
- A part (E, R, A) is kept only if removing it costs ≥ 0.05 Recall@5.
- Otherwise: record the result and do not build the feature.

## 6. Out of scope
App UI, the MCP tool itself, file watching and incremental re-index, other workspaces.
Those come after a positive result, with a mini-PRD.

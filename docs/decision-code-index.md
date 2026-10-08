# Decision — Code index for Muya agents (after the T5 lab)

Input: `docs/exp-code-index.md` and its progress file (lab on this repo, 39 blind questions),
plus one extra lab row added 2026-10-08 (Gb', below) and outside research (§4).

## 1. What we measured (File@5 = right file in the top 5; Chunk@5 = right block in the top 5)

| Method | File@5 | Chunk@5 | p95 | Needs |
|---|---|---|---|---|
| G grep, the question as asked | 0.67 | – | 13 ms | nothing |
| G' grep, agent-written keywords | 0.85 | – | 11 ms | nothing |
| Gb' grep keywords, ranked by enclosing block (no index) | 0.77 | 0.56 | 10 ms | tree-sitter only |
| **B' BM25 over tree-sitter blocks, keywords** | **0.97** | **0.72** | **0.6 ms** | in-memory index |
| Best embedding / reranker / Apple | ≤ 0.92 | ≤ 0.79 | 40–1958 ms | 129–627 MB model |

B' − G' = +0.12: 5 of 39 questions differ, all in B''s favour (sign test p≈0.06, bootstrap
95% CI +0.03..+0.23). Against our +0.15 ship bar that is **inconclusive**, not a clear miss.
With the raw question, BM25 = grep (G→B 4 wins each): the gain needs good keywords.
Gb' is consistent with "ranking matters" (B' beats it 8–0 on File@5) but does not isolate why.

## 2. Three options

| | A. `code_search` tool (BM25, no models) | B. Symbol tools (outline / definition / references) | C. Ship nothing, teach the agent |
|---|---|---|---|
| What the agent gets | `code_search("vault lock idle timeout")` → 10 blocks: file:line, symbol, 3-line snippet | `code_outline(file)`, `find_symbol(name)`, `references(name)` | A skill/CLAUDE.md hint: "turn the question into code keywords before grep" |
| Lab evidence | 0.97 / 0.72 (best) | symbols alone 0.51; fused with BM25 it hurts (0.79) | keywords alone took grep 0.69 → 0.85 |
| Build | tree-sitter + Tantivy (or own 270-line BM25) in the muya-mcp broker, scoped to workspace roots, rebuilt lazily by mtime | tree-sitter per language, or wrap LSP servers (Serena-style) | none |
| Cost to user | 0 MB models, ~0.25 s index per 50k lines, RAM ~ tens of MB | same parser; LSP route needs a language server per language | none |
| Main risk | agents keep using Grep; index stale; small gain vs a good grep | answers "where is X defined", not "where is X handled" | gain depends on the agent following the hint |

## 3. Recommendation (after the negative check)
**A, but only after a real-agent test (step 1). Steps 2–3 run only if step 1 passes.**

1. **Agent test (½ day, no product code).** Wrap the lab's BM25 as a throwaway MCP tool.
   Run ~20 of the questions headless in Claude Code twice: plain (Grep/Read) and with the
   tool. Measure turns and tokens until the gold file is read, plus how often Claude
   picks the tool at all. Also log Claude's own queries, which replaces the rewrite
   agent's.
   **Gate:** ≥ 20% fewer turns or tokens, no fewer right answers, and the tool chosen in
   ≥ 50% of runs. Add a second repo (another language) if step 1 passes.
2. **Build `code_search` in muya-mcp.** One tool with a short description.
   - No stored index. A per-file cache keyed on (mtime, size) is checked on every query,
     so it cannot go stale after a checkout.
   - Respects .gitignore, the workspace roots, and the same path exclusions as file access.
     Kept in RAM only, never written to disk.
   - Languages without a grammar fall back to line windows. Above a size cap the tool says
     "use grep" instead of returning a wrong "not found".
3. **Off by default, then on.** It is turned on for everyone after a week of own use.
   Kill switch in Settings.

If step 1 fails, take **C**: a one-line hint in the agent guidance ("turn the question into
code keywords before grep"). Close the index topic and record the result.

## 4. Outside evidence
| Source | Says | Weight |
|---|---|---|
| Claude Code team (B. Cherny, HN Feb 2025: news.ycombinator.com/item?id=43164253) | dropped RAG + vector DB; agentic grep "outperformed everything"; staleness, privacy | anecdote about *embeddings*; use only as a staleness/privacy caution |
| Cursor (cursor.com/blog/semsearch) | semantic search +12.5% answer accuracy; +2.6% code kept on 1,000+ file repos | embeddings on large repos; says nothing about BM25 |
| LocAgent (arXiv 2503.09089) | fine-tuned agent over a code graph → 92.7% file accuracy, SWE-bench-Lite | different setup; shows lexical/graph localisation works, not our number |
| ContextBench (arXiv 2602.05892) | fancy retrieval scaffolds gain little; agents often don't use what is retrieved | warns against A |
| Serena / LSP (ManoMano, n=1) | only Serena finished the task, at no cost saving; built-in LSP hallucinated | too thin to support B |
| Tantivy (github.com/quickwit-oss/tantivy) | MIT, 0.26.x, maintained | fine as A's engine |
| Tool overload (anthropic.com/engineering/code-execution-with-mcp) | every tool description costs context and selection accuracy | A must be one small tool |
No source measures whether agents actually pick a search tool over built-in Grep. That is the gap our pilot has to close.

## 5. Devil's advocate (3 frameworks, sonnet subagents; all three: "A holds with changes")
- ⚔ Pre-mortem 6 mo, pilot undefined: no N, no threshold → coin-flip decision. **→ §3 step 1 gate.**
- ⚔ Pre-mortem 6 mo, nobody calls it: ContextBench says agents ignore retrieved context.
  **→ tool-choice rate is part of the gate.**
- ⚔ Pre-mortem 6 mo, stale, huge or other-language repos: a confident "no results" is
  worse than grep. **→ per-query (mtime, size) cache, line-window fallback, size cap → "use grep".**
- ⚔ Pre-mortem 6 mo, second read path to secrets. **→ same exclusions as file access, RAM only.**
- ⚔ Pre-mortem 10 yr, grammar ABI churn and native agent search catching up.
  **→ kill switch; BM25 core works without grammars.**
- ⚔ Option-trail: the missed option is "C first, A only if a gap remains". **→ adopted as the failure path of step 1.**
- ⚔ Assumption, Claude writes keywords like the rewrite agent: untested. **→ step 1 logs real queries.**
- ⚔ Assumption, G' (one grep) stands in for a real multi-step agent: weak baseline. **→ step 1 compares against real Claude.**
- ⚔ Assumption, rewrites leak gold names: checked false (clean); but 30% of the questions name the function.
- ⚔ Evidence: the "+0.12" is p≈0.06, the "matches LocAgent" claim was wrong, and the
  Cherny and Cursor quotes are about embeddings. **→ reworded in §1 and §4.**

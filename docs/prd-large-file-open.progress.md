---
status: done
---
# Progress: large-file open
- 2026-11-12 Diagnosis (WebKit harness): md preview 3 MB = 1.5 s freeze, 5 MB = 2.8 s; Monaco plain text 3–5 MB fine (<400 ms gap) in the browser. Branch fix/large-file-open in worktree ../muya-bigfile.
- Implemented: src/lib/largeFile.ts (+test), fs.rs file_probe/read_file_prefix (+tests), FileEditor + MarkdownView gating, read_file cap 5→8 MB. Harness scripts/bigfile/. All suites green (vitest 540, cargo lib 424 — schedules lock test flaky under load, passes alone and on main).

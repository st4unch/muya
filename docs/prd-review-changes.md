# Mini-PRD — Review every changed file (Changes + Queue)

## 1. Problem
Inspector → Changes lists 3 files ("+ N more" does nothing) and "Review diff" opens only the first
file's diff. Queue lists changed file names as plain text with no diff. The operator cannot review a
whole change set.

## 2. Scope
- New **Review changes** dialog (modalKit `ModalShell`, wide): file list on the left (status code +
  path, count), side-by-side Monaco diff of the picked file on the right, ← Prev / Next → buttons
  (also `[` / `]` keys), "Open in editor" for working-tree files. Read-only.
- Two sources:
  - **Uncommitted** (working tree vs HEAD): `git_status(root)` list; original = `read_head_file`,
    modified = `read_file` (deleted → empty). Folders (`?? dir/`) are listed but have no diff.
  - **Branch** (merge-base(base, branch) vs branch tip): `branch_detail(...).changedFiles`; both
    sides from a new Rust command `git_branch_file_pair(repo, base, branch, path)`.
- Inspector Changes: list every file (scrolls); clicking a file opens the review at that file;
  "Review diff" opens it at the first file.
- Queue: project row gets "Review" buttons — "N uncommitted" (when dirty > 0) and "branch"
  (when changed > 0); branch inspector's "Changed files" rows open the branch review at that file.
- Not in scope: staging/committing from the dialog, inline comments, editing in the diff.

## 3. Acceptance criteria
- AC1: `git_branch_file_pair` returns (merge-base content, branch content), "" for a side where the
  file is missing; rejects revs starting with `-` and paths outside the repo — cargo test on a temp repo.
- AC2: `ReviewChanges` renders all files, loads the picked file's pair, Prev/Next move and wrap at the
  ends (disabled), "[" / "]" work — vitest.
- AC3: Inspector shows all changes (no "+ N more"), row click and "Review diff" open the dialog — vitest.
- AC4: `?mock=1`: Inspector → Review diff shows file 1 diff, Next shows file 2; Queue → Review opens
  it — Playwright, dark + light screenshots.
- AC5: `cargo test --lib`, `npx tsc --noEmit`, `npm test -- --run` pass.

## 5. Integration
- Changes data: `src/App.tsx` ~l.1793 (`changes`, `selectedCwd`), `reviewDiff`/`openChange` ~l.1814.
- Inspector: `src/redesign/Inspector.tsx` l.34 (slice 3), l.104-121.
- Queue: `src/components/QueuePage.tsx` props l.57, project row l.335-360, changed files l.291-304;
  mounted `src/App.tsx` ~l.2466.
- Rust: `src-tauri/src/fs.rs` `read_head_file` l.172, `git_status` l.600, `branch_detail` ~l.394;
  register in `src-tauri/src/lib.rs` invoke_handler (~l.427).
- Monaco: `src/components/FileEditor.tsx` l.1-24 (local Monaco + workers) — move the setup to a shared
  module so the dialog uses the same bundled Monaco.
- Mock: `src/mock/installMock.ts` (`git_status` l.395, `branch_detail` l.421, `read_head_file` stub l.314).

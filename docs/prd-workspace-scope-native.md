# Workspace scope in Muya Native — addendum to `prd-workspace-scope.md`

Classic scopes everything it lists to the chosen workspace. Native shows the same menu but the
choice does nothing: `FrameWiring.swift:388` says so outright ("Native has no workspace scope, so
choosing one selects its first session"), `Shortcuts.swift:84` makes ⌥⌘1-9 a no-op, and every list
reads `store.sessions` unfiltered. The operator reported it: switching workspace leaves the
sessions unchanged, and the "All workspaces" row is missing.

This addendum defines the scope for Native. Classic's behaviour (`src/App.tsx`,
`src/lib/workspaceScope.ts`) is the reference; where Native differs, the reason is given.

## 1. What a workspace is

Classic keeps an explicit list (`apex.workspaces`) because a workspace can exist with no agent in
it. Native has no such list and no way to add one — "Add workspace…" opens the new-session sheet,
so a folder becomes a workspace by having a session in it. **A workspace is therefore a distinct
working folder of the open sessions**, exactly as the menu already shows. The one addition: the
currently chosen folder stays in the list even after its last session closes, so the choice does
not evaporate under the operator.

## 2. Membership — classic's rule, unchanged

Ported from `src/lib/workspaceScope.ts`, with its tests:

- a session is in a root's scope when its cwd is the root or sits under it (`within`);
- it is also in scope when its cwd sits under `<parent>/<repo>-worktrees` for that root — a git
  worktree of the project belongs to the project;
- an SSH session is in **every** scope (it has no local folder);
- `nil` scope (All workspaces) admits everything;
- when roots nest, the longest match names the session's own workspace.

Membership is never stored. It is derived from where the session was opened.

## 3. What the scope changes

| Surface | Today | Required |
|---|---|---|
| Agents list (`FrameWiring.swift:71`) | all sessions | in-scope only |
| Grid (`FrameWiring.swift:221`) | all | in-scope only |
| Command palette (`UI.swift:548`) | all | in-scope only |
| ⌘1-9, session cycling (`UI.swift:800`) | all | in-scope only |
| Sidebar workspace count (`FrameWiring.swift:182`) | distinct cwds | unchanged |

Out-of-scope sessions keep running and keep their terminals; they are only not listed — classic's
rule, and the reason the scope is a view filter and nothing more.

## 4. The menu

Under the existing `WORKSPACES` heading, in this order:

1. **All workspaces** — first row, hint `⌥⌘0 · N agents`, ticked when nothing is chosen. Shown
   only when at least one workspace exists (otherwise the menu keeps "No workspace yet.").
2. One row per workspace: `<name>   N agents · ~/path`, hint `⌥⌘i` for the first nine, ticked when
   it is the chosen one. **N counts the sessions in that root's scope**, so the number on the row
   is the number of rows the list shows after choosing it.
3. Separator, then "Add workspace…" (unchanged: opens the new-session sheet).

Classic's "Remove selected workspace" is deliberately **not** ported: Native's workspaces are
derived from open sessions, so there is nothing to remove.

Choosing a row sets the scope. It does not select a session, except when the current selection
falls out of the new scope — then the first in-scope session is selected (classic `App.tsx:613`).

The header chip reads `Workspace <folder>`, `All workspaces`, or `No workspace` when there are no
sessions at all.

## 5. Shortcuts and persistence

⌥⌘1-9 choose the Nth row as listed, ⌥⌘0 chooses All (`ShortcutLogic` already parses both;
`Shortcuts.swift:84` must stop returning `false`). The chosen root is persisted through `Prefs`
and restored on launch; a restored root that no session matches still shows, with an empty list,
until the operator chooses another.

## 6. Acceptance criteria (binary)

1. `WorkspaceScope` logic is pure and unit-tested: `within`, worktree dir, SSH-always-in-scope,
   `nil` = everything, longest-match naming. Classic's cases from `workspaceScope.test.ts` pass.
2. With sessions in two different folders, choosing one folder leaves only its sessions in the
   agents list, the grid and the palette; choosing **All workspaces** brings all of them back.
3. The menu's first row is "All workspaces" with an agent count, and the tick follows the chosen
   scope, not the selected session.
4. A session whose cwd is a subfolder of the chosen root, and a session in that project's
   `-worktrees` folder, are both in scope. An SSH session shows in every scope.
5. ⌥⌘1 and ⌥⌘0 do what the rows do.
6. The choice survives a restart.
7. Choosing a scope that excludes the selected session selects the first in-scope session; no
   out-of-scope session is closed or detached.
8. Proved live against the real app through the debug socket, not only by unit tests:
   `native/app/verify-workspace-scope.sh` must pass.

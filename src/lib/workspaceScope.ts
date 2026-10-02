// Created by Claude — Classification: INTERNAL
//
// Which workspace a terminal belongs to, so the agent list can show one workspace at a
// time. Membership is derived from where the tab was opened (its spawn cwd), never
// stored, so tabs persisted by older versions need no migration.

export interface ScopedTab {
  cwd?: string;
  sshServerId?: string;
}

function within(path: string, root: string): boolean {
  const r = root.replace(/\/+$/, "");
  return path === r || path.startsWith(r + "/");
}

/** Muya puts a repo's worktrees next to it: `<parent>/<repo>-worktrees/<branch>`
 *  (src-tauri/src/fs.rs `create_worktree`). */
function worktreeDir(root: string): string | null {
  const r = root.replace(/\/+$/, "");
  const i = r.lastIndexOf("/");
  if (i <= 0) return null;
  return `${r.slice(0, i)}/${r.slice(i + 1)}-worktrees`;
}

/** Is the tab part of workspace `root`? */
export function belongsTo(tab: ScopedTab, root: string): boolean {
  if (!tab.cwd) return false;
  if (within(tab.cwd, root)) return true;
  const wt = worktreeDir(root);
  return wt !== null && within(tab.cwd, wt);
}

/** Should the tab be listed while `scope` is picked (undefined = all workspaces)?
 *  SSH tabs have no local folder, so they show everywhere. */
export function inScope(tab: ScopedTab, scope: string | undefined): boolean {
  if (scope === undefined || tab.sshServerId) return true;
  return belongsTo(tab, scope);
}

/** The workspace a tab belongs to: the most specific matching root, or undefined. */
export function workspaceOf(tab: ScopedTab, roots: readonly string[]): string | undefined {
  let best: string | undefined;
  for (const r of roots) {
    if (!belongsTo(tab, r)) continue;
    if (best === undefined || r.length > best.length) best = r;
  }
  return best;
}

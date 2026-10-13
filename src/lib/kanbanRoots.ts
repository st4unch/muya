// Created by Claude — Classification: INTERNAL
//
// Folders the Kanban scans for PRDs: what the operator added to Muya (workspaces),
// worktrees Muya made, and the folders of terminals open in Muya (an agent drops its
// PRD in its own worktree's docs/). NOT every Claude session on the machine: on a
// first install that pulled in plans from every project Claude had ever touched.

export function kanbanRoots(
  workspaces: string[],
  worktrees: string[],
  terminals: { key: string; cwd?: string }[],
  liveCwds: Record<string, string>,
): string[] {
  const termDirs = terminals.map((t) => liveCwds[t.key] ?? t.cwd ?? "");
  return [...new Set([...workspaces, ...worktrees, ...termDirs])].filter((w) => w.startsWith("/")).sort();
}

// Pure helper: which tab becomes active after one is closed.
//
// Closing a file must move focus to a NEIGHBOURING file, never jump onto a
// terminal — otherwise the next ⌘W would kill a running Claude session (L19).
// Only when no tab of the same kind remains do we fall back to whatever's left.

export interface TabLike {
  key: string;
  kind: "terminal" | "editor" | "mdview" | "imgview" | "pdfview";
}

// Terminals are one group; file tabs (editor + rendered markdown) are the other.
// Closing a file must stay among files, never jump onto a terminal (L19).
const isTerminal = (k: TabLike["kind"]) => k === "terminal";

/** The key that should become active after `closedKey` is removed from `tabs`.
 *  Prefers the nearest same-kind tab (before, then after the closed position). */
export function pickNextActiveKey(tabs: TabLike[], closedKey: string): string | null {
  const closedIdx = tabs.findIndex((t) => t.key === closedKey);
  if (closedIdx === -1) return tabs[tabs.length - 1]?.key ?? null;
  const closedTerm = isTerminal(tabs[closedIdx].kind);
  const next = tabs.filter((t) => t.key !== closedKey);
  if (next.length === 0) return null;

  const sameGroup = (t: TabLike) => isTerminal(t.kind) === closedTerm;
  const before = next.slice(0, closedIdx).reverse().find(sameGroup);
  const after = next.slice(closedIdx).find(sameGroup);
  if (before) return before.key;
  if (after) return after.key;
  // No same-kind tab left — fall back to the tab now at the closed position.
  return next[Math.min(closedIdx, next.length - 1)].key;
}

/** A fresh, collision-proof tab key for an SSH session to `serverId`. Unique per
 *  call (timestamp + random suffix) so two Connects in the same millisecond still
 *  differ. Always prefixed `ssh:<serverId>:` so duplicate/restore logic keeps
 *  recognising it as an SSH tab for that server. */
export function newSshTabKey(
  serverId: string,
  now: number = Date.now(),
  rand: () => number = Math.random,
): string {
  return `ssh:${serverId}:${now}:${rand().toString(36).slice(2, 7)}`;
}

/** Append a new SSH session tab. It NEVER removes the server's existing tabs:
 *  each Connect is an independent, parallel session to the same (or a different)
 *  host. Filtering the server's siblings here was the bug that made a second
 *  terminal to one host impossible and was the wrong fix for "retry reuses a dead
 *  terminal" — a fresh tab already avoids reuse (L28). */
export function addSshSession<T extends { key: string }>(prev: T[], tab: T): T[] {
  return [...prev, tab];
}

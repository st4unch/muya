// Pure helper: which tab becomes active after one is closed.
//
// Closing a file must move focus to a NEIGHBOURING file, never jump onto a
// terminal — otherwise the next ⌘W would kill a running Claude session (L19).
// Only when no tab of the same kind remains do we fall back to whatever's left.

export interface TabLike {
  key: string;
  kind: "terminal" | "editor";
}

/** The key that should become active after `closedKey` is removed from `tabs`.
 *  Prefers the nearest same-kind tab (before, then after the closed position). */
export function pickNextActiveKey(tabs: TabLike[], closedKey: string): string | null {
  const closedIdx = tabs.findIndex((t) => t.key === closedKey);
  if (closedIdx === -1) return tabs[tabs.length - 1]?.key ?? null;
  const closedKind = tabs[closedIdx].kind;
  const next = tabs.filter((t) => t.key !== closedKey);
  if (next.length === 0) return null;

  const before = next
    .slice(0, closedIdx)
    .reverse()
    .find((t) => t.kind === closedKind);
  const after = next.slice(closedIdx).find((t) => t.kind === closedKind);
  if (before) return before.key;
  if (after) return after.key;
  // No same-kind tab left — fall back to the tab now at the closed position.
  return next[Math.min(closedIdx, next.length - 1)].key;
}

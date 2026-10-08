// Created by Claude — Classification: INTERNAL
//
// Split Control: the Split button clones the terminal on screen (lib/tabs splitClone)
// and the clone joins that terminal's split GROUP. A group shows as 2–8 panes in the
// Control terminal area and as one collapsible row in the agent list; picking any of
// its terminals shows the whole group, a terminal outside every group shows alone.
// These helpers are pure so the grouping rules can be tested without the UI.

export const MAX_SPLIT = 8;

export interface SplitGroup {
  /** Stable id (the collapsed state is keyed on it). */
  id: string;
  /** Tab keys, in pane order. */
  keys: string[];
}

/** Columns × rows for `n` panes: 2 → 2×1, 3 → 3×1, 4 → 2×2, 5–6 → 3×2, 7–8 → 4×2. */
export function splitLayout(n: number): { cols: number; rows: number } {
  if (n <= 1) return { cols: 1, rows: 1 };
  if (n <= 3) return { cols: n, rows: 1 };
  if (n === 4) return { cols: 2, rows: 2 };
  if (n <= 6) return { cols: 3, rows: 2 };
  return { cols: 4, rows: 2 };
}

export function groupOf(groups: readonly SplitGroup[], key: string | null | undefined): SplitGroup | null {
  if (!key) return null;
  return groups.find((g) => g.keys.includes(key)) ?? null;
}

/** Is there room to split `source` again? (Its group is not full.) */
export function canSplit(groups: readonly SplitGroup[], source: string | null | undefined): boolean {
  if (!source) return false;
  return (groupOf(groups, source)?.keys.length ?? 1) < MAX_SPLIT;
}

/**
 * `clone` was split off `source`: it joins `source`'s group, or the two start a new
 * group with id `newId`. Null when the group is already full.
 */
export function addToGroup(groups: readonly SplitGroup[], source: string, clone: string, newId: string): SplitGroup[] | null {
  if (clone === source || groupOf(groups, clone)) return null;
  const g = groupOf(groups, source);
  if (!g) return [...groups, { id: newId, keys: [source, clone] }];
  if (g.keys.length >= MAX_SPLIT) return null;
  return groups.map((x) => (x === g ? { ...x, keys: [...x.keys, clone] } : x));
}

/** A pane closed (or its tab closed): the terminal leaves its group; a group left with
 *  one terminal dissolves. */
export function removeFromGroups(groups: readonly SplitGroup[], key: string): SplitGroup[] {
  return groups
    .map((g) => (g.keys.includes(key) ? { ...g, keys: g.keys.filter((k) => k !== key) } : g))
    .filter((g) => g.keys.length > 1);
}

/** Pane to focus after `closed` leaves `keys`: its right neighbour, else its left one. */
export function neighbourAfterClose(keys: readonly string[], closed: string): string | null {
  const i = keys.indexOf(closed);
  if (i < 0) return null;
  return keys[i + 1] ?? keys[i - 1] ?? null;
}

/** Groups against the tabs that exist: drop closed tabs and keys already claimed by an
 *  earlier group, cap at MAX_SPLIT, dissolve groups under two. */
export function resolveGroups(groups: readonly SplitGroup[], existing: ReadonlySet<string>): SplitGroup[] {
  const claimed = new Set<string>();
  const out: SplitGroup[] = [];
  for (const g of groups) {
    const keys = g.keys.filter((k) => existing.has(k) && !claimed.has(k)).slice(0, MAX_SPLIT);
    if (keys.length < 2) continue;
    keys.forEach((k) => claimed.add(k));
    out.push({ id: g.id, keys });
  }
  return out;
}

/** localStorage validator for the persisted groups. */
export function asSplitGroups(raw: unknown): SplitGroup[] | null {
  if (!Array.isArray(raw)) return null;
  const out: SplitGroup[] = [];
  for (const g of raw) {
    if (!g || typeof g !== "object") continue;
    const { id, keys } = g as { id?: unknown; keys?: unknown };
    if (typeof id !== "string" || !Array.isArray(keys)) continue;
    out.push({ id, keys: keys.filter((k): k is string => typeof k === "string") });
  }
  return out;
}

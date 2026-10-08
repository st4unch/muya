// Created by Claude — Classification: INTERNAL
//
// Split Control: the terminal area of the Control screen shows up to MAX_SPLIT panes
// side by side, without leaving for the Grid screen. A pane holds an agent's tab key,
// or an "empty:<n>" placeholder waiting for the operator to pick an agent. These
// helpers are pure so the add / close / place rules can be tested without the UI.

export const MAX_SPLIT = 8;
const EMPTY_PREFIX = "empty:";

export const isEmptyPane = (key: string): boolean => key.startsWith(EMPTY_PREFIX);

/** Columns × rows for `n` panes: 2 → 2×1, 3 → 3×1, 4 → 2×2, 5–6 → 3×2, 7–8 → 4×2. */
export function splitLayout(n: number): { cols: number; rows: number } {
  if (n <= 1) return { cols: 1, rows: 1 };
  if (n <= 3) return { cols: n, rows: 1 };
  if (n === 4) return { cols: 2, rows: 2 };
  if (n <= 6) return { cols: 3, rows: 2 };
  return { cols: 4, rows: 2 };
}

function nextEmptyKey(panes: string[]): string {
  let n = 1;
  while (panes.includes(`${EMPTY_PREFIX}${n}`)) n++;
  return `${EMPTY_PREFIX}${n}`;
}

/**
 * Add a pane. Starting from a single terminal, the current agent becomes the first
 * pane. The new pane takes the first agent (in list order) that isn't shown yet,
 * otherwise an empty placeholder. Returns the new list and the added key, or null at
 * the limit.
 */
export function addPane(panes: string[], current: string | null, agentOrder: string[]): { panes: string[]; added: string } | null {
  const base = panes.length > 0 ? panes : current ? [current] : [];
  if (base.length >= MAX_SPLIT) return null;
  const added = agentOrder.find((k) => !base.includes(k)) ?? nextEmptyKey(base);
  return { panes: [...base, added], added };
}

/** Remove a pane (the agent keeps running). One pane left = back to the plain terminal. */
export function closePane(panes: string[], key: string): string[] {
  const next = panes.filter((k) => k !== key);
  return next.length <= 1 ? [] : next;
}

/** Pane to focus after `closed` goes away: its right neighbour, else its left one. */
export function neighbourAfterClose(panes: string[], closed: string): string | null {
  const i = panes.indexOf(closed);
  if (i < 0) return null;
  return panes[i + 1] ?? panes[i - 1] ?? null;
}

/**
 * The operator picked `key` in the agent list while the area is split. Already in a
 * pane → just focus it. Otherwise it replaces the focused pane (an empty one, or the
 * agent shown there).
 */
export function placeAgent(panes: string[], focused: string | null, key: string): string[] {
  if (panes.includes(key)) return panes;
  const i = focused ? panes.indexOf(focused) : -1;
  if (i < 0) return panes;
  const next = [...panes];
  next[i] = key;
  return next;
}

/** Saved panes after a restart / agent close: drop agents that no longer exist, keep
 *  placeholders, cap at MAX_SPLIT; fewer than two panes means "not split". */
export function resolvePanes(saved: string[], existing: ReadonlySet<string>): string[] {
  const seen = new Set<string>();
  const kept = saved.filter((k) => {
    if (seen.has(k)) return false;
    seen.add(k);
    return isEmptyPane(k) || existing.has(k);
  }).slice(0, MAX_SPLIT);
  return kept.length <= 1 ? [] : kept;
}

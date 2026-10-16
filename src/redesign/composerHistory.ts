// Created by Claude — Classification: INTERNAL
//
// ↑/↓ recall of what was sent from the Composer (docs/prd-composer-history.md).
// One list per target (agent prompts / shell commands), shared by all agents.

export type HistoryKind = "agent" | "shell";

export const HISTORY_MAX = 200;

const storageKey = (kind: HistoryKind) => `apex.composerHistory.${kind}`;

export function loadHistory(kind: HistoryKind): string[] {
  try {
    const raw = localStorage.getItem(storageKey(kind));
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

export function saveHistory(kind: HistoryKind, list: readonly string[]): void {
  try {
    localStorage.setItem(storageKey(kind), JSON.stringify(list));
  } catch {
    // storage full or blocked: history just isn't kept
  }
}

/** Append `text` (newest last), skipping a repeat of the newest entry, keeping the last `HISTORY_MAX`. */
export function pushHistory(list: readonly string[], text: string): string[] {
  if (!text || list[list.length - 1] === text) return [...list];
  const next = [...list, text];
  return next.length > HISTORY_MAX ? next.slice(next.length - HISTORY_MAX) : next;
}

/** Browsing position: `index` into the list (null = not browsing), and the text that was
 *  being typed before browsing started. */
export interface HistoryCursor {
  index: number | null;
  draft: string;
}

/** One ↑ ("up") or ↓ ("down") step. Returns the new cursor and the text to show, or null
 *  when there is nowhere to go (the key then keeps its normal caret behaviour). */
export function stepHistory(
  list: readonly string[],
  cursor: HistoryCursor,
  dir: "up" | "down",
  current: string,
): { cursor: HistoryCursor; text: string } | null {
  if (dir === "up") {
    if (list.length === 0) return null;
    if (cursor.index === null) return { cursor: { index: list.length - 1, draft: current }, text: list[list.length - 1] };
    if (cursor.index === 0) return null;
    return { cursor: { index: cursor.index - 1, draft: cursor.draft }, text: list[cursor.index - 1] };
  }
  if (cursor.index === null) return null;
  if (cursor.index >= list.length - 1) return { cursor: { index: null, draft: "" }, text: cursor.draft };
  return { cursor: { index: cursor.index + 1, draft: cursor.draft }, text: list[cursor.index + 1] };
}

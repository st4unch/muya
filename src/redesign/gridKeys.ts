// Created by Claude — Classification: INTERNAL
//
// Esc leaves the grid (docs/prd-v04-followups.md §3) — but only when the key isn't
// meant for something else: a terminal (the agent uses Esc to interrupt), a text
// field, or an open dialog/menu.

export function shouldExitGridOnEscape(
  e: Pick<KeyboardEvent, "key" | "metaKey" | "ctrlKey" | "altKey" | "shiftKey"> & { target: EventTarget | null },
  overlayOpen: boolean,
): boolean {
  if (e.key !== "Escape" || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey || overlayOpen) return false;
  const t = e.target as HTMLElement | null;
  if (t?.closest?.("[data-terminal-slot], .xterm")) return false;
  if (t?.closest?.('input, textarea, select, [contenteditable="true"], [role="dialog"]')) return false;
  return true;
}

/** The grid keys after choosing `pick` for the cell showing `target` (`visible` is the
 *  grid's current panel keys, in cell order). A session already in another cell trades
 *  places with the target, since one terminal can't be shown twice; any other session
 *  takes the target's cell. Nothing is closed: a session that leaves the grid keeps
 *  running. An "empty:<n>" target has no session to replace, so the pick is appended. */
export function assignGridCell(visible: string[], target: string, pick: string): string[] {
  if (target === pick) return visible;
  if (target.startsWith("empty:")) return [...visible.filter((k) => k !== pick), pick];
  const i = visible.indexOf(target);
  if (i === -1) return visible;
  const next = [...visible];
  const j = next.indexOf(pick);
  if (j !== -1) next[j] = target;
  next[i] = pick;
  return next;
}

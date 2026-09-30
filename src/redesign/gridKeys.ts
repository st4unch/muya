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

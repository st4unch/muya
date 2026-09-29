// Created by Claude — Classification: INTERNAL

/**
 * Shorten a name for use INSIDE a longer string whose element can't ellipsize — a
 * textarea placeholder wraps instead of truncating in WebKit, which broke the
 * composer onto two lines for long agent names. Cuts on the character boundary
 * (never mid-surrogate) and marks the cut with "…".
 */
export function shortName(name: string, max = 24): string {
  const chars = [...name];
  return chars.length <= max ? name : `${chars.slice(0, max - 1).join("")}…`;
}

/** "Message <name>…" — the design ends the hint with "…"; a shortened name already
 *  carries one, so it must not get a second ("name-……"). */
export function messageHint(name: string): string {
  const n = shortName(name);
  return `Message ${n.endsWith("…") ? n : `${n}…`}`;
}

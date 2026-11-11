// Created by Claude — Classification: INTERNAL
//
// Claude Code asks "Is this a project you created or one you trust?" the first time it runs in
// a folder. open_session starts its agents unattended, so Muya answers that question for the
// operator (PRD agent-session-open) — but only by looking at the screen: which option is
// pre-selected differs between Claude Code versions (older ones put "Yes" first, 2.1.3xx puts
// "No, exit" first), so a blind Enter either trusts the folder or quits Claude, and a session
// that quit never registers. Looks the same in a visible and a hidden workspace.

/** Keys that choose "Yes, I trust this folder" on the given screen, or null when the screen is
 *  not that dialog (or not fully drawn yet). */
export function trustPromptKeys(lines: string[]): string | null {
  const text = lines.join("\n");
  if (!/Is this a project you created or one you trust|Quick safety check/i.test(text)) return null;
  if (!lines.some((l) => /\byes\b.*\b(trust|proceed)\b/i.test(l))) return null;
  const selected = lines.find((l) => /^\s*[❯>]\s*\S/.test(l) && /\b(yes|no)\b/i.test(l));
  if (!selected) return null;
  return /\byes\b/i.test(selected) ? "\r" : "\x1b[B\r"; // Down to "Yes", then confirm
}

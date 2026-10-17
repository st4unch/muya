// Created by Claude — Classification: INTERNAL
//
// Helpers for the terminal right-click menu (components/TerminalContextMenu.tsx).

/** Backslash every character a shell would read specially, so a pasted path with
 *  spaces or brackets arrives as one word (iTerm2's "Paste Escaping Special Characters").
 *  A trailing newline is dropped: pasting a path must not run it. */
export function escapeForShell(text: string): string {
  return text.replace(/\r?\n$/, "").replace(/[\s!"#$&'()*,;<=>?[\\\]^`{|}~]/g, "\\$&");
}

/** The selection is one http(s) URL (surrounding whitespace allowed). */
export function isWebUrl(text: string): boolean {
  const t = text.trim();
  if (!/^https?:\/\/\S+$/i.test(t)) return false;
  try {
    return !!new URL(t).host;
  } catch {
    return false;
  }
}

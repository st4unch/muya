// Created by Claude — Classification: INTERNAL
//
// Claude Code asks once per session before loading a development channel. Muya starts
// its Claude sessions with its own channel (muya-mcp, see CHANNEL_FLAG in statusline.ts)
// and confirms that question itself — the operator decided so (PRD
// bridge-channel-delivery §6), like the trust-folder auto-accept.

/** Is this screen Claude Code's development-channel warning for Muya's channel ONLY,
 *  with "I am using this for local development" selected? A warning that lists any
 *  other channel is left for the operator. */
export function isMuyaChannelWarning(lines: string[]): boolean {
  const text = lines.join("\n");
  if (!/Loading development channels/i.test(text)) return false;
  const channels = lines.map((l) => /^\s*Channels:\s*(.+?)\s*$/.exec(l)?.[1]).find(Boolean);
  if (channels?.split(/[\s,]+/).join(" ") !== "server:muya-mcp") return false;
  return lines.some((l) => /❯\s*1\.\s*I am using this for local development/.test(l));
}

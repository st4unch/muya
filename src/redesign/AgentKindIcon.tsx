// Created by Claude — Classification: INTERNAL
//
// Which CLI a session runs — Claude Code, opencode, a plain terminal or SSH — as a
// small coloured glyph next to its name (agents list, session header, grid panel).

import type { AgentVM } from "./types";
import { ClaudeKindIcon, OpencodeKindIcon, SshRailIcon, TerminalKindIcon } from "./icons";

export type AgentGlyph = "claude" | "opencode" | "terminal" | "ssh";

/** A plain shell whose screen shows Claude's UI (claude typed by hand) counts as Claude. */
export function agentGlyph(agent: Pick<AgentVM, "kind" | "agentRunning">): AgentGlyph {
  if (agent.kind === "opencode") return "opencode";
  if (agent.kind === "ssh") return "ssh";
  if (agent.kind === "claude" || agent.agentRunning) return "claude";
  return "terminal";
}

const META: Record<AgentGlyph, { label: string; color: string }> = {
  claude: { label: "Claude Code", color: "var(--agent-claude)" },
  opencode: { label: "opencode", color: "var(--agent-opencode)" },
  terminal: { label: "Terminal", color: "var(--accent)" },
  ssh: { label: "SSH", color: "var(--text-muted)" },
};

/** "Claude Code" / "opencode" / "Terminal" / "SSH". */
export function agentGlyphLabel(agent: Pick<AgentVM, "kind" | "agentRunning">): string {
  return META[agentGlyph(agent)].label;
}

export function AgentKindIcon({ agent, size = 13 }: { agent: Pick<AgentVM, "kind" | "agentRunning">; size?: number }) {
  const g = agentGlyph(agent);
  const { label, color } = META[g];
  const style = { color, flexShrink: 0, display: "block" } as const;
  const common = { size, role: "img", "aria-label": label, "aria-hidden": false, style } as const;
  return (
    <span title={label} data-agent-kind={g} style={{ display: "inline-flex", flexShrink: 0 }}>
      {g === "claude" ? (
        <ClaudeKindIcon {...common} />
      ) : g === "opencode" ? (
        <OpencodeKindIcon {...common} />
      ) : g === "ssh" ? (
        <SshRailIcon {...common} />
      ) : (
        <TerminalKindIcon {...common} />
      )}
    </span>
  );
}

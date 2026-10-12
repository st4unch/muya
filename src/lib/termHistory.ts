// Created by Claude — Classification: INTERNAL
//
// Per-terminal command history (src-tauri/src/term_history.rs): a plain terminal tab
// spawns its shell with its own history file, keyed by the tab key, so ↑ shows that
// tab's commands and the Sessions page can list them. Agent and SSH tabs keep the
// shared history — their sessions are listed by the agent CLI already.

export interface TermHistory {
  key: string;
  name: string;
  cwd: string;
  updatedMs: number;
  count: number;
  /** Newest first. */
  recent: string[];
}

interface TabLike {
  key: string;
  kind: string;
  sshServerId?: string;
  isClaude?: boolean;
  agent?: string;
  sessionId?: string;
  initialCommand?: string;
}

/** The history key to spawn this tab's shell with, or undefined for shared history. */
export function historyKeyOf(tab: TabLike): string | undefined {
  if (tab.kind !== "terminal" || tab.sshServerId || tab.isClaude || tab.agent || tab.sessionId || tab.initialCommand) return undefined;
  return /^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,127}$/.test(tab.key) ? tab.key : undefined;
}

/** Pure logic for building the shell command a new agent terminal runs. */

/** The agent CLIs Muya can run in a terminal tab. */
export type AgentKind = "claude" | "opencode";

export interface AgentCommandSpec {
  command: string;
  prompt: string;
  files: string[];
}

/** POSIX single-quote a string (safe for arbitrary content). */
export function singleQuote(s: string): string {
  return `'${s.replace(/'/g, "'\\''")}'`;
}

/**
 * The command that starts each agent with tool-use auto-approved.
 *
 * The flags are NOT interchangeable: opencode rejects
 * `--dangerously-skip-permissions` outright, and Claude rejects `--auto`. Keeping
 * them in one table is what stops a copy-paste from silently producing a terminal
 * that opens and immediately dies.
 */
export const AGENT_BASE_COMMAND: Record<AgentKind, string> = {
  claude: "claude --dangerously-skip-permissions",
  opencode: "opencode --auto",
};

/** Display name for an agent, for buttons/labels/tooltips. */
export const AGENT_LABEL: Record<AgentKind, string> = {
  claude: "Claude",
  opencode: "opencode",
};

/**
 * Which agent, if any, a command line starts.
 *
 * Matched on a word boundary against the FIRST word, so `opencoded`, `my-claude`
 * and a path mentioned mid-prompt don't count, while `/usr/local/bin/opencode
 * --auto` does — the resolver hands us absolute paths on machines where the bare
 * name isn't on PATH, and those must still be recognised as agent sessions or the
 * tab silently loses its icon and its resume behavior.
 */
export function detectAgent(command: string | undefined | null): AgentKind | null {
  if (!command) return null;
  const first = command.trim().split(/\s+/)[0] ?? "";
  // Strip any directory prefix so an absolute path matches by its binary name.
  const bin = first.split("/").pop() ?? "";
  if (bin === "claude") return "claude";
  if (bin === "opencode") return "opencode";
  return null;
}

/**
 * Build the initial command for a new agent. Files become `@path` references,
 * combined with the prompt and passed as one quoted positional arg to the base
 * command (default `claude --dangerously-skip-permissions`).
 */
export function buildAgentCommand(spec: AgentCommandSpec): string {
  const refs = spec.files.map((f) => `@${f}`).join(" ");
  const promptArg = [refs, spec.prompt.trim()].filter(Boolean).join(" ");
  const base = spec.command.trim() || AGENT_BASE_COMMAND.claude;
  if (!promptArg) return base;
  // WHERE THE PROMPT GOES DIFFERS, and getting it wrong is silent:
  //   claude   <prompt>   → a positional arg IS the prompt
  //   opencode [project]  → the positional is "path to start opencode in"
  // So handing opencode a positional prompt makes it treat the whole sentence as
  // a directory path. Its prompt has its own flag. (Verified against opencode
  // 1.18.32 --help.)
  return detectAgent(base) === "opencode"
    ? `${base} --prompt ${singleQuote(promptArg)}`
    : `${base} ${singleQuote(promptArg)}`;
}

/**
 * Build the command that resumes an existing session of the given agent.
 *
 * The two CLIs spell this differently — `claude --resume <id>` vs
 * `opencode --session <id>` — and each rejects the other's flag. Returns null for
 * an id with unexpected characters (never built into a shell command).
 */
export function buildResumeCommand(agent: AgentKind, sessionId: string): string | null {
  if (!isSafeSessionId(sessionId)) return null;
  const id = singleQuote(sessionId);
  return agent === "opencode"
    ? `opencode --session ${id} --auto`
    : `claude --resume ${id} --dangerously-skip-permissions`;
}

/** Session ids land in a shell command, so only plain id characters are accepted. */
export function isSafeSessionId(id: string): boolean {
  return /^[A-Za-z0-9._-]+$/.test(id);
}

/**
 * The agent a tab is running, for tabs persisted before `agent` existed.
 *
 * Old tabs carry only `isClaude`. Reading `agent` alone would silently demote
 * every restored Claude tab to a plain shell — losing its icon and its resume
 * behavior — which is exactly the kind of quiet regression a stored boolean
 * invites. Prefer the new field, fall back to the old one.
 */
export function tabAgent(t: { agent?: AgentKind; isClaude?: boolean }): AgentKind | null {
  if (t.agent) return t.agent;
  return t.isClaude ? "claude" : null;
}

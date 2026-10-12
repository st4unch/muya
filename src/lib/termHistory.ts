// Created by Claude — Classification: INTERNAL
//
// Per-terminal command history (src-tauri/src/term_history.rs): a plain terminal tab
// spawns its shell with its own history file, keyed by the tab key, so ↑ shows that
// tab's commands and the Sessions page can list them. Agent and SSH tabs keep the
// shared history — their sessions are listed by the agent CLI already.

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

export interface HistoryEntry {
  /** Seconds since epoch (zsh EXTENDED_HISTORY); null for lines saved without one. */
  ts: number | null;
  cmd: string;
}

export interface TermEntries {
  key: string;
  name: string;
  cwd: string;
  updatedMs: number;
  /** Oldest first. */
  entries: HistoryEntry[];
}

export interface DayGroup {
  /** "YYYY-MM-DD" (local), or "undated". */
  day: string;
  label: string;
  terminals: { key: string; name: string; cwd: string; entries: HistoryEntry[] }[];
}

const pad = (n: number) => String(n).padStart(2, "0");
export const localDay = (ms: number) => {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
};
export const localTime = (ms: number) => {
  const d = new Date(ms);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
};

/** Commands grouped by the day they ran (newest day first), each day split by
 *  terminal (most recent first); entries inside a terminal are newest first.
 *  Commands saved before timestamps were on go to a last "Earlier (no date)" group. */
export function groupByDay(terms: readonly TermEntries[], now: number = Date.now()): DayGroup[] {
  const today = localDay(now);
  const yesterday = localDay(now - 86_400_000);
  const days = new Map<string, Map<string, { key: string; name: string; cwd: string; entries: HistoryEntry[]; last: number }>>();
  for (const t of terms) {
    for (const e of t.entries) {
      const day = e.ts == null ? "undated" : localDay(e.ts * 1000);
      let byKey = days.get(day);
      if (!byKey) days.set(day, (byKey = new Map()));
      let g = byKey.get(t.key);
      if (!g) byKey.set(t.key, (g = { key: t.key, name: t.name, cwd: t.cwd, entries: [], last: 0 }));
      g.entries.push(e);
      g.last = Math.max(g.last, e.ts ?? 0);
    }
  }
  const order = [...days.keys()].filter((d) => d !== "undated").sort().reverse();
  if (days.has("undated")) order.push("undated");
  return order.map((day) => ({
    day,
    label: day === "undated" ? "Earlier (no date)" : day === today ? "Today" : day === yesterday ? "Yesterday" : day,
    terminals: [...days.get(day)!.values()]
      .sort((a, b) => b.last - a.last)
      .map(({ key, name, cwd, entries }) => ({ key, name, cwd, entries: [...entries].reverse() })),
  }));
}

/** Plain-text export: a header, then one "YYYY-MM-DD HH:MM  command" line each. */
export function historyText(name: string, cwd: string, entries: readonly HistoryEntry[]): string {
  const head = `# ${name || "Terminal"}${cwd ? ` — ${cwd}` : ""}\n`;
  return head + entries.map((e) => `${e.ts == null ? "                " : `${localDay(e.ts * 1000)} ${localTime(e.ts * 1000)}`}  ${e.cmd}`).join("\n") + "\n";
}

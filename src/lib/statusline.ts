// Created by Claude — Classification: INTERNAL
//
// Claude status data for the footer: the launch-command transform (so Muya-started Claude
// sessions write their status JSON where Muya can read it), the catalogue of every
// documented status field, and the human formatters. Pure module apart from the cached
// settings-path lookup.

import { invoke } from "@tauri-apps/api/core";
import { singleQuote } from "./agent";

// ── Launch transform ──────────────────────────────────────────────────────────

/** Insert `--settings <path>` right after every `claude` at command start or after `&&` / `;`.
 *  Skips subcommands (`claude agents`, `claude mcp …`: a bare word follows) and commands that
 *  already pass --settings. Prompts are quoted, so `claude "fix it"` is still a launch. */
export function withStatusline(cmd: string, settingsPath: string | null | undefined, quote: (s: string) => string = singleQuote): string {
  if (!settingsPath || /(^|\s)--settings(\s|=)/.test(cmd)) return cmd;
  return cmd.replace(/(^|&&|;)(\s*)claude(?=\s|$)([ \t]*)(\S*)/g, (m, sep: string, ws: string, gap: string, next: string) => {
    if (/^[A-Za-z][\w-]*$/.test(next)) return m; // subcommand
    return `${sep}${ws}claude --settings ${quote(settingsPath)}${next ? (gap || " ") + next : gap}`;
  });
}

let settingsPathPromise: Promise<string | null> | null = null;

/** Settings file Muya's status tap lives in (fetched once). Null when unavailable. */
export function statuslineSettingsPath(): Promise<string | null> {
  if (!settingsPathPromise) {
    settingsPathPromise = invoke<string | null>("statusline_settings_path")
      .then((p) => (typeof p === "string" && p ? p : null))
      .catch(() => null);
  }
  return settingsPathPromise;
}

/** Test hook: forget the cached settings path. */
export function resetStatuslineCache(): void {
  settingsPathPromise = null;
}

/** `cmd` with the status tap attached to every claude launch (unchanged when unavailable). */
export async function applyStatusline(cmd: string): Promise<string> {
  if (!/claude/.test(cmd)) return cmd;
  return withStatusline(cmd, await statuslineSettingsPath());
}

// ── Formatters ────────────────────────────────────────────────────────────────

export function fmtUsd(n: number): string {
  return `$${n.toFixed(2)}`;
}

export function fmtDuration(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${sec}s`;
  return `${sec}s`;
}

export function fmtPct(n: number): string {
  return `${Math.round(n)}%`;
}

export function fmtTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
  return String(Math.round(n));
}

export function fmtBool(b: boolean): string {
  return b ? "on" : "off";
}

export function fmtLines(added: number, removed: number): string {
  return `+${added} −${removed}`;
}

function clock(d: Date): string {
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/** Epoch seconds → "18:30", or "Sat 18:30" when `weekday`. */
export function fmtEpoch(sec: number, weekday = false): string {
  const d = new Date(sec * 1000);
  return weekday ? `${WEEKDAYS[d.getDay()]} ${clock(d)}` : clock(d);
}

function basename(p: string): string {
  const parts = p.replace(/[\\/]+$/, "").split(/[\\/]/);
  return parts[parts.length - 1] || p;
}

// ── Field catalogue ───────────────────────────────────────────────────────────

export type StatusData = Record<string, unknown>;

export const STATUS_GROUPS = [
  "Model",
  "Context",
  "Cost & time",
  "Rate limits",
  "Session",
  "Workspace & git",
  "Pull request",
  "Worktree",
  "Prompt cache",
  "Modes",
] as const;
export type StatusGroup = (typeof STATUS_GROUPS)[number];

export interface StatusField {
  /** Stable id (the documented JSON path; `cost.lines` is a combined pair). */
  id: string;
  group: StatusGroup;
  label: string;
  /** Text for the field, or null when the data lacks it (the item is then hidden). */
  format: (data: StatusData) => string | null;
}

/** Value at a dotted path; null for absent/null. */
export function pathGet(data: StatusData | null | undefined, path: string): unknown {
  let cur: unknown = data;
  for (const k of path.split(".")) {
    if (cur === null || typeof cur !== "object") return null;
    cur = (cur as Record<string, unknown>)[k];
  }
  return cur === undefined ? null : cur;
}

type Fmt = (v: unknown, data: StatusData) => string | null;

const str: Fmt = (v) => (typeof v === "string" && v ? v : null);
const num: Fmt = (v) => (typeof v === "number" && Number.isFinite(v) ? String(v) : null);
const pct: Fmt = (v) => (typeof v === "number" ? fmtPct(v) : null);
const tok: Fmt = (v) => (typeof v === "number" ? fmtTokens(v) : null);
const bool: Fmt = (v) => (typeof v === "boolean" ? fmtBool(v) : null);
const dur: Fmt = (v) => (typeof v === "number" ? fmtDuration(v) : null);
const tail: Fmt = (v) => (typeof v === "string" && v ? basename(v) : null);
const count: Fmt = (v) => (Array.isArray(v) ? String(v.length) : null);
const resets = (weekday: boolean): Fmt => (v) => (typeof v === "number" ? `resets ${fmtEpoch(v, weekday)}` : null);
const expiry: Fmt = (v) => (typeof v === "number" ? `until ${fmtEpoch(v)}` : null);
const ago: Fmt = (v) => (typeof v === "number" ? `at ${fmtEpoch(v)}` : null);

function f(id: string, group: StatusGroup, label: string, fmt: Fmt, path = id): StatusField {
  return { id, group, label, format: (d) => (pathGet(d, path) === null ? null : fmt(pathGet(d, path), d)) };
}

export const STATUS_FIELDS: StatusField[] = [
  // Model
  f("model.display_name", "Model", "Model", str),
  f("model.id", "Model", "Model id", str),
  f("effort.level", "Model", "Effort", str),
  f("version", "Model", "Claude Code version", str),
  // Context
  f("context_window.used_percentage", "Context", "Context used", pct),
  f("context_window.remaining_percentage", "Context", "Context left", pct),
  f("context_window.context_window_size", "Context", "Context size", tok),
  f("context_window.total_input_tokens", "Context", "Input tokens", tok),
  f("context_window.total_output_tokens", "Context", "Output tokens", tok),
  f("context_window.current_usage.input_tokens", "Context", "Fresh input", tok),
  f("context_window.current_usage.output_tokens", "Context", "Last output", tok),
  f("context_window.current_usage.cache_creation_input_tokens", "Context", "Cache written", tok),
  f("context_window.current_usage.cache_read_input_tokens", "Context", "Cache read", tok),
  f("exceeds_200k_tokens", "Context", "Over 200k", bool),
  // Cost & time
  f("cost.total_cost_usd", "Cost & time", "Cost", (v) => (typeof v === "number" ? fmtUsd(v) : null)),
  f("cost.total_duration_ms", "Cost & time", "Duration", dur),
  f("cost.total_api_duration_ms", "Cost & time", "API time", dur),
  {
    id: "cost.lines",
    group: "Cost & time",
    label: "Lines changed",
    format: (d) => {
      const a = pathGet(d, "cost.total_lines_added");
      const r = pathGet(d, "cost.total_lines_removed");
      return typeof a === "number" && typeof r === "number" ? fmtLines(a, r) : null;
    },
  },
  // Rate limits
  f("rate_limits.five_hour.used_percentage", "Rate limits", "5-hour used", pct),
  f("rate_limits.five_hour.resets_at", "Rate limits", "5-hour window", resets(false)),
  f("rate_limits.seven_day.used_percentage", "Rate limits", "7-day used", pct),
  f("rate_limits.seven_day.resets_at", "Rate limits", "7-day window", resets(true)),
  f("rate_limits.spend_limit.used_percentage", "Rate limits", "Spend used", pct),
  f("rate_limits.spend_limit.resets_at", "Rate limits", "Spend window", resets(true)),
  // Session
  f("session_id", "Session", "Session id", str),
  f("session_name", "Session", "Session name", str),
  f("prompt_id", "Session", "Prompt id", str),
  f("transcript_path", "Session", "Transcript", tail),
  f("cwd", "Session", "Directory", tail),
  // Workspace & git
  f("workspace.current_dir", "Workspace & git", "Current dir", tail),
  f("workspace.project_dir", "Workspace & git", "Project dir", tail),
  f("workspace.added_dirs", "Workspace & git", "Added dirs", count),
  f("workspace.git_worktree", "Workspace & git", "Git worktree", str),
  f("workspace.repo.host", "Workspace & git", "Repo host", str),
  f("workspace.repo.owner", "Workspace & git", "Repo owner", str),
  f("workspace.repo.name", "Workspace & git", "Repo name", str),
  {
    id: "workspace.repo",
    group: "Workspace & git",
    label: "Repository",
    format: (d) => {
      const o = pathGet(d, "workspace.repo.owner");
      const n = pathGet(d, "workspace.repo.name");
      return typeof o === "string" && typeof n === "string" ? `${o}/${n}` : null;
    },
  },
  // Pull request
  f("pr.number", "Pull request", "PR number", (v) => (typeof v === "number" ? `#${v}` : null)),
  f("pr.url", "Pull request", "PR link", str),
  f("pr.review_state", "Pull request", "PR review", (v) => (typeof v === "string" ? v.replace(/_/g, " ") : null)),
  f("pr.kind", "Pull request", "PR kind", (v) => (v === "mr" ? "merge request" : typeof v === "string" ? v : null)),
  // Worktree
  f("worktree.name", "Worktree", "Worktree", str),
  f("worktree.path", "Worktree", "Worktree path", tail),
  f("worktree.branch", "Worktree", "Worktree branch", str),
  f("worktree.original_cwd", "Worktree", "Original dir", tail),
  f("worktree.original_branch", "Worktree", "Original branch", str),
  // Prompt cache
  f("prompt_cache.warm", "Prompt cache", "Cache warm", bool),
  f("prompt_cache.caching_observed", "Prompt cache", "Caching seen", bool),
  f("prompt_cache.ttl", "Prompt cache", "Cache TTL", str),
  f("prompt_cache.expires_at", "Prompt cache", "Cache expires", expiry),
  f("prompt_cache.requests", "Prompt cache", "Cache requests", num),
  f("prompt_cache.misses", "Prompt cache", "Cache misses", num),
  f("prompt_cache.expected_rebuilds", "Prompt cache", "Expected rebuilds", num),
  f("prompt_cache.hit_ratio", "Prompt cache", "Cache hit ratio", (v) => (typeof v === "number" ? fmtPct(v * 100) : null)),
  f("prompt_cache.cache_write_tokens", "Prompt cache", "Cache write tokens", tok),
  f("prompt_cache.miss_recache_tokens", "Prompt cache", "Miss re-cache tokens", tok),
  f("prompt_cache.last_miss_at", "Prompt cache", "Last miss", ago),
  f("prompt_cache.last_miss_cause", "Prompt cache", "Last miss cause", (v) => {
    const c = pathGet(v as StatusData, "causes");
    return Array.isArray(c) && c.length ? c.join(", ").replace(/_/g, " ") : null;
  }),
  f("prompt_cache.miss_causes", "Prompt cache", "Miss causes", (v) => {
    if (!v || typeof v !== "object") return null;
    const total = Object.values(v as Record<string, unknown>).reduce<number>((s, n) => s + (typeof n === "number" ? n : 0), 0);
    return String(total);
  }),
  f("prompt_cache.recache_tokens_if_cold", "Prompt cache", "Re-cache if cold", tok),
  // Modes
  f("fast_mode", "Modes", "Fast mode", bool),
  f("thinking.enabled", "Modes", "Thinking", bool),
  f("vim.mode", "Modes", "Vim mode", str),
  f("agent.name", "Modes", "Agent", str),
  f("output_style.name", "Modes", "Output style", str),
];

const FIELD_BY_ID = new Map(STATUS_FIELDS.map((x) => [x.id, x]));

export function statusField(id: string): StatusField | undefined {
  return FIELD_BY_ID.get(id);
}

/** Formatted value for a field, or null when hidden/absent. */
export function statusValue(id: string, data: StatusData | null | undefined): string | null {
  const field = FIELD_BY_ID.get(id);
  if (!field || !data) return null;
  try {
    return field.format(data);
  } catch {
    return null;
  }
}

// Created by Claude — Classification: INTERNAL
//
// When each terminal was last active, for the agent list's "Recent" filter
// (docs/prd-recent-agents-filter.md). Pure helpers; useAgentModel feeds them and keeps
// the map in localStorage so it survives an app restart.

import type { AgentVM } from "./types";

/** The "Recent" window: the operator asked for the last 6 hours. */
export const RECENT_MS = 6 * 60 * 60 * 1000;
/** A working/waiting agent re-stamps at most this often (keeps storage writes rare). */
export const TOUCH_EVERY_MS = 60_000;
export const LAST_ACTIVE_KEY = "muya.lastActive";

export type LastActive = Record<string, number>;

export function readLastActive(): LastActive {
  try {
    const v = JSON.parse(localStorage.getItem(LAST_ACTIVE_KEY) ?? "{}");
    if (!v || typeof v !== "object" || Array.isArray(v)) return {};
    const out: LastActive = {};
    for (const [k, t] of Object.entries(v)) if (typeof t === "number" && Number.isFinite(t)) out[k] = t;
    return out;
  } catch {
    return {};
  }
}

export function writeLastActive(map: LastActive): void {
  try {
    localStorage.setItem(LAST_ACTIVE_KEY, JSON.stringify(map));
  } catch {
    /* storage unavailable — Recent then only knows this launch */
  }
}

/** Fold the agents' current state (and transcript times, by tab key) into `prev`.
 *  Working/waiting agents are stamped `now`; closed tabs are dropped once any tab is
 *  known. Returns the SAME object when nothing changed (callers compare by identity). */
export function touchActive(
  prev: LastActive,
  agents: Pick<AgentVM, "key" | "status">[],
  now: number,
  seeds: LastActive = {},
): LastActive {
  let next: LastActive | null = null;
  const set = (k: string, t: number) => {
    next ??= { ...prev };
    next[k] = t;
  };
  for (const a of agents) {
    const had = prev[a.key] ?? 0;
    const seed = seeds[a.key] ?? 0;
    if (a.status !== "idle" && now - had >= TOUCH_EVERY_MS) set(a.key, now);
    else if (seed > had) set(a.key, seed);
  }
  if (agents.length > 0) {
    const live = new Set(agents.map((a) => a.key));
    for (const k of Object.keys(prev)) {
      if (!live.has(k)) {
        next ??= { ...prev };
        delete next[k];
      }
    }
  }
  return next ?? prev;
}

/** Recent = doing something now, or active within RECENT_MS. */
export function isRecent(status: AgentVM["status"], lastActiveAt: number | undefined, now: number): boolean {
  return status !== "idle" || (lastActiveAt !== undefined && now - lastActiveAt < RECENT_MS);
}

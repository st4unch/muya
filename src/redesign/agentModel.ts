// Created by Claude — Classification: INTERNAL
//
// Pure derivation of the redesign's AgentVM[] (the ONE source the agent list, header
// bell, inspector approvals, grid, footer counts and palette all read). No React, no
// Tauri: tabs + polled session status + the parsed terminal screen in, view models out.

import type { AgentStatus, AgentVM, PendingApproval, PermissionMode } from "./types";
import type { ScreenMode, ScreenState } from "../lib/screenState";

export type SessionStatus = "working" | "waiting-for-input" | "idle" | "stopped";

/** The subset of an open tab the model needs (structurally satisfied by App's tab). */
export interface AgentTab {
  key: string;
  name: string;
  kind: string;
  cwd?: string;
  initialCommand?: string;
  sshServerId?: string;
  isClaude?: boolean;
  agent?: "claude" | "opencode";
}

export interface StatusStamp {
  status: AgentStatus;
  at: number;
}

export interface AgentModelInput {
  tabs: AgentTab[];
  /** Polled Claude session status per tab key (pty_session_ids, ~15s cadence). */
  sessionStatus: Record<string, SessionStatus | undefined>;
  screens: Record<string, ScreenState | undefined>;
  /** Last mode a footer actually showed, per tab (a permission dialog hides the footer). */
  lastModes: Record<string, ScreenMode | undefined>;
  liveCwds: Record<string, string>;
  /** Branch by absolute working directory, where the app already knows it. */
  branchByCwd: Record<string, string>;
  /** Keys whose permission prompt the operator just answered: the (slow) session poll
   *  may still say "waiting" for a few seconds — don't trust it over the screen. */
  answered: Record<string, number>;
  stamps: Record<string, StatusStamp>;
  now: number;
}

/** How long after answering a prompt the stale poll status is ignored. */
export const ANSWERED_GRACE_MS = 20_000;

/** "~"-abbreviate a home directory without knowing whose it is (macOS/Linux layouts). */
export function abbreviateHome(path: string): string {
  const m = /^(\/Users\/[^/]+|\/home\/[^/]+|\/root)(?=\/|$)/.exec(path);
  return m ? `~${path.slice(m[1].length)}` : path;
}

/** "<1m", "4m", "1h 5m", "3d" — coarse on purpose: it is re-evaluated every ~30s. */
export function formatSince(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (s < 60) return "<1m";
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d`;
}

/** Parser tokens come as "16.9k", "↓ 16.9k tokens" … → "16.9k tokens". */
export function normalizeTokens(raw?: string): string | undefined {
  if (!raw) return undefined;
  const t = raw.replace(/[↓↑]/g, "").replace(/\s*tokens?\s*$/i, "").trim();
  return t ? `${t} tokens` : undefined;
}

function approvalSummary(tool: string | undefined): string {
  if (!tool) return "is waiting for permission";
  if (/write|edit|create|patch|update/i.test(tool)) return "wants to write a file";
  if (/bash|shell|exec|command|run/i.test(tool)) return "wants to run a command";
  if (/read|cat|view|grep|glob|search|list/i.test(tool)) return "wants to read files";
  return `wants to use ${tool}`;
}

/** Status the row shows: the screen is authoritative about what is ON it (a permission
 *  dialog or a spinner), the slow session poll fills in whatever the screen can't say. */
export function deriveStatus(
  tab: AgentTab,
  input: Pick<AgentModelInput, "sessionStatus" | "screens" | "answered" | "now">,
): AgentStatus {
  const screen = input.screens[tab.key];
  if (screen?.permission) return "waiting";
  const polled = input.sessionStatus[tab.key];
  const answeredAt = input.answered[tab.key];
  const justAnswered = answeredAt !== undefined && input.now - answeredAt < ANSWERED_GRACE_MS;
  if (screen?.activity) return "working";
  if (polled === "waiting-for-input") return justAnswered ? "idle" : "waiting";
  if (polled === "working") return "working";
  return "idle";
}

function kindOf(tab: AgentTab): AgentVM["kind"] {
  if (tab.sshServerId) return "ssh";
  if (tab.agent === "opencode") return "opencode";
  if (tab.isClaude || tab.agent === "claude") return "claude";
  return "shell";
}

/** Screen footer when it is visible; otherwise the last mode seen; otherwise the launch flag. */
export function deriveMode(tab: AgentTab, screen: ScreenState | undefined, lastMode?: ScreenMode): PermissionMode {
  if (screen?.modeDetected) return screen.mode;
  if (lastMode) return lastMode;
  return tab.initialCommand?.includes("--dangerously-skip-permissions") ? "bypass" : "default";
}

export function buildAgents(input: AgentModelInput): AgentVM[] {
  return input.tabs
    .filter((t) => t.kind === "terminal")
    .map((tab) => {
      const screen = input.screens[tab.key];
      const status = deriveStatus(tab, input);
      const cwd = input.liveCwds[tab.key] ?? tab.cwd ?? "";
      const stamp = input.stamps[tab.key];
      const activity = screen?.activity;

      let approval: PendingApproval | undefined;
      let since: string | undefined;
      let activityLine: string | undefined;
      if (status === "waiting") {
        const p = screen?.permission;
        approval = {
          tool: p?.tool,
          target: p?.target,
          summary: approvalSummary(p?.tool),
          actionable: Boolean(p && p.options.length > 0),
        };
        activityLine = `Needs permission: ${p?.tool ?? "permission prompt"}`;
        since = stamp?.status === "waiting" ? formatSince(input.now - stamp.at) : undefined;
      } else if (status === "working") {
        const tokens = normalizeTokens(activity?.tokens);
        activityLine = activity?.verb ? `${activity.verb}${tokens ? ` · ${tokens}` : ""}` : "Working…";
        since = activity?.elapsed;
      }

      return {
        key: tab.key,
        name: tab.name,
        status,
        since,
        activity: activityLine,
        path: abbreviateHome(cwd),
        branch: cwd ? input.branchByCwd[cwd] : undefined,
        mode: deriveMode(tab, screen, input.lastModes[tab.key]),
        approval,
        progress:
          status === "working" && activity
            ? { verb: activity.verb, elapsed: activity.elapsed, tokens: normalizeTokens(activity.tokens), thought: activity.thought }
            : undefined,
        kind: kindOf(tab),
      };
    });
}

/** Stamp status changes so "waiting for 1m" survives re-renders. Returns the SAME
 *  object when nothing changed (callers compare by identity). */
export function recordTransitions(
  prev: Record<string, StatusStamp>,
  agents: Pick<AgentVM, "key" | "status">[],
  now: number,
  seed: Record<string, number> = {},
): Record<string, StatusStamp> {
  let next: Record<string, StatusStamp> | null = null;
  const live = new Set(agents.map((a) => a.key));
  for (const a of agents) {
    if (prev[a.key]?.status === a.status) continue;
    next ??= { ...prev };
    next[a.key] = { status: a.status, at: a.status === "waiting" && seed[a.key] ? seed[a.key] : now };
  }
  for (const k of Object.keys(prev)) {
    if (!live.has(k)) {
      next ??= { ...prev };
      delete next[k];
    }
  }
  return next ?? prev;
}

export interface AgentCounts {
  agents: number;
  working: number;
  waiting: number;
}

export function countAgents(agents: Pick<AgentVM, "status">[]): AgentCounts {
  return {
    agents: agents.length,
    working: agents.filter((a) => a.status === "working").length,
    waiting: agents.filter((a) => a.status === "waiting").length,
  };
}

/** Grid panel selection: chosen keys first (still open), topped up in list order. */
export function pickGridPanels(agents: AgentVM[], chosen: string[], capacity: number): AgentVM[] {
  const byKey = new Map(agents.map((a) => [a.key, a]));
  const picked: AgentVM[] = [];
  for (const k of chosen) {
    const a = byKey.get(k);
    if (a && !picked.includes(a)) picked.push(a);
  }
  for (const a of agents) if (picked.length < capacity && !picked.includes(a)) picked.push(a);
  return picked.slice(0, capacity);
}

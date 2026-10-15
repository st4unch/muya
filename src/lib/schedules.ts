// Created by Claude — Classification: INTERNAL
//
// Schedules page model (docs/prd-schedules.md): the types the Rust side
// (src-tauri/src/schedules.rs) returns, and the pure formatting the page shows.

export type Schedule =
  | { kind: "interval"; minutes: number }
  | { kind: "daily"; time: string; extraTimes?: string[] }
  | { kind: "weekly"; days: number[]; time: string; extraTimes?: string[] };

/** Most runs a daily/weekly schedule may have in a day (Rust MAX_TIMES_PER_DAY). */
export const MAX_TIMES_PER_DAY = 6;

/** Every time of day a daily/weekly schedule runs, sorted, without duplicates. */
export function dayTimes(s: { time: string; extraTimes?: string[] }): string[] {
  return [...new Set([s.time, ...(s.extraTimes ?? [])])].sort();
}

export type RunStatus = "success" | "failed" | "timeout";

export interface Job {
  id: string;
  name: string;
  prompt: string;
  folder: string;
  schedule: Schedule;
  enabled: boolean;
  timeoutMin: number;
  bypass: boolean;
  /** Load Claude in Chrome (`--chrome`). */
  chrome: boolean;
  created: number;
  updated: number;
}

export interface JobView extends Job {
  nextRun: number | null;
  running: boolean;
  queued: boolean;
  runs: number;
  ok: number;
  failed: number;
  last: { started: number; ended: number; status: RunStatus } | null;
}

export interface Run {
  jobId: string;
  started: number;
  ended: number;
  status: RunStatus;
  exitCode: number | null;
  costUsd: number | null;
  trigger: "schedule" | "manual";
  output: string;
}

export interface JobInput {
  id?: string;
  name: string;
  prompt: string;
  folder: string;
  schedule: Schedule;
  enabled: boolean;
  timeoutMin: number;
  bypass: boolean;
  chrome: boolean;
}

/** Monday first, matching the Rust side (0 = Monday … 6 = Sunday). */
export const WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

export function describeSchedule(s: Schedule): string {
  switch (s.kind) {
    case "interval":
      if (s.minutes % 60 === 0) return s.minutes === 60 ? "Every hour" : `Every ${s.minutes / 60} hours`;
      return `Every ${s.minutes} min`;
    case "daily":
      return `Every day at ${dayTimes(s).join(", ")}`;
    case "weekly": {
      const days = [...s.days].sort((a, b) => a - b);
      const label =
        days.join() === "0,1,2,3,4" ? "Weekdays" : days.join() === "5,6" ? "Weekends" : days.length === 7 ? "Every day" : days.map((d) => WEEKDAYS[d]).join(", ");
      return `${label} at ${dayTimes(s).join(", ")}`;
    }
  }
}

/** "just now", "5 min ago", "in 2 h", "in 3 d". */
export function relTime(ms: number, now = Date.now()): string {
  const d = ms - now;
  const a = Math.abs(d);
  if (a < 45_000) return d > 0 ? "in a moment" : "just now";
  const [n, u] = a < 3_600_000 ? [Math.round(a / 60_000), "min"] : a < 86_400_000 ? [Math.round(a / 3_600_000), "h"] : [Math.round(a / 86_400_000), "d"];
  return d > 0 ? `in ${n} ${u}` : `${n} ${u} ago`;
}

export function fmtDurationMs(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

export function fmtClock(ms: number, now = Date.now()): string {
  const d = new Date(ms);
  const t = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  const today = new Date(now);
  if (d.toDateString() === today.toDateString()) return `today ${t}`;
  const tomorrow = new Date(now + 86_400_000);
  if (d.toDateString() === tomorrow.toDateString()) return `tomorrow ${t}`;
  return `${d.getDate()} ${d.toLocaleString("en", { month: "short" })} ${t}`;
}

export interface Summary {
  schedules: number;
  enabled: number;
  runs: number;
  ok: number;
  failed: number;
  /** Whole percent, null before any run. */
  successRate: number | null;
  /** The most recent run that did not succeed. */
  lastFailure: { name: string; at: number } | null;
}

export function summarize(jobs: JobView[]): Summary {
  const runs = jobs.reduce((n, j) => n + j.runs, 0);
  const ok = jobs.reduce((n, j) => n + j.ok, 0);
  let lastFailure: Summary["lastFailure"] = null;
  for (const j of jobs) {
    if (j.last && j.last.status !== "success" && (!lastFailure || j.last.ended > lastFailure.at)) lastFailure = { name: j.name, at: j.last.ended };
  }
  return {
    schedules: jobs.length,
    enabled: jobs.filter((j) => j.enabled).length,
    runs,
    ok,
    failed: runs - ok,
    successRate: runs ? Math.round((ok / runs) * 100) : null,
    lastFailure,
  };
}

/** The card's state pill: what is happening now, else how the last run ended. */
export function jobState(j: JobView): { label: string; tone: "running" | "success" | "failed" | "muted" } {
  if (j.running) return { label: "Running", tone: "running" };
  if (j.queued) return { label: "Waiting", tone: "muted" };
  if (!j.last) return { label: "Never run", tone: "muted" };
  if (j.last.status === "success") return { label: "Success", tone: "success" };
  return { label: j.last.status === "timeout" ? "Timed out" : "Failed", tone: "failed" };
}

/** Who fires the timers (schedules_list `runner`). */
export type Runner = "here" | "service" | "other" | "none";

/** The background service ("Run when Muya is closed"), from bg_service_status. */
export interface ServiceStatus {
  state: "off" | "on" | "approval" | "unavailable";
  /** Its heartbeat is fresh: it is running now. */
  running: boolean;
  version: string | null;
}

/** The line under the "Run when Muya is closed" switch. */
export function serviceLine(s: ServiceStatus | null, appVersion?: string): { text: string; tone: "success" | "warning" | "muted" } {
  if (!s) return { text: "Checking…", tone: "muted" };
  switch (s.state) {
    case "unavailable":
      return { text: "Available in the installed Muya app on macOS 13 or later.", tone: "muted" };
    case "approval":
      return { text: "macOS is waiting for your OK: turn Muya on under Allow in the Background in Login Items.", tone: "warning" };
    case "off":
      return { text: "Off. Schedules run while Muya is open.", tone: "muted" };
    case "on":
      if (!s.running) return { text: "On, starting…", tone: "warning" };
      if (appVersion && s.version && s.version !== appVersion) return { text: `On and running (Muya ${s.version}); it moves to ${appVersion} once its runs finish.`, tone: "success" };
      return { text: "On and running. Schedules run even after you quit Muya.", tone: "success" };
  }
}

export function emptyInput(): JobInput {
  return { name: "", prompt: "", folder: "", schedule: { kind: "daily", time: "09:00" }, enabled: true, timeoutMin: 30, bypass: true, chrome: true };
}

/** What the form remembers across kind switches, so a detour through "Every few
 *  minutes" doesn't lose the days and time already picked. */
export interface ScheduleMemory {
  time: string;
  extraTimes: string[];
  days: number[];
  minutes: number;
}

export function rememberSchedule(s: Schedule, mem: ScheduleMemory): ScheduleMemory {
  if (s.kind === "interval") return { ...mem, minutes: s.minutes };
  if (s.kind === "daily") return { ...mem, time: s.time, extraTimes: s.extraTimes ?? [] };
  return { ...mem, time: s.time, extraTimes: s.extraTimes ?? [], days: s.days };
}

export function initialMemory(s: Schedule): ScheduleMemory {
  return rememberSchedule(s, { time: "09:00", extraTimes: [], days: [0, 1, 2, 3, 4], minutes: 60 });
}

/** The schedule after switching to `kind`, filled from what was picked before. */
export function withKind(s: Schedule, kind: Schedule["kind"], mem: ScheduleMemory = initialMemory(s)): Schedule {
  const m = rememberSchedule(s, mem);
  if (kind === "interval") return { kind, minutes: m.minutes };
  const extra = m.extraTimes.length ? { extraTimes: m.extraTimes } : {};
  if (kind === "daily") return { kind, time: m.time, ...extra };
  return { kind, days: m.days, time: m.time, ...extra };
}

// Created by Claude — Classification: INTERNAL
//
// Mock backend for the Schedules page (browser ?mock=1 only — dev builds). Seeds a
// few schedules with history so the page, cards, report and dialogs can be checked
// in a real browser in both themes.

import type { JobInput, JobView, Run } from "../lib/schedules";

const H = 3_600_000;
let seq = 3;
let jobs: JobView[] = [];
let runs: Record<string, Run[]> = {};
let seeded = false;

// Seeded on first use: the mock clock is set up after this module loads.
function seed() {
  if (seeded) return;
  seeded = true;
  const now = Date.now();
  jobs = [
  {
    id: "s1", name: "Nightly dependency audit", prompt: "Run npm audit and cargo audit; summarize anything high or critical into docs/audit.md.",
    folder: "/Users/someone/Projects/muya", schedule: { kind: "daily", time: "02:30" }, enabled: true, timeoutMin: 30, bypass: true, chrome: true,
    created: now - 30 * 24 * H, updated: now - 2 * 24 * H, nextRun: now + 5 * H, running: false, queued: false, runs: 0, ok: 0, failed: 0, last: null,
  },
  {
    id: "s2", name: "Standup summary", prompt: "Summarize yesterday's commits and open PRs, then write it to docs/standup.md",
    folder: "/Users/someone/Projects/api-gateway", schedule: { kind: "weekly", days: [0, 1, 2, 3, 4], time: "09:00" }, enabled: true, timeoutMin: 15, bypass: false, chrome: false,
    created: now - 10 * 24 * H, updated: now - 10 * 24 * H, nextRun: now + 9 * H, running: false, queued: false, runs: 0, ok: 0, failed: 0, last: null,
  },
  {
    id: "s3", name: "Inbox triage", prompt: "Check new GitHub issues and label them.", folder: "/Users/someone/Projects/website",
    schedule: { kind: "interval", minutes: 120 }, enabled: false, timeoutMin: 10, bypass: true, chrome: true,
    created: now - 3 * 24 * H, updated: now - H, nextRun: null, running: false, queued: false, runs: 0, ok: 0, failed: 0, last: null,
  },
];
  runs = {
  s1: Array.from({ length: 12 }, (_, i) => ({
    jobId: "s1", started: now - (i + 1) * 24 * H, ended: now - (i + 1) * 24 * H + 95_000 + i * 4000,
    status: i === 3 ? "failed" : "success", exitCode: i === 3 ? 1 : 0, costUsd: 0.08 + i * 0.01, trigger: i === 0 ? "manual" : "schedule",
    output: i === 3 ? "Error: MCP server \"github\" failed to start (ENOENT: npx)\n\nclaude exited with code 1" : `No high or critical advisories.\n\nnpm audit: 0 vulnerabilities\ncargo audit: 2 warnings (unmaintained crates), written to docs/audit.md`,
  })) as Run[],
  s2: [
    { jobId: "s2", started: now - 26 * H, ended: now - 26 * H + 900_000, status: "timeout", exitCode: null, costUsd: 0.41, trigger: "schedule", output: "Stopped after 15 min.\n\nReading 214 commits…" },
    { jobId: "s2", started: now - 50 * H, ended: now - 50 * H + 210_000, status: "success", exitCode: 0, costUsd: 0.22, trigger: "schedule", output: "Wrote docs/standup.md (3 PRs, 18 commits)." },
  ],
  s3: [],
  };
}

function view(j: JobView): JobView {
  const r = runs[j.id] ?? [];
  const ok = r.filter((x) => x.status === "success").length;
  const last = r[0];
  return { ...j, nextRun: j.enabled ? j.nextRun ?? Date.now() + H : null, runs: r.length, ok, failed: r.length - ok, last: last ? { started: last.started, ended: last.ended, status: last.status } : null };
}

export function handleSchedules(cmd: string, p: Record<string, unknown>): { handled: boolean; value?: unknown } {
  if (cmd.startsWith("schedule")) seed();
  switch (cmd) {
    case "schedules_list":
      return { handled: true, value: { jobs: jobs.map(view), active: true } };
    case "schedule_runs":
      return { handled: true, value: runs[String(p.id)] ?? [] };
    case "schedule_set_enabled": {
      const j = jobs.find((x) => x.id === p.id);
      if (j) j.enabled = Boolean(p.enabled);
      return { handled: true, value: null };
    }
    case "schedule_delete": {
      const i = jobs.findIndex((x) => x.id === p.id);
      if (i >= 0) jobs.splice(i, 1);
      return { handled: true, value: null };
    }
    case "schedule_run_now": {
      const id = String(p.id);
      const t = Date.now();
      (runs[id] ??= []).unshift({ jobId: id, started: t - 42_000, ended: t, status: "success", exitCode: 0, costUsd: 0.05, trigger: "manual", output: "Done (mock run)." });
      return { handled: true, value: null };
    }
    case "schedule_save": {
      const job = p.job as JobInput;
      if (!job.name?.trim()) throw "Give the schedule a name.";
      if (!job.prompt?.trim()) throw "The prompt is empty.";
      if (!job.folder?.startsWith("/")) throw "Choose a folder.";
      const existing = jobs.find((x) => x.id === job.id);
      if (existing) Object.assign(existing, job, { updated: Date.now() });
      else jobs.push({ ...job, id: `s${++seq}`, created: Date.now(), updated: Date.now(), nextRun: Date.now() + 2 * H, running: false, queued: false, runs: 0, ok: 0, failed: 0, last: null });
      runs[job.id ?? `s${seq}`] ??= [];
      return { handled: true, value: job };
    }
  }
  return { handled: false };
}

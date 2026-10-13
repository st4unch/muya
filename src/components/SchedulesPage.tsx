// Created by Claude — Classification: INTERNAL
//
// Schedules page (docs/prd-schedules.md): Claude prompts that run headless on a timer
// in a chosen folder. The page follows the SSH page (icon + title, full width); the
// report is a row of small stat cards; each schedule is a small card with its on/off
// switch, Run now, History, Edit and Delete. Every dialog is built from modalKit —
// the same shell, labels, controls and switch as Settings.

import { useCallback, useEffect, useId, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { AlertTriangle, CalendarClock, ChevronDown, ChevronRight, FolderOpen, History, Pencil, Play, Plus, Trash2 } from "lucide-react";
import { ModalCss, ModalShell, Segmented, Switch, dangerBtn, ghostBtn, groupStyle, helperStyle, inputStyle, labelStyle, primaryBtn, rowStyle, rowsBox } from "./modalKit";
import {
  WEEKDAYS,
  describeSchedule,
  emptyInput,
  initialMemory,
  rememberSchedule,
  fmtClock,
  fmtDurationMs,
  jobState,
  relTime,
  summarize,
  withKind,
  type JobInput,
  type JobView,
  type Run,
  type Schedule,
} from "../lib/schedules";

type Tone = ReturnType<typeof jobState>["tone"];
const TONE: Record<Tone, { bg: string; fg: string; dot: string }> = {
  running: { bg: "var(--warning-bg)", fg: "var(--warning-text)", dot: "var(--warning)" },
  success: { bg: "var(--success-bg)", fg: "var(--success-text)", dot: "var(--success)" },
  failed: { bg: "var(--danger-pill-bg)", fg: "var(--danger-text)", dot: "var(--danger-text)" },
  muted: { bg: "var(--bg-segment)", fg: "var(--text-muted)", dot: "var(--text-faint)" },
};

function Pill({ label, tone }: { label: string; tone: Tone }) {
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 5, fontSize: 11, fontWeight: 600, padding: "2px 8px", borderRadius: 9, background: TONE[tone].bg, color: TONE[tone].fg, whiteSpace: "nowrap", flexShrink: 0 }}>
      <span style={{ width: 6, height: 6, borderRadius: 3, background: TONE[tone].dot }} />
      {label}
    </span>
  );
}

const card: CSSProperties = { border: "1px solid var(--border)", background: "var(--bg-panel)", borderRadius: 10, minWidth: 0 };
const smallGhost: CSSProperties = { ...ghostBtn, height: 28, padding: "0 10px", fontSize: 12 };
const iconBtn: CSSProperties = { width: 28, height: 28, borderRadius: 7, border: "none", background: "transparent", color: "var(--text-muted)", display: "inline-flex", alignItems: "center", justifyContent: "center", cursor: "pointer", flexShrink: 0 };

export default function SchedulesPage({ visible = true }: { visible?: boolean }) {
  const [jobs, setJobs] = useState<JobView[]>([]);
  const [active, setActive] = useState(true);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState("");
  const [editing, setEditing] = useState<JobInput | null>(null);
  const [historyId, setHistoryId] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<JobView | null>(null);
  const [now, setNow] = useState(() => Date.now());

  const refresh = useCallback(async () => {
    try {
      const r = await invoke<{ jobs: JobView[]; active: boolean }>("schedules_list");
      setJobs(r.jobs);
      setActive(r.active);
      setNow(Date.now());
    } catch (e) {
      setError(String(e));
    } finally {
      setLoaded(true);
    }
  }, []);

  useEffect(() => {
    if (!visible) return;
    void refresh();
    let unlisten: (() => void) | undefined;
    let gone = false;
    void listen("schedules-changed", () => void refresh()).then((u) => (gone ? u() : (unlisten = u)));
    // Relative times ("in 5 min") and next runs move on their own.
    const t = setInterval(() => void refresh(), 30_000);
    return () => {
      gone = true;
      unlisten?.();
      clearInterval(t);
    };
  }, [visible, refresh]);

  const act = async (fn: () => Promise<unknown>) => {
    try {
      setError("");
      await fn();
      await refresh();
    } catch (e) {
      setError(String(e));
    }
  };

  const sum = summarize(jobs);
  const historyJob = historyId ? jobs.find((j) => j.id === historyId) ?? null : null;

  return (
    <div className="flex-1 overflow-auto st-root">
      <ModalCss />
      <div className="w-full p-6" style={{ display: "flex", flexDirection: "column", gap: 16 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <CalendarClock className="h-5 w-5 text-[var(--text-muted)]" />
          <h1 className="text-lg font-semibold" style={{ margin: 0 }}>
            Schedules
          </h1>
          <span style={{ flex: 1 }} />
          <button type="button" className="st-primary" style={primaryBtn} onClick={() => setEditing(emptyInput())}>
            <Plus size={15} /> New schedule
          </button>
        </div>
        <p style={{ ...helperStyle, fontSize: 13, color: "var(--text-muted)", margin: "-8px 0 0" }}>
          Claude prompts that run on their own in a folder — headless, with your settings, MCP servers and skills. They run while Muya is open; a run missed while it was closed is skipped.
        </p>

        {!active && (
          <div role="status" style={{ fontSize: 13, padding: "8px 12px", borderRadius: 8, background: "var(--warning-card-bg)", color: "var(--warning-text)", border: "1px solid var(--warning-border)" }}>
            Another Muya window is running these schedules, so timers are paused here. Run now still works.
          </div>
        )}
        {error && (
          <div role="alert" style={{ fontSize: 13, padding: "8px 12px", borderRadius: 8, background: "var(--danger-pill-bg)", color: "var(--danger-text)", overflowWrap: "anywhere" }}>
            {error}
          </div>
        )}

        {/* The report. */}
        <div aria-label="Summary" style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(170px, 1fr))", gap: 12 }}>
          <Stat label="Schedules" value={String(sum.schedules)} hint={`${sum.enabled} on · ${sum.schedules - sum.enabled} off`} />
          <Stat label="Runs" value={String(sum.runs)} hint={`${sum.ok} succeeded · ${sum.failed} failed`} />
          <Stat label="Success rate" value={sum.successRate === null ? "—" : `${sum.successRate}%`} hint={sum.runs ? "across the kept runs" : "no runs yet"} tone={sum.successRate === null ? undefined : sum.successRate >= 90 ? "success" : sum.successRate < 60 ? "failed" : undefined} />
          <Stat label="Last failure" value={sum.lastFailure ? sum.lastFailure.name : "None"} hint={sum.lastFailure ? relTime(sum.lastFailure.at, now) : "every run succeeded"} tone={sum.lastFailure ? "failed" : undefined} />
        </div>

        {loaded && jobs.length === 0 ? (
          <div style={{ ...card, borderStyle: "dashed", padding: "40px 16px", display: "flex", flexDirection: "column", alignItems: "center", gap: 10, textAlign: "center" }}>
            <CalendarClock size={22} color="var(--text-faint)" />
            <div style={{ fontSize: 13, fontWeight: 600 }}>No schedules yet</div>
            <div style={{ ...helperStyle, maxWidth: 420 }}>Run a Claude prompt every few hours, every day or on chosen weekdays — a nightly report, a dependency check, a summary of yesterday's work.</div>
            <button type="button" className="st-btn" style={ghostBtn} onClick={() => setEditing(emptyInput())}>
              <Plus size={14} /> New schedule
            </button>
          </div>
        ) : (
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(300px, 1fr))", gap: 12 }}>
            {jobs.map((j) => (
              <JobCard
                key={j.id}
                job={j}
                now={now}
                onToggle={(on) => act(() => invoke("schedule_set_enabled", { id: j.id, enabled: on }))}
                onRun={() => act(() => invoke("schedule_run_now", { id: j.id }))}
                onHistory={() => setHistoryId(j.id)}
                onEdit={() => setEditing({ id: j.id, name: j.name, prompt: j.prompt, folder: j.folder, schedule: j.schedule, enabled: j.enabled, timeoutMin: j.timeoutMin, bypass: j.bypass, chrome: j.chrome })}
                onDelete={() => setDeleting(j)}
              />
            ))}
          </div>
        )}
      </div>

      {editing && (
        <EditDialog
          initial={editing}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            void refresh();
          }}
        />
      )}
      {historyJob && <HistoryDialog job={historyJob} onClose={() => setHistoryId(null)} />}
      {deleting && (
        <ModalShell
          title="Delete schedule"
          width={420}
          onClose={() => setDeleting(null)}
          footer={
            <>
              <span />
              <div style={{ display: "flex", gap: 8 }}>
                <button type="button" className="st-btn" style={ghostBtn} onClick={() => setDeleting(null)}>
                  Cancel
                </button>
                <button
                  type="button"
                  className="st-primary"
                  style={dangerBtn}
                  onClick={() => {
                    const id = deleting.id;
                    setDeleting(null);
                    void act(() => invoke("schedule_delete", { id }));
                  }}
                >
                  Delete
                </button>
              </div>
            </>
          }
        >
          <div style={{ fontSize: 13, lineHeight: 1.5 }}>
            Delete <strong>{deleting.name}</strong>?{" "}
            {deleting.runs ? `Its ${deleting.runs} saved run${deleting.runs === 1 ? "" : "s"} and their output are deleted too.` : "It has no saved runs."}
          </div>
        </ModalShell>
      )}
    </div>
  );
}

function Stat({ label, value, hint, tone }: { label: string; value: string; hint: string; tone?: "success" | "failed" }) {
  return (
    <div style={{ ...card, padding: "12px 14px" }}>
      <div style={labelStyle}>{label}</div>
      <div title={value} style={{ fontSize: 20, fontWeight: 600, marginTop: 6, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", color: tone ? TONE[tone].fg : "var(--text)" }}>
        {value}
      </div>
      <div style={{ ...helperStyle, marginTop: 2 }}>{hint}</div>
    </div>
  );
}

function Metric({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div style={{ minWidth: 0, flex: "0 1 auto" }}>
      <div style={{ ...labelStyle, fontSize: 10 }}>{label}</div>
      <div style={{ fontSize: 13, marginTop: 3, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{children}</div>
    </div>
  );
}

function JobCard({
  job: j,
  now,
  onToggle,
  onRun,
  onHistory,
  onEdit,
  onDelete,
}: {
  job: JobView;
  now: number;
  onToggle: (on: boolean) => void;
  onRun: () => void;
  onHistory: () => void;
  onEdit: () => void;
  onDelete: () => void;
}) {
  const nameId = useId();
  const busy = j.running || j.queued;
  return (
    <section aria-labelledby={nameId} style={{ ...card, display: "flex", flexDirection: "column" }}>
      <div style={{ padding: "12px 14px", display: "flex", flexDirection: "column", gap: 6 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0 }}>
          <span id={nameId} title={j.name} style={{ fontSize: 14, fontWeight: 600, flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", color: j.enabled ? "var(--text)" : "var(--text-muted)" }}>
            {j.name}
          </span>
          <Pill {...jobState(j)} />
          <Switch checked={j.enabled} onChange={onToggle} labelledBy={nameId} />
        </div>
        <div style={{ fontSize: 12, color: "var(--text-tertiary)" }}>{describeSchedule(j.schedule)}</div>
        <div title={j.folder} style={{ fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--text-faint)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
          {j.folder}
        </div>
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", gap: 12, padding: "10px 14px", borderTop: "1px solid var(--border)", background: "var(--bg-control)" }}>
        <Metric label="Runs">
          {j.runs}{" "}
          <span style={{ fontSize: 12, color: "var(--text-muted)" }}>
            (<span style={{ color: "var(--success-text)" }}>{j.ok}✓</span> <span style={{ color: j.failed ? "var(--danger-text)" : undefined }}>{j.failed}✗</span>)
          </span>
        </Metric>
        <Metric label="Last run">{j.last ? relTime(j.last.ended, now) : "never"}</Metric>
        <Metric label="Next run">{!j.enabled ? "off" : j.nextRun ? fmtClock(j.nextRun, now) : "—"}</Metric>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "8px 10px 8px 14px", borderTop: "1px solid var(--border)" }}>
        <button type="button" className="st-btn" style={smallGhost} onClick={onRun} disabled={busy}>
          <Play size={13} />
          {j.running ? "Running…" : j.queued ? "Waiting…" : "Run now"}
        </button>
        <button type="button" className="st-btn" style={smallGhost} onClick={onHistory}>
          <History size={13} /> History
        </button>
        <span style={{ flex: 1 }} />
        <button type="button" className="st-btn" style={iconBtn} aria-label={`Edit ${j.name}`} title="Edit" onClick={onEdit}>
          <Pencil size={14} />
        </button>
        <button type="button" className="st-btn" style={iconBtn} aria-label={`Delete ${j.name}`} title={busy ? "Wait for the run to finish" : "Delete"} onClick={onDelete} disabled={busy}>
          <Trash2 size={14} />
        </button>
      </div>
    </section>
  );
}

function Group({ label, htmlFor, labelId, helper, children }: { label: string; htmlFor?: string; labelId?: string; helper?: ReactNode; children: ReactNode }) {
  return (
    <div style={groupStyle}>
      <label id={labelId} htmlFor={htmlFor} style={labelStyle}>
        {label}
      </label>
      {children}
      {helper && <div style={helperStyle}>{helper}</div>}
    </div>
  );
}

const KINDS: { value: Schedule["kind"]; label: string }[] = [
  { value: "interval", label: "Every few minutes" },
  { value: "daily", label: "Daily" },
  { value: "weekly", label: "Weekly" },
];

export function EditDialog({ initial, onClose, onSaved }: { initial: JobInput; onClose: () => void; onSaved: () => void }) {
  const uid = useId();
  const id = (s: string) => `${uid}-${s}`;
  const [v, setV] = useState<JobInput>(initial);
  const [err, setErr] = useState("");
  const [saving, setSaving] = useState(false);
  const set = (patch: Partial<JobInput>) => setV((p) => ({ ...p, ...patch }));
  const s = v.schedule;
  const memory = useRef(initialMemory(initial.schedule));
  const setS = (next: Schedule) => {
    memory.current = rememberSchedule(next, memory.current);
    set({ schedule: next });
  };

  const pickFolder = async () => {
    try {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const dir = await open({ directory: true, multiple: false, title: "Folder the prompt runs in", defaultPath: v.folder || undefined });
      if (typeof dir === "string") set({ folder: dir });
    } catch (e) {
      setErr(String(e));
    }
  };

  const save = async () => {
    if (saving) return;
    setSaving(true);
    setErr("");
    try {
      await invoke("schedule_save", { job: { ...v, id: v.id ?? null } });
      onSaved();
    } catch (e) {
      setErr(String(e));
    } finally {
      setSaving(false);
    }
  };

  const title = v.id ? "Edit schedule" : "New schedule";
  return (
    <ModalShell
      title={title}
      width={540}
      onClose={onClose}
      onSubmit={() => void save()}
      footer={
        <>
          <span style={{ fontSize: 12, color: "var(--text-faint)", whiteSpace: "nowrap" }}>⌘ Enter to save</span>
          <div style={{ display: "flex", gap: 8 }}>
            <button type="button" className="st-btn" style={ghostBtn} onClick={onClose}>
              Cancel
            </button>
            <button type="button" className="st-primary" style={primaryBtn} onClick={() => void save()} disabled={saving} aria-busy={saving}>
              {saving ? "Saving…" : v.id ? "Save" : "Create"}
            </button>
          </div>
        </>
      }
    >
      <Group label="Name" htmlFor={id("name")}>
        <input id={id("name")} data-autofocus style={inputStyle} value={v.name} onChange={(e) => set({ name: e.target.value })} placeholder="Nightly report" spellCheck={false} />
      </Group>

      <Group label="Prompt" htmlFor={id("prompt")} helper="Runs as claude -p in the folder below, with your Claude settings, MCP servers and skills.">
        <textarea
          id={id("prompt")}
          rows={6}
          value={v.prompt}
          onChange={(e) => set({ prompt: e.target.value })}
          placeholder="Summarize yesterday's commits and open PRs, then write it to docs/standup.md"
          style={{ ...inputStyle, height: "auto", padding: "8px 10px", lineHeight: 1.5, resize: "vertical", fontFamily: "var(--font-mono)", fontSize: 12 }}
        />
      </Group>

      <Group label="Folder" htmlFor={id("folder")}>
        <div style={{ display: "flex", gap: 8 }}>
          <input id={id("folder")} style={{ ...inputStyle, fontFamily: "var(--font-mono)", fontSize: 12 }} value={v.folder} onChange={(e) => set({ folder: e.target.value })} placeholder="/path/to/project" spellCheck={false} />
          <button type="button" className="st-btn" style={ghostBtn} onClick={pickFolder}>
            <FolderOpen size={14} /> Choose…
          </button>
        </div>
      </Group>

      <Group label="Schedule" labelId={id("kind")} helper={`Runs: ${describeSchedule(s)}`}>
        <Segmented value={s.kind} options={KINDS} onChange={(k) => setS(withKind(s, k, memory.current))} labelledBy={id("kind")} />
        <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap", fontSize: 13, color: "var(--text-tertiary)" }}>
          {s.kind === "interval" ? (
            <>
              Every
              <input
                aria-label="Minutes between runs"
                type="number"
                min={5}
                step={5}
                style={{ ...inputStyle, width: 84 }}
                value={s.minutes}
                onChange={(e) => setS({ kind: "interval", minutes: Number(e.target.value) || 0 })}
              />
              minutes <span style={helperStyle}>(5 or more)</span>
            </>
          ) : (
            <>
              {s.kind === "weekly" && (
                <div role="group" aria-label="Days" style={{ display: "flex", gap: 4 }}>
                  {WEEKDAYS.map((d, i) => {
                    const on = s.days.includes(i);
                    return (
                      <button
                        key={d}
                        type="button"
                        aria-pressed={on}
                        className={on ? "st-primary" : "st-btn"}
                        onClick={() => setS({ ...s, days: on ? s.days.filter((x) => x !== i) : [...s.days, i].sort() })}
                        style={{
                          height: 30,
                          width: 40,
                          borderRadius: 7,
                          fontSize: 12,
                          fontWeight: on ? 600 : 500,
                          cursor: "pointer",
                          border: on ? "1px solid var(--primary-bg)" : "1px solid var(--border-control)",
                          background: on ? "var(--primary-bg)" : "var(--bg-control)",
                          color: on ? "var(--primary-fg)" : "var(--text-muted)",
                        }}
                      >
                        {d}
                      </button>
                    );
                  })}
                </div>
              )}
              <label htmlFor={id("time")}>at</label>
              <input id={id("time")} aria-label="Time" type="time" style={{ ...inputStyle, width: 112 }} value={s.time} onChange={(e) => setS({ ...s, time: e.target.value })} />
            </>
          )}
        </div>
      </Group>

      <div style={groupStyle}>
        <span style={labelStyle}>Options</span>
        <div style={rowsBox}>
          <div style={rowStyle}>
            <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 4 }}>
              <span id={id("enabled")} style={{ fontSize: 13, fontWeight: 600 }}>On</span>
              <span style={helperStyle}>Off keeps the schedule; it then runs only with Run now.</span>
            </div>
            <Switch checked={v.enabled} onChange={(on) => set({ enabled: on })} labelledBy={id("enabled")} />
          </div>
          <div style={{ ...rowStyle, borderTop: "1px solid var(--border)" }}>
            <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 4 }}>
              <span id={id("bypass")} style={{ fontSize: 13, fontWeight: 600 }}>Skip permission prompts</span>
              <span style={helperStyle}>Nobody is there to answer them. Off: Claude may edit files, but a shell command or MCP tool that needs approval stops the run.</span>
            </div>
            <Switch checked={v.bypass} onChange={(on) => set({ bypass: on })} labelledBy={id("bypass")} />
          </div>
          <div style={{ ...rowStyle, borderTop: "1px solid var(--border)" }}>
            <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 4 }}>
              <span id={id("chrome")} style={{ fontSize: 13, fontWeight: 600 }}>Browser (Claude in Chrome)</span>
              <span style={helperStyle}>Lets the prompt use your Chrome, as your own sessions do. Chrome must be open with the Claude extension connected when it runs.</span>
            </div>
            <Switch checked={v.chrome} onChange={(on) => set({ chrome: on })} labelledBy={id("chrome")} />
          </div>
          <div style={{ ...rowStyle, alignItems: "center", borderTop: "1px solid var(--border)" }}>
            <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 4 }}>
              <label htmlFor={id("timeout")} style={{ fontSize: 13, fontWeight: 600 }}>Timeout</label>
              <span style={helperStyle}>A run still going after this is stopped and marked timed out.</span>
            </div>
            <input id={id("timeout")} type="number" min={1} max={1440} style={{ ...inputStyle, width: 72 }} value={v.timeoutMin} onChange={(e) => set({ timeoutMin: Number(e.target.value) || 0 })} />
            <span style={{ fontSize: 13, color: "var(--text-muted)" }}>min</span>
          </div>
        </div>
      </div>

      <div role="note" style={{ display: "flex", gap: 10, alignItems: "flex-start", padding: "10px 12px", borderRadius: 9, background: "var(--warning-card-bg)", border: "1px solid var(--warning-border)", color: "var(--warning-text)", fontSize: 12, lineHeight: 1.5 }}>
        <AlertTriangle size={15} style={{ flexShrink: 0, marginTop: 1 }} />
        <span>
          {v.bypass
            ? "Runs headless with permission prompts skipped: Claude can run any command and use every MCP tool in this folder without asking. Only schedule prompts you would run yourself."
            : "Runs headless: steps that need approval fail the run instead of waiting."}
        </span>
      </div>

      {err && (
        <div role="alert" style={{ fontSize: 12, color: "var(--danger-text)", overflowWrap: "anywhere" }}>
          {err}
        </div>
      )}
    </ModalShell>
  );
}

export function HistoryDialog({ job, onClose }: { job: JobView; onClose: () => void }) {
  const [runs, setRuns] = useState<Run[] | null>(null);
  const [open, setOpen] = useState<number | null>(null);
  const [err, setErr] = useState("");
  // Re-read when a run starts or ends while the dialog is open.
  const stamp = `${job.runs}|${job.running}`;
  useEffect(() => {
    invoke<Run[]>("schedule_runs", { id: job.id })
      .then((r) => {
        setRuns(r);
        setOpen((cur) => cur ?? (r[0] ? r[0].started : null));
      })
      .catch((e) => setErr(String(e)));
  }, [job.id, stamp]);
  const now = Date.now();
  return (
    <ModalShell
      title={`History · ${job.name}`}
      width={680}
      onClose={onClose}
      footer={
        <>
          <span style={{ fontSize: 12, color: "var(--text-faint)" }}>The last 100 runs are kept.</span>
          <button type="button" className="st-btn" style={ghostBtn} onClick={onClose}>
            Close
          </button>
        </>
      }
    >
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        <Pill label={`${job.runs} run${job.runs === 1 ? "" : "s"}`} tone="muted" />
        <Pill label={`${job.ok} succeeded`} tone="success" />
        <Pill label={`${job.failed} failed`} tone={job.failed ? "failed" : "muted"} />
        {job.running && <Pill label="Running now" tone="running" />}
      </div>
      {err && <div role="alert" style={{ fontSize: 12, color: "var(--danger-text)" }}>{err}</div>}
      {runs && runs.length === 0 && <div style={helperStyle}>No runs yet. Use Run now on the card to try it.</div>}
      {runs && runs.length > 0 && (
        <div style={rowsBox}>
          {runs.map((r, i) => {
            const expanded = open === r.started;
            const st = r.status === "success" ? { label: "Success", tone: "success" as const } : { label: r.status === "timeout" ? "Timed out" : "Failed", tone: "failed" as const };
            return (
              <div key={r.started} style={{ borderTop: i ? "1px solid var(--border)" : undefined }}>
                <button
                  type="button"
                  aria-expanded={expanded}
                  onClick={() => setOpen(expanded ? null : r.started)}
                  className="st-btn"
                  style={{ display: "flex", alignItems: "center", gap: 10, width: "100%", padding: "10px 12px", background: "transparent", border: "none", cursor: "pointer", color: "var(--text)", fontSize: 13, textAlign: "left" }}
                >
                  {expanded ? <ChevronDown size={14} color="var(--text-muted)" /> : <ChevronRight size={14} color="var(--text-muted)" />}
                  <Pill {...st} />
                  <span style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                    {fmtClock(r.started, now)} <span style={{ color: "var(--text-faint)" }}>· {relTime(r.started, now)}</span>
                  </span>
                  <span style={{ fontSize: 12, color: "var(--text-muted)" }}>{r.trigger === "manual" ? "Run now" : "Scheduled"}</span>
                  <span style={{ fontSize: 12, color: "var(--text-muted)", fontFamily: "var(--font-mono)", minWidth: 52, textAlign: "right" }}>{fmtDurationMs(r.ended - r.started)}</span>
                  <span style={{ fontSize: 12, color: "var(--text-muted)", fontFamily: "var(--font-mono)", minWidth: 44, textAlign: "right" }}>{r.costUsd != null ? `$${r.costUsd.toFixed(2)}` : ""}</span>
                </button>
                {expanded && (
                  <pre
                    aria-label="Run output"
                    style={{ margin: 0, padding: "10px 14px", maxHeight: 340, overflow: "auto", whiteSpace: "pre-wrap", wordBreak: "break-word", fontFamily: "var(--font-mono)", fontSize: 12, lineHeight: 1.5, background: "var(--bg-control)", borderTop: "1px solid var(--border)", color: "var(--text)" }}
                  >
                    {r.output || "(no output)"}
                  </pre>
                )}
              </div>
            );
          })}
        </div>
      )}
    </ModalShell>
  );
}

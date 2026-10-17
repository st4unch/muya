// Created by Claude — Classification: INTERNAL
//
// Sessions → "Clean up…": pick old or big Claude sessions and archive them (restorable)
// or move them to the Trash; the Archived tab brings them back
// (docs/prd-session-housekeeping.md). Built from modalKit like SettingsModal.

import { useCallback, useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { ModalShell, Segmented, Switch, ghostBtn, helperStyle, inputStyle, primaryBtn, rowStyle, rowsBox } from "./modalKit";
import { ageDays, cleanupCandidates, formatBytes, sessionBytes, type StoredSession } from "../lib/sessionStorage";
import { shortCwd } from "../lib/format";

interface Result {
  done: number;
  skipped: [string, string][];
}

const OLDER = [7, 14, 30, 60, 90];
const LARGER = [50, 100, 250, 500];

const titleOf = (s: StoredSession) => s.name || s.cwd.split("/").filter(Boolean).pop() || s.sessionId.slice(0, 8);
const age = (d: number) => (d === 0 ? "today" : d === 1 ? "1 day ago" : `${d} days ago`);

/** What a run did, in one line. */
export function resultLine(verb: string, r: Result): string {
  const n = (k: number) => `${k} session${k === 1 ? "" : "s"}`;
  const head = r.done ? `${verb} ${n(r.done)}.` : `Nothing ${verb.toLowerCase()}.`;
  if (!r.skipped.length) return head;
  const why = [...new Set(r.skipped.map(([, w]) => w))].join(", ");
  return `${head} ${n(r.skipped.length)} left as they were (${why}).`;
}

export default function SessionCleanupDialog({
  history,
  liveIds,
  onClose,
  onChanged,
}: {
  history: StoredSession[];
  liveIds: ReadonlySet<string>;
  onClose: () => void;
  /** Files moved: the Sessions list must be read again. */
  onChanged: () => void;
}) {
  const [tab, setTab] = useState<"cleanup" | "archived">("cleanup");
  const [olderOn, setOlderOn] = useState(true);
  const [olderDays, setOlderDays] = useState(30);
  const [largerOn, setLargerOn] = useState(true);
  const [largerMb, setLargerMb] = useState(100);
  const [archived, setArchived] = useState<StoredSession[]>([]);
  // Unticked paths: everything a rule picks starts ticked.
  const [unticked, setUnticked] = useState<Set<string>>(new Set());
  // The action in progress ("Archiving…"): buttons say what is happening and stay disabled.
  const [running, setRunning] = useState<string | null>(null);
  const busy = running !== null;
  const [note, setNote] = useState("");
  const now = Date.now();

  const loadArchived = useCallback(() => {
    invoke<StoredSession[]>("list_archived_sessions")
      .then((a) => setArchived(Array.isArray(a) ? a : []))
      .catch(() => setArchived([]));
  }, []);
  useEffect(loadArchived, [loadArchived]);

  const candidates = useMemo(
    () => cleanupCandidates(history, { olderDays: olderOn ? olderDays : null, largerMb: largerOn ? largerMb : null }, liveIds, now),
    // `now` moves every render; the list only needs the rules and the data.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [history, liveIds, olderOn, olderDays, largerOn, largerMb],
  );
  const shown = tab === "cleanup" ? candidates : archived;
  const picked = shown.filter((s) => !unticked.has(s.path));
  const pickedBytes = picked.reduce((n, s) => n + sessionBytes(s), 0);

  const toggle = (path: string) =>
    setUnticked((u) => {
      const next = new Set(u);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });

  const run = async (cmd: "archive_sessions" | "trash_sessions" | "restore_sessions", verb: string, doing: string) => {
    if (!picked.length || busy) return;
    setRunning(doing);
    setNote("");
    try {
      const paths = picked.map((s) => s.path);
      const args = cmd === "restore_sessions" ? { paths } : { paths, liveIds: [...liveIds] };
      const r = await invoke<Result>(cmd, args);
      setNote(resultLine(verb, r));
      setUnticked(new Set());
      onChanged();
      loadArchived();
    } catch (e) {
      setNote(String(e));
    } finally {
      setRunning(null);
    }
  };

  // Why nothing can be done right now — shown in the list, the footer and the buttons' tooltip.
  const rulesOff = tab === "cleanup" && !olderOn && !largerOn;
  const emptyText =
    tab === "archived"
      ? "Nothing archived yet."
      : rulesOff
        ? "Turn on a rule above to pick sessions."
        : `No session is ${[olderOn ? `unused for ${olderDays}+ days` : "", largerOn ? `larger than ${largerMb} MB` : ""].filter(Boolean).join(" or ")}. Running sessions and ones used in the last 10 minutes are left out — loosen the rules to see more.`;
  const idleReason = shown.length === 0 ? (tab === "archived" ? "Nothing archived yet" : "Nothing to clean up with these rules") : picked.length === 0 ? "Tick the sessions to clean up" : "";
  const btn = (base: React.CSSProperties) => ({ ...base, cursor: busy || !picked.length ? "not-allowed" : "pointer" });

  const rule = (label: string, id: string, on: boolean, setOn: (v: boolean) => void, value: number, setValue: (v: number) => void, options: number[], unit: (v: number) => string, border: boolean) => (
    <div style={{ ...rowStyle, alignItems: "center", ...(border ? { borderTop: "1px solid var(--border)" } : null) }}>
      <span id={id} style={{ flex: 1, fontSize: 13, fontWeight: 600 }}>
        {label}
      </span>
      <select aria-label={`${label} value`} value={value} disabled={!on} onChange={(e) => setValue(Number(e.target.value))} style={{ ...inputStyle, width: "auto", cursor: "pointer" }}>
        {options.map((o) => (
          <option key={o} value={o}>
            {unit(o)}
          </option>
        ))}
      </select>
      <Switch checked={on} onChange={setOn} labelledBy={id} />
    </div>
  );

  return (
    <ModalShell
      title="Clean up Claude sessions"
      onClose={onClose}
      width={600}
      footer={
        <>
          <span style={{ ...helperStyle, minWidth: 0 }} role="status">
            {running ? `${running} ${picked.length} session${picked.length === 1 ? "" : "s"}…` : note || (picked.length ? `${picked.length} selected · ${formatBytes(pickedBytes)}` : idleReason)}
          </span>
          <div style={{ display: "flex", gap: 8, flexShrink: 0 }}>
            <button type="button" style={btn(ghostBtn)} className="st-btn" title={idleReason || undefined} aria-busy={running === "Moving to the Trash"} disabled={busy || !picked.length} onClick={() => void run("trash_sessions", "Moved to the Trash:", "Moving to the Trash")}>
              {running === "Moving to the Trash" ? "Moving…" : "Move to Trash"}
            </button>
            {tab === "cleanup" ? (
              <button type="button" style={btn(primaryBtn)} className="st-btn" title={idleReason || undefined} aria-busy={running === "Archiving"} disabled={busy || !picked.length} onClick={() => void run("archive_sessions", "Archived", "Archiving")}>
                {running === "Archiving" ? "Archiving…" : "Archive"}
              </button>
            ) : (
              <button type="button" style={btn(primaryBtn)} className="st-btn" title={idleReason || undefined} aria-busy={running === "Restoring"} disabled={busy || !picked.length} onClick={() => void run("restore_sessions", "Restored", "Restoring")}>
                {running === "Restoring" ? "Restoring…" : "Restore"}
              </button>
            )}
          </div>
        </>
      }
    >
      <Segmented
        value={tab}
        onChange={(t) => {
          setTab(t);
          setUnticked(new Set());
          setNote("");
        }}
        options={[
          { value: "cleanup", label: "Clean up" },
          { value: "archived", label: `Archived (${archived.length})` },
        ]}
      />
      {tab === "cleanup" ? (
        <>
          <div style={helperStyle}>
            Archive moves sessions out of Claude's folder into Muya's archive — you can restore them here. Running sessions and ones used in the last 10 minutes are never touched.
          </div>
          <div style={rowsBox}>
            {rule("Not used for", "cu-older", olderOn, setOlderOn, olderDays, setOlderDays, OLDER, (d) => `${d} days`, false)}
            {rule("Larger than", "cu-larger", largerOn, setLargerOn, largerMb, setLargerMb, LARGER, (m) => `${m} MB`, true)}
          </div>
        </>
      ) : (
        <div style={helperStyle}>Archived sessions are kept until you move them to the Trash. Restore puts them back where Claude finds them.</div>
      )}
      <div style={{ ...rowsBox, maxHeight: 300, overflowY: "auto" }} aria-label={tab === "cleanup" ? "Sessions to clean up" : "Archived sessions"} role="group">
        {shown.length === 0 ? (
          <div style={{ ...rowStyle, ...helperStyle }}>{emptyText}</div>
        ) : (
          shown.map((s, i) => (
            <label key={s.path} style={{ ...rowStyle, alignItems: "center", cursor: "pointer", ...(i ? { borderTop: "1px solid var(--border)" } : null) }}>
              <input type="checkbox" checked={!unticked.has(s.path)} onChange={() => toggle(s.path)} style={{ accentColor: "var(--accent)", width: 15, height: 15, flexShrink: 0 }} />
              <span style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 2 }}>
                <span style={{ fontSize: 13, fontWeight: 600, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{titleOf(s)}</span>
                <span style={{ ...helperStyle, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                  {shortCwd(s.cwd)} · {age(ageDays(s, now))}
                </span>
              </span>
              <span style={{ fontSize: 12, fontVariantNumeric: "tabular-nums", color: "var(--text-muted)", flexShrink: 0 }}>{formatBytes(sessionBytes(s))}</span>
            </label>
          ))
        )}
      </div>
    </ModalShell>
  );
}

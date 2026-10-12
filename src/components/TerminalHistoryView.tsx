// Created by Claude — Classification: INTERNAL
//
// Sessions → Terminal History: plain terminals' own command histories
// (src-tauri/src/term_history.rs), grouped by day. Each terminal can be reopened with
// its history (same tab key → same history file), its commands downloaded as text,
// or its history deleted.
import { useCallback, useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { ChevronDown, ChevronRight, Clock, Download, Play, SquareTerminal, Trash2 } from "lucide-react";
import { shortCwd } from "../lib/format";
import { groupByDay, historyText, localTime, type TermEntries } from "../lib/termHistory";

/** Commands shown per terminal per day before "show all". */
const PREVIEW = 5;
/** Must match MAX_TERMINALS in src-tauri/src/term_history.rs. */
const MAX_TERMINALS = 100;

const btn =
  "flex items-center gap-1 text-[11px] font-mono px-2 py-1 rounded border border-neutral-200 dark:border-neutral-700 bg-[var(--bg-control)] text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-pointer transition-colors";

export default function TerminalHistoryView({
  query,
  onReopen,
  refreshToken,
}: {
  query: string;
  onReopen: (spec: { key: string; name: string; cwd?: string }) => void;
  /** Bumped by the page's Refresh button. */
  refreshToken: number;
}) {
  const [terms, setTerms] = useState<TermEntries[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());

  const load = useCallback(async () => {
    setTerms(await invoke<TermEntries[]>("term_history_entries").catch(() => []));
    setLoaded(true);
  }, []);
  useEffect(() => {
    void load();
  }, [load, refreshToken]);

  const q = query.trim().toLowerCase();
  const groups = useMemo(() => {
    const filtered = q
      ? terms
          .map((t) => ({
            ...t,
            entries: [t.name, t.cwd].some((x) => x.toLowerCase().includes(q)) ? t.entries : t.entries.filter((e) => e.cmd.toLowerCase().includes(q)),
          }))
          .filter((t) => t.entries.length > 0)
      : terms;
    return groupByDay(filtered);
  }, [terms, q]);

  // The list holds only each terminal's newest commands; "View all" and download read
  // that one terminal in full, once.
  const full = async (key: string): Promise<TermEntries | undefined> => {
    const have = terms.find((x) => x.key === key);
    if (have && have.entries.length >= have.total) return have;
    const t = await invoke<TermEntries | null>("term_history_full", { key }).catch(() => null);
    if (!t) return have;
    setTerms((prev) => prev.map((x) => (x.key === key ? t : x)));
    return t;
  };

  const expand = (id: string, key: string) => {
    setExpanded((prev) => new Set(prev).add(id));
    void full(key);
  };

  const download = async (key: string) => {
    try {
      const t = await full(key);
      if (!t) return;
      const { save } = await import("@tauri-apps/plugin-dialog");
      const dest = (await save({
        title: "Download terminal history",
        defaultPath: `${(t.name || t.key).replace(/[^\w.-]+/g, "-")}-history.txt`,
      })) as string | null;
      if (!dest) return;
      await invoke("term_history_export", { dest, text: historyText(t.name, t.cwd, t.entries) });
    } catch (e) {
      console.warn("[muya] terminal history download failed:", e);
    }
  };

  const remove = async (key: string) => {
    await invoke("term_history_delete", { key }).catch((e) => console.warn("[muya] terminal history delete failed:", e));
    setTerms((prev) => prev.filter((t) => t.key !== key));
  };

  if (loaded && groups.length === 0) {
    return (
      <div className="text-[11px] font-mono text-neutral-400 dark:text-neutral-500 py-2">
        {q ? "No matching terminal commands." : "No terminal history yet. Commands typed in a terminal tab show up here, by day."}
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {groups.map((g) => (
        <section key={g.day}>
          <h2 className="text-[10px] font-mono uppercase tracking-widest font-bold text-neutral-500 dark:text-neutral-400 mb-2">
            {g.label} <span className="font-normal normal-case tracking-normal">· {g.terminals.length} terminal{g.terminals.length === 1 ? "" : "s"}</span>
          </h2>
          <div className="space-y-1.5">
            {g.terminals.map((t) => {
              const id = `${g.day}/${t.key}`;
              const open = expanded.has(id);
              const lines = open ? t.entries : t.entries.slice(0, PREVIEW);
              return (
                <div key={id} className="bg-[var(--bg-control)] border border-neutral-200 dark:border-neutral-700 rounded-lg p-3 shadow-sm">
                  <div className="flex items-center justify-between gap-3">
                    <button
                      type="button"
                      onClick={() => (open ? setExpanded((prev) => { const n = new Set(prev); n.delete(id); return n; }) : expand(id, t.key))}
                      className="min-w-0 text-left cursor-pointer"
                      title={open ? "Show fewer" : "View all commands of this day"}
                    >
                      <div className="flex items-center gap-2">
                        {open ? <ChevronDown className="h-3 w-3 text-neutral-400" /> : <ChevronRight className="h-3 w-3 text-neutral-400" />}
                        <SquareTerminal className="h-3.5 w-3.5 text-neutral-500 dark:text-neutral-400" />
                        <span className="font-mono text-xs font-semibold text-neutral-800 dark:text-neutral-200 truncate max-w-[240px]">{t.name || "Terminal"}</span>
                        <span className="text-[9px] font-mono text-neutral-400 dark:text-neutral-500">{t.entries.length} commands</span>
                      </div>
                      {t.cwd && <div className="mt-1 ml-5 text-[10px] font-mono text-neutral-500 dark:text-neutral-400 truncate max-w-[400px]">{shortCwd(t.cwd)}</div>}
                    </button>
                    <div className="shrink-0 flex items-center gap-1.5">
                      <button type="button" className={btn} title="Delete this terminal's whole history" onClick={() => void remove(t.key)}>
                        <Trash2 className="h-3 w-3" />
                      </button>
                      <button type="button" className={btn} title="Download this terminal's whole history (.txt)" onClick={() => void download(t.key)}>
                        <Download className="h-3 w-3" /> .txt
                      </button>
                      <button
                        type="button"
                        className={`${btn} font-semibold`}
                        title="Open this terminal again with its history (↑ shows its commands)"
                        onClick={() => onReopen({ key: t.key, name: t.name || "Terminal", cwd: t.cwd.startsWith("/") ? t.cwd : undefined })}
                      >
                        <Play className="h-3 w-3" /> Reopen
                      </button>
                    </div>
                  </div>
                  <div className={`mt-2 ml-5 space-y-0.5 ${open ? "max-h-80 overflow-y-auto" : ""}`}>
                    {lines.map((e, i) => (
                      <div key={i} className="flex gap-2 font-mono text-[10px] text-neutral-600 dark:text-neutral-300" title={e.cmd}>
                        <span className="shrink-0 w-10 text-neutral-400 dark:text-neutral-500 flex items-center gap-0.5">
                          {e.ts != null ? <><Clock className="h-2.5 w-2.5" />{localTime(e.ts * 1000)}</> : ""}
                        </span>
                        <span className="truncate select-text">{e.cmd}</span>
                      </div>
                    ))}
                    {!open && t.entries.length > PREVIEW && (
                      <button
                        type="button"
                        onClick={() => expand(id, t.key)}
                        className="text-[10px] font-mono text-indigo-600 dark:text-indigo-400 cursor-pointer"
                      >
                        View all {t.entries.length}
                      </button>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </section>
      ))}
      {terms.length >= MAX_TERMINALS && (
        <div className="text-[10px] font-mono text-neutral-400 dark:text-neutral-500">
          Showing the {MAX_TERMINALS} most recently used terminals, with each one's latest commands. View all or .txt loads a terminal in full.
        </div>
      )}
    </div>
  );
}

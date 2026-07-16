import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { relTime, shortCwd } from "../lib/format";
import { RefreshCw, Play, Plug, FolderGit2, Clock, Square, Search, X, MessageSquare, User, Bot } from "lucide-react";

interface AgentSession {
  id: string;
  name: string;
  branch: string;
  worktree: string;
  status: string;
  duration: string;
  modelsUsed: string;
  attachable?: boolean;
  attachId?: string;
}

interface HistoryEntry {
  sessionId: string;
  cwd: string;
  lastModified: number;
  sizeBytes: number;
  path: string;
}

interface TranscriptMessage {
  role: string;
  text: string;
  timestamp: string | null;
}

export interface OpenTerminalSpec {
  key: string;
  name: string;
  cwd?: string;
  initialCommand?: string;
}

function statusColor(s: string) {
  if (s === "working") return "bg-emerald-50 dark:bg-green-900/30 text-emerald-700 dark:text-green-400 border-emerald-200 dark:border-green-700";
  if (s === "waiting-for-input") return "bg-amber-50 dark:bg-amber-900/25 text-amber-700 dark:text-amber-400 border-amber-200 dark:border-amber-600";
  if (s === "stopped") return "bg-rose-50 dark:bg-red-900/30 text-rose-700 dark:text-red-400 border-rose-200 dark:border-red-700";
  return "bg-blue-50 text-blue-700 border-blue-200";
}

/** Full session view: live sessions (claude agents --json --all) + transcript history. */
export default function SessionsPage({
  onOpen,
}: {
  onOpen: (spec: OpenTerminalSpec) => void;
}) {
  const [live, setLive] = useState<AgentSession[]>([]);
  const [history, setHistory] = useState<HistoryEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [query, setQuery] = useState("");
  // Transcript drawer: which past session's conversation is open.
  const [transcript, setTranscript] = useState<{ title: string; id: string; msgs: TranscriptMessage[] } | null>(null);
  const [transcriptLoading, setTranscriptLoading] = useState(false);

  const openTranscript = useCallback(async (h: HistoryEntry) => {
    const title = h.cwd.split("/").filter(Boolean).pop() || h.sessionId.slice(0, 8);
    setTranscriptLoading(true);
    setTranscript({ title, id: h.sessionId, msgs: [] });
    try {
      const msgs = await invoke<TranscriptMessage[]>("read_session_transcript", { path: h.path });
      setTranscript({ title, id: h.sessionId, msgs });
    } catch (e) {
      setTranscript({ title, id: h.sessionId, msgs: [{ role: "assistant", text: `Transcript okunamadı: ${e}`, timestamp: null }] });
    } finally {
      setTranscriptLoading(false);
    }
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const [l, h] = await Promise.all([
        invoke<AgentSession[]>("list_agent_sessions", { includeAll: true }),
        invoke<HistoryEntry[]>("list_session_history"),
      ]);
      setLive(l);
      setHistory(h);
    } catch (e) {
      console.warn("[apex] sessions refresh failed:", e);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const t = setInterval(() => {
      if (!document.hidden) void refresh();
    }, 5000);
    return () => clearInterval(t);
  }, [refresh]);

  const stop = async (s: AgentSession) => {
    try {
      await invoke("stop_agent", { id: s.attachId ?? s.id });
      void refresh();
    } catch (e) {
      console.warn("[apex] stop_agent failed:", e);
    }
  };

  const liveIds = new Set(live.map((s) => s.id));

  const q = query.trim().toLowerCase();
  const filteredLive = q
    ? live.filter(s =>
        s.name.toLowerCase().includes(q) ||
        s.worktree.toLowerCase().includes(q) ||
        s.branch.toLowerCase().includes(q) ||
        s.status.toLowerCase().includes(q)
      )
    : live;
  const filteredHistory = q
    ? history.filter(h => {
        const name = h.cwd.split("/").filter(Boolean).pop() ?? "";
        return name.toLowerCase().includes(q) ||
          h.cwd.toLowerCase().includes(q) ||
          h.sessionId.toLowerCase().includes(q);
      })
    : history;

  return (
    <div className="flex-1 overflow-y-auto bg-neutral-50/50 dark:bg-[#25272b] p-5">
      <div className="flex items-center justify-between mb-3">
        <h1 className="text-sm font-display font-bold text-neutral-800 dark:text-neutral-200 flex items-center gap-2">
          <Plug className="h-4 w-4 text-indigo-500 dark:text-indigo-400" /> Claude Sessions
        </h1>
        <button
          type="button"
          onClick={() => void refresh()}
          className="flex items-center gap-1.5 text-[11px] font-mono px-2 py-1 rounded border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-[#25272b] hover:bg-neutral-100 dark:hover:bg-neutral-800 text-neutral-600 dark:text-neutral-400 cursor-pointer transition-colors"
        >
          <RefreshCw className={`h-3 w-3 ${loading ? "animate-spin" : ""}`} /> Refresh
        </button>
      </div>

      {/* Search */}
      <div className="relative mb-4">
        <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-neutral-400 dark:text-neutral-500 pointer-events-none" />
        <input
          type="text"
          placeholder="Search by name, path, branch, session ID…"
          value={query}
          onChange={e => setQuery(e.target.value)}
          className="w-full pl-8 pr-8 py-1.5 text-[11px] font-mono rounded border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-[#25272b] text-neutral-800 dark:text-neutral-200 placeholder-neutral-400 dark:placeholder-neutral-600 focus:outline-none focus:border-indigo-400 dark:focus:border-indigo-600"
        />
        {query && (
          <button type="button" onClick={() => setQuery("")} className="absolute right-2 top-1/2 -translate-y-1/2 text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 cursor-pointer">
            <X className="h-3.5 w-3.5" />
          </button>
        )}
      </div>

      {/* LIVE */}
      <section className="mb-6">
        <h2 className="text-[10px] font-mono uppercase tracking-widest font-bold text-emerald-600 dark:text-green-400 mb-2">
          Live sessions ({filteredLive.length}{q && live.length !== filteredLive.length ? `/${live.length}` : ""})
        </h2>
        <div className="space-y-1.5">
          {filteredLive.length === 0 && (
            <div className="text-[11px] font-mono text-neutral-400 dark:text-neutral-500 py-2">
              {q ? "No matching live sessions." : "No live sessions."}
            </div>
          )}
          {filteredLive.map((s) => (
            <div
              key={s.id}
              className="bg-white dark:bg-[#25272b] border border-neutral-200 dark:border-neutral-700 rounded-lg p-3 flex items-center justify-between gap-3 shadow-sm"
            >
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <span className="font-mono text-xs font-bold text-neutral-900 dark:text-neutral-100 truncate max-w-[260px]">
                    {s.name}
                  </span>
                  <span
                    className={`text-[8px] font-mono font-bold px-1.5 py-0.5 rounded border uppercase ${statusColor(
                      s.status
                    )}`}
                  >
                    {s.status}
                  </span>
                  <span className="text-[9px] font-mono text-neutral-400 dark:text-neutral-500">{s.modelsUsed}</span>
                </div>
                <div className="flex items-center gap-3 mt-1 text-[10px] font-mono text-neutral-500 dark:text-neutral-400">
                  <span className="flex items-center gap-1 truncate max-w-[280px]">
                    <FolderGit2 className="h-3 w-3" /> {shortCwd(s.worktree)}
                  </span>
                  <span>{s.branch}</span>
                  <span className="flex items-center gap-1">
                    <Clock className="h-3 w-3" /> {s.duration}
                  </span>
                </div>
              </div>
              <div className="shrink-0 flex items-center gap-1.5">
                <button
                  type="button"
                  onClick={() =>
                    onOpen({
                      key: s.id,
                      name: s.name,
                      cwd: s.worktree.startsWith("/") ? s.worktree : undefined,
                      initialCommand:
                        s.attachable && s.attachId
                          ? `claude attach ${s.attachId} --dangerously-skip-permissions`
                          : undefined,
                    })
                  }
                  className="flex items-center gap-1.5 text-[11px] font-mono font-semibold px-2.5 py-1 rounded border border-indigo-200 dark:border-indigo-800 bg-indigo-50 dark:bg-indigo-950/40 text-indigo-700 dark:text-indigo-300 hover:bg-indigo-100 dark:hover:bg-indigo-900/40 cursor-pointer transition-colors"
                >
                  <Plug className="h-3 w-3" /> {s.attachable ? "Attach" : "Aç"}
                </button>
                {s.attachable && (
                  <button
                    type="button"
                    onClick={() => void stop(s)}
                    className="flex items-center gap-1.5 text-[11px] font-mono font-semibold px-2.5 py-1 rounded border border-rose-200 dark:border-rose-800 bg-rose-50 dark:bg-rose-950/40 text-rose-700 dark:text-rose-300 hover:bg-rose-100 dark:hover:bg-rose-900/40 cursor-pointer transition-colors"
                    title="Stop background session (claude stop)"
                  >
                    <Square className="h-3 w-3" /> Stop
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* HISTORY */}
      <section>
        <h2 className="text-[10px] font-mono uppercase tracking-widest font-bold text-neutral-500 dark:text-neutral-400 mb-2">
          Past sessions ({filteredHistory.length}{q && history.length !== filteredHistory.length ? `/${history.length}` : ""})
        </h2>
        <div className="space-y-1.5">
          {filteredHistory.length === 0 && (
            <div className="text-[11px] font-mono text-neutral-400 dark:text-neutral-500 py-2">
              {q ? "No matching past sessions." : "No transcript history."}
            </div>
          )}
          {filteredHistory.map((h) => {
            const isLive = liveIds.has(h.sessionId);
            const name = h.cwd.split("/").filter(Boolean).pop() || h.sessionId.slice(0, 8);
            return (
              <div
                key={h.sessionId}
                className="bg-white dark:bg-[#25272b] border border-neutral-200 dark:border-neutral-700 rounded-lg p-3 flex items-center justify-between gap-3 shadow-sm"
              >
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="font-mono text-xs font-semibold text-neutral-800 dark:text-neutral-200 truncate max-w-[240px]">
                      {name}
                    </span>
                    {isLive && (
                      <span className="text-[8px] font-mono font-bold px-1.5 py-0.5 rounded border uppercase bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300 border-emerald-200 dark:border-emerald-800">
                        live
                      </span>
                    )}
                    <span className="text-[9px] font-mono text-neutral-400 dark:text-neutral-500">
                      {(h.sizeBytes / 1024).toFixed(0)} KB
                    </span>
                  </div>
                  <div className="flex items-center gap-3 mt-1 text-[10px] font-mono text-neutral-500 dark:text-neutral-400">
                    <span className="truncate max-w-[300px]">{shortCwd(h.cwd)}</span>
                    <span className="flex items-center gap-1">
                      <Clock className="h-3 w-3" /> {relTime(h.lastModified)}
                    </span>
                    <span className="text-neutral-300 dark:text-neutral-600">{h.sessionId.slice(0, 8)}</span>
                  </div>
                </div>
                <div className="shrink-0 flex items-center gap-1.5">
                  <button
                    type="button"
                    onClick={() => void openTranscript(h)}
                    className="flex items-center gap-1.5 text-[11px] font-mono font-semibold px-2.5 py-1 rounded border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-[#25272b] text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-pointer transition-colors"
                    title="View this session's conversation"
                  >
                    <MessageSquare className="h-3 w-3" /> View
                  </button>
                  <button
                    type="button"
                    onClick={() =>
                      onOpen({
                        key: `resume:${h.sessionId}`,
                        name: `↻ ${name}`,
                        cwd: h.cwd.startsWith("/") ? h.cwd : undefined,
                        initialCommand: `claude --resume ${h.sessionId} --dangerously-skip-permissions`,
                      })
                    }
                    className="flex items-center gap-1.5 text-[11px] font-mono font-semibold px-2.5 py-1 rounded border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-[#25272b] text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-pointer transition-colors"
                    title="Resume this session in a new terminal"
                  >
                    <Play className="h-3 w-3" /> Resume
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      </section>

      {/* TRANSCRIPT DRAWER — right slide-over showing the conversation */}
      {transcript && (
        <>
          <div
            className="fixed inset-0 bg-black/40 z-40"
            onClick={() => setTranscript(null)}
          />
          <div className="fixed top-0 right-0 bottom-0 w-[560px] max-w-[90vw] bg-white dark:bg-[#1e1f23] border-l border-neutral-200 dark:border-[#3d3f44] z-50 flex flex-col shadow-2xl">
            <div className="flex items-center justify-between px-4 py-3 border-b border-neutral-200 dark:border-[#3d3f44] shrink-0">
              <div className="min-w-0">
                <h3 className="text-sm font-bold text-neutral-800 dark:text-neutral-100 truncate flex items-center gap-2">
                  <MessageSquare className="h-4 w-4 text-indigo-500 shrink-0" />
                  {transcript.title}
                </h3>
                <p className="text-[10px] font-mono text-neutral-400 dark:text-neutral-500">
                  {transcript.id.slice(0, 8)} · {transcript.msgs.length} messages
                </p>
              </div>
              <button
                type="button"
                onClick={() => setTranscript(null)}
                className="p-1 rounded text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200 hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-pointer transition-colors"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
            <div className="flex-1 overflow-y-auto px-4 py-3 space-y-3">
              {transcriptLoading && (
                <p className="text-[11px] font-mono text-neutral-400 animate-pulse">Loading transcript…</p>
              )}
              {!transcriptLoading && transcript.msgs.length === 0 && (
                <p className="text-[11px] font-mono text-neutral-400">No displayable messages in this transcript.</p>
              )}
              {transcript.msgs.map((m, i) => (
                <div key={i} className={`flex gap-2 ${m.role === "user" ? "flex-row" : "flex-row"}`}>
                  <div className={`shrink-0 h-5 w-5 rounded flex items-center justify-center mt-0.5 ${
                    m.role === "user"
                      ? "bg-indigo-600 dark:bg-indigo-500 text-white"
                      : "bg-neutral-200 dark:bg-neutral-700 text-neutral-600 dark:text-neutral-300"
                  }`}>
                    {m.role === "user" ? <User className="h-3 w-3" /> : <Bot className="h-3 w-3" />}
                  </div>
                  <div className={`min-w-0 flex-1 rounded-lg px-3 py-2 border ${
                    m.role === "user"
                      ? "bg-indigo-50 dark:bg-indigo-500/10 border-indigo-200 dark:border-indigo-500/30"
                      : "bg-neutral-50 dark:bg-[#25272b] border-neutral-200 dark:border-neutral-700"
                  }`}>
                    <p className="text-[11px] leading-relaxed text-neutral-800 dark:text-neutral-200 whitespace-pre-wrap break-words">
                      {m.text}
                    </p>
                    {m.timestamp && (
                      <p className="text-[9px] font-mono text-neutral-400 dark:text-neutral-500 mt-1">
                        {new Date(m.timestamp).toLocaleString()}
                      </p>
                    )}
                  </div>
                </div>
              ))}
            </div>
          </div>
        </>
      )}
    </div>
  );
}

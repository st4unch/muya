import React, { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import {
  FileCode,
  CheckCircle2,
  Clock,
  AlertTriangle,
  ChevronRight,
  RefreshCw,
  ExternalLink,
  Layers,
} from "lucide-react";

interface PrdDoc {
  name: string;
  slug: string;
  prdPath: string;
  progressPath: string | null;
  status: string;
  owner: string | null;
  started: string | null;
  completed: string | null;
  totalPhases: number;
  donePhases: number;
  phaseSummary: string[];
}

type Column = "draft" | "active" | "review" | "done";

const COLUMNS: { key: Column; label: string; color: string; icon: React.ReactNode }[] = [
  { key: "draft", label: "Draft", color: "border-neutral-400 dark:border-neutral-500", icon: <FileCode className="h-3.5 w-3.5" /> },
  { key: "active", label: "In Progress", color: "border-blue-500 dark:border-blue-400", icon: <Clock className="h-3.5 w-3.5" /> },
  { key: "review", label: "Review", color: "border-amber-500 dark:border-amber-400", icon: <AlertTriangle className="h-3.5 w-3.5" /> },
  { key: "done", label: "Done", color: "border-emerald-500 dark:border-emerald-400", icon: <CheckCircle2 className="h-3.5 w-3.5" /> },
];

function classifyStatus(raw: string): Column {
  const s = raw.toLowerCase();
  if (s.includes("done") || s.includes("completed") || s.includes("shipped")) return "done";
  if (s.includes("active") || s.includes("in progress") || s.includes("in_progress") || s.includes("implementing")) return "active";
  if (s.includes("review") || s.includes("pending") || s.includes("awaiting")) return "review";
  return "draft";
}

const STATUS_BADGE: Record<Column, string> = {
  draft: "bg-neutral-200 dark:bg-neutral-700 text-neutral-600 dark:text-neutral-300",
  active: "bg-blue-100 dark:bg-blue-900/40 text-blue-700 dark:text-blue-300",
  review: "bg-amber-100 dark:bg-amber-900/40 text-amber-700 dark:text-amber-300",
  done: "bg-emerald-100 dark:bg-emerald-900/40 text-emerald-700 dark:text-emerald-300",
};

function PrdCard({ doc, onOpenFile }: { doc: PrdDoc; onOpenFile: (path: string) => void }) {
  const [expanded, setExpanded] = useState(false);
  const col = classifyStatus(doc.status);
  const progress = doc.totalPhases > 0 ? (doc.donePhases / doc.totalPhases) * 100 : 0;

  return (
    <div className="bg-white dark:bg-[#2d2f34] rounded-lg border border-neutral-200 dark:border-neutral-700 shadow-sm hover:shadow-md transition-shadow">
      <div className="p-3">
        <div className="flex items-start justify-between gap-2 mb-2">
          <h4 className="text-[11px] font-semibold text-neutral-800 dark:text-neutral-100 leading-tight line-clamp-2">
            {doc.name}
          </h4>
          <span className={`shrink-0 text-[9px] font-mono font-bold px-1.5 py-0.5 rounded ${STATUS_BADGE[col]}`}>
            {doc.status}
          </span>
        </div>

        {doc.totalPhases > 0 && (
          <div className="mb-2">
            <div className="flex items-center justify-between mb-1">
              <span className="text-[9px] font-mono text-neutral-500 dark:text-neutral-400">
                {doc.donePhases}/{doc.totalPhases} phases
              </span>
              <span className="text-[9px] font-mono text-neutral-400">
                {progress.toFixed(0)}%
              </span>
            </div>
            <div className="h-1.5 bg-neutral-200 dark:bg-neutral-700 rounded-full overflow-hidden">
              <div
                className="h-full bg-gradient-to-r from-blue-500 to-emerald-500 rounded-full transition-all duration-500"
                style={{ width: `${progress}%` }}
              />
            </div>
          </div>
        )}

        <div className="flex items-center gap-2 text-[9px] font-mono text-neutral-400 dark:text-neutral-500">
          {doc.owner && <span>{doc.owner}</span>}
          {doc.started && <span>{doc.started}</span>}
          {doc.completed && <span className="text-emerald-500">completed {doc.completed}</span>}
        </div>

        {doc.phaseSummary.length > 0 && (
          <button
            type="button"
            onClick={() => setExpanded((v) => !v)}
            className="mt-2 flex items-center gap-1 text-[9px] font-mono text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 cursor-pointer transition-colors"
          >
            <ChevronRight className={`h-3 w-3 transition-transform ${expanded ? "rotate-90" : ""}`} />
            phases
          </button>
        )}

        {expanded && (
          <ul className="mt-1 ml-4 space-y-0.5">
            {doc.phaseSummary.map((ph, i) => (
              <li key={i} className="text-[9px] font-mono text-neutral-500 dark:text-neutral-400 flex items-center gap-1">
                {ph.includes("✅") || ph.includes("PASS") ? (
                  <CheckCircle2 className="h-2.5 w-2.5 text-emerald-500 shrink-0" />
                ) : (
                  <Clock className="h-2.5 w-2.5 text-neutral-400 shrink-0" />
                )}
                <span className="truncate">{ph}</span>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="border-t border-neutral-100 dark:border-neutral-700 px-3 py-1.5 flex items-center gap-2">
        <button
          type="button"
          onClick={() => onOpenFile(doc.prdPath)}
          className="text-[9px] font-mono text-indigo-500 hover:text-indigo-700 dark:hover:text-indigo-300 cursor-pointer flex items-center gap-1 transition-colors"
        >
          <ExternalLink className="h-3 w-3" /> PRD
        </button>
        {doc.progressPath && (
          <button
            type="button"
            onClick={() => onOpenFile(doc.progressPath!)}
            className="text-[9px] font-mono text-violet-500 hover:text-violet-700 dark:hover:text-violet-300 cursor-pointer flex items-center gap-1 transition-colors"
          >
            <ExternalLink className="h-3 w-3" /> Progress
          </button>
        )}
      </div>
    </div>
  );
}

export default function PrdBoard({
  workspaces,
  onOpenFile,
}: {
  workspaces: string[];
  onOpenFile: (path: string) => void;
}) {
  const [docs, setDocs] = useState<PrdDoc[]>([]);
  const [loading, setLoading] = useState(false);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const result = await invoke<PrdDoc[]>("scan_prd_docs", { dirs: workspaces });
      setDocs(result);
    } catch (e) {
      console.warn("[prd-board] scan failed:", e);
    } finally {
      setLoading(false);
    }
  }, [workspaces]);

  useEffect(() => {
    if (workspaces.length > 0) void refresh();
  }, [workspaces, refresh]);

  const grouped: Record<Column, PrdDoc[]> = { draft: [], active: [], review: [], done: [] };
  for (const doc of docs) {
    grouped[classifyStatus(doc.status)].push(doc);
  }

  return (
    <div className="flex-1 flex flex-col overflow-hidden bg-neutral-100 dark:bg-[#1a1b1e]">
      {/* Header */}
      <div className="px-6 py-4 border-b border-neutral-200 dark:border-[#3d3f44] bg-white dark:bg-[#1e1f23] flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Layers className="h-4 w-4 text-indigo-500" />
          <h2 className="text-sm font-bold text-neutral-800 dark:text-neutral-100">PRD Board</h2>
          <span className="text-[10px] font-mono text-neutral-400 bg-neutral-100 dark:bg-neutral-800 px-2 py-0.5 rounded">
            {docs.length} docs
          </span>
        </div>
        <button
          type="button"
          onClick={() => void refresh()}
          disabled={loading}
          className="text-[10px] font-mono text-neutral-500 hover:text-neutral-800 dark:hover:text-neutral-200 cursor-pointer flex items-center gap-1 transition-colors disabled:opacity-50"
        >
          <RefreshCw className={`h-3 w-3 ${loading ? "animate-spin" : ""}`} />
          Refresh
        </button>
      </div>

      {/* Kanban Columns */}
      <div className="flex-1 overflow-x-auto overflow-y-hidden p-4">
        <div className="flex gap-4 h-full min-w-max">
          {COLUMNS.map((col) => (
            <div
              key={col.key}
              className={`w-72 flex flex-col bg-white/60 dark:bg-[#232529]/60 rounded-xl border-t-2 ${col.color}`}
            >
              {/* Column header */}
              <div className="px-3 py-2.5 flex items-center justify-between">
                <div className="flex items-center gap-1.5">
                  <span className="text-neutral-500 dark:text-neutral-400">{col.icon}</span>
                  <span className="text-[11px] font-bold uppercase tracking-wider text-neutral-600 dark:text-neutral-300">
                    {col.label}
                  </span>
                </div>
                <span className="text-[10px] font-mono text-neutral-400 bg-neutral-200/60 dark:bg-neutral-700/60 px-1.5 py-0.5 rounded-full">
                  {grouped[col.key].length}
                </span>
              </div>

              {/* Cards */}
              <div className="flex-1 overflow-y-auto px-2 pb-2 space-y-2">
                {grouped[col.key].length === 0 && (
                  <p className="text-[10px] font-mono text-neutral-400 dark:text-neutral-500 italic text-center py-8">
                    No PRDs
                  </p>
                )}
                {grouped[col.key].map((doc) => (
                  <PrdCard key={doc.slug} doc={doc} onOpenFile={onOpenFile} />
                ))}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

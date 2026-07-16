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
  Search,
  X,
  FolderGit2,
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

function PrdCard({ doc, project, onOpenFile }: { doc: PrdDoc; project?: string; onOpenFile: (path: string) => void }) {
  const [expanded, setExpanded] = useState(false);
  const col = classifyStatus(doc.status);
  const progress = doc.totalPhases > 0 ? (doc.donePhases / doc.totalPhases) * 100 : 0;

  return (
    <div className="bg-white dark:bg-[#2d2f34] rounded-lg border border-neutral-200 dark:border-neutral-700 shadow-sm hover:shadow-md transition-shadow">
      <div className="p-3">
        {project && (
          <div className="mb-1.5 flex items-center gap-1 text-[8px] font-mono uppercase tracking-wider text-indigo-500 dark:text-indigo-400">
            <FolderGit2 className="h-2.5 w-2.5 shrink-0" />
            <span className="truncate" title={project}>{project}</span>
          </div>
        )}
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

// The project a PRD belongs to = the folder that contains its `docs/` dir.
// e.g. /Users/x/Documents/claude-control-plane/docs/prd-vault-rag.md → claude-control-plane
function projectOf(prdPath: string): string {
  const parts = prdPath.split("/").filter(Boolean);
  const docsIdx = parts.lastIndexOf("docs");
  if (docsIdx > 0) return parts[docsIdx - 1];
  return parts[parts.length - 2] ?? "—";
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
  const [query, setQuery] = useState("");
  const [projectFilter, setProjectFilter] = useState<string>("all");

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

  // Distinct projects present, for the project filter pills.
  const projects = [...new Set(docs.map((d) => projectOf(d.prdPath)))].sort();
  // Drop a stale project filter if its project is no longer present.
  useEffect(() => {
    if (projectFilter !== "all" && !projects.includes(projectFilter)) setProjectFilter("all");
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projects.join("|")]);

  const q = query.trim().toLowerCase();
  const filtered = docs.filter((d) => {
    if (projectFilter !== "all" && projectOf(d.prdPath) !== projectFilter) return false;
    if (!q) return true;
    return (
      d.name.toLowerCase().includes(q) ||
      d.slug.toLowerCase().includes(q) ||
      d.status.toLowerCase().includes(q) ||
      (d.owner ?? "").toLowerCase().includes(q) ||
      projectOf(d.prdPath).toLowerCase().includes(q)
    );
  });

  const grouped: Record<Column, PrdDoc[]> = { draft: [], active: [], review: [], done: [] };
  for (const doc of filtered) {
    grouped[classifyStatus(doc.status)].push(doc);
  }

  return (
    <div className="flex-1 flex flex-col overflow-hidden bg-neutral-100 dark:bg-[#1a1b1e]">
      {/* Header */}
      <div className="px-6 py-3 border-b border-neutral-200 dark:border-[#3d3f44] bg-white dark:bg-[#1e1f23] space-y-2.5">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Layers className="h-4 w-4 text-indigo-500" />
            <h2 className="text-sm font-bold text-neutral-800 dark:text-neutral-100">PRD Board</h2>
            <span className="text-[10px] font-mono text-neutral-400 bg-neutral-100 dark:bg-neutral-800 px-2 py-0.5 rounded">
              {filtered.length}{filtered.length !== docs.length ? `/${docs.length}` : ""} docs
            </span>
          </div>
          <div className="flex items-center gap-3">
            {/* Search */}
            <div className="relative">
              <Search className="h-3 w-3 text-neutral-400 absolute left-2 top-1/2 -translate-y-1/2" />
              <input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Search PRDs…"
                className="w-52 pl-7 pr-6 py-1 text-[11px] font-mono rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 focus:outline-none focus:border-indigo-400"
              />
              {query && (
                <button type="button" onClick={() => setQuery("")} className="absolute right-1.5 top-1/2 -translate-y-1/2 text-neutral-400 hover:text-neutral-600 cursor-pointer">
                  <X className="h-3 w-3" />
                </button>
              )}
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
        </div>

        {/* Project filter pills */}
        {projects.length > 1 && (
          <div className="flex items-center gap-1.5 flex-wrap">
            <FolderGit2 className="h-3 w-3 text-neutral-400 shrink-0" />
            <button
              type="button"
              onClick={() => setProjectFilter("all")}
              className={`px-2 py-0.5 rounded-full text-[10px] font-mono font-semibold cursor-pointer transition-colors ${
                projectFilter === "all"
                  ? "bg-indigo-600 text-white"
                  : "bg-neutral-100 dark:bg-neutral-800 text-neutral-500 dark:text-neutral-400 hover:bg-neutral-200 dark:hover:bg-neutral-700"
              }`}
            >
              All
            </button>
            {projects.map((p) => (
              <button
                key={p}
                type="button"
                onClick={() => setProjectFilter(p)}
                className={`px-2 py-0.5 rounded-full text-[10px] font-mono font-semibold cursor-pointer transition-colors ${
                  projectFilter === p
                    ? "bg-indigo-600 text-white"
                    : "bg-neutral-100 dark:bg-neutral-800 text-neutral-500 dark:text-neutral-400 hover:bg-neutral-200 dark:hover:bg-neutral-700"
                }`}
              >
                {p}
              </button>
            ))}
          </div>
        )}
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
                  <PrdCard
                    key={doc.prdPath}
                    doc={doc}
                    project={projects.length > 1 ? projectOf(doc.prdPath) : undefined}
                    onOpenFile={onOpenFile}
                  />
                ))}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { relTime, shortCwd } from "../lib/format";
import {
  RefreshCw,
  GitBranch,
  FolderGit2,
  ArrowUp,
  GitMerge,
  Plus,
  X,
  Clock,
  Trash2,
  GitCommit,
  FileDiff,
} from "lucide-react";

interface BranchCommit {
  hash: string;
  subject: string;
  author: string;
  relDate: string;
}

interface BranchDetail {
  name: string;
  base: string;
  ahead: number;
  behind: number;
  commits: BranchCommit[];
  changedFiles: string[];
}

interface ProjectStatus {
  path: string;
  name: string;
  isGit: boolean;
  branch: string;
  base: string;
  ahead: number;
  behind: number;
  dirty: number;
  changed: number;
  lastActivity: number;
}

interface MergeCheck {
  clean: boolean;
  detail: string;
}

const QKEY = "apex.mergeQueue";

/** Push/Merge Queue: live PM status per tracked project + a FIFO queue with
 *  trial-merge checks and operator-confirmed Push / local Merge actions. */
export default function QueuePage({
  paths,
  worktrees = [],
  refreshSignal,
  onWorktreeRemoved,
  inspect,
  onClearInspect,
}: {
  paths: string[];
  worktrees?: string[];
  refreshSignal?: number;
  onWorktreeRemoved?: (path: string) => void;
  /** A branch picked in the sidebar to inspect (commits / diff vs base). */
  inspect?: { repo: string; name: string } | null;
  onClearInspect?: () => void;
}) {
  const [projects, setProjects] = useState<ProjectStatus[]>([]);
  const [loading, setLoading] = useState(false);
  const [queue, setQueue] = useState<string[]>(() => {
    try {
      return JSON.parse(localStorage.getItem(QKEY) || "[]");
    } catch {
      return [];
    }
  });
  const [checks, setChecks] = useState<Record<string, MergeCheck>>({});
  const [confirming, setConfirming] = useState<string>("");
  const [toast, setToast] = useState<string>("");
  const [detail, setDetail] = useState<BranchDetail | null>(null);
  const [detailErr, setDetailErr] = useState<string>("");

  // Load the inspected branch's detail (commits + diff vs base) from git.
  useEffect(() => {
    if (!inspect) {
      setDetail(null);
      setDetailErr("");
      return;
    }
    let active = true;
    setDetail(null);
    setDetailErr("");
    invoke<BranchDetail>("branch_detail", { repo: inspect.repo, branch: inspect.name })
      .then((d) => {
        if (active) setDetail(d);
      })
      .catch((e) => {
        if (active) setDetailErr(String(e));
      });
    return () => {
      active = false;
    };
  }, [inspect, refreshSignal]);

  useEffect(() => {
    localStorage.setItem(QKEY, JSON.stringify(queue));
  }, [queue]);

  const refresh = useCallback(async () => {
    if (!paths.length) {
      setProjects([]);
      return;
    }
    setLoading(true);
    try {
      setProjects(await invoke<ProjectStatus[]>("pm_status", { paths }));
    } catch (e) {
      console.warn("[apex] pm_status failed:", e);
    } finally {
      setLoading(false);
    }
  }, [paths]);

  useEffect(() => {
    void refresh();
    const t = setInterval(() => {
      if (!document.hidden) void refresh();
    }, 5000);
    return () => clearInterval(t);
  }, [refresh]);

  // Immediate refresh on a real filesystem change (notify watcher).
  useEffect(() => {
    if (refreshSignal !== undefined) void refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refreshSignal]);

  // Trial-merge check for queued git projects.
  useEffect(() => {
    queue.forEach((p) => {
      const proj = projects.find((x) => x.path === p);
      if (!proj?.isGit) return;
      invoke<MergeCheck>("pm_check_merge", { repo: p, branch: proj.branch })
        .then((c) => setChecks((prev) => ({ ...prev, [p]: c })))
        .catch(() => {});
    });
  }, [queue, projects]);

  const inQueue = (p: string) => queue.includes(p);
  const toggle = (p: string) =>
    setQueue((q) => (q.includes(p) ? q.filter((x) => x !== p) : [...q, p]));

  const act = async (kind: "push" | "merge", proj: ProjectStatus) => {
    const id = `${proj.path}:${kind}`;
    if (confirming !== id) {
      setConfirming(id);
      return;
    }
    setConfirming("");
    setToast(`${kind}: ${proj.name}…`);
    try {
      const cmd = kind === "push" ? "pm_push" : "pm_merge";
      const res = await invoke<string>(cmd, { repo: proj.path, branch: proj.branch });
      // After a successful merge, auto-clean the now-redundant worktree.
      if (kind === "merge" && worktrees.includes(proj.path)) {
        await doRemoveWt(proj.path);
        setToast(`${res} · worktree removed`);
      } else {
        setToast(res);
      }
      void refresh();
    } catch (e) {
      setToast(`error: ${String(e)}`);
    }
  };

  const doRemoveWt = async (path: string) => {
    try {
      const res = await invoke<string>("remove_worktree", { worktree: path });
      setToast(res);
      setQueue((q) => q.filter((x) => x !== path));
      onWorktreeRemoved?.(path);
      void refresh();
    } catch (e) {
      setToast(`error: ${String(e)}`);
    }
  };

  const removeWt = async (path: string) => {
    const id = `${path}:removewt`;
    if (confirming !== id) {
      setConfirming(id);
      return;
    }
    setConfirming("");
    await doRemoveWt(path);
  };

  const git = projects.filter((p) => p.isGit);
  const queued = queue
    .map((p) => projects.find((x) => x.path === p))
    .filter((p): p is ProjectStatus => !!p);

  return (
    <div className="flex-1 overflow-y-auto bg-neutral-50/50 dark:bg-[#25272b] p-5">
      <div className="flex items-center justify-between mb-4">
        <h1 className="text-sm font-display font-bold text-neutral-800 dark:text-neutral-200 flex items-center gap-2">
          <GitMerge className="h-4 w-4 text-indigo-500 dark:text-indigo-400" /> Push / Merge Queue
        </h1>
        <button
          type="button"
          onClick={() => void refresh()}
          className="flex items-center gap-1.5 text-[11px] font-mono px-2 py-1 rounded border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-[#25272b] hover:bg-neutral-100 dark:hover:bg-neutral-800 text-neutral-600 dark:text-neutral-400 cursor-pointer"
        >
          <RefreshCw className={`h-3 w-3 ${loading ? "animate-spin" : ""}`} /> Refresh
        </button>
      </div>

      {toast && (
        <div className="mb-3 text-[11px] font-mono px-3 py-2 rounded border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-[#25272b] text-neutral-700 dark:text-neutral-300 break-words">
          {toast}
        </div>
      )}

      {/* BRANCH DETAIL — shown when a branch is clicked in the sidebar */}
      {inspect && (
        <section className="mb-6">
          <div className="bg-white dark:bg-[#25272b] border border-indigo-200 dark:border-indigo-800 rounded-lg shadow-sm overflow-hidden">
            <div className="flex items-center justify-between gap-2 px-3 py-2 bg-indigo-50/60 dark:bg-neutral-700/50 border-b border-indigo-100 dark:border-neutral-600">
              <span className="font-mono text-xs font-bold text-indigo-800 dark:text-white flex items-center gap-1.5 min-w-0">
                <GitBranch className="h-3.5 w-3.5 shrink-0" />
                <span className="truncate">{inspect.name}</span>
              </span>
              <div className="flex items-center gap-2 shrink-0">
                {detail && (
                  <span className="text-[10px] font-mono text-neutral-500 dark:text-neutral-400">
                    vs <span className="font-semibold">{detail.base}</span> · ↑{detail.ahead} ↓{detail.behind}
                  </span>
                )}
                <button
                  type="button"
                  onClick={() => onClearInspect?.()}
                  className="text-neutral-400 dark:text-neutral-500 hover:text-rose-600 dark:hover:text-rose-300 cursor-pointer"
                  title="Close branch detail"
                >
                  <X className="h-3.5 w-3.5" />
                </button>
              </div>
            </div>

            {detailErr ? (
              <div className="px-3 py-3 text-[11px] font-mono text-rose-600 dark:text-red-400">{detailErr}</div>
            ) : !detail ? (
              <div className="px-3 py-3 text-[11px] font-mono text-neutral-400 dark:text-neutral-500">loading…</div>
            ) : (
              <div className="p-3 space-y-3">
                <div>
                  <h3 className="text-[10px] font-mono uppercase tracking-widest font-bold text-neutral-500 dark:text-neutral-400 mb-1.5 flex items-center gap-1">
                    <GitCommit className="h-3 w-3" /> Commits ({detail.commits.length})
                  </h3>
                  {detail.commits.length === 0 ? (
                    <div className="text-[11px] font-mono text-neutral-400 dark:text-neutral-500">
                      No commits ahead of {detail.base}.
                    </div>
                  ) : (
                    <div className="space-y-1">
                      {detail.commits.map((c) => (
                        <div key={c.hash} className="flex items-start gap-2 text-[11px] font-mono">
                          <span className="text-indigo-600 dark:text-indigo-400 font-semibold shrink-0">{c.hash}</span>
                          <span className="text-neutral-700 dark:text-neutral-300 truncate flex-1" title={c.subject}>
                            {c.subject}
                          </span>
                          <span className="text-neutral-400 dark:text-neutral-500 shrink-0">{c.author} · {c.relDate}</span>
                        </div>
                      ))}
                    </div>
                  )}
                </div>

                {detail.changedFiles.length > 0 && (
                  <div>
                    <h3 className="text-[10px] font-mono uppercase tracking-widest font-bold text-neutral-500 dark:text-neutral-400 mb-1.5 flex items-center gap-1">
                      <FileDiff className="h-3 w-3" /> Changed files ({detail.changedFiles.length})
                    </h3>
                    <div className="space-y-0.5">
                      {detail.changedFiles.map((f) => (
                        <div key={f} className="text-[10px] font-mono text-neutral-600 dark:text-neutral-400 truncate" title={f}>
                          {f}
                        </div>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>
        </section>
      )}

      {/* QUEUE */}
      <section className="mb-6">
        <h2 className="text-[10px] font-mono uppercase tracking-widest font-bold text-indigo-600 dark:text-indigo-400 mb-2">
          Queue ({queued.length})
        </h2>
        {queued.length === 0 && (
          <div className="text-[11px] font-mono text-neutral-400 dark:text-neutral-500 py-2">
            Queue is empty — add a project below.
          </div>
        )}
        <div className="space-y-1.5">
          {queued.map((p) => {
            const chk = checks[p.path];
            return (
              <div
                key={p.path}
                className="bg-white dark:bg-[#25272b] border border-neutral-200 dark:border-neutral-700 rounded-lg p-3 shadow-sm"
              >
                <div className="flex items-center justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <span className="font-mono text-xs font-bold text-neutral-900 dark:text-neutral-100 truncate">
                        {p.name}
                      </span>
                      <span className="text-[10px] font-mono text-neutral-500 dark:text-neutral-400 flex items-center gap-1">
                        <GitBranch className="h-3 w-3" /> {p.branch} → {p.base}
                      </span>
                      {chk ? (
                        <span
                          className={`text-[8px] font-mono font-bold px-1.5 py-0.5 rounded border uppercase ${
                            chk.clean
                              ? "bg-emerald-50 dark:bg-green-900/30 text-emerald-700 dark:text-green-400 border-emerald-200 dark:border-green-700"
                              : "bg-rose-50 dark:bg-red-900/30 text-rose-700 dark:text-red-400 border-rose-200 dark:border-red-700"
                          }`}
                          title={chk.detail}
                        >
                          {chk.clean ? "ready" : "conflict"}
                        </span>
                      ) : (
                        <span className="text-[8px] font-mono text-neutral-400 dark:text-neutral-500">checking…</span>
                      )}
                    </div>
                    <div className="flex items-center gap-3 mt-1 text-[10px] font-mono text-neutral-500 dark:text-neutral-400">
                      <span>↑{p.ahead} ↓{p.behind}</span>
                      <span>{p.changed} changed</span>
                      {p.dirty > 0 && <span className="text-amber-600 dark:text-amber-400">{p.dirty} uncommitted</span>}
                    </div>
                  </div>
                  <div className="flex items-center gap-1.5 shrink-0">
                    <button
                      type="button"
                      onClick={() => void act("push", p)}
                      className={`flex items-center gap-1 text-[11px] font-mono font-semibold px-2 py-1 rounded border cursor-pointer ${
                        confirming === `${p.path}:push`
                          ? "border-rose-300 dark:border-red-700 bg-rose-50 dark:bg-red-900/30 text-rose-700 dark:text-red-400"
                          : "border-indigo-700 dark:border-indigo-400 bg-indigo-600 dark:bg-indigo-500 text-white hover:bg-indigo-700 dark:hover:bg-indigo-400 shadow-sm"
                      }`}
                    >
                      <ArrowUp className="h-3 w-3" />
                      {confirming === `${p.path}:push` ? "Confirm push" : "Push"}
                    </button>
                    <button
                      type="button"
                      onClick={() => void act("merge", p)}
                      className={`flex items-center gap-1 text-[11px] font-mono font-semibold px-2 py-1 rounded border cursor-pointer ${
                        confirming === `${p.path}:merge`
                          ? "border-rose-300 dark:border-red-700 bg-rose-50 dark:bg-red-900/30 text-rose-700 dark:text-red-400"
                          : "border-neutral-200 dark:border-neutral-700 bg-white dark:bg-[#25272b] text-neutral-700 dark:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-700"
                      }`}
                      title={`Merge ${p.branch} into ${p.base} (local)`}
                    >
                      <GitMerge className="h-3 w-3" />
                      {confirming === `${p.path}:merge` ? "Confirm merge" : "Merge"}
                    </button>
                    <button
                      type="button"
                      onClick={() => toggle(p.path)}
                      className="text-neutral-400 dark:text-neutral-500 hover:text-rose-600 dark:hover:text-rose-300 cursor-pointer"
                      title="Remove from queue"
                    >
                      <X className="h-3.5 w-3.5" />
                    </button>
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </section>

      {/* TRACKED PROJECTS */}
      <section>
        <h2 className="text-[10px] font-mono uppercase tracking-widest font-bold text-neutral-500 dark:text-neutral-400 mb-2">
          Tracked projects ({git.length})
        </h2>
        {paths.length === 0 && (
          <div className="text-[11px] font-mono text-neutral-400 dark:text-neutral-500 py-2">
            No projects — add a workspace (+ Workspace) on the Control page.
          </div>
        )}
        <div className="space-y-1.5">
          {git.map((p) => (
            <div
              key={p.path}
              className="bg-white dark:bg-[#25272b] border border-neutral-200 dark:border-neutral-700 rounded-lg p-3 flex items-center justify-between gap-3 shadow-sm"
            >
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <span className="font-mono text-xs font-bold text-neutral-900 dark:text-neutral-100 truncate">
                    {p.name}
                  </span>
                  <span className="text-[10px] font-mono text-neutral-500 dark:text-neutral-400 flex items-center gap-1">
                    <GitBranch className="h-3 w-3" /> {p.branch}
                  </span>
                </div>
                <div className="flex items-center gap-3 mt-1 text-[10px] font-mono text-neutral-500 dark:text-neutral-400">
                  <span className="flex items-center gap-1 truncate max-w-[280px]">
                    <FolderGit2 className="h-3 w-3" /> {shortCwd(p.path)}
                  </span>
                  <span>↑{p.ahead} ↓{p.behind}</span>
                  <span>{p.changed} changed</span>
                  <span className="flex items-center gap-0.5">
                    <Clock className="h-2.5 w-2.5" /> {relTime(p.lastActivity)}
                  </span>
                </div>
              </div>
              <div className="shrink-0 flex items-center gap-1.5">
                <button
                  type="button"
                  onClick={() => toggle(p.path)}
                  disabled={inQueue(p.path)}
                  className="flex items-center gap-1 text-[11px] font-mono font-semibold px-2.5 py-1 rounded border border-indigo-700 dark:border-indigo-400 bg-indigo-600 dark:bg-indigo-500 text-white hover:bg-indigo-700 dark:hover:bg-indigo-400 shadow-sm disabled:opacity-40 disabled:cursor-default cursor-pointer"
                >
                  <Plus className="h-3 w-3" /> {inQueue(p.path) ? "Queued" : "Add to queue"}
                </button>
                {worktrees.includes(p.path) && (
                  <button
                    type="button"
                    onClick={() => void removeWt(p.path)}
                    className={`flex items-center gap-1 text-[11px] font-mono font-semibold px-2 py-1 rounded border cursor-pointer ${
                      confirming === `${p.path}:removewt`
                        ? "border-rose-300 dark:border-red-700 bg-rose-50 dark:bg-red-900/30 text-rose-700 dark:text-red-400"
                        : "border-neutral-200 dark:border-neutral-700 bg-white dark:bg-[#25272b] text-neutral-500 dark:text-neutral-400 hover:text-rose-600 dark:hover:text-red-400 hover:bg-neutral-100 dark:hover:bg-neutral-700"
                    }`}
                    title="Remove worktree (deletes the folder)"
                  >
                    <Trash2 className="h-3 w-3" />
                    {confirming === `${p.path}:removewt` ? "Confirm" : ""}
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}

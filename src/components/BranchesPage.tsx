import type React from "react";
import BranchDAG from "./BranchDAG";
import { AlertTriangle, GitBranch, GitPullRequest, ShieldCheck, Zap } from "lucide-react";

// The branch topology view: what used to be the right panel's "Branch" tab. Reachable
// from the command palette ("Branches") now that the redesign has no right sidebar.

type DagProps = React.ComponentProps<typeof BranchDAG>;
type BranchAgent = DagProps["agents"][number];
type Branch = DagProps["branchList"][number];

function renderSyncStatusBadge(status: string) {
    switch (status) {
      case "synced":
        return (
          <span className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[9px] font-mono font-bold bg-emerald-50 dark:bg-green-900/30 text-emerald-700 dark:text-green-400 border border-emerald-250 dark:border-green-700 shrink-0">
            <span className="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse shrink-0" />
            <span>SYNCED</span>
          </span>
        );
      case "ahead":
        return (
          <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[9px] font-mono font-bold bg-indigo-50 dark:bg-indigo-900/30 text-indigo-700 dark:text-indigo-400 border border-indigo-200 dark:border-indigo-600 shrink-0">
            <span className="w-1.5 h-1.5 rounded-full bg-indigo-500 shrink-0" />
            <span>AHEAD</span>
          </span>
        );
      case "diverged":
        return (
          <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[9px] font-mono font-bold bg-amber-50 dark:bg-amber-900/25 text-amber-700 dark:text-amber-400 border border-amber-250 dark:border-amber-600 shrink-0 animate-pulse">
            <AlertTriangle className="h-2.5 w-2.5 text-amber-500 dark:text-amber-400 shrink-0" />
            <span>DIVERGED</span>
          </span>
        );
      case "conflict":
        return (
          <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[9px] font-mono font-bold bg-rose-50 dark:bg-red-900/30 text-rose-750 dark:text-red-400 border border-rose-250 dark:border-red-700 shrink-0 animate-bounce">
            <AlertTriangle className="h-2.5 w-2.5 text-rose-500 dark:text-red-400 shrink-0" />
            <span>CONFLICT</span>
          </span>
        );
      default:
        return (
          <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[9px] font-mono font-bold bg-neutral-55 dark:bg-neutral-900 bg-neutral-100 dark:bg-neutral-800 text-neutral-600 dark:text-neutral-400 border border-neutral-250 dark:border-neutral-700 shrink-0">
            <span className="w-1.5 h-1.5 rounded-full bg-neutral-300 dark:bg-neutral-600 shrink-0" />
            <span>{status.toUpperCase()}</span>
          </span>
        );
    }
  }

export interface BranchesPageProps {
  repoList: string[];
  branchRepo: string;
  onSelectRepo: (repo: string) => void;
  branchMap: Record<string, Branch[]>;
  branchList: Branch[];
  agents: BranchAgent[];
  selectedAgentId: string;
  onSelectAgent: (id: string) => void;
  /** Open this branch's detail card on the Queue page. */
  onInspect: (branchName: string) => void;
}

export default function BranchesPage({ repoList, branchRepo, onSelectRepo, branchMap, branchList, agents, selectedAgentId, onSelectAgent, onInspect }: BranchesPageProps) {
  return (
    <div className="flex-1 overflow-y-auto custom-scrollbar p-3 space-y-4 max-w-[720px] mx-auto w-full">

            {/* Multi-repo selector */}
            {repoList.length > 1 && (
              <div className="flex items-center gap-2">
                <GitBranch className="h-3.5 w-3.5 text-indigo-500 dark:text-indigo-400 shrink-0" />
                <select
                  value={branchRepo}
                  onChange={(e) => onSelectRepo(e.target.value)}
                  className="flex-1 text-[10px] font-mono bg-white dark:bg-[var(--bg-control)] border border-neutral-200 dark:border-neutral-700 rounded px-2 py-1 text-neutral-700 dark:text-neutral-300 cursor-pointer"
                >
                  {repoList.map((r) => (
                    <option key={r} value={r}>
                      {r.split("/").filter(Boolean).slice(-2).join("/")}
                      {" "}({(branchMap[r] ?? []).length})
                    </option>
                  ))}
                </select>
              </div>
            )}

            {/* Visual DAG Representation showing commit lineage / status mapping */}
            <BranchDAG
              branchList={branchList}
              agents={agents}
              selectedAgentId={selectedAgentId}
              setSelectedAgentId={onSelectAgent}
              setTerminalHistory={() => {}}
            />
            
            {/* CATEGORY 1: PRODUCTION / RELEASE ENVS (PRD) */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-[10px] font-mono uppercase tracking-widest font-bold text-emerald-600 dark:text-green-400 flex items-center gap-1">
                  <ShieldCheck className="h-3 w-3" /> Production Branches (PRD)
                </span>
                <span className="text-[9px] font-mono bg-neutral-100 dark:bg-neutral-800 text-emerald-700 dark:text-green-400 px-1 border border-neutral-250 dark:border-neutral-700 rounded font-semibold">
                  {branchList.filter(b => b.type === "PRD").length}
                </span>
              </div>

              <div className="space-y-1.5">
                {branchList
                  .filter((b) => b.type === "PRD")
                  .map((branch) => (
                    <div
                      key={branch.name}
                      onClick={() => {
                        onInspect(branch.name);
                      }}
                      className="p-2 border border-emerald-100 dark:border-green-900 bg-emerald-50/10 dark:bg-green-900/20 hover:border-emerald-200 dark:hover:border-green-800 rounded cursor-pointer transition-colors shadow-sm"
                    >
                      <div className="flex items-start justify-between gap-1.5">
                        <span className="font-mono text-xs font-bold text-emerald-800 dark:text-green-400 truncate max-w-[140px]">
                          {branch.name}
                        </span>
                        <div className="flex items-center gap-1.5 shrink-0">
                          {renderSyncStatusBadge(branch.status || "synced")}
                        </div>
                      </div>
                      <p className="mt-1 text-[10px] text-neutral-600 dark:text-neutral-400 truncate">
                        {branch.lastCommit}
                      </p>
                      <div className="mt-1.5 flex items-center justify-between text-[9px] font-mono text-neutral-500 dark:text-neutral-400">
                        <span className="truncate">{branch.author}</span>
                      </div>
                    </div>
                  ))}
              </div>
            </div>

            {/* CATEGORY 2: WORK-IN-PROGRESS (WIP) */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-[10px] font-mono uppercase tracking-widest font-semibold text-amber-600 dark:text-amber-400 flex items-center gap-1">
                  <Zap className="h-3 w-3 animate-pulse" /> Active Workspace WIP
                </span>
                <span className="text-[9px] font-mono bg-neutral-100 dark:bg-neutral-800 text-amber-700 dark:text-amber-400 px-1 border border-neutral-250 dark:border-neutral-700 rounded font-semibold">
                  {branchList.filter(b => b.type === "WIP").length}
                </span>
              </div>

              <div className="space-y-1.5">
                {branchList
                  .filter((b) => b.type === "WIP")
                  .map((branch) => {
                    const agentObj = agents.find((a) => a.id === branch.associatedAgent);
                    return (
                      <div
                        id={`branch-row-${branch.name.replace(/\//g, "-")}`}
                        key={branch.name}
                        onClick={() => {
                          if (agentObj) {
                            onSelectAgent(agentObj.id);
                          }
                          onInspect(branch.name);
                        }}
                        className={`p-2 border rounded cursor-pointer transition-colors shadow-sm ${
                          agentObj?.id === selectedAgentId
                            ? "bg-amber-50/40 dark:bg-amber-900/25 border-amber-500"
                            : "border-neutral-200 dark:border-neutral-700 hover:border-neutral-300 dark:hover:border-neutral-700 bg-[var(--bg-panel)]"
                        }`}
                      >
                        <div className="flex items-start justify-between gap-1.5">
                          <span className="font-mono text-xs font-bold text-neutral-800 dark:text-neutral-200 truncate max-w-[150px]">
                            {branch.name}
                          </span>
                          {renderSyncStatusBadge(branch.status)}
                        </div>
                        
                        <p className="mt-1 text-[10px] text-neutral-650 dark:text-neutral-400 truncate">
                          {branch.lastCommit}
                        </p>

                        {agentObj && (
                          <div className="mt-2 p-1 bg-[var(--bg-control)] rounded border border-neutral-200 dark:border-neutral-700 flex items-center justify-between text-[9px] font-mono text-neutral-600 dark:text-neutral-400">
                            <span className="text-indigo-650 dark:text-indigo-400 font-bold">
                              🤖 {agentObj.name}
                            </span>
                            <span className="text-[8px] uppercase font-bold text-neutral-550 dark:text-neutral-400">{agentObj.status}</span>
                          </div>
                        )}
                      </div>
                    );
                  })}
              </div>
            </div>

            {/* CATEGORY 3: OPEN PENDING / STALE BRANCHES */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-[10px] font-mono uppercase tracking-widest font-bold text-indigo-550 dark:text-indigo-400 flex items-center gap-1">
                  <GitPullRequest className="h-3 w-3" /> Open Pending (PR/stale)
                </span>
                <span className="text-[9px] font-mono bg-neutral-100 dark:bg-neutral-800 text-indigo-700 dark:text-indigo-400 px-1 border border-neutral-250 dark:border-neutral-700 rounded font-semibold">
                  {branchList.filter(b => b.type === "OPEN").length}
                </span>
              </div>

              <div className="space-y-1.5">
                {branchList
                  .filter((b) => b.type === "OPEN")
                  .map((branch) => (
                    <div
                      key={branch.name}
                      onClick={() => {
                        onInspect(branch.name);
                      }}
                      className="p-2 border border-neutral-200 dark:border-neutral-700 bg-[var(--bg-panel)] hover:border-neutral-300 dark:hover:border-neutral-600 rounded cursor-pointer transition-colors shadow-sm"
                    >
                      <div className="flex items-start justify-between gap-1.5">
                        <span className="font-mono text-xs text-neutral-700 dark:text-neutral-300 truncate max-w-[140px]">
                          {branch.name}
                        </span>
                        <div className="flex items-center gap-1.5 shrink-0">
                          {renderSyncStatusBadge(branch.status || "synced")}
                        </div>
                      </div>
                      <p className="mt-1 text-[10px] text-neutral-500 dark:text-neutral-400 truncate">
                        {branch.lastCommit}
                      </p>
                      <div className="mt-1.5 flex items-center justify-between text-[9px] font-mono text-neutral-500 dark:text-neutral-400">
                        <span className="truncate">{branch.author}</span>
                      </div>
                    </div>
                  ))}
              </div>
            </div>

    </div>
  );
}

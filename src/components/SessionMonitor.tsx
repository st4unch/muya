import { useMemo } from "react";
import { Square, SquareX, Plug, Clock } from "lucide-react";

interface AgentSession {
  id: string;
  name: string;
  branch: string;
  worktree: string;
  status: string;
  duration: string;
  modelsUsed?: string; // "background" | "interactive" | ""
  attachable?: boolean;
  attachId?: string;
  pid?: number;
  parentId?: string;
}

function statusDot(s: string) {
  if (s === "working") return "bg-emerald-500";
  if (s === "waiting-for-input") return "bg-amber-500";
  if (s === "stopped") return "bg-rose-500";
  return "bg-neutral-400 dark:bg-neutral-500";
}

function statusLabel(s: string) {
  if (s === "working") return "working";
  if (s === "waiting-for-input") return "waiting";
  if (s === "stopped") return "stopped";
  return "idle";
}

interface TreeNode {
  session: AgentSession;
  children: TreeNode[];
}

function buildTree(agents: AgentSession[]): TreeNode[] {
  const byId = new Map(agents.map((a) => [a.id, { session: a, children: [] as TreeNode[] }]));
  const roots: TreeNode[] = [];
  for (const node of byId.values()) {
    const parentId = node.session.parentId;
    if (parentId && byId.has(parentId)) {
      byId.get(parentId)!.children.push(node);
    } else {
      roots.push(node);
    }
  }
  return roots;
}

function SessionCard({
  a,
  isSelected,
  depth = 0,
  onOpen,
  onKill,
}: {
  a: AgentSession;
  isSelected: boolean;
  depth?: number;
  onOpen: (a: AgentSession) => void;
  onKill: (a: AgentSession) => void;
}) {
  const isBg = a.attachable;

  return (
    <div
      style={{ marginLeft: depth > 0 ? `${depth * 10}px` : undefined }}
      onClick={() => onOpen(a)}
      className={`group relative p-2 rounded border cursor-pointer transition-colors ${
        isSelected
          ? "bg-indigo-50/70 dark:bg-indigo-950/30 border-indigo-200 dark:border-indigo-700"
          : isBg
          ? "bg-[var(--bg-segment-active)] border-indigo-100 dark:border-indigo-900 hover:border-indigo-300 dark:hover:border-indigo-700"
          : "bg-[var(--bg-segment-active)] border-neutral-200 dark:border-neutral-700 hover:border-neutral-300 dark:hover:border-neutral-600"
      }`}
    >
      {depth > 0 && (
        <span className="absolute left-[-10px] top-3 text-neutral-400 dark:text-neutral-600 text-[10px]">└</span>
      )}

      <div className="flex items-start justify-between gap-1.5">
        <div className="flex items-center gap-1.5 min-w-0">
          <span className={`h-1.5 w-1.5 rounded-full shrink-0 mt-0.5 ${statusDot(a.status)}`} />
          <span className="font-mono text-xs font-bold text-neutral-900 dark:text-neutral-100 truncate leading-tight">
            {a.name}
          </span>
        </div>

        <div className="flex items-center gap-1 shrink-0">
          {/* Attach — always visible for background sessions */}
          {isBg && (
            <button
              type="button"
              onClick={(e) => { e.stopPropagation(); onOpen(a); }}
              title={`claude attach ${a.attachId ?? a.id}`}
              className="flex items-center gap-0.5 text-[9px] font-mono font-bold px-1.5 py-0.5 rounded bg-indigo-600 text-white hover:bg-indigo-700 cursor-pointer transition-colors"
            >
              <Plug className="h-2.5 w-2.5" /> Attach
            </button>
          )}
          {/* Stop */}
          <button
            type="button"
            onClick={(e) => { e.stopPropagation(); onKill(a); }}
            className="group/stop text-neutral-300 dark:text-neutral-600 hover:text-rose-600 dark:hover:text-red-400 opacity-0 group-hover:opacity-100 transition-opacity cursor-pointer"
            title="Stop session"
          >
            <Square className="h-3 w-3 group-hover/stop:hidden" />
            <SquareX className="h-3 w-3 hidden group-hover/stop:block" />
          </button>
        </div>
      </div>

      <div className="flex items-center gap-2 mt-0.5 text-[9px] font-mono text-neutral-400 dark:text-neutral-500">
        <span className={`uppercase font-semibold ${
          a.status === "working" ? "text-emerald-600 dark:text-green-400" :
          a.status === "waiting-for-input" ? "text-amber-600 dark:text-amber-400" :
          a.status === "stopped" ? "text-rose-600 dark:text-red-400" : ""
        }`}>{statusLabel(a.status)}</span>
        <span>·</span>
        <span className="truncate">{a.branch === "—" ? (a.worktree.split("/").pop() ?? a.worktree) : a.branch}</span>
        <span className="flex items-center gap-0.5 ml-auto shrink-0">
          <Clock className="h-2.5 w-2.5" /> {a.duration}
        </span>
      </div>
    </div>
  );
}

function renderTree(
  nodes: TreeNode[],
  selectedId: string,
  onOpen: (a: AgentSession) => void,
  onKill: (a: AgentSession) => void,
  depth = 0
): React.ReactNode[] {
  return nodes.flatMap((node) => [
    <SessionCard
      key={node.session.id}
      a={node.session}
      isSelected={node.session.id === selectedId}
      depth={depth}
      onOpen={onOpen}
      onKill={onKill}
    />,
    ...renderTree(node.children, selectedId, onOpen, onKill, depth + 1),
  ]);
}

export default function SessionMonitor({
  agents,
  selectedAgentId,
  onOpen,
  onKill,
}: {
  agents: AgentSession[];
  selectedAgentId: string;
  onOpen: (a: AgentSession) => void;
  onKill: (a: AgentSession) => void;
}) {
  const background = agents.filter((a) => a.attachable);
  const interactive = agents.filter((a) => !a.attachable);

  const bgTree = useMemo(() => buildTree(background), [background]);
  const intTree = useMemo(() => buildTree(interactive), [interactive]);

  return (
    <div className="space-y-3">
      {/* Background agents (from claude agents) */}
      {background.length > 0 && (
        <div>
          <div className="flex items-center gap-1.5 mb-1.5">
            <Plug className="h-2.5 w-2.5 text-indigo-400" />
            <span className="text-[9px] font-mono uppercase tracking-widest font-bold text-indigo-600 dark:text-indigo-400">
              Background agents ({background.length})
            </span>
          </div>
          <div className="space-y-1.5">
            {renderTree(bgTree, selectedAgentId, onOpen, onKill)}
          </div>
        </div>
      )}

      {/* Interactive / other sessions */}
      {interactive.length > 0 && (
        <div>
          <span className="text-[9px] font-mono uppercase tracking-widest font-bold text-neutral-400 dark:text-neutral-500 block mb-1.5">
            Interactive ({interactive.length})
          </span>
          <div className="space-y-1.5">
            {renderTree(intTree, selectedAgentId, onOpen, onKill)}
          </div>
        </div>
      )}

      {agents.length === 0 && (
        <div className="text-[11px] font-mono text-neutral-400 dark:text-neutral-500 py-2">
          No live sessions.
        </div>
      )}

      <div className="pt-1 border-t border-neutral-100 dark:border-neutral-800">
        <span className="text-[8px] font-mono text-neutral-300 dark:text-neutral-600">
          ~/.claude · auto-refresh 3s
        </span>
      </div>
    </div>
  );
}

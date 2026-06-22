import React, { useState } from "react";
import {
  GitBranch,
  GitCommit,
  CheckCircle2,
  AlertTriangle,
  Clock,
  Terminal,
  X,
  Search,
} from "lucide-react";

interface AgentSession {
  id: string;
  name: string;
  branch: string;
  worktree: string;
  status: "working" | "waiting-for-input" | "idle" | "stopped";
  activeTask: string;
  activeFile: string;
  tokensUsed: number;
  modelsUsed: string;
  quotaBurn: number;
  duration: string;
  createdAt: string;
}

interface GitBranchState {
  name: string;
  type: "PRD" | "WIP" | "OPEN";
  lastCommit: string;
  author: string;
  associatedAgent?: string;
  status: "synced" | "ahead" | "diverged" | "conflict";
  parent?: string;
}

interface BranchDAGProps {
  branchList: GitBranchState[];
  agents: AgentSession[];
  selectedAgentId: string;
  setSelectedAgentId: (id: string) => void;
  setTerminalHistory: React.Dispatch<React.SetStateAction<string[]>>;
}

export default function BranchDAG({
  branchList,
  agents,
  selectedAgentId,
  setSelectedAgentId,
  setTerminalHistory
}: BranchDAGProps) {
  const [hoveredNode, setHoveredNode] = useState<string | null>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [activeTab, setActiveTab] = useState<"graph" | "info">("graph");

  // Determine active branch based on active agent
  const selectedAgent = agents.find((a) => a.id === selectedAgentId);
  const activeBranchName = selectedAgent ? selectedAgent.branch : "feature/stripe-webhooks";

  // Build the nodes grid dynamically based on the branch list
  const prdBranches = branchList.filter((b) => b.type === "PRD");
  const wipBranches = branchList.filter((b) => b.type === "WIP");
  const openBranches = branchList.filter((b) => b.type === "OPEN");

  // Filter branches for search highlights
  const highlightedBranches = searchQuery.trim()
    ? branchList
        .filter(
          (b) =>
            b.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
            b.lastCommit.toLowerCase().includes(searchQuery.toLowerCase()) ||
            b.author.toLowerCase().includes(searchQuery.toLowerCase())
        )
        .map((b) => b.name)
    : [];

  // Set up static lanes (X positions)
  const laneWidth = 75;
  const paddingLeft = 35;
  const getX = (type: "PRD" | "WIP" | "OPEN") => {
    if (type === "PRD") return paddingLeft;
    if (type === "WIP") return paddingLeft + laneWidth;
    return paddingLeft + laneWidth * 2;
  };

  // Row spacing (Y positions)
  const rowHeight = 60;
  const paddingTop = 40;

  // Let's layout nodes and remember their coordinates
  const nodes = branchList.map((branch, index) => {
    const x = getX(branch.type);
    // Find index inside its own category to give a clean vertical order
    let offsetIndex = index;
    if (branch.type === "PRD") {
      offsetIndex = prdBranches.findIndex((b) => b.name === branch.name);
    } else if (branch.type === "WIP") {
      offsetIndex = prdBranches.length + wipBranches.findIndex((b) => b.name === branch.name);
    } else {
      offsetIndex =
        prdBranches.length + wipBranches.length + openBranches.findIndex((b) => b.name === branch.name);
    }

    const y = paddingTop + offsetIndex * rowHeight;
    return {
      ...branch,
      x,
      y,
      id: branch.name
    };
  });

  // Root node is hardwired to be 'main'
  const rootNode = nodes.find((n) => n.name === "main") || nodes[0];

  // Connection connections list
  const connections: { fromX: number; fromY: number; toX: number; toY: number; status: string; id: string }[] = [];

  nodes.forEach((node) => {
    // Real lineage: use the branch's computed parent (closest divergence); fall back
    // to the root node when unknown.
    if (node.parent || (node.name !== "main" && node.name !== rootNode.name)) {
      const parentNode =
        (node.parent && nodes.find((n) => n.name === node.parent)) || rootNode;
      if (parentNode.name === node.name) return; // no self-edge

      connections.push({
        id: `${parentNode.name}->${node.name}`,
        fromX: parentNode.x,
        fromY: parentNode.y,
        toX: node.x,
        toY: node.y,
        status: node.status
      });
    }
  });

  const handleNodeClick = (node: any) => {
    // Log the action inside embedded multiplex terminal
    setTerminalHistory((prev) => [
      ...prev,
      `$ git checkout ${node.name}`,
      `[DAG Sync] Switched HEAD reference view inside DAG monitor to '${node.name}'.`,
      node.associatedAgent
        ? `[Supervisor] Synchronizing layout with active session thread '${node.associatedAgent}' (${node.author}).`
        : `[System] Local developer checkout: No background agent session is pending on this tracking branch.`,
      ""
    ]);

    // Focus active agent details if applicable
    if (node.associatedAgent) {
      setSelectedAgentId(node.associatedAgent);
    }
  };

  // Helper colors mapping
  const getNodeColorClass = (branch: GitBranchState, isActive: boolean) => {
    if (isActive) {
      if (branch.type === "PRD") return "fill-emerald-500 stroke-emerald-600 ring-2 ring-emerald-250";
      if (branch.status === "diverged") return "fill-amber-500 stroke-amber-600 ring-2 ring-amber-250";
      return "fill-indigo-500 stroke-indigo-600 ring-2 ring-indigo-250";
    }

    if (branch.type === "PRD") return "fill-emerald-50 dark:fill-emerald-950/40 stroke-emerald-500 hover:fill-emerald-100";
    if (branch.status === "diverged") return "fill-amber-50 dark:fill-amber-950/40 stroke-amber-500 hover:fill-amber-100";
    if (branch.type === "WIP") return "fill-indigo-50 dark:fill-indigo-950/40 stroke-indigo-500 hover:fill-indigo-100";
    return "fill-neutral-50 dark:fill-neutral-900 stroke-neutral-400 dark:stroke-neutral-600 hover:fill-neutral-100";
  };

  const selectedNodeData = nodes.find((n) => n.name === hoveredNode);

  // SVG dimensions
  const svgHeight = paddingTop + nodes.length * rowHeight + 20;

  return (
    <div id="branch-dag-root" className="border border-neutral-200 dark:border-neutral-700 rounded-lg bg-white dark:bg-neutral-900 overflow-hidden shadow-sm flex flex-col">
      <div className="bg-neutral-50 dark:bg-neutral-900 border-b border-neutral-200 dark:border-neutral-700 px-3 py-2 flex items-center justify-between">
        <div className="flex items-center space-x-2">
          <GitBranch className="h-4 w-4 text-indigo-500 dark:text-indigo-400 animate-pulse" />
          <span className="font-mono text-[11px] font-bold text-neutral-800 dark:text-neutral-200 uppercase tracking-tight">
            Branch Topology DAG
          </span>
        </div>
        <div className="flex items-center space-x-1 font-mono text-[10px]">
          <button
            type="button"
            onClick={() => setActiveTab("graph")}
            className={`px-2 py-0.5 rounded transition-colors ${
              activeTab === "graph" ? "bg-indigo-50 dark:bg-indigo-950/40 text-indigo-700 dark:text-indigo-300 font-semibold border border-indigo-150 dark:border-indigo-800" : "text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800"
            }`}
          >
            DAG Graph
          </button>
          <button
            type="button"
            onClick={() => setActiveTab("info")}
            className={`px-2 py-0.5 rounded transition-colors ${
              activeTab === "info" ? "bg-indigo-50 dark:bg-indigo-950/40 text-indigo-700 dark:text-indigo-300 font-semibold border border-indigo-150 dark:border-indigo-800" : "text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800"
            }`}
          >
            Map Details
          </button>
        </div>
      </div>

      <div className="p-2.5 border-b border-auth-split border-neutral-100 dark:border-neutral-800 bg-neutral-50/20 dark:bg-neutral-900">
        <div className="relative">
          <Search className="absolute left-2 top-2 h-3.5 w-3.5 text-neutral-400 dark:text-neutral-500" />
          <input
            type="text"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            placeholder="Search commits, branches, authors..."
            className="w-full bg-white dark:bg-neutral-900 border border-neutral-200 dark:border-neutral-700 rounded px-7 py-1 font-mono text-[10px] text-neutral-800 dark:text-neutral-200 focus:outline-none focus:border-indigo-500 focus:ring-1 focus:ring-indigo-100 placeholder-neutral-400 shadow-inner"
          />
          {searchQuery && (
            <button
              type="button"
              onClick={() => setSearchQuery("")}
              className="absolute right-2 top-2 text-neutral-400 dark:text-neutral-500 hover:text-neutral-600 dark:hover:text-neutral-400"
            >
              <X className="h-3 w-3" />
            </button>
          )}
        </div>
      </div>

      {activeTab === "graph" ? (
        <div className="relative flex-1 min-h-[310px] max-h-[380px] overflow-y-auto overflow-x-hidden bg-neutral-50/10 dark:bg-neutral-900 custom-scrollbar select-none">
          {/* Lane Labels Header inside SVG Area */}
          <div className="absolute top-1 left-0 right-0 px-2 flex justify-between font-mono text-[8px] tracking-wider text-neutral-400 dark:text-neutral-500 font-bold uppercase select-none pointer-events-none">
            <span style={{ transform: "translateX(14px)" }}>PRD Release</span>
            <span style={{ transform: "translateX(-2px)" }}>Workspace WIP</span>
            <span style={{ transform: "translateX(-14px)" }}>Open Stale</span>
          </div>

          <svg width="265" height={svgHeight} className="mx-auto block">
            <defs>
              {/* Radial gradient glow for hover or active nodes */}
              <radialGradient id="glow-indigo" cx="50%" cy="50%" r="50%">
                <stop offset="0%" stopColor="#818cf8" stopOpacity="0.4" />
                <stop offset="100%" stopColor="#818cf8" stopOpacity="0" />
              </radialGradient>
              <radialGradient id="glow-emerald" cx="50%" cy="50%" r="50%">
                <stop offset="0%" stopColor="#34d399" stopOpacity="0.4" />
                <stop offset="100%" stopColor="#34d399" stopOpacity="0" />
              </radialGradient>
            </defs>

            {/* Grid Helper Guidelines indicator */}
            <line x1={getX("PRD")} y1="30" x2={getX("PRD")} y2={svgHeight} strokeWidth="1.5" strokeDasharray="3 3" className="stroke-neutral-200 dark:stroke-neutral-700" />
            <line x1={getX("WIP")} y1="30" x2={getX("WIP")} y2={svgHeight} strokeWidth="1.5" strokeDasharray="3 3" className="stroke-neutral-200 dark:stroke-neutral-700" />
            <line x1={getX("OPEN")} y1="30" x2={getX("OPEN")} y2={svgHeight} strokeWidth="1.5" strokeDasharray="3 3" className="stroke-neutral-200 dark:stroke-neutral-700" />

            {/* Render curved bezier DAG connection paths */}
            {connections.map((conn) => {
              const dx = (conn.toX - conn.fromX) * 0.55;
              // Build standard natural S-curve SVG command
              const pathData = `M ${conn.fromX} ${conn.fromY} C ${conn.fromX + dx} ${conn.fromY}, ${conn.toX - dx} ${conn.toY}, ${conn.toX} ${conn.toY}`;
              const isDiverged = conn.status === "diverged" || conn.status === "conflict";

              return (
                <path
                  key={conn.id}
                  d={pathData}
                  fill="none"
                  strokeWidth="2"
                  strokeDasharray={isDiverged ? "4 4" : "none"}
                  className={`transition-all duration-300 ${
                    isDiverged ? "stroke-amber-500" : "stroke-slate-300 dark:stroke-neutral-600"
                  }`}
                />
              );
            })}

            {/* Outer highlighting ring for Active Selected Branch Node */}
            {nodes.map((node) => {
              const isActive = node.name === activeBranchName;
              if (!isActive) return null;
              return (
                <circle
                  key={`glow-${node.name}`}
                  cx={node.x}
                  cy={node.y}
                  r="14"
                  className={node.type === "PRD" ? "fill-[url(#glow-emerald)]" : "fill-[url(#glow-indigo)]"}
                />
              );
            })}

            {/* Render Nodes dots */}
            {nodes.map((node) => {
              const isActive = node.name === activeBranchName;
              const isSearching = searchQuery.trim() !== "";
              const isFound = highlightedBranches.includes(node.name);
              const isHovered = hoveredNode === node.name;

              return (
                <g
                  key={node.name}
                  className="cursor-pointer group"
                  onClick={() => handleNodeClick(node)}
                  onMouseEnter={() => setHoveredNode(node.name)}
                  onMouseLeave={() => setHoveredNode(null)}
                >
                  {/* Subtle hover background ring */}
                  <circle
                    cx={node.x}
                    cy={node.y}
                    r={isHovered ? "10" : "8"}
                    className="fill-transparent stroke-transparent group-hover:stroke-neutral-200 dark:group-hover:stroke-neutral-700 transition-all duration-150"
                    strokeWidth="1.5"
                  />

                  {/* Core DAG Node circle with custom colors */}
                  <circle
                    cx={node.x}
                    cy={node.y}
                    r={isActive ? "6.5" : "5"}
                    className={`transition-all duration-200 stroke-2 ${getNodeColorClass(node, isActive)} ${
                      isSearching && !isFound ? "opacity-35" : "opacity-100"
                    } ${isSearching && isFound ? "stroke-indigo-600 stroke-3 scale-110" : ""}`}
                  />

                  {/* Label tag helper for node names */}
                  <text
                    x={node.x + (node.type === "OPEN" ? -12 : 12)}
                    y={node.y + 3}
                    textAnchor={node.type === "OPEN" ? "end" : "start"}
                    className={`font-mono text-[9px] font-semibold transition-colors pointer-events-none select-none ${
                      isActive ? "fill-indigo-950 dark:fill-indigo-300 font-bold" : "fill-neutral-500 dark:fill-neutral-400 hover:fill-neutral-900 dark:hover:fill-neutral-100"
                    } ${isSearching && !isFound ? "opacity-30" : "opacity-100"}`}
                  >
                    {node.name.length > 20 ? `${node.name.slice(0, 18)}...` : node.name}
                  </text>
                </g>
              );
            })}
          </svg>

          {/* Absolute Hover state tooltip box */}
          {selectedNodeData && (
            <div className="absolute bottom-2 left-2 right-2 p-3 bg-white dark:bg-neutral-900 border border-neutral-200 dark:border-neutral-700 rounded-md shadow-lg pointer-events-none z-10 animate-in fade-in slide-in-from-bottom-1 duration-150">
              <div className="flex items-center justify-between border-b border-neutral-100 dark:border-neutral-800 pb-1 mb-1.5">
                <span className="font-mono text-[10px] font-bold text-neutral-800 dark:text-neutral-200 truncate pr-2">
                  🌿 {selectedNodeData.name}
                </span>
                <span
                  className={`text-[8px] font-mono px-1 py-0.2 rounded uppercase font-bold shrink-0 ${
                    selectedNodeData.type === "PRD"
                      ? "bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300"
                      : selectedNodeData.status === "diverged"
                      ? "bg-amber-50 dark:bg-amber-950/40 text-amber-700 dark:text-amber-300 animate-pulse"
                      : "bg-indigo-50 dark:bg-indigo-950/40 text-indigo-700 dark:text-indigo-300"
                  }`}
                >
                  {selectedNodeData.type} - {selectedNodeData.status}
                </span>
              </div>
              <p className="text-[10px] font-mono text-neutral-700 dark:text-neutral-300 leading-tight italic truncate">
                "{selectedNodeData.lastCommit}"
              </p>
              <div className="mt-1.5 flex items-center justify-between text-[8px] font-mono text-neutral-400 dark:text-neutral-500 border-t border-neutral-50 dark:border-neutral-800 pt-1">
                <span>By: {selectedNodeData.author}</span>
                <span>Click to checkout PTY</span>
              </div>
            </div>
          )}
        </div>
      ) : (
        <div className="border-t border-neutral-100 dark:border-neutral-800 bg-white dark:bg-neutral-900 overflow-y-auto max-h-[380px]">
          {/* Stats row */}
          <div className="grid grid-cols-3 divide-x divide-neutral-100 dark:divide-neutral-800 text-center font-mono text-[9px] border-b border-neutral-100 dark:border-neutral-800">
            <div className="py-2">
              <strong className="block text-neutral-800 dark:text-neutral-200 text-xs">{branchList.length}</strong>
              <span className="text-neutral-400 dark:text-neutral-500 uppercase">Branches</span>
            </div>
            <div className="py-2">
              <strong className="block text-amber-500 dark:text-amber-400 text-xs">
                {branchList.filter(b => b.status === "ahead" || b.status === "diverged").length}
              </strong>
              <span className="text-neutral-400 dark:text-neutral-500 uppercase">Ahead</span>
            </div>
            <div className="py-2">
              <strong className="block text-rose-500 dark:text-rose-400 text-xs">
                {branchList.filter(b => b.status === "conflict").length}
              </strong>
              <span className="text-neutral-400 dark:text-neutral-500 uppercase">Conflict</span>
            </div>
          </div>

          {/* Branch list */}
          <div className="divide-y divide-neutral-50 dark:divide-neutral-800/60">
            {branchList.length === 0 && (
              <div className="p-4 text-center text-[10px] text-neutral-400 dark:text-neutral-500 font-mono">No branches</div>
            )}
            {branchList.map((b) => {
              const agent = agents.find(a => a.branch === b.name);
              const statusColor =
                b.status === "conflict"  ? "text-rose-500 dark:text-rose-400 bg-rose-50 dark:bg-rose-900/20" :
                b.status === "diverged"  ? "text-orange-500 dark:text-orange-400 bg-orange-50 dark:bg-orange-900/20" :
                b.status === "ahead"     ? "text-amber-600 dark:text-amber-400 bg-amber-50 dark:bg-amber-900/20" :
                                           "text-emerald-600 dark:text-emerald-400 bg-emerald-50 dark:bg-emerald-900/20";
              return (
                <div key={b.name} className={`px-3 py-2 font-mono text-[10px] hover:bg-neutral-50 dark:hover:bg-neutral-800/40 cursor-default ${b.name === activeBranchName ? "bg-indigo-50/60 dark:bg-indigo-900/10" : ""}`}>
                  <div className="flex items-center gap-1.5 min-w-0">
                    <GitBranch className="h-3 w-3 text-neutral-400 dark:text-neutral-500 shrink-0" />
                    <span className="truncate text-neutral-800 dark:text-neutral-200 font-semibold flex-1 min-w-0">{b.name}</span>
                    <span className={`shrink-0 px-1 py-0.5 rounded text-[8px] font-bold uppercase ${statusColor}`}>{b.status}</span>
                  </div>
                  <div className="mt-0.5 flex items-center gap-2 text-neutral-400 dark:text-neutral-500 pl-4.5">
                    <GitCommit className="h-2.5 w-2.5 shrink-0" />
                    <span className="truncate">{b.lastCommit}</span>
                    {agent && (
                      <span className="shrink-0 flex items-center gap-0.5 text-indigo-500 dark:text-indigo-400">
                        <Terminal className="h-2.5 w-2.5" />{agent.name}
                      </span>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Legend Tray footer */}
      <div className="bg-neutral-50 dark:bg-neutral-900 border-t border-neutral-200 dark:border-neutral-700 p-2 flex items-center justify-between font-mono text-[8px] text-neutral-400 dark:text-neutral-500 uppercase select-none">
        <div className="flex items-center space-x-1">
          <span className="w-1.5 h-1.5 rounded-full bg-emerald-500"></span>
          <span>Deployable</span>
        </div>
        <div className="flex items-center space-x-1">
          <span className="w-1.5 h-1.5 rounded-full bg-indigo-500"></span>
          <span>Drafting</span>
        </div>
        <div className="flex items-center space-x-1">
          <span className="w-1.5 h-1.5 rounded-full bg-amber-500"></span>
          <span>Conflict / Ahead</span>
        </div>
      </div>
    </div>
  );
}

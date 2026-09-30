// Created by Claude — Classification: INTERNAL
//
// Left agent panel on Control (PROMPT.md §3). Groups agents into
// WAITING FOR YOU / WORKING / IDLE (empty groups hidden), filters via the
// segmented control, and supports HTML5 drag-and-drop reordering + ⌘1–7.

import { useEffect, useRef, useState } from "react";
import type { AgentStatus, AgentVM } from "./types";

export type AgentFilter = "all" | "waiting" | "working";

export interface AgentListProps {
  agents: AgentVM[];
  selectedKey: string | null;
  filter: AgentFilter;
  onFilterChange: (filter: AgentFilter) => void;
  onSelectAgent: (key: string) => void;
  onNewAgent: () => void;
  onReorder: (fromKey: string, toKey: string) => void;
}

const GROUPS: { status: AgentStatus; label: string; color: string }[] = [
  { status: "waiting", label: "WAITING FOR YOU", color: "var(--warning-label)" },
  { status: "working", label: "WORKING", color: "var(--success)" },
  { status: "idle", label: "IDLE", color: "var(--text-muted)" },
];

export function AgentList({ agents, selectedKey, filter, onFilterChange, onSelectAgent, onNewAgent, onReorder }: AgentListProps) {
  const dragKeyRef = useRef<string | null>(null);
  const [dragOverKey, setDragOverKey] = useState<string | null>(null);

  const waitingCount = agents.filter((a) => a.status === "waiting").length;
  const workingCount = agents.filter((a) => a.status === "working").length;

  // ⌘1–7 jumps straight to the Nth agent in list order.
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (!e.metaKey) return;
      const n = Number(e.key);
      if (!Number.isInteger(n) || n < 1 || n > 9) return;
      const target = agents[n - 1];
      if (!target) return;
      e.preventDefault();
      onSelectAgent(target.key);
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [agents, onSelectAgent]);

  const filtered = agents.filter((a) => filter === "all" || a.status === filter);

  function dragProps(key: string) {
    return {
      draggable: true,
      onDragStart: () => {
        dragKeyRef.current = key;
      },
      onDragOver: (e: React.DragEvent) => {
        e.preventDefault();
        setDragOverKey(key);
      },
      onDragLeave: (e: React.DragEvent<HTMLElement>) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) {
          setDragOverKey((k) => (k === key ? null : k));
        }
      },
      onDrop: (e: React.DragEvent) => {
        e.preventDefault();
        setDragOverKey(null);
        const from = dragKeyRef.current;
        dragKeyRef.current = null;
        if (from && from !== key) onReorder(from, key);
      },
      onDragEnd: () => {
        dragKeyRef.current = null;
        setDragOverKey(null);
      },
    };
  }

  return (
    <aside
      aria-label="Agents"
      className="rd-agent-list"
      style={{
        width: 296,
        flexShrink: 0,
        display: "flex",
        flexDirection: "column",
        borderRight: "1px solid var(--border)",
        background: "var(--bg-panel)",
        minHeight: 0,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "16px 16px 10px" }}>
        <h2 style={{ margin: 0, fontSize: 14, fontWeight: 600 }}>
          Agents <span style={{ color: "var(--text-muted)", fontWeight: 400 }}>{agents.length}</span>
        </h2>
        <button
          type="button"
          onClick={onNewAgent}
          style={{
            height: 30,
            padding: "0 10px",
            borderRadius: 7,
            border: "none",
            background: "var(--primary-bg)",
            color: "var(--primary-fg)",
            fontSize: 12,
            fontWeight: 600,
          }}
        >
          + New agent
        </button>
      </div>

      <div role="tablist" aria-label="Filter" style={{ display: "flex", gap: 4, margin: "0 16px 12px", padding: 3, borderRadius: 8, background: "var(--bg-segment)" }}>
        {([
          ["all", "All"],
          ["waiting", `Waiting ${waitingCount}`],
          ["working", `Working ${workingCount}`],
        ] as const).map(([value, label]) => {
          const active = filter === value;
          return (
            <button
              key={value}
              type="button"
              role="tab"
              aria-selected={active}
              onClick={() => onFilterChange(value)}
              className="rd-segment-btn"
              style={{
                flexGrow: 1,
                height: 28,
                borderRadius: 6,
                border: "none",
                background: active ? "var(--bg-segment-active)" : "transparent",
                color: active ? "var(--text-strong)" : "var(--text-tertiary)",
                fontSize: 12,
                boxShadow: active ? "var(--shadow-segment-active)" : undefined,
              }}
            >
              {label}
            </button>
          );
        })}
      </div>

      <div style={{ flexGrow: 1, overflow: "auto", padding: "0 10px", display: "flex", flexDirection: "column", gap: 4, minHeight: 0 }}>
        {(() => {
          let visibleGroupIndex = -1;
          return GROUPS.map(({ status, label, color }) => {
            const members = filtered.filter((a) => a.status === status);
            if (members.length === 0) return null;
            visibleGroupIndex += 1;
            const headTop = visibleGroupIndex === 0 ? 6 : 10;
            return (
              <div key={status} style={{ display: "flex", flexDirection: "column", gap: 4 }}>
                <div style={{ padding: `${headTop}px 6px 4px`, fontSize: 11, fontWeight: 600, letterSpacing: "0.06em", color }}>{label}</div>
              {members.map((agent) =>
                status === "idle" ? (
                  <IdleRow key={agent.key} agent={agent} onSelect={() => onSelectAgent(agent.key)} dragOver={dragOverKey === agent.key} dragProps={dragProps(agent.key)} />
                ) : (
                  <AgentCard
                    key={agent.key}
                    agent={agent}
                    selected={agent.key === selectedKey}
                    onSelect={() => onSelectAgent(agent.key)}
                    dragOver={dragOverKey === agent.key}
                    dragProps={dragProps(agent.key)}
                  />
                  ),
                )}
              </div>
            );
          });
        })()}
      </div>

      <div style={{ padding: "12px 16px", borderTop: "1px solid var(--border)", fontSize: 12, color: "var(--text-muted)", display: "flex", justifyContent: "space-between" }}>
        <span>Drag to reorder</span>
        <span style={{ fontFamily: "var(--font-mono)" }}>⌘1–7</span>
      </div>
    </aside>
  );
}

interface CardProps {
  agent: AgentVM;
  selected: boolean;
  onSelect: () => void;
  dragOver: boolean;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  dragProps: any;
}

function AgentCard({ agent, selected, onSelect, dragOver, dragProps }: CardProps) {
  const waiting = agent.status === "waiting";
  const dotColor = waiting ? "var(--warning)" : "var(--success)";
  const border = waiting ? "1px solid var(--warning-border)" : selected ? "1px solid var(--border-selected)" : "1px solid transparent";
  const background = waiting ? "var(--warning-bg)" : selected ? "var(--bg-selected)" : "transparent";
  return (
    <button
      type="button"
      {...dragProps}
      onClick={onSelect}
      aria-current={selected ? "true" : undefined}
      className="rd-agent-card"
      style={{
        textAlign: "left",
        padding: "10px 12px",
        borderRadius: 10,
        border,
        outlineOffset: dragOver ? -2 : undefined,
        outline: dragOver ? "2px dashed var(--accent)" : undefined,
        background,
        color: "var(--text)",
        display: "flex",
        flexDirection: "column",
        gap: 4,
      }}
    >
      <span style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <span style={{ width: 8, height: 8, borderRadius: 4, background: dotColor, flexShrink: 0 }} />
        <span className="rd-ellipsis" style={{ fontWeight: 600, fontSize: 13, flexGrow: 1, textAlign: "left" }}>
          {agent.name}
        </span>
        <span style={{ fontSize: 11, color: waiting ? "var(--warning)" : "var(--text-muted)", flexShrink: 0 }}>{agent.since}</span>
      </span>
      <span className="rd-ellipsis" style={{ display: "block", fontSize: 12, color: waiting ? "var(--warning-text)" : "var(--text-secondary)" }}>
        {agent.activity}
      </span>
      <span className="rd-ellipsis" style={{ display: "block", fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--text-muted)" }}>
        {agent.path}
      </span>
    </button>
  );
}

function IdleRow({ agent, onSelect, dragOver, dragProps }: { agent: AgentVM; onSelect: () => void; dragOver: boolean; dragProps: CardProps["dragProps"] }) {
  return (
    <button
      type="button"
      {...dragProps}
      onClick={onSelect}
      className="rd-idle-row"
      style={{
        textAlign: "left",
        padding: "8px 12px",
        borderRadius: 8,
        border: "none",
        outline: dragOver ? "2px dashed var(--accent)" : undefined,
        outlineOffset: dragOver ? -2 : undefined,
        background: "transparent",
        color: "var(--text)",
        display: "flex",
        alignItems: "center",
        gap: 8,
      }}
    >
      <span style={{ width: 8, height: 8, borderRadius: 4, border: "1.5px solid var(--text-faint)", boxSizing: "border-box", flexShrink: 0 }} />
      {/* The name is what identifies the row: it keeps its full width up to 70% of the
          row and only then truncates. The path takes whatever is left, right-aligned,
          and truncates first. Proportional flex-shrink wasn't enough — a long path
          still cut "Terminal" to "Termi…" in the live app (2026-09-30). */}
      <span className="rd-ellipsis" title={agent.name} style={{ fontSize: 13, flex: "0 1 auto", maxWidth: "70%", minWidth: 0, textAlign: "left" }}>
        {agent.name}
      </span>
      <span className="rd-ellipsis" title={agent.path} style={{ fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--text-muted)", flex: "1 1 0", minWidth: 0, textAlign: "right" }}>
        {agent.path}
      </span>
    </button>
  );
}

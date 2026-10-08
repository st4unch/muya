// Created by Claude — Classification: INTERNAL
//
// Left agent panel on Control (PROMPT.md §3). Groups agents into
// PINNED / WAITING FOR YOU / WORKING / IDLE (empty groups hidden), filters via the
// segmented control, and supports HTML5 drag-and-drop reordering + ⌘1–7.

import { AgentKindIcon } from "./AgentKindIcon";
import { useEffect, useRef, useState, type MouseEvent as ReactMouseEvent, type ReactNode } from "react";
import { InlineRename } from "./InlineRename";
import { ChevronDownIcon, SplitPaneIcon } from "./icons";
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
  /** Double-click a session to rename it in place (terminal, Claude, opencode alike). */
  onRenameAgent?: (key: string, name: string) => void;
  /** Right-click a session: the caller opens its actions menu at the pointer. */
  onAgentContextMenu?: (key: string, e: ReactMouseEvent) => void;
  /** Agents the operator pinned: listed first under PINNED, whatever their status. */
  pinnedKeys?: ReadonlySet<string>;
  /** Operator-set width in px; undefined = the responsive default (296, 264 at ≤1360). */
  width?: number;
  /** Resize handle for the panel's inner edge (rendered over the border). */
  resizeHandle?: ReactNode;
  /** The Files section, pinned between the agents list and the footer. */
  filesSection?: ReactNode;
  /** The expanded Files section fills the panel: the list takes only the height its
   *  rows need (scrolling past half the panel), Files gets everything else. */
  filesFill?: boolean;
  /** Split groups (lib/controlSplit): each shows as one collapsible row whose terminals
   *  are listed under it instead of in the status sections. */
  splitGroups?: { id: string; keys: string[]; collapsed: boolean }[];
  onToggleGroup?: (id: string) => void;
  onSelectGroup?: (id: string) => void;
}

const GROUPS: { status: AgentStatus; label: string; color: string }[] = [
  { status: "waiting", label: "WAITING FOR YOU", color: "var(--warning-label)" },
  { status: "working", label: "WORKING", color: "var(--success)" },
  { status: "idle", label: "IDLE", color: "var(--text-muted)" },
];

export function AgentList({ agents, selectedKey, filter, onFilterChange, onSelectAgent, onNewAgent, onReorder, width, resizeHandle, filesSection, filesFill = false, onRenameAgent, onAgentContextMenu, pinnedKeys, splitGroups = [], onToggleGroup, onSelectGroup }: AgentListProps) {
  const dragKeyRef = useRef<string | null>(null);
  const [dragOverKey, setDragOverKey] = useState<string | null>(null);

  const waitingCount = agents.filter((a) => a.status === "waiting").length;
  const workingCount = agents.filter((a) => a.status === "working").length;

  const matches = (a: AgentVM) => filter === "all" || a.status === filter;
  // Grouped terminals are listed under their group, not again in a status section.
  const grouped = new Set(splitGroups.flatMap((g) => g.keys));
  const byKey = new Map(agents.map((a) => [a.key, a]));
  const groupsShown = splitGroups
    .map((g) => ({ ...g, members: g.keys.map((k) => byKey.get(k)).filter((a): a is AgentVM => !!a) }))
    .filter((g) => g.members.length > 0 && g.members.some(matches));
  const filtered = agents.filter((a) => matches(a) && !grouped.has(a.key));
  const isPinned = (a: AgentVM) => pinnedKeys?.has(a.key) ?? false;
  const sections = [
    { id: "pinned", label: "PINNED", color: "var(--text-strong)", members: filtered.filter(isPinned) },
    ...GROUPS.map((g) => ({ id: g.status, label: g.label, color: g.color, members: filtered.filter((a) => a.status === g.status && !isPinned(a)) })),
  ];
  const onScreen = [...groupsShown.flatMap((g) => (g.collapsed ? [] : g.members)), ...sections.flatMap((sec) => sec.members)];

  // ⌘1–9 jumps to the Nth agent as listed on screen (pinned first).
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (!e.metaKey) return;
      const n = Number(e.key);
      if (!Number.isInteger(n) || n < 1 || n > 9) return;
      const target = onScreen[n - 1];
      if (!target) return;
      e.preventDefault();
      onSelectAgent(target.key);
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onScreen, onSelectAgent]);

  const [renamingKey, setRenamingKey] = useState<string | null>(null);
  // Per-row extras: double-click → rename in place, right-click → actions menu.
  const rowExtras = (key: string) => ({
    onDoubleClick: onRenameAgent ? () => setRenamingKey(key) : undefined,
    onContextMenu: onAgentContextMenu
      ? (e: ReactMouseEvent) => {
          e.preventDefault();
          onAgentContextMenu(key, e);
        }
      : undefined,
    title: onRenameAgent ? "Double-click to rename" : undefined,
  });

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

  const renderRow = (agent: AgentVM) =>
                agent.key === renamingKey && onRenameAgent ? (
                  <div
                    key={agent.key}
                    style={{ display: "flex", alignItems: "center", gap: 8, padding: agent.status === "idle" ? "8px 12px" : "12px 12px", borderRadius: agent.status === "idle" ? 8 : 10, border: "1px solid var(--border-selected)", background: "var(--bg-selected)" }}
                  >
                    <span style={{ width: 8, height: 8, borderRadius: 4, background: agent.status === "idle" ? "transparent" : agent.status === "waiting" ? "var(--warning)" : "var(--success)", border: agent.status === "idle" ? "1.5px solid var(--text-faint)" : "none", boxSizing: "border-box", flexShrink: 0 }} />
                    <InlineRename
                      initial={agent.name}
                      onCommit={(name) => {
                        setRenamingKey(null);
                        onRenameAgent(agent.key, name);
                      }}
                      onCancel={() => setRenamingKey(null)}
                    />
                  </div>
                ) : agent.status === "idle" ? (
                  <IdleRow key={agent.key} agent={agent} onSelect={() => onSelectAgent(agent.key)} dragOver={dragOverKey === agent.key} dragProps={{ ...dragProps(agent.key), ...rowExtras(agent.key) }} />
                ) : (
                  <AgentCard
                    key={agent.key}
                    agent={agent}
                    selected={agent.key === selectedKey}
                    onSelect={() => onSelectAgent(agent.key)}
                    dragOver={dragOverKey === agent.key}
                    dragProps={{ ...dragProps(agent.key), ...rowExtras(agent.key) }}
                  />
                  );

  return (
    <aside
      aria-label="Agents"
      className="rd-agent-list"
      data-custom={width !== undefined ? "" : undefined}
      style={{
        position: "relative",
        width: width ?? 296,
        flexShrink: 0,
        display: "flex",
        flexDirection: "column",
        borderRight: "1px solid var(--border)",
        background: "var(--bg-panel)",
        minHeight: 0,
      }}
    >
      {resizeHandle}
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

      <div
        style={{
          flex: filesFill ? "0 1 auto" : "1 1 0",
          maxHeight: filesFill ? "50%" : undefined,
          overflow: "auto",
          padding: filesFill ? "0 10px 8px" : "0 10px",
          display: "flex",
          flexDirection: "column",
          gap: 4,
          minHeight: filesSection && !filesFill ? 120 : 0,
        }}
      >
        {groupsShown.length > 0 && (
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            <div style={{ padding: "6px 6px 4px", fontSize: 11, fontWeight: 600, letterSpacing: "0.06em", color: "var(--text-strong)" }}>SPLITS</div>
            {groupsShown.map((g) => (
              <div key={g.id} style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                <GroupRow
                  members={g.members}
                  collapsed={g.collapsed}
                  selected={!!selectedKey && g.keys.includes(selectedKey)}
                  onToggle={() => onToggleGroup?.(g.id)}
                  onSelect={() => onSelectGroup?.(g.id)}
                />
                {!g.collapsed && (
                  <div role="group" aria-label={`${g.members[0].name} split`} style={{ display: "flex", flexDirection: "column", gap: 4, paddingLeft: 14, marginLeft: 10, borderLeft: "1px solid var(--border)" }}>
                    {g.members.map((agent) => renderRow(agent))}
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
        {(() => {
          let visibleGroupIndex = -1;
          return sections.map(({ id, label, color, members }) => {
            if (members.length === 0) return null;
            visibleGroupIndex += 1;
            const headTop = visibleGroupIndex === 0 ? 6 : 10;
            return (
              <div key={id} style={{ display: "flex", flexDirection: "column", gap: 4 }}>
                <div style={{ padding: `${headTop}px 6px 4px`, fontSize: 11, fontWeight: 600, letterSpacing: "0.06em", color }}>{label}</div>
              {members.map((agent) => renderRow(agent))}
              </div>
            );
          });
        })()}
      </div>

      {filesSection}

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
        <AgentKindIcon agent={agent} />
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
      <AgentKindIcon agent={agent} />
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

/** One split group in the list: chevron (expand / collapse), the split icon, the first
 *  terminal's name and the pane count; its dot is the most urgent member status. */
function GroupRow({ members, collapsed, selected, onToggle, onSelect }: { members: AgentVM[]; collapsed: boolean; selected: boolean; onToggle: () => void; onSelect: () => void }) {
  const waiting = members.some((a) => a.status === "waiting");
  const working = members.some((a) => a.status === "working");
  const dot = waiting ? "var(--warning)" : working ? "var(--success)" : "var(--text-faint)";
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 4,
        borderRadius: 8,
        border: selected ? "1px solid var(--border-selected)" : "1px solid transparent",
        background: selected ? "var(--bg-selected)" : "transparent",
      }}
    >
      <button
        type="button"
        onClick={onToggle}
        aria-expanded={!collapsed}
        aria-label={collapsed ? "Expand split" : "Collapse split"}
        className="rd-icon-btn"
        style={{ width: 24, height: 30, border: "none", background: "transparent", color: "var(--text-muted)", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}
      >
        <span style={{ display: "flex", transform: collapsed ? "rotate(-90deg)" : undefined, transition: "transform 120ms" }}>
          <ChevronDownIcon size={12} />
        </span>
      </button>
      <button
        type="button"
        onClick={onSelect}
        title="Show this split"
        className="rd-idle-row"
        style={{ flexGrow: 1, minWidth: 0, textAlign: "left", padding: "7px 8px 7px 0", border: "none", background: "transparent", color: "var(--text)", display: "flex", alignItems: "center", gap: 8 }}
      >
        <span style={{ width: 8, height: 8, borderRadius: 4, background: dot, flexShrink: 0 }} />
        <span style={{ display: "flex", color: "var(--text-muted)", flexShrink: 0 }}>
          <SplitPaneIcon size={13} />
        </span>
        <span className="rd-ellipsis" style={{ fontSize: 13, fontWeight: 600, minWidth: 0 }}>
          {members[0]?.name ?? "Split"}
        </span>
        <span style={{ fontSize: 11, color: "var(--text-muted)", flexShrink: 0 }}>· {members.length} panes</span>
      </button>
    </div>
  );
}

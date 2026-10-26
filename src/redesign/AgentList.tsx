// Created by Claude — Classification: INTERNAL
//
// Left agent panel on Control (PROMPT.md §3). Groups agents into
// PINNED / WAITING FOR YOU / WORKING / IDLE (empty groups hidden), filters via the
// segmented control, and supports HTML5 drag-and-drop reordering + ⌘1–7.

import { AgentKindIcon } from "./AgentKindIcon";
import { useEffect, useRef, useState, type CSSProperties, type MouseEvent as ReactMouseEvent, type ReactNode } from "react";
import { InlineRename } from "./InlineRename";
import { ChevronDownIcon, SplitPaneIcon } from "./icons";
import type { AgentStatus, AgentVM } from "./types";

export type AgentFilter = "all" | "waiting" | "working" | "recent";

export interface AgentListProps {
  agents: AgentVM[];
  selectedKey: string | null;
  filter: AgentFilter;
  onFilterChange: (filter: AgentFilter) => void;
  onSelectAgent: (key: string) => void;
  onNewAgent: () => void;
  onReorder: (fromKey: string, toKey: string) => void;
  /** A session dropped onto the middle of another: group the two into a split. */
  onGroup?: (fromKey: string, toKey: string) => void;
  /** A session dropped onto a split's header row: it joins that split. */
  onGroupInto?: (fromKey: string, groupId: string) => void;
  /** Double-click a session to rename it in place (terminal, Claude, opencode alike). */
  onRenameAgent?: (key: string, name: string) => void;
  /** Right-click a session: the caller opens its actions menu at the pointer. */
  onAgentContextMenu?: (key: string, e: ReactMouseEvent) => void;
  /** The × in a session's top-right corner. */
  onCloseAgent?: (key: string) => void;
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

/** Past this many sessions every row is one line, so a long list stays scannable. */
export const COMPACT_AFTER = 20;

/** Where a drag would land: between rows (reorder) or onto a row (group into a split). */
export type DropMode = "reorder" | "group";

/** The middle half of a row groups, its top and bottom quarters reorder. */
export function dropModeAt(clientY: number, rect: { top: number; height: number }): DropMode {
  const y = clientY - rect.top;
  return y > rect.height * 0.25 && y < rect.height * 0.75 ? "group" : "reorder";
}

/** The outline a row shows while something is dragged over it. */
export function dropStyle(mode: DropMode | null): CSSProperties {
  if (mode === "reorder") return { outline: "2px dashed var(--accent)", outlineOffset: -2 };
  if (mode === "group") return { outline: "2px solid var(--accent)", outlineOffset: -2, background: "var(--bg-selected)" };
  return {};
}

const GROUPS: { status: AgentStatus; label: string; color: string }[] = [
  { status: "waiting", label: "WAITING FOR YOU", color: "var(--warning-label)" },
  { status: "working", label: "WORKING", color: "var(--success)" },
  { status: "idle", label: "IDLE", color: "var(--text-muted)" },
];

export function AgentList({ agents, selectedKey, filter, onFilterChange, onSelectAgent, onNewAgent, onReorder, onGroup, onGroupInto, width, resizeHandle, filesSection, filesFill = false, onRenameAgent, onAgentContextMenu, onCloseAgent, pinnedKeys, splitGroups = [], onToggleGroup, onSelectGroup }: AgentListProps) {
  const dragKeyRef = useRef<string | null>(null);
  const [dragOver, setDragOver] = useState<{ key: string; mode: DropMode } | null>(null);
  const overMode = (key: string): DropMode | null => (dragOver?.key === key ? dragOver.mode : null);

  const waitingCount = agents.filter((a) => a.status === "waiting").length;
  const workingCount = agents.filter((a) => a.status === "working").length;
  const recentCount = agents.filter((a) => a.recent).length;

  const matches = (a: AgentVM) => filter === "all" || (filter === "recent" ? !!a.recent : a.status === filter);
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
      onDragOver: (e: React.DragEvent<HTMLElement>) => {
        e.preventDefault();
        const mode = onGroup && dragKeyRef.current !== key ? dropModeAt(e.clientY, e.currentTarget.getBoundingClientRect()) : "reorder";
        setDragOver((d) => (d?.key === key && d.mode === mode ? d : { key, mode }));
      },
      onDragLeave: (e: React.DragEvent<HTMLElement>) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) {
          setDragOver((d) => (d?.key === key ? null : d));
        }
      },
      onDrop: (e: React.DragEvent<HTMLElement>) => {
        e.preventDefault();
        setDragOver(null);
        const from = dragKeyRef.current;
        dragKeyRef.current = null;
        if (!from || from === key) return;
        if (onGroup && dropModeAt(e.clientY, e.currentTarget.getBoundingClientRect()) === "group") onGroup(from, key);
        else onReorder(from, key);
      },
      onDragEnd: () => {
        dragKeyRef.current = null;
        setDragOver(null);
      },
    };
  }

  /** A split's header row only takes drops that join the split. */
  function groupDropProps(groupId: string, keys: string[]) {
    const id = `group:${groupId}`;
    if (!onGroupInto) return {};
    return {
      onDragOver: (e: React.DragEvent) => {
        if (!dragKeyRef.current || keys.includes(dragKeyRef.current)) return;
        e.preventDefault();
        setDragOver((d) => (d?.key === id ? d : { key: id, mode: "group" }));
      },
      onDragLeave: (e: React.DragEvent<HTMLElement>) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setDragOver((d) => (d?.key === id ? null : d));
      },
      onDrop: (e: React.DragEvent) => {
        e.preventDefault();
        setDragOver(null);
        const from = dragKeyRef.current;
        dragKeyRef.current = null;
        if (from && !keys.includes(from)) onGroupInto(from, groupId);
      },
    };
  }

  const compact = agents.length > COMPACT_AFTER;
  const renderRow = (agent: AgentVM) =>
    agent.key === renamingKey || !onCloseAgent ? (
      renderBody(agent)
    ) : (
      <div key={agent.key} className="rd-agent-row" style={{ position: "relative", display: "flex", flexDirection: "column", minWidth: 0 }}>
        {renderBody(agent)}
        <button
          type="button"
          aria-label={`Close ${agent.name}`}
          title="Close"
          draggable={false}
          onClick={(e) => {
            e.stopPropagation();
            onCloseAgent(agent.key);
          }}
          onDoubleClick={(e) => e.stopPropagation()}
          className="rd-agent-close"
          style={{ position: "absolute", top: compact || agent.status === "idle" ? 7 : 8, right: 6, width: 20, height: 20, display: "flex", alignItems: "center", justifyContent: "center", border: "none", borderRadius: 5, background: "transparent", color: "var(--text-faint)", fontSize: 14, lineHeight: 1, padding: 0 }}
        >
          ×
        </button>
      </div>
    );
  const closable = !!onCloseAgent;
  const renderBody = (agent: AgentVM) =>
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
                ) : agent.status === "idle" || compact ? (
                  <IdleRow key={agent.key} agent={agent} selected={compact && agent.key === selectedKey} closable={closable} onSelect={() => onSelectAgent(agent.key)} dragOver={overMode(agent.key)} dragProps={{ ...dragProps(agent.key), ...rowExtras(agent.key) }} />
                ) : (
                  <AgentCard
                    key={agent.key}
                    agent={agent}
                    selected={agent.key === selectedKey}
                    closable={closable}
                    onSelect={() => onSelectAgent(agent.key)}
                    dragOver={overMode(agent.key)}
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
          ["recent", `Recent ${recentCount}`],
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
                padding: "0 4px",
                minWidth: 0,
                whiteSpace: "nowrap",
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
                  dragOver={overMode(`group:${g.id}`)}
                  dropProps={groupDropProps(g.id, g.keys)}
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

      <div style={{ padding: "10px 16px", borderTop: "1px solid var(--border)", fontSize: 12, color: "var(--text-muted)", display: "flex", flexDirection: "column", gap: 4 }}>
        <div style={{ display: "flex", justifyContent: "space-between", gap: 8 }}>
          <span>Drag to reorder · onto a session to split</span>
          <span style={{ fontFamily: "var(--font-mono)" }}>⌘1–9</span>
        </div>
        <div style={{ display: "flex", justifyContent: "space-between", gap: 8 }}>
          <span>Switch workspace</span>
          <span style={{ fontFamily: "var(--font-mono)" }} title="⌥⌘0 shows all workspaces">⌥⌘1–9 · ⌥⌘0 all</span>
        </div>
      </div>
    </aside>
  );
}

interface CardProps {
  agent: AgentVM;
  selected: boolean;
  /** Leave room for the × in the top-right corner. */
  closable?: boolean;
  onSelect: () => void;
  dragOver: DropMode | null;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  dragProps: any;
}

function AgentCard({ agent, selected, closable, onSelect, dragOver, dragProps }: CardProps) {
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
        padding: closable ? "10px 30px 10px 12px" : "10px 12px",
        borderRadius: 10,
        border,
        background,
        ...dropStyle(dragOver),
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

/** One-line row: idle sessions, and every session once the list is compact. */
function IdleRow({ agent, selected, closable, onSelect, dragOver, dragProps }: { agent: AgentVM; selected?: boolean; closable?: boolean; onSelect: () => void; dragOver: DropMode | null; dragProps: CardProps["dragProps"] }) {
  const waiting = agent.status === "waiting";
  const idle = agent.status === "idle";
  return (
    <button
      type="button"
      {...dragProps}
      onClick={onSelect}
      aria-current={selected ? "true" : undefined}
      className="rd-idle-row"
      title={idle ? dragProps?.title : `${agent.activity}${dragProps?.title ? ` — ${dragProps.title}` : ""}`}
      style={{
        textAlign: "left",
        padding: closable ? "8px 30px 8px 12px" : "8px 12px",
        borderRadius: 8,
        border: waiting ? "1px solid var(--warning-border)" : selected ? "1px solid var(--border-selected)" : "1px solid transparent",
        background: waiting ? "var(--warning-bg)" : selected ? "var(--bg-selected)" : "transparent",
        ...dropStyle(dragOver),
        color: "var(--text)",
        display: "flex",
        alignItems: "center",
        gap: 8,
      }}
    >
      <span style={{ width: 8, height: 8, borderRadius: 4, background: idle ? "transparent" : waiting ? "var(--warning)" : "var(--success)", border: idle ? "1.5px solid var(--text-faint)" : "none", boxSizing: "border-box", flexShrink: 0 }} />
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
function GroupRow({ members, collapsed, selected, onToggle, onSelect, dragOver = null, dropProps }: { members: AgentVM[]; collapsed: boolean; selected: boolean; onToggle: () => void; onSelect: () => void; dragOver?: DropMode | null; dropProps?: Record<string, unknown> }) {
  const waiting = members.some((a) => a.status === "waiting");
  const working = members.some((a) => a.status === "working");
  const dot = waiting ? "var(--warning)" : working ? "var(--success)" : "var(--text-faint)";
  return (
    <div
      {...dropProps}
      style={{
        display: "flex",
        alignItems: "center",
        gap: 4,
        borderRadius: 8,
        border: selected ? "1px solid var(--border-selected)" : "1px solid transparent",
        background: selected ? "var(--bg-selected)" : "transparent",
        ...dropStyle(dragOver),
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

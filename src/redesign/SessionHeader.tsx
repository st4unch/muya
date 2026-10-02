// Created by Claude — Classification: INTERNAL
//
// Control main-area session header (PROMPT.md §3). Single line: the reference
// itself wraps at 1440px (a defect — PROMPT update), so every piece here is
// nowrap + flex-shrink:0, with only the h1 allowed to ellipsis.

import { AgentKindIcon, agentGlyphLabel } from "./AgentKindIcon";
import type { CSSProperties, MouseEvent } from "react";
import type { AgentVM } from "./types";
import { useLayoutEffect, useRef, useState } from "react";
import { BypassWarningIcon, ChevronDownIcon, CompactIcon, GridSplitIcon } from "./icons";
import { asBool, usePersistentState } from "./usePersistentState";
import { InlineRename } from "./InlineRename";
import { withDetail } from "./text";

export interface SessionHeaderProps {
  agent: AgentVM;
  onCompact: () => void;
  onSplitToGrid: () => void;
  onStop: () => void;
  /** Receives the click so the caller can anchor the actions menu under the button. */
  onMore: (e: MouseEvent<HTMLElement>) => void;
  /** Double-click the name to rename the session in place. */
  onRename?: (name: string) => void;
}

function statusPill(agent: AgentVM) {
  if (agent.status === "working") {
    return { text: withDetail("Working", agent.since), bg: "var(--success-bg)", fg: "var(--success-text)", dot: "var(--success)" };
  }
  if (agent.status === "waiting") {
    return { text: withDetail("Waiting", agent.since), bg: "var(--warning-card-bg)", fg: "var(--warning-label)", dot: "var(--warning)" };
  }
  return { text: "Idle", bg: "var(--bg-segment)", fg: "var(--text-muted)", dot: "var(--text-faint)" };
}

const secondaryBtn: CSSProperties = {
  height: 32,
  padding: "0 12px",
  borderRadius: 8,
  border: "1px solid var(--border-control)",
  background: "var(--bg-control)",
  color: "var(--text)",
  fontSize: 13,
  flexShrink: 0,
};

/**
 * The name matters more than the bypass label. When the title row can't hold the full
 * name AND both pills, the bypass pill drops to its warning icon (full text in the
 * tooltip) before the name loses a single character. It comes back once the row is
 * wide enough for the full version again — measured once when it collapsed, so it
 * can't flip back and forth at the boundary.
 */
function useCompactBypass(active: boolean, deps: unknown[]) {
  const rowRef = useRef<HTMLDivElement>(null);
  const nameRef = useRef<HTMLHeadingElement>(null);
  const [compact, setCompact] = useState(false);
  const fullWidth = useRef(0);
  useLayoutEffect(() => {
    const row = rowRef.current;
    const name = nameRef.current;
    if (!row || !name || !active) {
      setCompact(false);
      return;
    }
    // The remembered "full width" belongs to the previous name/pill text; drop it and
    // re-measure (same layout pass, so nothing flashes).
    fullWidth.current = 0;
    setCompact(false);
    const check = () => {
      setCompact((was) => {
        if (!was) {
          const clipped = name.scrollWidth - name.clientWidth;
          if (clipped <= 0) return false;
          fullWidth.current = row.clientWidth + clipped;
          return true;
        }
        return row.clientWidth < fullWidth.current;
      });
    };
    check();
    if (typeof ResizeObserver === "undefined") return; // jsdom / very old runtimes: one check
    const ro = new ResizeObserver(check);
    ro.observe(row);
    return () => ro.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active, ...deps]);
  return { rowRef, nameRef, compact };
}

/** Icon-only action button in the collapsed header row. */
const slimBtn: CSSProperties = {
  width: 26,
  height: 24,
  borderRadius: 6,
  border: "1px solid var(--border-control)",
  background: "var(--bg-control)",
  color: "var(--text)",
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  flexShrink: 0,
  padding: 0,
};

/** Expand/collapse toggle; sits left of the name in both states so it never moves. */
function CollapseToggle({ collapsed, onToggle }: { collapsed: boolean; onToggle: () => void }) {
  const label = collapsed ? "Expand session header" : "Collapse session header";
  return (
    <button
      type="button"
      onClick={onToggle}
      aria-label={label}
      aria-expanded={!collapsed}
      title={label}
      className="rd-icon-btn"
      style={{
        width: 22,
        height: 22,
        borderRadius: 6,
        border: "none",
        background: "transparent",
        color: "var(--text-muted)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        flexShrink: 0,
        padding: 0,
      }}
    >
      <ChevronDownIcon size={14} style={{ transform: collapsed ? "rotate(-90deg)" : undefined, transition: "transform 120ms ease" }} />
    </button>
  );
}

export function SessionHeader({ agent, onCompact, onSplitToGrid, onStop, onMore, onRename }: SessionHeaderProps) {
  const [renaming, setRenaming] = useState(false);
  // One setting for every agent: the operator wants the terminal taller, not this agent's bar hidden.
  const [collapsed, setCollapsed] = usePersistentState<boolean>("muya.sessionHeaderCollapsed", false, asBool);
  const pill = statusPill(agent);
  const bypass = agent.mode === "bypass";
  const { rowRef, nameRef, compact } = useCompactBypass(bypass && !collapsed, [agent.name, pill.text]);
  const pillEl = (
    <span
      style={{
        display: "flex",
        alignItems: "center",
        gap: 6,
        height: 22,
        padding: "0 8px",
        borderRadius: 11,
        background: pill.bg,
        color: pill.fg,
        fontSize: 12,
        fontWeight: 500,
        flexShrink: 0,
      }}
    >
      <span style={{ width: 6, height: 6, borderRadius: 3, background: pill.dot, flexShrink: 0 }} />
      {pill.text}
    </span>
  );
  if (collapsed) {
    return (
      <div className="rd-session-head" style={{ display: "flex", alignItems: "center", gap: 8, padding: "4px 20px 4px 14px", borderBottom: "1px solid var(--border)", minWidth: 0 }}>
        <CollapseToggle collapsed onToggle={() => setCollapsed(false)} />
        <span className="rd-ellipsis" title={agent.name} style={{ fontSize: 13, fontWeight: 600, minWidth: 0 }}>
          {agent.name}
        </span>
        {pillEl}
        {bypass && (
          <span title="Bypass permissions on" aria-label="Bypass permissions on" style={{ display: "flex", color: "var(--danger-text)", flexShrink: 0 }}>
            <BypassWarningIcon size={12} />
          </span>
        )}
        <div style={{ display: "flex", alignItems: "center", gap: 4, marginLeft: "auto", flexShrink: 0 }}>
          <button
            type="button"
            onClick={onCompact}
            disabled={!agent.agentRunning}
            title={agent.agentRunning ? "Compact" : "No agent is running in this terminal"}
            aria-label="Compact"
            className="rd-icon-btn"
            style={slimBtn}
          >
            <CompactIcon size={14} />
          </button>
          <button type="button" onClick={onSplitToGrid} title="Split to grid" aria-label="Split to grid" className="rd-icon-btn" style={slimBtn}>
            <GridSplitIcon size={14} />
          </button>
          <button
            type="button"
            onClick={onStop}
            title="Stop (esc)"
            aria-label="Stop"
            className="rd-icon-btn"
            style={{ ...slimBtn, border: "1px solid var(--danger-border)", background: "var(--danger-btn-bg)", color: "var(--danger-text)" }}
          >
            <svg width="12" height="12" viewBox="0 0 24 24" aria-hidden="true">
              <rect x="5" y="5" width="14" height="14" rx="2.5" fill="currentColor" />
            </svg>
          </button>
        </div>
      </div>
    );
  }
  return (
    <div className="rd-session-head" style={{ display: "flex", alignItems: "center", gap: 12, padding: "12px 20px 12px 14px", borderBottom: "1px solid var(--border)", minWidth: 0 }}>
      <div style={{ display: "flex", flexDirection: "column", gap: 3, flexGrow: 1, minWidth: 0 }}>
        <div ref={rowRef} style={{ display: "flex", alignItems: "center", gap: 10, minWidth: 0 }}>
          <CollapseToggle collapsed={false} onToggle={() => setCollapsed(true)} />
          {renaming && onRename ? (
            <InlineRename
              initial={agent.name}
              onCommit={(name) => {
                setRenaming(false);
                onRename(name);
              }}
              onCancel={() => setRenaming(false)}
              style={{ fontSize: 17, height: 28, maxWidth: 360 }}
            />
          ) : (
            <h1
              ref={nameRef}
              className="rd-ellipsis"
              title={onRename ? `${agent.name} — double-click to rename` : agent.name}
              onDoubleClick={onRename ? () => setRenaming(true) : undefined}
              style={{ margin: 0, fontSize: 17, fontWeight: 600, flexShrink: 1, minWidth: 0, cursor: onRename ? "text" : undefined }}
            >
              {agent.name}
            </h1>
          )}
          {pillEl}
          {bypass && (
            <span
              title={compact ? "Bypass permissions on" : undefined}
              aria-label={compact ? "Bypass permissions on" : undefined}
              style={{
                display: "flex",
                alignItems: "center",
                gap: 6,
                height: 22,
                padding: "0 8px",
                borderRadius: 11,
                background: "var(--danger-pill-bg)",
                color: "var(--danger-text)",
                fontSize: 12,
                fontWeight: 500,
                flexShrink: 0,
              }}
            >
              <BypassWarningIcon size={12} />
              {compact ? null : "Bypass permissions on"}
            </span>
          )}
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 6, minWidth: 0, paddingLeft: 32 }}>
          <AgentKindIcon agent={agent} size={12} />
          <span style={{ fontSize: 12, color: "var(--text-secondary)", whiteSpace: "nowrap", flexShrink: 0 }}>{agentGlyphLabel(agent)} ·</span>
          <span className="rd-ellipsis" style={{ fontFamily: "var(--font-mono)", fontSize: 12, color: "var(--text-muted)", minWidth: 0 }}>
            {agent.path}
            {agent.branch ? ` · ${agent.branch}` : ""}
          </span>
        </div>
      </div>

      {/* /compact is a Claude command; typed into a plain shell it is "command not found". */}
      <button
        type="button"
        onClick={onCompact}
        disabled={!agent.agentRunning}
        title={agent.agentRunning ? "Compact" : "No agent is running in this terminal"}
        aria-label="Compact"
        className="rd-btn2 rd-sess-btn"
        style={secondaryBtn}
      >
        <CompactIcon className="rd-sess-icon" />
        <span className="rd-sess-label">Compact</span>
      </button>
      <button type="button" onClick={onSplitToGrid} title="Split to grid" aria-label="Split to grid" className="rd-btn2 rd-sess-btn" style={secondaryBtn}>
        <GridSplitIcon className="rd-sess-icon" />
        <span className="rd-sess-label">Split to grid</span>
      </button>
      <button
        type="button"
        onClick={onStop}
        className="rd-btn2"
        style={{
          height: 32,
          padding: "0 12px",
          borderRadius: 8,
          border: "1px solid var(--danger-border)",
          background: "var(--danger-btn-bg)",
          color: "var(--danger-text)",
          fontSize: 13,
          display: "flex",
          alignItems: "center",
          gap: 8,
          flexShrink: 0,
        }}
      >
        Stop <span style={{ fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--danger-kbd)" }}>esc</span>
      </button>
      <button
        type="button"
        aria-label="More actions"
        onClick={onMore}
        className="rd-icon-btn"
        style={{
          width: 32,
          height: 32,
          borderRadius: 8,
          border: "1px solid var(--border-control)",
          background: "var(--bg-control)",
          color: "var(--text)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          flexShrink: 0,
        }}
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" aria-hidden="true">
          <path d="M5 12h.01M12 12h.01M19 12h.01" />
        </svg>
      </button>
    </div>
  );
}

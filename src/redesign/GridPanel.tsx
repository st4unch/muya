// Created by Claude — Classification: INTERNAL
//
// One panel in the Grid layout (PROMPT.md §4). Header is a fixed 49px (incl. the
// 1px bottom border) and the bottom bar (approval row or composer) a fixed 58px
// (incl. the 1px top border) on EVERY panel regardless of variant, so neighbour
// panels line up to the pixel (operator alignment note) — the waiting panel's
// emphasis is a 1px border + an extra 1px box-shadow ring, never a 2px border,
// so it never grows taller than its neighbours.

import type { KeyboardEvent } from "react";
import type { AgentVM } from "./types";
import { MaximizeIcon } from "./icons";
import { messageHint, withDetail } from "./text";

export interface GridPanelProps {
  agent: AgentVM;
  focused: boolean;
  onFocus: () => void;
  onMaximize: () => void;
  onApprove: () => void;
  onDeny: () => void;
  onAlwaysAllow: () => void;
  composerValue: string;
  onComposerChange: (value: string) => void;
  onSendMessage: (text: string) => void;
}

const HEAD_HEIGHT = 49;
const BAR_HEIGHT = 58;

export function GridPanel({
  agent,
  focused,
  onFocus,
  onMaximize,
  onApprove,
  onDeny,
  onAlwaysAllow,
  composerValue,
  onComposerChange,
  onSendMessage,
}: GridPanelProps) {
  const waiting = agent.status === "waiting";
  const idle = agent.status === "idle";
  const working = agent.status === "working";

  const border = waiting ? "1px solid var(--warning)" : focused ? "1px solid var(--border-selected)" : "1px solid var(--border)";
  const boxShadow = waiting ? "0 0 0 1px var(--warning)" : undefined;
  const headBg = waiting ? "var(--warning-card-bg)" : focused ? "var(--bg-selected-head)" : "var(--bg-panel)";
  const headBorder = waiting ? "1px solid var(--warning-border)" : "1px solid var(--border)";

  const statusText = waiting ? withDetail("Needs permission", agent.since) : working ? withDetail("Working", agent.since) : "Idle";
  const statusColor = waiting ? "var(--warning)" : working ? "var(--success-text)" : "var(--text-muted)";
  const dot = waiting || working ? (
    <span style={{ width: 8, height: 8, borderRadius: 4, background: waiting ? "var(--warning)" : "var(--success)", flexShrink: 0 }} />
  ) : (
    <span style={{ width: 8, height: 8, borderRadius: 4, border: "1.5px solid var(--text-faint)", boxSizing: "border-box", flexShrink: 0 }} />
  );

  function handleKeyDown(e: KeyboardEvent<HTMLElement>) {
    if (e.key === "y" || e.key === "Y") {
      if (waiting) {
        e.preventDefault();
        onApprove();
      }
    } else if (e.key === "n" || e.key === "N") {
      if (waiting) {
        e.preventDefault();
        onDeny();
      }
    }
  }

  return (
    <section
      aria-label={agent.name}
      tabIndex={0}
      onFocus={onFocus}
      onKeyDown={handleKeyDown}
      className="rd-agent-card"
      style={{
        display: "flex",
        flexDirection: "column",
        minHeight: 0,
        borderRadius: 12,
        border,
        boxShadow,
        background: "var(--bg-terminal)",
        overflow: "hidden",
      }}
    >
      <div
        style={{
          height: HEAD_HEIGHT,
          boxSizing: "border-box",
          display: "flex",
          alignItems: "center",
          gap: 10,
          padding: "0 14px",
          background: headBg,
          borderBottom: headBorder,
        }}
      >
        {dot}
        <span className="rd-ellipsis" style={{ fontWeight: 600, fontSize: 14, flexShrink: 1, minWidth: 0 }}>
          {agent.name}
        </span>
        <span style={{ fontSize: 12, color: statusColor, flexShrink: 0 }}>{statusText}</span>
        {agent.mode === "bypass" && !idle && (
          <span style={{ fontSize: 11, padding: "2px 7px", borderRadius: 9, background: "var(--danger-pill-bg)", color: "var(--danger-text)", flexShrink: 0 }}>bypass</span>
        )}
        <div style={{ flexGrow: 1 }} />
        {waiting ? (
          <button
            type="button"
            aria-label="Maximize"
            onClick={onMaximize}
            className="rd-icon-btn"
            style={{ width: 28, height: 28, borderRadius: 6, border: "none", background: "transparent", color: "var(--warning-text)", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}
          >
            <MaximizeIcon size={14} />
          </button>
        ) : agent.progress?.tokens ? (
          <span style={{ fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--text-muted)", flexShrink: 0 }}>
            {agent.progress.tokens.replace(/\s*tokens?$/i, "")} tok
          </span>
        ) : idle ? (
          <span className="rd-ellipsis" style={{ fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--text-muted)", flex: "0 4 auto", minWidth: 0 }}>
            {agent.path}
          </span>
        ) : null}
      </div>

      {/* Every agent panel shows its REAL terminal — idle included. An idle Claude
          session is sitting at its prompt waiting for input; hiding it behind a
          "Waiting for a task" card (as the reference drew it) made it impossible to
          see or type to from the grid. Found live, 2026-09-30. The empty-state card
          now belongs to grid cells with no agent (EmptyGridPanel below). */}
      {/* Real xterm is adopted into this slot; it fills the region with NO padding
          of its own — the xterm host itself carries the 14px/16px reference padding. */}
      <div data-terminal-slot={agent.key} data-terminal-pad="14px 16px" data-diff-mask style={{ flexGrow: 1, minHeight: 0, overflow: "hidden", background: "var(--bg-terminal)" }} />

      {waiting && (
        <div style={{ height: BAR_HEIGHT, boxSizing: "border-box", display: "flex", alignItems: "center", gap: 8, padding: "0 14px", borderTop: "1px solid var(--border)", background: "var(--bg-chrome)" }}>
          <button type="button" disabled={agent.approval?.actionable === false} onClick={onApprove} style={{ height: 34, padding: "0 16px", borderRadius: 7, border: "none", background: "var(--warning-btn-bg)", color: "var(--warning-btn-fg)", fontSize: 13, fontWeight: 600 }}>
            Allow <span style={{ fontFamily: "var(--font-mono)", fontWeight: 400, fontSize: 11 }}>Y</span>
          </button>
          <button type="button" disabled={agent.approval?.actionable === false} onClick={onDeny} className="rd-btn2" style={{ height: 34, padding: "0 16px", borderRadius: 7, border: "1px solid var(--warning-border)", background: "transparent", color: "var(--warning-text)", fontSize: 13 }}>
            Deny <span style={{ fontFamily: "var(--font-mono)", fontSize: 11 }}>N</span>
          </button>
          <button type="button" disabled={agent.approval?.actionable === false} onClick={onAlwaysAllow} className="rd-btn2" style={{ height: 34, padding: "0 16px", borderRadius: 7, border: "1px solid var(--border-strong)", background: "transparent", color: "var(--text-tertiary)", fontSize: 13 }}>
            Always allow this session
          </button>
        </div>
      )}

      {!waiting && (
        <div style={{ height: BAR_HEIGHT, boxSizing: "border-box", display: "flex", alignItems: "center", padding: "0 14px", borderTop: "1px solid var(--border)", background: "var(--bg-chrome)" }}>
          <input
            aria-label={`Message ${agent.name}`}
            className="rd-grid-composer"
            value={composerValue}
            onChange={(e) => onComposerChange(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && composerValue.trim()) {
                e.preventDefault();
                onSendMessage(composerValue.trim());
              }
            }}
            placeholder={messageHint(agent.name)}
            style={{ width: "100%", height: 34, borderRadius: 8, border: "1px solid var(--border-control)", background: "var(--bg-input)", color: "var(--text)", padding: "0 12px", fontSize: 13, boxSizing: "border-box" }}
          />
        </div>
      )}
    </section>
  );
}

/** A grid cell the current layout has room for but no agent fills. Same frame and
 *  header height as an agent panel so the grid stays aligned. */
export function EmptyGridPanel({ onAssignFromQueue, onPickAgent }: { onAssignFromQueue: () => void; onPickAgent: () => void }) {
  return (
    <section
      aria-label="Empty panel"
      style={{ display: "flex", flexDirection: "column", minHeight: 0, borderRadius: 12, border: "1px solid var(--border)", background: "var(--bg-terminal)", overflow: "hidden" }}
    >
      <div style={{ height: HEAD_HEIGHT, boxSizing: "border-box", display: "flex", alignItems: "center", gap: 10, padding: "0 14px", background: "var(--bg-panel)", borderBottom: "1px solid var(--border)" }}>
        <span style={{ width: 8, height: 8, borderRadius: 4, border: "1.5px solid var(--text-faint)", boxSizing: "border-box", flexShrink: 0 }} />
        <span style={{ fontSize: 12, color: "var(--text-muted)" }}>Empty panel</span>
      </div>
      <div style={{ flexGrow: 1, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 10, color: "var(--text-muted)", fontSize: 13 }}>
        <span>Waiting for a task</span>
        <div style={{ display: "flex", gap: 8 }}>
          <button type="button" onClick={onAssignFromQueue} className="rd-btn2" style={{ height: 32, padding: "0 12px", borderRadius: 7, border: "1px solid var(--border-control)", background: "var(--bg-control)", color: "var(--text)", fontSize: 13 }}>
            Assign from Queue
          </button>
          <button type="button" onClick={onPickAgent} className="rd-btn2" style={{ height: 32, padding: "0 12px", borderRadius: 7, border: "1px solid var(--border-control)", background: "transparent", color: "var(--text-tertiary)", fontSize: 13 }}>
            Swap panel
          </button>
        </div>
      </div>
    </section>
  );
}

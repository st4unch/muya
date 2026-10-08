// Created by Claude — Classification: INTERNAL
//
// Split Control: the terminal area of the Control screen divided into up to 8 panes
// (lib/controlSplit). Each pane is a slim title row + an empty
// [data-terminal-slot=<key>] box — the orchestrator adopts the agent's real terminal
// into it, exactly like the single-terminal slot. Presentational only.

import { useEffect, useRef, type CSSProperties } from "react";
import { splitLayout } from "../lib/controlSplit";
import type { AgentVM } from "./types";

export interface SplitPaneVM {
  key: string;
  /** null = an empty pane waiting for the operator to pick an agent. */
  agent: AgentVM | null;
}

export interface SplitAreaProps {
  panes: SplitPaneVM[];
  focusedKey: string | null;
  onFocusPane: (key: string) => void;
  onClosePane: (key: string) => void;
  onNewTerminal?: () => void;
  onNewAgent: () => void;
}

function dotColor(agent: AgentVM): string {
  if (agent.status === "working") return "var(--success)";
  if (agent.status === "waiting") return "var(--warning)";
  return "var(--text-faint)";
}

const smallBtn: CSSProperties = {
  height: 28,
  padding: "0 10px",
  borderRadius: 7,
  border: "1px solid var(--border-control)",
  background: "var(--bg-control)",
  color: "var(--text)",
  fontSize: 12,
};

export function SplitArea({ panes, focusedKey, onFocusPane, onClosePane, onNewTerminal, onNewAgent }: SplitAreaProps) {
  const { cols, rows } = splitLayout(panes.length);
  // A click inside a pane makes it the focused one. Native listener, not React's
  // onMouseDown: each terminal is a portal of the app root that is only *moved* into its
  // pane, so React never routes its events through this component.
  const areaRef = useRef<HTMLDivElement>(null);
  const onFocusRef = useRef(onFocusPane);
  onFocusRef.current = onFocusPane;
  useEffect(() => {
    const el = areaRef.current;
    if (!el) return;
    const onDown = (e: MouseEvent) => {
      const t = e.target as HTMLElement | null;
      if (t?.closest?.("button")) return; // close ×, New terminal / New agent
      const pane = t?.closest?.<HTMLElement>("[data-split-pane]");
      if (pane?.dataset.splitPane && el.contains(pane)) onFocusRef.current(pane.dataset.splitPane);
    };
    el.addEventListener("mousedown", onDown, true);
    return () => el.removeEventListener("mousedown", onDown, true);
  }, []);
  return (
    <div
      ref={areaRef}
      data-testid="split-area"
      style={{
        flexGrow: 1,
        minHeight: 0,
        minWidth: 0,
        display: "grid",
        gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`,
        gridTemplateRows: `repeat(${rows}, minmax(0, 1fr))`,
        gap: 1,
        background: "var(--border)",
      }}
    >
      {panes.map(({ key, agent }) => {
        const focused = key === focusedKey;
        const waiting = agent?.status === "waiting";
        return (
          <section
            key={key}
            aria-label={agent ? agent.name : "Empty pane"}
            data-split-pane={key}
            style={{
              display: "flex",
              flexDirection: "column",
              minWidth: 0,
              minHeight: 0,
              background: "var(--bg-terminal)",
              boxShadow: focused ? "inset 0 0 0 1px var(--accent)" : undefined,
              position: "relative",
              overflow: "hidden",
            }}
          >
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 6,
                height: 26,
                padding: "0 6px 0 10px",
                flexShrink: 0,
                background: waiting ? "var(--warning-card-bg)" : focused ? "var(--bg-selected)" : "var(--bg-panel)",
                borderBottom: "1px solid var(--border)",
                fontSize: 12,
              }}
            >
              {agent && <span style={{ width: 6, height: 6, borderRadius: 3, background: dotColor(agent), flexShrink: 0 }} />}
              <span
                className="rd-ellipsis"
                title={agent?.name}
                style={{ minWidth: 0, flexGrow: 1, fontWeight: focused ? 600 : 500, color: agent ? "var(--text)" : "var(--text-muted)" }}
              >
                {agent ? agent.name : "Empty pane"}
              </span>
              <button
                type="button"
                aria-label={`Close pane ${agent?.name ?? ""}`.trim()}
                title="Close pane (the agent keeps running)"
                onClick={(e) => {
                  e.stopPropagation();
                  onClosePane(key);
                }}
                className="rd-icon-btn"
                style={{ width: 20, height: 20, border: "none", background: "transparent", color: "var(--text-muted)", borderRadius: 5, display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}
              >
                <svg width="10" height="10" viewBox="0 0 24 24" aria-hidden="true" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
                  <path d="M6 6l12 12M18 6L6 18" />
                </svg>
              </button>
            </div>
            {agent ? (
              <div data-terminal-slot={key} data-terminal-pad="10px 14px" data-diff-mask style={{ flexGrow: 1, minHeight: 0, overflow: "hidden" }} />
            ) : (
              <div style={{ flexGrow: 1, minHeight: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 8, color: "var(--text-muted)", fontSize: 12, padding: 12, textAlign: "center" }}>
                <span style={{ whiteSpace: "normal", maxWidth: "100%" }}>Pick an agent in the list</span>
                <div style={{ display: "flex", gap: 6, flexWrap: "wrap", justifyContent: "center" }}>
                  {onNewTerminal && (
                    <button type="button" onClick={onNewTerminal} className="rd-btn2" style={smallBtn}>
                      New terminal
                    </button>
                  )}
                  <button type="button" onClick={onNewAgent} className="rd-btn2" style={smallBtn}>
                    New agent
                  </button>
                </div>
              </div>
            )}
          </section>
        );
      })}
    </div>
  );
}

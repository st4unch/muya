// Created by Claude — Classification: INTERNAL
//
// Right panel on Control (PROMPT.md §3): approvals (one card per waiting agent),
// Changes/Files/Activity tabs, and the worktree-conflict card at the bottom.

import type { ReactNode } from "react";
import type { AgentVM, InspectorVM } from "./types";
import { plural } from "./text";

export type InspectorTab = "changes" | "files" | "activity";

export interface InspectorProps {
  waitingAgents: AgentVM[];
  onApprove: (key: string) => void;
  onDeny: (key: string) => void;
  onOpen: (key: string) => void;
  activeTab: InspectorTab;
  onTabChange: (tab: InspectorTab) => void;
  inspector: InspectorVM;
  onReviewDiff: () => void;
  onCommit: () => void;
  /** A row in Changes was clicked. Omitted = rows are inert. */
  onOpenChange?: (path: string) => void;
  filesSlot?: ReactNode;
  activitySlot?: ReactNode;
}

const CODE_COLOR: Record<string, string> = { M: "var(--warning)", A: "var(--success)", D: "var(--danger-text)" };

export function Inspector({ waitingAgents, onApprove, onDeny, onOpen, activeTab, onTabChange, inspector, onReviewDiff, onCommit, onOpenChange, filesSlot, activitySlot }: InspectorProps) {
  const visibleChanges = inspector.changes.slice(0, 3);
  const moreCount = inspector.changes.length - visibleChanges.length;
  const hasCollisions = inspector.collisions.length > 0;

  return (
    <aside aria-label="Inspector" className="rd-inspector" style={{ width: 320, flexShrink: 0, display: "flex", flexDirection: "column", borderLeft: "1px solid var(--border)", background: "var(--bg-panel)", minHeight: 0 }}>
      {waitingAgents.length > 0 && (
        <div style={{ padding: 16, display: "flex", flexDirection: "column", gap: 10, borderBottom: "1px solid var(--border)" }}>
          <div style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.06em", color: "var(--warning-label)" }}>NEEDS APPROVAL</div>
          {waitingAgents.map((agent) => (
            <div key={agent.key} style={{ border: "1px solid var(--warning-border)", background: "var(--warning-card-bg)", borderRadius: 10, padding: 12, display: "flex", flexDirection: "column", gap: 8 }}>
              <div style={{ fontSize: 13 }}>
                <span style={{ fontWeight: 600 }}>{agent.name}</span> {agent.approval?.summary ?? "wants to write a file"}
              </div>
              {(agent.approval?.tool || agent.approval?.target) && (
                <div className="rd-ellipsis" style={{ fontFamily: "var(--font-mono)", fontSize: 11.5, color: "var(--warning-text)", background: "var(--warning-code-bg)", borderRadius: 6, padding: "6px 8px" }}>
                  {agent.approval?.tool}
                  {agent.approval?.tool && agent.approval?.target ? " → " : ""}
                  {agent.approval?.target}
                </div>
              )}
              <div style={{ display: "flex", gap: 8 }}>
                <button type="button" disabled={agent.approval?.actionable === false} onClick={() => onApprove(agent.key)} style={{ flexGrow: 1, height: 32, borderRadius: 7, border: "none", background: "var(--warning-btn-bg)", color: "var(--warning-btn-fg)", fontSize: 13, fontWeight: 600 }}>
                  Allow
                </button>
                <button type="button" disabled={agent.approval?.actionable === false} onClick={() => onDeny(agent.key)} className="rd-btn2" style={{ flexGrow: 1, height: 32, borderRadius: 7, border: "1px solid var(--warning-border)", background: "transparent", color: "var(--warning-text)", fontSize: 13 }}>
                  Deny
                </button>
                <button type="button" onClick={() => onOpen(agent.key)} className="rd-btn2" style={{ height: 32, padding: "0 10px", borderRadius: 7, border: "1px solid var(--warning-border)", background: "transparent", color: "var(--warning-text)", fontSize: 13, flexShrink: 0 }}>
                  Open
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      <div role="tablist" style={{ display: "flex", gap: 18, padding: "0 16px", borderBottom: "1px solid var(--border)", flexShrink: 0 }}>
        {([
          ["changes", `Changes ${inspector.changes.length}`],
          ["files", "Files"],
          ["activity", "Activity"],
        ] as const).map(([tab, label]) => {
          const active = activeTab === tab;
          return (
            <button
              key={tab}
              type="button"
              role="tab"
              aria-selected={active}
              onClick={() => onTabChange(tab)}
              className="rd-tab"
              style={{
                height: 40,
                border: "none",
                borderBottom: `2px solid ${active ? "var(--text)" : "transparent"}`,
                background: "transparent",
                color: active ? "var(--text-strong)" : "var(--text-muted)",
                fontSize: 13,
                fontWeight: active ? 500 : 400,
                padding: 0,
              }}
            >
              {label}
            </button>
          );
        })}
      </div>

      {activeTab === "changes" && (
        <>
          <div style={{ padding: "10px 8px", display: "flex", flexDirection: "column", gap: 2, fontFamily: "var(--font-mono)", fontSize: 12, overflow: "auto", minHeight: 0 }}>
            {visibleChanges.map((change) => (
              <button key={change.path} type="button" onClick={() => onOpenChange?.(change.path)} className="rd-change-row" style={{ display: "flex", gap: 10, alignItems: "center", padding: "7px 8px", borderRadius: 6, border: "none", background: "transparent", color: "var(--text)", textAlign: "left", fontFamily: "inherit", fontSize: "inherit" }}>
                <span style={{ color: CODE_COLOR[change.code] ?? "var(--text-muted)", width: 12, flexShrink: 0 }}>{change.code}</span>
                <span className="rd-ellipsis" style={{ flexGrow: 1 }}>{change.path}</span>
              </button>
            ))}
            {moreCount > 0 && (
              <button type="button" className="rd-change-row" style={{ display: "flex", gap: 10, alignItems: "center", padding: "7px 8px", borderRadius: 6, border: "none", background: "transparent", color: "var(--text-muted)", textAlign: "left", fontFamily: "var(--font-sans)", fontSize: 12 }}>
                + {plural(moreCount, "more file", "more files")}
              </button>
            )}
          </div>
          <div style={{ margin: "4px 16px 0", display: "flex", gap: 8, flexShrink: 0 }}>
            <button type="button" onClick={onReviewDiff} className="rd-btn2" style={{ flexGrow: 1, height: 32, borderRadius: 7, border: "1px solid var(--border-control)", background: "var(--bg-control)", color: "var(--text)", fontSize: 13 }}>
              Review diff
            </button>
            <button type="button" onClick={onCommit} className="rd-btn2" style={{ flexGrow: 1, height: 32, borderRadius: 7, border: "1px solid var(--border-control)", background: "var(--bg-control)", color: "var(--text)", fontSize: 13 }}>
              Commit…
            </button>
          </div>
        </>
      )}
      {activeTab === "files" && <div style={{ flexGrow: 1, overflow: "auto", minHeight: 0 }}>{filesSlot}</div>}
      {activeTab === "activity" && <div style={{ flexGrow: 1, overflow: "auto", minHeight: 0 }}>{activitySlot}</div>}

      <div style={{ flexGrow: 1 }} />

      {hasCollisions ? (
        <div style={{ margin: 16, padding: 12, borderRadius: 10, background: "var(--danger-btn-bg)", border: "1px solid var(--danger-border)", display: "flex", flexDirection: "column", gap: 6 }}>
          <span style={{ fontSize: 13, fontWeight: 500, color: "var(--danger-text)" }}>File conflicts</span>
          {inspector.collisions.map((c) => (
            <span key={c.file} className="rd-ellipsis" style={{ fontSize: 12, color: "var(--danger-text)", fontFamily: "var(--font-mono)" }}>
              {c.file} — {c.worktrees.join(", ")}
            </span>
          ))}
        </div>
      ) : (
        <div style={{ margin: 16, padding: 12, borderRadius: 10, background: "var(--success-card-bg)", border: "1px solid var(--success-card-border)", display: "flex", gap: 10, alignItems: "flex-start" }}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="var(--success)" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" style={{ flexShrink: 0 }}>
            <path d="M20 6 9 17l-5-5" />
          </svg>
          <div style={{ display: "flex", flexDirection: "column", gap: 2, minWidth: 0 }}>
            <span style={{ fontSize: 13, fontWeight: 500, color: "var(--success-card-text)" }}>No file conflicts</span>
            <span style={{ fontSize: 12, color: "var(--text-muted)" }}>
              {plural(inspector.worktreesWatched, "worktree watched", "worktrees watched")} · {plural(inspector.changes.length, "change")}
            </span>
          </div>
        </div>
      )}
    </aside>
  );
}

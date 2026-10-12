// Created by Claude — Classification: INTERNAL
//
// Shown for a few seconds when a permission prompt appears while Auto-allow is off:
// offers to turn it on. Closed by its X, by Esc (App handles the key so it neither
// reaches the terminal nor takes Muya out of fullscreen), or by timing out.
import { X } from "lucide-react";

export function AutoAllowSuggest({ agentName, onEnable, onDismiss }: { agentName: string; onEnable: () => void; onDismiss: () => void }) {
  return (
    <div
      className="rd-root"
      role="status"
      aria-live="polite"
      style={{
        position: "fixed",
        bottom: 72,
        right: 16,
        width: 340,
        zIndex: 140,
        padding: "12px 14px",
        borderRadius: 12,
        border: "1px solid var(--border)",
        boxShadow: "var(--shadow-popover, 0 12px 40px rgba(0,0,0,0.35))",
        background: "var(--bg-panel)",
        color: "var(--text-strong)",
        display: "flex",
        flexDirection: "column",
        gap: 10,
      }}
    >
      <div style={{ display: "flex", alignItems: "flex-start", gap: 8 }}>
        <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 4 }}>
          <span style={{ fontSize: 13, fontWeight: 600 }}>Turn on Auto-allow?</span>
          <span style={{ fontSize: 12, color: "var(--text-tertiary)" }}>
            {agentName} is asking for permission. With Auto-allow on, Muya clicks Allow for you after 2 seconds, in every session.
          </span>
        </div>
        <button type="button" aria-label="Close" onClick={onDismiss} className="rd-btn2" style={{ width: 24, height: 24, display: "grid", placeItems: "center", borderRadius: 6, border: "none", background: "transparent", color: "var(--text-tertiary)" }}>
          <X size={14} />
        </button>
      </div>
      <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
        <button type="button" onClick={onDismiss} className="rd-btn2" style={{ height: 28, padding: "0 12px", borderRadius: 7, border: "1px solid var(--border-strong)", background: "transparent", color: "var(--text-tertiary)", fontSize: 12 }}>
          Not now
        </button>
        <button type="button" onClick={onEnable} style={{ height: 28, padding: "0 12px", borderRadius: 7, border: "none", background: "var(--warning-btn-bg)", color: "var(--warning-btn-fg)", fontSize: 12, fontWeight: 600 }}>
          Turn on
        </button>
      </div>
    </div>
  );
}

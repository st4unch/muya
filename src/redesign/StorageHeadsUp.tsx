// Created by Claude — Classification: INTERNAL
//
// "Claude sessions use 2.4 GB" — a once-a-day nudge when saved sessions got big enough
// to slow Muya and Claude down (docs/prd-session-housekeeping.md, plan C).

import { formatBytes, type StorageSummary } from "../lib/sessionStorage";

const KEY = "apex.sessionsHeadsUp";

/** Not shown yet today (per viewer; unreadable storage = show). */
export function headsUpDue(today: string): boolean {
  try {
    return localStorage.getItem(KEY) !== today;
  } catch {
    return true;
  }
}

export function markHeadsUpShown(today: string): void {
  try {
    localStorage.setItem(KEY, today);
  } catch {
    /* private mode: it may show again */
  }
}

export default function StorageHeadsUp({ summary, onOpen, onDismiss }: { summary: StorageSummary; onOpen: () => void; onDismiss: () => void }) {
  const detail = [
    summary.oldCount > 0 ? `${summary.oldCount} not used for 30+ days` : "",
    summary.bigCount > 0 ? `${summary.bigCount} over 100 MB` : "",
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <div
      className="rd-root"
      role="status"
      aria-live="polite"
      style={{ position: "fixed", top: 52, right: 16, width: 340, zIndex: 140, borderRadius: 12, boxShadow: "var(--shadow-popover, 0 12px 40px rgba(0,0,0,0.35))", background: "var(--bg-panel)" }}
    >
      <div style={{ display: "flex", gap: 10, padding: "10px 10px 10px 12px", borderRadius: 10, border: "1px solid var(--border)", background: "var(--bg-control)" }}>
        <span style={{ width: 8, height: 8, borderRadius: 4, background: "var(--warning)", flexShrink: 0, marginTop: 5 }} />
        <div style={{ display: "flex", flexDirection: "column", gap: 2, flexGrow: 1, minWidth: 0 }}>
          <span style={{ fontWeight: 600, fontSize: 13 }}>Claude sessions use {formatBytes(summary.totalBytes)}</span>
          <span style={{ fontSize: 13, color: "var(--text-secondary)" }}>Big histories slow Muya and Claude down.</span>
          {detail && <span style={{ fontSize: 11, color: "var(--text-muted)" }}>{detail}</span>}
          <div style={{ display: "flex", gap: 8, marginTop: 6 }}>
            <button type="button" className="rd-btn2" onClick={onOpen} style={{ height: 26, padding: "0 10px", borderRadius: 6, border: "1px solid var(--border-strong)", background: "var(--bg-panel)", color: "var(--text)", fontSize: 12, fontWeight: 600, cursor: "pointer" }}>
              Clean up…
            </button>
            <button type="button" className="rd-btn2" onClick={onDismiss} style={{ height: 26, padding: "0 10px", borderRadius: 6, border: "none", background: "transparent", color: "var(--text-muted)", fontSize: 12, cursor: "pointer" }}>
              Not now
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

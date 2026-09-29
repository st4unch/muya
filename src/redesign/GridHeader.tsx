// Created by Claude — Classification: INTERNAL
//
// Grid screen's own header (PROMPT.md §4) — a different, denser toolbar than
// ControlHeader's (no workspace/search/CPU/bell in the grid.reference.html).

import type { GridLayout } from "./types";

export interface GridHeaderProps {
  panelCount: number;
  layout: GridLayout;
  onLayoutChange: (layout: GridLayout) => void;
  onWaitingFirst: () => void;
  onBroadcast: () => void;
}

const LAYOUTS: { value: GridLayout; label: string }[] = [
  { value: "1", label: "1" },
  { value: "1x2", label: "1×2" },
  { value: "2x2", label: "2×2" },
  { value: "3x2", label: "3×2" },
];

export function GridHeader({ panelCount, layout, onLayoutChange, onWaitingFirst, onBroadcast }: GridHeaderProps) {
  return (
    <header
      data-tauri-drag-region
      style={{
        height: 48,
        flexShrink: 0,
        display: "flex",
        alignItems: "center",
        gap: 16,
        padding: "0 16px 0 88px",
        borderBottom: "1px solid var(--border)",
        background: "var(--bg-chrome)",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 10, flexShrink: 0 }}>
        <div style={{ width: 26, height: 26, borderRadius: 7, background: "var(--primary-bg)", color: "var(--primary-fg)", display: "flex", alignItems: "center", justifyContent: "center", fontWeight: 700, fontSize: 14 }}>
          M
        </div>
        <span style={{ fontWeight: 600, fontSize: 15 }}>Muya</span>
      </div>
      <span style={{ color: "var(--text-faint)", flexShrink: 0 }}>/</span>
      <span style={{ fontSize: 14, fontWeight: 500, flexShrink: 0 }}>Grid</span>
      <span style={{ fontSize: 13, color: "var(--text-muted)", flexShrink: 0 }}>{panelCount} panels</span>

      <div style={{ flexGrow: 1 }} />

      <div role="tablist" aria-label="Layout" style={{ display: "flex", gap: 4, padding: 3, borderRadius: 8, background: "var(--bg-segment)", flexShrink: 0 }}>
        {LAYOUTS.map(({ value, label }) => {
          const active = layout === value;
          return (
            <button
              key={value}
              type="button"
              role="tab"
              aria-selected={active}
              onClick={() => onLayoutChange(value)}
              className="rd-segment-btn"
              style={{
                height: 28,
                padding: "0 10px",
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

      <button
        type="button"
        onClick={onWaitingFirst}
        className="rd-btn2"
        style={{ height: 32, padding: "0 12px", borderRadius: 8, border: "1px solid var(--border-control)", background: "var(--bg-control)", color: "var(--text)", fontSize: 13, flexShrink: 0 }}
      >
        Waiting first
      </button>
      <button
        type="button"
        onClick={onBroadcast}
        className="rd-btn2"
        style={{ height: 32, padding: "0 12px", borderRadius: 8, border: "1px solid var(--border-control)", background: "var(--bg-control)", color: "var(--text)", fontSize: 13, flexShrink: 0 }}
      >
        Broadcast to all…
      </button>
    </header>
  );
}

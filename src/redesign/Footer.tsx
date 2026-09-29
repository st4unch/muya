// Created by Claude — Classification: INTERNAL
//
// Status bar (PROMPT.md §2, §3, §4). Control shows "UTF-8"; Grid shows the panel
// keyboard hint instead — same FooterVM, `variant` picks the trailing item.

import type { CSSProperties } from "react";
import type { FooterVM } from "./types";

const NOWRAP: CSSProperties = { whiteSpace: "nowrap" };

export function Footer({ workspaceCount, agents, working, waiting, collisions, version, variant }: FooterVM) {
  return (
    <footer
      style={{
        height: 28,
        flexShrink: 0,
        display: "flex",
        alignItems: "center",
        gap: 18,
        padding: "0 16px",
        borderTop: "1px solid var(--border)",
        background: "var(--bg-chrome)",
        fontSize: 12,
        color: "var(--text-muted)",
      }}
    >
      <span style={{ display: "flex", alignItems: "center", gap: 6, ...NOWRAP }}>
        <span style={{ width: 6, height: 6, borderRadius: 3, background: "var(--success)", flexShrink: 0 }} />
        Ready
      </span>
      <span style={NOWRAP}>{workspaceCount} workspaces</span>
      <span style={NOWRAP}>
        {agents} agents · <span style={{ color: "var(--success-text)" }}>{working} working</span> ·{" "}
        <span style={{ color: "var(--warning)" }}>{waiting} waiting</span>
      </span>
      <span style={NOWRAP}>{collisions} conflicts</span>
      <div style={{ flexGrow: 1 }} />
      <span style={NOWRAP}>{variant === "grid" ? "Tab to switch panels · ⌘⏎ maximize" : "UTF-8"}</span>
      <span style={NOWRAP}>Muya v{version}</span>
    </footer>
  );
}

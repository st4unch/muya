// Created by Claude — Classification: INTERNAL
//
// Status bar (PROMPT.md §2, §3, §4). Control shows "UTF-8"; Grid shows the panel
// keyboard hint instead — same FooterVM, `variant` picks the trailing item.
// Left of the version: the Claude status fields the user pinned (see StatusPicker) and
// the "+" that adds more. A field the selected session lacks is simply not rendered.

import { useState } from "react";
import type { CSSProperties } from "react";
import type { FooterVM } from "./types";
import { plural } from "./text";
import { PlusIcon } from "./icons";
import { anchorFromRect, type Anchor } from "./Menus";
import { StatusPicker } from "./StatusPicker";
import { statusField, statusValue, type StatusData } from "../lib/statusline";

const NOWRAP: CSSProperties = { whiteSpace: "nowrap" };

function StatusItem({ id, data, onRemove }: { id: string; data: StatusData | null; onRemove: (id: string) => void }) {
  const field = statusField(id);
  const value = statusValue(id, data);
  if (!field || value === null) return null;
  return (
    <span
      className="rd-ellipsis"
      title={`${field.label}: ${value} (right-click to remove)`}
      data-status-field={id}
      onContextMenu={(e) => {
        e.preventDefault();
        onRemove(id);
      }}
      style={{ ...NOWRAP, flexShrink: 1, maxWidth: 200, cursor: "default" }}
    >
      <span style={{ color: "var(--text-faint)" }}>{field.label} </span>
      {value}
    </span>
  );
}

export function Footer({ workspaceCount, agents, working, waiting, collisions, version, variant, status }: FooterVM) {
  const [anchor, setAnchor] = useState<Anchor | null>(null);
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
      <span style={NOWRAP}>{plural(workspaceCount, "workspace")}</span>
      <span style={NOWRAP}>
        {plural(agents, "agent")} · <span style={{ color: "var(--success-text)" }}>{working} working</span> ·{" "}
        <span style={{ color: "var(--warning)" }}>{waiting} waiting</span>
      </span>
      <span style={NOWRAP}>{plural(collisions, "conflict")}</span>
      <div style={{ flexGrow: 1 }} />
      {status && (
        <div style={{ display: "flex", alignItems: "center", gap: 14, minWidth: 0, flexShrink: 1, overflow: "hidden" }}>
          {status.fields.map((id) => (
            <StatusItem key={id} id={id} data={status.data} onRemove={status.onRemove} />
          ))}
        </div>
      )}
      <span style={NOWRAP}>{variant === "grid" ? "Tab to switch panels · ⌘⏎ maximize" : "UTF-8"}</span>
      {status && (
        <button
          type="button"
          aria-label="Add status field"
          title="Add status field"
          onClick={(e) => setAnchor(anchorFromRect(e.currentTarget.getBoundingClientRect(), "right", "above"))}
          className="rd-icon-btn"
          style={{ width: 20, height: 20, marginRight: -8, flexShrink: 0, display: "flex", alignItems: "center", justifyContent: "center", padding: 0, border: "none", borderRadius: 5, background: "transparent", color: "var(--text-muted)" }}
        >
          <PlusIcon size={12} />
        </button>
      )}
      <span style={NOWRAP}>Muya v{version}</span>
      {status && anchor && (
        <StatusPicker anchor={anchor} fields={status.fields} data={status.data} onToggle={status.onToggle} onClose={() => setAnchor(null)} />
      )}
    </footer>
  );
}

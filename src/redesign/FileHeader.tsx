// Created by Claude — Classification: INTERNAL
//
// Same visual language as SessionHeader, shown instead of it when a file is open
// in the main area (PLAN.md decision, PROMPT.md main-area contract). The single
// element the operator approved beyond the references: one "Close" button.

import type { FileVM } from "./types";

export interface FileHeaderProps {
  file: FileVM;
  onClose: () => void;
}

export function FileHeader({ file, onClose }: FileHeaderProps) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 12, padding: "12px 20px", borderBottom: "1px solid var(--border)", minWidth: 0 }}>
      <div style={{ display: "flex", flexDirection: "column", gap: 3, flexGrow: 1, minWidth: 0 }}>
        <h1 className="rd-ellipsis" style={{ margin: 0, fontSize: 17, fontWeight: 600 }}>
          {file.name}
        </h1>
        <div className="rd-ellipsis" style={{ fontFamily: "var(--font-mono)", fontSize: 12, color: "var(--text-muted)" }}>
          {file.path}
        </div>
      </div>
      <button
        type="button"
        onClick={onClose}
        className="rd-btn2"
        style={{
          height: 32,
          padding: "0 12px",
          borderRadius: 8,
          border: "1px solid var(--border-control)",
          background: "var(--bg-control)",
          color: "var(--text)",
          fontSize: 13,
          flexShrink: 0,
        }}
      >
        Close
      </button>
    </div>
  );
}

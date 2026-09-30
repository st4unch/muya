// Created by Claude — Classification: INTERNAL
//
// Small token-styled overlays the redesigned screens open: an anchored popover menu
// (agent actions, workspaces, permission mode), a rename dialog and an agent picker.
// Everything is declared at module level — a component declared inside another
// component's render body is a new type every render and swaps its DOM (lost clicks).

import { useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import type { AgentVM } from "./types";

export interface Anchor {
  x: number;
  /** Top edge of the popover (place "below") or the trigger's top edge (place "above"). */
  y: number;
  /** Which edge of the trigger the popover hangs from. */
  align: "left" | "right";
  place: "below" | "above";
}

export function anchorFromRect(rect: DOMRect, align: "left" | "right" = "left", place: "below" | "above" = "below"): Anchor {
  return { x: align === "left" ? rect.left : rect.right, y: place === "below" ? rect.bottom + 6 : rect.top - 6, align, place };
}

const PANEL: React.CSSProperties = {
  background: "var(--bg-panel)",
  border: "1px solid var(--border-strong)",
  borderRadius: 10,
  boxShadow: "var(--shadow-popover, 0 12px 40px rgba(0,0,0,0.35))",
  color: "var(--text)",
  fontSize: 13,
};

function useEscape(onClose: () => void) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [onClose]);
}

export function MenuPopover({ anchor, width = 240, onClose, children, label }: { anchor: Anchor; width?: number; onClose: () => void; children: ReactNode; label: string }) {
  useEscape(onClose);
  const left = anchor.align === "left" ? Math.min(anchor.x, window.innerWidth - width - 8) : Math.max(8, anchor.x - width);
  return (
    <div className="rd-root" style={{ position: "fixed", inset: 0, zIndex: 150 }} onMouseDown={onClose} onContextMenu={(e) => { e.preventDefault(); onClose(); }}>
      <div role="menu" aria-label={label} onMouseDown={(e) => e.stopPropagation()} style={{ ...PANEL, position: "absolute", ...(anchor.place === "below" ? { top: anchor.y } : { bottom: window.innerHeight - anchor.y }), left, width, padding: 4, display: "flex", flexDirection: "column", gap: 1 }}>
        {children}
      </div>
    </div>
  );
}

export function MenuItem({ label, hint, onSelect, danger, disabled, checked }: { label: string; hint?: string; onSelect: () => void; danger?: boolean; disabled?: boolean; checked?: boolean }) {
  return (
    <button
      type="button"
      role="menuitem"
      disabled={disabled}
      onClick={onSelect}
      className="rd-btn2"
      style={{ display: "flex", alignItems: "center", gap: 8, height: 30, padding: "0 10px", borderRadius: 6, border: "none", background: "transparent", color: danger ? "var(--danger-text)" : "var(--text)", fontSize: 13, textAlign: "left" }}
    >
      <span style={{ width: 12, flexShrink: 0, color: "var(--accent)" }}>{checked ? "✓" : ""}</span>
      <span className="rd-ellipsis" style={{ flexGrow: hint ? 0 : 1, flexShrink: hint ? 0 : 1 }}>{label}</span>
      {hint && (
        <span className="rd-ellipsis" style={{ color: "var(--text-muted)", fontSize: 11, flexGrow: 1, textAlign: "right" }}>
          {hint}
        </span>
      )}
    </button>
  );
}

export function MenuHeading({ children }: { children: ReactNode }) {
  return <div style={{ padding: "6px 10px 4px", fontSize: 11, fontWeight: 600, letterSpacing: "0.06em", color: "var(--text-muted)" }}>{children}</div>;
}

export function MenuSeparator() {
  return <div style={{ height: 1, margin: "4px 6px", background: "var(--border)" }} />;
}

/** Modal shell: `role="dialog"` so the terminal key-guard stops forwarding keys to the PTY. */
function DialogShell({ label, onClose, children, width }: { label: string; onClose: () => void; children: ReactNode; width: number }) {
  useEscape(onClose);
  return (
    <div className="rd-root fixed inset-0 z-50" style={{ position: "fixed", inset: 0, zIndex: 160, background: "rgba(0,0,0,0.45)", display: "flex", alignItems: "flex-start", justifyContent: "center", paddingTop: "18vh" }} onMouseDown={onClose}>
      <div role="dialog" aria-modal="true" aria-label={label} onMouseDown={(e) => e.stopPropagation()} style={{ ...PANEL, width, padding: 16, display: "flex", flexDirection: "column", gap: 12 }}>
        {children}
      </div>
    </div>
  );
}

export function RenameDialog({ initial, onSubmit, onClose }: { initial: string; onSubmit: (name: string) => void; onClose: () => void }) {
  const [value, setValue] = useState(initial);
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => {
    ref.current?.focus();
    ref.current?.select();
  }, []);
  const submit = () => {
    const name = value.trim();
    if (name) onSubmit(name);
    onClose();
  };
  return (
    <DialogShell label="Rename agent" onClose={onClose} width={380}>
      <div style={{ fontWeight: 600 }}>Rename agent</div>
      <input
        ref={ref}
        value={value}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") submit();
        }}
        style={{ height: 34, borderRadius: 8, border: "1px solid var(--border-control)", background: "var(--bg-input)", color: "var(--text)", padding: "0 12px", fontSize: 13 }}
      />
      <div style={{ display: "flex", justifyContent: "flex-end", gap: 8 }}>
        <button type="button" onClick={onClose} className="rd-btn2" style={{ height: 30, padding: "0 12px", borderRadius: 7, border: "1px solid var(--border-control)", background: "transparent", color: "var(--text)", fontSize: 13 }}>
          Cancel
        </button>
        <button type="button" onClick={submit} style={{ height: 30, padding: "0 14px", borderRadius: 7, border: "none", background: "var(--primary-bg)", color: "var(--primary-fg)", fontSize: 13, fontWeight: 600 }}>
          Rename
        </button>
      </div>
    </DialogShell>
  );
}

export function AgentPickerDialog({ title, agents, onPick, onClose }: { title: string; agents: AgentVM[]; onPick: (key: string) => void; onClose: () => void }) {
  return (
    <DialogShell label={title} onClose={onClose} width={420}>
      <div style={{ fontWeight: 600 }}>{title}</div>
      <div style={{ display: "flex", flexDirection: "column", gap: 2, maxHeight: 320, overflow: "auto" }}>
        {agents.length === 0 && <div style={{ color: "var(--text-muted)", padding: "8px 4px" }}>No other agents are open.</div>}
        {agents.map((a) => (
          <button key={a.key} type="button" onClick={() => onPick(a.key)} className="rd-btn2" style={{ display: "flex", alignItems: "center", gap: 10, height: 34, padding: "0 10px", borderRadius: 7, border: "none", background: "transparent", color: "var(--text)", fontSize: 13, textAlign: "left" }}>
            <span style={{ width: 8, height: 8, borderRadius: 4, flexShrink: 0, background: a.status === "waiting" ? "var(--warning)" : a.status === "working" ? "var(--success)" : "transparent", border: a.status === "idle" ? "1.5px solid var(--text-faint)" : "none", boxSizing: "border-box" }} />
            <span className="rd-ellipsis" style={{ fontWeight: 500 }}>{a.name}</span>
            <span className="rd-ellipsis" style={{ color: "var(--text-muted)", fontFamily: "var(--font-mono)", fontSize: 11, flexGrow: 1, textAlign: "right" }}>{a.path}</span>
          </button>
        ))}
      </div>
    </DialogShell>
  );
}

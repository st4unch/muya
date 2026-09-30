// Created by Claude — Classification: INTERNAL
//
// Footer "+" popover: every documented Claude status field, grouped, with a live preview.
// Checking a field appends it to the footer; unchecking removes it.

import { useEffect, useRef, useState } from "react";
import { MenuHeading, MenuPopover, type Anchor } from "./Menus";
import { STATUS_FIELDS, STATUS_GROUPS, statusValue, type StatusData } from "../lib/statusline";

export interface StatusPickerProps {
  anchor: Anchor;
  fields: string[];
  data: StatusData | null;
  onToggle: (id: string) => void;
  onClose: () => void;
}

export function StatusPicker({ anchor, fields, data, onToggle, onClose }: StatusPickerProps) {
  const [query, setQuery] = useState("");
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => ref.current?.focus(), []);
  const q = query.trim().toLowerCase();
  const match = (label: string, id: string, group: string) =>
    !q || label.toLowerCase().includes(q) || id.toLowerCase().includes(q) || group.toLowerCase().includes(q);
  const visible = STATUS_FIELDS.filter((f) => match(f.label, f.id, f.group));
  return (
    <MenuPopover anchor={anchor} width={360} onClose={onClose} label="Status fields">
      <input
        ref={ref}
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder="Filter fields"
        aria-label="Filter status fields"
        style={{ height: 30, margin: "2px 4px 4px", borderRadius: 7, border: "1px solid var(--border-control)", background: "var(--bg-input)", color: "var(--text)", padding: "0 10px", fontSize: 13 }}
      />
      {!data && (
        <div style={{ padding: "2px 10px 6px", fontSize: 11, color: "var(--text-muted)" }}>
          Status data appears for Claude sessions started from Muya
        </div>
      )}
      <div style={{ maxHeight: "min(60vh, 460px)", overflowY: "auto", display: "flex", flexDirection: "column", gap: 1 }}>
        {STATUS_GROUPS.map((g) => {
          const rows = visible.filter((f) => f.group === g);
          if (rows.length === 0) return null;
          return (
            <div key={g} role="group" aria-label={g}>
              <MenuHeading>{g.toUpperCase()}</MenuHeading>
              {rows.map((f) => {
                const on = fields.includes(f.id);
                const val = statusValue(f.id, data);
                return (
                  <button
                    key={f.id}
                    type="button"
                    role="menuitemcheckbox"
                    aria-checked={on}
                    onClick={() => onToggle(f.id)}
                    className="rd-btn2"
                    style={{ display: "flex", alignItems: "center", gap: 8, width: "100%", height: 28, padding: "0 10px", borderRadius: 6, border: "none", background: "transparent", color: "var(--text)", fontSize: 13, textAlign: "left" }}
                  >
                    <span style={{ width: 12, flexShrink: 0, color: "var(--accent)" }}>{on ? "✓" : ""}</span>
                    <span className="rd-ellipsis" style={{ flexShrink: 0 }}>{f.label}</span>
                    <span className="rd-ellipsis" style={{ flexGrow: 1, textAlign: "right", color: "var(--text-muted)", fontSize: 12 }}>{val ?? "—"}</span>
                  </button>
                );
              })}
            </div>
          );
        })}
        {visible.length === 0 && <div style={{ padding: "8px 10px", color: "var(--text-muted)" }}>No matching fields</div>}
      </div>
    </MenuPopover>
  );
}

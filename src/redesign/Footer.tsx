// Created by Claude — Classification: INTERNAL
//
// Status bar (PROMPT.md §2, §3, §4). Control shows "UTF-8"; Grid shows the panel
// keyboard hint instead — same FooterVM, `variant` picks the trailing item.
// Left of the version: the Claude status fields the user pinned (see StatusPicker) and
// the "+" that adds more. A field the selected session lacks is simply not rendered.

import { useLayoutEffect, useRef, useState } from "react";
import type { CSSProperties } from "react";
import type { FooterVM } from "./types";
import { plural } from "./text";
import { ChatRailIcon, PlusIcon, TextSizeIcon } from "./icons";
import { TerminalAppearanceMenu } from "./TerminalAppearance";
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
      style={{ ...NOWRAP, flexShrink: 0, maxWidth: 320, cursor: "default" }}
    >
      <span style={{ color: "var(--text-faint)" }}>{field.label} </span>
      {value}
    </span>
  );
}

const FOOTER_ICON_BTN: CSSProperties = {
  width: 20,
  height: 20,
  flexShrink: 0,
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  padding: 0,
  border: "none",
  borderRadius: 5,
  background: "transparent",
  color: "var(--text-muted)",
};

/**
 * One line while the chosen status fields fit; a second line for them (right-aligned,
 * never truncated) only once they don't. Measured before paint: the fields are laid out
 * in the first line, and if they overflow we remember the footer width they would need,
 * so the footer goes back to one line only when it is wide enough again (no flip-flop
 * at the boundary). Any change to the fields or their values re-measures from one line.
 */
function useStatusSecondLine(key: string) {
  const rowRef = useRef<HTMLDivElement>(null);
  const fieldsRef = useRef<HTMLDivElement>(null);
  const [twoLine, setTwoLine] = useState(false);
  const need = useRef(0);
  const lastKey = useRef(key);
  useLayoutEffect(() => {
    if (lastKey.current !== key) {
      lastKey.current = key;
      need.current = 0;
      if (twoLine) {
        setTwoLine(false); // lay out in one line again, then re-measure
        return;
      }
    }
    const row = rowRef.current;
    if (!row) return;
    const check = () => {
      setTwoLine((was) => {
        if (!was) {
          const f = fieldsRef.current;
          const over = f ? f.scrollWidth - f.clientWidth : 0;
          if (over <= 0) return false;
          need.current = row.clientWidth + over;
          return true;
        }
        return row.clientWidth < need.current;
      });
    };
    check();
    if (typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(check);
    ro.observe(row);
    return () => ro.disconnect();
  }, [key, twoLine]);
  return { rowRef, fieldsRef, twoLine };
}

export function Footer({ workspaceCount, agents, working, waiting, collisions, version, variant, status, composer }: FooterVM) {
  const [anchor, setAnchor] = useState<Anchor | null>(null);
  const [appearance, setAppearance] = useState<Anchor | null>(null);
  const shown = status ? status.fields.filter((id) => statusValue(id, status.data) !== null) : [];
  const key = shown.map((id) => `${id}=${statusValue(id, status?.data ?? null)}`).join("|");
  const { rowRef, fieldsRef, twoLine } = useStatusSecondLine(key);
  const items = status
    ? status.fields.map((id) => <StatusItem key={id} id={id} data={status.data} onRemove={status.onRemove} />)
    : null;
  return (
    <footer
      style={{
        flexShrink: 0,
        display: "flex",
        flexDirection: "column",
        borderTop: "1px solid var(--border)",
        background: "var(--bg-chrome)",
        fontSize: 12,
        color: "var(--text-muted)",
      }}
    >
    <div
      ref={rowRef}
      style={{
        height: 28,
        flexShrink: 0,
        display: "flex",
        alignItems: "center",
        gap: 18,
        padding: "0 16px",
        minWidth: 0,
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
      {status && !twoLine && (
        <div ref={fieldsRef} style={{ display: "flex", alignItems: "center", gap: 14, minWidth: 0, flexShrink: 1, overflow: "hidden" }}>
          {items}
        </div>
      )}
      <span style={NOWRAP}>{variant === "grid" ? "Tab to switch panels · ⌘⏎ maximize" : "UTF-8"}</span>
      <span style={{ display: "flex", alignItems: "center", gap: 2, marginRight: -8, flexShrink: 0 }}>
        <button
          type="button"
          aria-label="Terminal appearance"
          title="Terminal font size, spacing and colors"
          aria-expanded={appearance !== null}
          onClick={(e) => setAppearance(anchorFromRect(e.currentTarget.getBoundingClientRect(), "right", "above"))}
          className="rd-icon-btn"
          style={{ ...FOOTER_ICON_BTN, color: appearance ? "var(--text)" : "var(--text-muted)" }}
        >
          <TextSizeIcon size={14} />
        </button>
        {composer && variant !== "grid" && (
          <button
            type="button"
            aria-label={composer.open ? "Hide message box" : "Show message box"}
            title={composer.open ? "Hide message box" : "Show message box"}
            aria-pressed={composer.open}
            onClick={composer.onToggle}
            className="rd-icon-btn"
            style={{ ...FOOTER_ICON_BTN, color: composer.open ? "var(--text)" : "var(--text-muted)" }}
          >
            <ChatRailIcon size={13} />
          </button>
        )}
        {status && (
          <button
            type="button"
            aria-label="Add status field"
            title="Add status field"
            onClick={(e) => {
              setAnchor(anchorFromRect(e.currentTarget.getBoundingClientRect(), "right", "above"));
              status?.onPickerOpenChange?.(true);
            }}
            className="rd-icon-btn"
            style={FOOTER_ICON_BTN}
          >
            <PlusIcon size={12} />
          </button>
        )}
      </span>
      <span style={NOWRAP}>Muya v{version}</span>
    </div>
      {status && twoLine && (
        <div
          data-status-line="2"
          style={{ display: "flex", flexWrap: "wrap", justifyContent: "flex-end", alignItems: "center", columnGap: 14, rowGap: 4, padding: "0 16px 7px", minWidth: 0 }}
        >
          {items}
        </div>
      )}
      {appearance && (
        <TerminalAppearanceMenu
          anchor={appearance}
          appTheme={document.documentElement.dataset.theme === "light" ? "light" : "dark"}
          onClose={() => setAppearance(null)}
        />
      )}
      {status && anchor && (
        <StatusPicker anchor={anchor} fields={status.fields} data={status.data} onToggle={status.onToggle} onClose={() => {
            setAnchor(null);
            status.onPickerOpenChange?.(false);
          }} />
      )}
    </footer>
  );
}

// Created by Claude — Classification: INTERNAL
//
// Popover opened by the composer's "/ Commands" chip: type-to-filter list of the slash
// commands available to the agent in this terminal, grouped Built-in / Project / User /
// Skills. ↑/↓ + Enter or click picks one; Esc or an outside click closes. Rows and
// headings are module-level components (never declared inside a render body).

import { useEffect, useMemo, useRef, useState } from "react";
import type { KeyboardEvent } from "react";
import type { SlashItem, SlashSource } from "./useSlashCommands";

const WIDTH = 420;
const GROUPS: { source: SlashSource; label: string }[] = [
  { source: "builtin", label: "BUILT-IN" },
  { source: "project", label: "PROJECT" },
  { source: "user", label: "USER" },
  { source: "skill", label: "SKILLS" },
];

export function filterSlashItems(items: SlashItem[], query: string): SlashItem[] {
  const q = query.trim().replace(/^\//, "").toLowerCase();
  if (!q) return items;
  const starts: SlashItem[] = [];
  const rest: SlashItem[] = [];
  for (const it of items) {
    const n = it.name.toLowerCase();
    if (n.startsWith(q)) starts.push(it);
    else if (n.includes(q) || it.description.toLowerCase().includes(q)) rest.push(it);
  }
  return [...starts, ...rest];
}

/** Flat display order: by group, keeping each group's own order. */
function orderByGroup(items: SlashItem[]): SlashItem[] {
  return GROUPS.flatMap((g) => items.filter((i) => i.source === g.source));
}

function optionId(item: SlashItem) {
  return `rd-slash-${item.source}-${item.name.replace(/[^a-zA-Z0-9_-]/g, "_")}`;
}

function GroupHeading({ children }: { children: string }) {
  return (
    <li role="presentation" style={{ padding: "8px 10px 4px", fontSize: 11, fontWeight: 600, letterSpacing: "0.06em", color: "var(--text-muted)" }}>
      {children}
    </li>
  );
}

function SlashRow({ item, active, onPick, onHover }: { item: SlashItem; active: boolean; onPick: (i: SlashItem) => void; onHover: () => void }) {
  return (
    <li
      id={optionId(item)}
      role="option"
      aria-selected={active}
      // mouseDown (not click) so the input keeps focus and the backdrop never sees it.
      onMouseDown={(e) => {
        e.preventDefault();
        e.stopPropagation();
        onPick(item);
      }}
      onMouseEnter={onHover}
      style={{ display: "flex", alignItems: "center", gap: 10, height: 28, padding: "0 10px", borderRadius: 6, background: active ? "var(--bg-segment)" : "transparent", cursor: "pointer", boxSizing: "border-box" }}
    >
      <span className="rd-ellipsis" style={{ fontFamily: "var(--font-mono)", fontSize: 12.5, color: "var(--text)", flexShrink: 0, maxWidth: 170 }}>
        /{item.name}
      </span>
      <span className="rd-ellipsis" style={{ fontSize: 12, color: "var(--text-muted)", flexGrow: 1, minWidth: 0 }}>
        {item.description}
      </span>
    </li>
  );
}

export interface SlashCommandsPopoverProps {
  /** The "/ Commands" chip's rect; the popover hangs above it. */
  anchor: DOMRect;
  items: SlashItem[];
  loading?: boolean;
  onPick: (name: string) => void;
  onClose: () => void;
}

export function SlashCommandsPopover({ anchor, items, loading, onPick, onClose }: SlashCommandsPopoverProps) {
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLUListElement>(null);

  const shown = useMemo(() => filterSlashItems(items, query), [items, query]);
  // Display order (grouped) is what ↑/↓ walks.
  const flat = useMemo(() => orderByGroup(shown), [shown]);
  const active = Math.min(index, Math.max(0, flat.length - 1));

  useEffect(() => {
    inputRef.current?.focus();
  }, []);
  useEffect(() => {
    const onKey = (e: globalThis.KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [onClose]);
  useEffect(() => {
    const el = flat[active] ? listRef.current?.querySelector<HTMLElement>(`#${CSS.escape(optionId(flat[active]))}`) : null;
    el?.scrollIntoView?.({ block: "nearest" });
  }, [active, flat]);

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setIndex(flat.length ? (active + 1) % flat.length : 0);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setIndex(flat.length ? (active - 1 + flat.length) % flat.length : 0);
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (flat[active]) onPick(flat[active].name);
    }
  }

  const left = Math.max(8, Math.min(anchor.left, window.innerWidth - WIDTH - 8));
  const bottom = window.innerHeight - anchor.top + 6;

  return (
    <div className="rd-root" style={{ position: "fixed", inset: 0, zIndex: 150 }} onMouseDown={onClose}>
      <div
        role="dialog"
        aria-label="Slash commands"
        onMouseDown={(e) => e.stopPropagation()}
        style={{ position: "absolute", left, bottom, width: WIDTH, background: "var(--bg-panel)", border: "1px solid var(--border-strong)", borderRadius: 10, boxShadow: "var(--shadow-popover, 0 12px 40px rgba(0,0,0,0.35))", color: "var(--text)", fontSize: 13, display: "flex", flexDirection: "column", boxSizing: "border-box" }}
      >
        <div style={{ padding: 8, borderBottom: "1px solid var(--border)" }}>
          <input
            ref={inputRef}
            type="text"
            role="combobox"
            aria-label="Filter slash commands"
            aria-expanded="true"
            aria-controls="rd-slash-list"
            aria-activedescendant={flat[active] ? optionId(flat[active]) : undefined}
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setIndex(0);
            }}
            onKeyDown={onKeyDown}
            placeholder="Filter commands…"
            style={{ width: "100%", boxSizing: "border-box", height: 28, padding: "0 8px", borderRadius: 6, border: "1px solid var(--border-control)", background: "var(--bg-input)", color: "var(--text)", fontSize: 13, outline: "none" }}
          />
        </div>
        <ul ref={listRef} id="rd-slash-list" role="listbox" aria-label="Slash commands" style={{ listStyle: "none", margin: 0, padding: 4, maxHeight: 320, overflowY: "auto", overflowX: "hidden" }}>
          {GROUPS.map((g) => {
            const rows = flat.filter((i) => i.source === g.source);
            if (!rows.length) return null;
            return [
              <GroupHeading key={`h-${g.source}`}>{g.label}</GroupHeading>,
              ...rows.map((it) => {
                const at = flat.indexOf(it);
                return <SlashRow key={`${it.source}-${it.name}`} item={it} active={at === active} onPick={(i) => onPick(i.name)} onHover={() => setIndex(at)} />;
              }),
            ];
          })}
          {!flat.length && (
            <li role="presentation" style={{ padding: "12px 10px", fontSize: 12, color: "var(--text-muted)" }}>
              {loading ? "Loading…" : "No matching commands"}
            </li>
          )}
        </ul>
      </div>
    </div>
  );
}

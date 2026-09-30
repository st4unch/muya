// Created by Claude — Classification: INTERNAL
//
// The "Files" half of the agents panel (docs/prd-v04-followups.md §2): a full-width
// header row (chevron + FILES + root count) that toggles the section, and — when
// expanded — the file tree in the slot under a draggable split. Collapsed it is the
// header only, pinned above the panel footer. Presentational: state lives in the caller.

import { useMemo, useRef, useState, type ReactNode } from "react";
import { FileTreeSearchContext } from "../components/fileTreeSearch";
import { ChevronDownIcon, ChevronRightIcon, SearchIcon } from "./icons";
import { ResizeHandle } from "./ResizeHandle";

export const FILES_MIN = 120;
export const FILES_MAX = 2000;

export interface FilesSectionProps {
  open: boolean;
  onToggle: () => void;
  count: number;
  /** null = fill every pixel the agents list doesn't use (the default). */
  height: number | null;
  onHeightChange: (px: number) => void;
  onHeightReset: () => void;
  children?: ReactNode;
}

export function FilesSection({ open, onToggle, count, height, onHeightChange, onHeightReset, children }: FilesSectionProps) {
  const ref = useRef<HTMLElement>(null);
  const [searchOpen, setSearchOpen] = useState(false);
  const search = useMemo(() => ({ open: searchOpen, setOpen: setSearchOpen }), [searchOpen]);
  // Largest the section may grow: what it has now plus what the agents list can give up
  // while keeping its own minimum.
  const getMax = () => {
    const sec = ref.current;
    const list = sec?.previousElementSibling as HTMLElement | null;
    if (!sec || !list) return FILES_MAX;
    return sec.offsetHeight + list.offsetHeight - FILES_MIN;
  };
  return (
    <section
      ref={ref}
      aria-label="Files"
      style={{
        position: "relative",
        boxSizing: "border-box",
        flex: !open ? "0 0 auto" : height === null ? "1 1 0px" : `0 1 ${height}px`,
        minHeight: open ? FILES_MIN : undefined,
        display: "flex",
        flexDirection: "column",
        borderTop: "1px solid var(--border)",
      }}
    >
      {open && (
        <ResizeHandle
          side="top"
          label="Resize files section"
          min={FILES_MIN}
          max={FILES_MAX}
          getMax={getMax}
          onResize={onHeightChange}
          onReset={onHeightReset}
        />
      )}
      <div style={{ display: "flex", alignItems: "center", height: 34, flexShrink: 0, paddingRight: 10 }}>
        <button
          type="button"
          onClick={onToggle}
          aria-expanded={open}
          className="rd-files-head"
          style={{
            flex: 1,
            minWidth: 0,
            height: "100%",
            display: "flex",
            alignItems: "center",
            gap: 6,
            padding: "0 6px 0 16px",
            border: "none",
            background: "transparent",
            color: "var(--text-muted)",
            fontSize: 11,
            fontWeight: 600,
            letterSpacing: "0.06em",
            textAlign: "left",
            whiteSpace: "nowrap",
          }}
        >
          {open ? <ChevronDownIcon size={14} /> : <ChevronRightIcon size={14} />}
          <span>FILES</span>
          <span style={{ fontWeight: 400, letterSpacing: 0 }}>{count}</span>
        </button>
        {open && (
          <button
            type="button"
            className="rd-icon-btn"
            aria-label={searchOpen ? "Close file filter" : "Filter files"}
            title="Filter files"
            aria-pressed={searchOpen}
            onClick={() => setSearchOpen(!searchOpen)}
            style={{
              width: 24,
              height: 24,
              flexShrink: 0,
              display: "inline-flex",
              alignItems: "center",
              justifyContent: "center",
              borderRadius: 6,
              border: "none",
              background: "transparent",
              color: "var(--text-muted)",
              cursor: "pointer",
            }}
          >
            <SearchIcon size={13} />
          </button>
        )}
      </div>
      {open && (
        <div style={{ flexGrow: 1, minHeight: 0, overflow: "auto" }}>
          <FileTreeSearchContext.Provider value={search}>{children}</FileTreeSearchContext.Provider>
        </div>
      )}
    </section>
  );
}

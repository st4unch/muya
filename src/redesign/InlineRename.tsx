// Created by Claude — Classification: INTERNAL
//
// In-place rename field for a session name (agents list, session header, grid panel).
// Enter or blur commits a non-empty, changed name; Esc cancels. Keys are stopped here so
// the app's global shortcuts (Esc exits grid, ⌘1–7, …) and the terminal never see them.

import { useEffect, useRef, useState, type CSSProperties } from "react";

export function InlineRename({
  initial,
  onCommit,
  onCancel,
  style,
  label = "Session name",
}: {
  initial: string;
  onCommit: (name: string) => void;
  onCancel: () => void;
  style?: CSSProperties;
  label?: string;
}) {
  const [value, setValue] = useState(initial);
  const ref = useRef<HTMLInputElement>(null);
  const done = useRef(false);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.focus();
    el.select();
  }, []);

  const finish = (commit: boolean) => {
    if (done.current) return;
    done.current = true;
    const name = value.trim();
    if (commit && name && name !== initial) onCommit(name);
    else onCancel();
  };

  return (
    <input
      ref={ref}
      aria-label={label}
      value={value}
      spellCheck={false}
      maxLength={80}
      onChange={(e) => setValue(e.target.value)}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") {
          e.preventDefault();
          finish(true);
        } else if (e.key === "Escape") {
          e.preventDefault();
          finish(false);
        }
      }}
      onBlur={() => finish(true)}
      onClick={(e) => e.stopPropagation()}
      onDoubleClick={(e) => e.stopPropagation()}
      style={{
        minWidth: 0,
        width: "100%",
        boxSizing: "border-box",
        height: 24,
        padding: "0 6px",
        margin: "-3px 0",
        borderRadius: 6,
        border: "1px solid var(--accent)",
        outline: "none",
        background: "var(--bg-panel)",
        color: "var(--text)",
        fontFamily: "var(--font-sans)",
        fontSize: 13,
        fontWeight: 600,
        ...style,
      }}
    />
  );
}

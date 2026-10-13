// Created by Claude — Classification: INTERNAL
//
// The v0.4 modal look, shared: SettingsModal's shell (title bar with ×, scrolling
// body, footer), its group label / helper text / 32px controls, the segmented
// control and the on/off switch. New dialogs build from these instead of mixing
// in other style sets, so every modal in Muya reads the same.

import { useEffect, useId, useRef, type CSSProperties, type KeyboardEvent as ReactKeyboardEvent, type ReactNode } from "react";
import { X } from "lucide-react";

export const labelStyle: CSSProperties = {
  fontSize: 11,
  fontWeight: 600,
  letterSpacing: ".06em",
  textTransform: "uppercase",
  color: "var(--text-muted)",
  whiteSpace: "nowrap",
};
export const helperStyle: CSSProperties = { fontSize: 12, color: "var(--text-faint)", lineHeight: 1.45 };
export const groupStyle: CSSProperties = { display: "flex", flexDirection: "column", gap: 8, minWidth: 0 };
export const ghostBtn: CSSProperties = {
  height: 32,
  padding: "0 12px",
  borderRadius: 7,
  border: "1px solid var(--border-control)",
  background: "var(--bg-control)",
  color: "var(--text)",
  fontSize: 13,
  whiteSpace: "nowrap",
  cursor: "pointer",
  display: "inline-flex",
  alignItems: "center",
  gap: 6,
};
export const primaryBtn: CSSProperties = {
  height: 32,
  padding: "0 14px",
  borderRadius: 7,
  border: "none",
  background: "var(--primary-bg)",
  color: "var(--primary-fg)",
  fontSize: 13,
  fontWeight: 600,
  whiteSpace: "nowrap",
  cursor: "pointer",
  display: "inline-flex",
  alignItems: "center",
  gap: 6,
};
export const dangerBtn: CSSProperties = {
  ...primaryBtn,
  background: "var(--danger-btn-bg)",
  color: "var(--danger-text)",
  border: "1px solid var(--danger-border)",
};
export const inputStyle: CSSProperties = {
  width: "100%",
  boxSizing: "border-box",
  height: 32,
  padding: "0 10px",
  borderRadius: 7,
  border: "1px solid var(--border-control)",
  background: "var(--bg-input)",
  color: "var(--text)",
  fontSize: 13,
  minWidth: 0,
};
/** A bordered block of rows, like Settings' Startup group. */
export const rowsBox: CSSProperties = { border: "1px solid var(--border)", borderRadius: 10, overflow: "hidden" };
export const rowStyle: CSSProperties = { display: "flex", alignItems: "flex-start", gap: 12, padding: "12px 14px" };

/** Hover / focus rules the inline styles can't express. Rendered once per modal. */
export function ModalCss() {
  return (
    <style>{`
      .st-root input:focus-visible, .st-root textarea:focus-visible, .st-root button:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
      .st-root input::placeholder, .st-root textarea::placeholder { color: var(--text-faint); }
      .st-btn:not(:disabled):hover { background: var(--bg-segment); }
      .st-seg:not([aria-checked="true"]):hover { color: var(--text); }
      .st-primary:not(:disabled):hover { filter: brightness(0.92); }
      .st-root button:disabled { opacity: .45; cursor: default; }
    `}</style>
  );
}

const FOCUSABLE = 'button:not([disabled]), input:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/** Settings' modal shell: backdrop, 12px panel, title bar with ×, scrolling body, footer.
 *  `role="dialog"` so the terminal key-guard stops forwarding keys to a PTY. Esc closes;
 *  Tab stays inside; ⌘Enter runs `onSubmit`. */
export function ModalShell({
  title,
  onClose,
  onSubmit,
  width = 480,
  footer,
  children,
}: {
  title: ReactNode;
  onClose: () => void;
  onSubmit?: () => void;
  width?: number;
  footer?: ReactNode;
  children: ReactNode;
}) {
  const titleId = useId();
  const ref = useRef<HTMLDivElement>(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.stopPropagation();
      closeRef.current();
    };
    window.addEventListener("keydown", onKey, true);
    const t = setTimeout(() => ref.current?.querySelector<HTMLElement>("[data-autofocus], input, textarea")?.focus(), 0);
    return () => {
      window.removeEventListener("keydown", onKey, true);
      clearTimeout(t);
    };
  }, []);

  const onKeyDown = (e: ReactKeyboardEvent) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && onSubmit) {
      e.preventDefault();
      onSubmit();
      return;
    }
    if (e.key !== "Tab" || !ref.current) return;
    const els = Array.from(ref.current.querySelectorAll<HTMLElement>(FOCUSABLE));
    if (els.length === 0) return;
    const first = els[0];
    const last = els[els.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  };

  return (
    <div
      style={{ position: "fixed", inset: 0, zIndex: 100, background: "rgba(0,0,0,0.5)", display: "flex", alignItems: "center", justifyContent: "center", padding: 24 }}
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <ModalCss />
      <div
        ref={ref}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        className="st-root"
        onKeyDown={onKeyDown}
        style={{
          width,
          maxWidth: "100%",
          maxHeight: "85vh",
          display: "flex",
          flexDirection: "column",
          borderRadius: 12,
          border: "1px solid var(--border)",
          background: "var(--bg-panel)",
          color: "var(--text)",
          fontFamily: "var(--font-sans)",
          overflow: "hidden",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12, padding: "14px 20px", borderBottom: "1px solid var(--border)", flexShrink: 0 }}>
          <h2 id={titleId} style={{ margin: 0, fontSize: 15, fontWeight: 600, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
            {title}
          </h2>
          <button type="button" aria-label="Close" onClick={onClose} className="st-btn" style={{ width: 28, height: 28, flexShrink: 0, borderRadius: 7, border: "none", background: "transparent", color: "var(--text-muted)", display: "inline-flex", alignItems: "center", justifyContent: "center", cursor: "pointer" }}>
            <X size={16} />
          </button>
        </div>
        <div style={{ flex: 1, minHeight: 0, overflowY: "auto", padding: 20, display: "flex", flexDirection: "column", gap: 20 }}>{children}</div>
        {footer && (
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, padding: "12px 20px", borderTop: "1px solid var(--border)", flexShrink: 0 }}>
            {footer}
          </div>
        )}
      </div>
    </div>
  );
}

/** Settings' segmented control (radiogroup; arrow keys move the choice). */
export function Segmented<T extends string>({
  value,
  options,
  onChange,
  labelledBy,
}: {
  value: T;
  options: { value: T; label: string }[];
  onChange: (v: T) => void;
  labelledBy?: string;
}) {
  const onKey = (e: ReactKeyboardEvent, i: number) => {
    const step = e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : 0;
    if (!step) return;
    e.preventDefault();
    onChange(options[(i + step + options.length) % options.length].value);
  };
  return (
    <div role="radiogroup" aria-labelledby={labelledBy} style={{ display: "flex", padding: 3, gap: 2, borderRadius: 9, background: "var(--bg-segment)" }}>
      {options.map((o, i) => {
        const active = o.value === value;
        return (
          <button
            key={o.value}
            type="button"
            role="radio"
            aria-checked={active}
            tabIndex={active ? 0 : -1}
            onClick={() => onChange(o.value)}
            onKeyDown={(e) => onKey(e, i)}
            className="st-seg"
            style={{
              flex: 1,
              height: 30,
              borderRadius: 7,
              border: "none",
              background: active ? "var(--bg-segment-active)" : "transparent",
              boxShadow: active ? "var(--shadow-segment-active)" : "none",
              color: active ? "var(--text)" : "var(--text-muted)",
              fontSize: 13,
              fontWeight: active ? 600 : 500,
              whiteSpace: "nowrap",
              cursor: "pointer",
            }}
          >
            {o.label}
          </button>
        );
      })}
    </div>
  );
}

/** A 32×18 on/off switch (role="switch"), accent track when on. */
export function Switch({ checked, onChange, labelledBy, disabled }: { checked: boolean; onChange: (v: boolean) => void; labelledBy: string; disabled?: boolean }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-labelledby={labelledBy}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      style={{
        position: "relative",
        width: 32,
        height: 18,
        flexShrink: 0,
        marginTop: 1,
        padding: 0,
        borderRadius: 9,
        border: "none",
        background: checked ? "var(--accent)" : "var(--border-control)",
        transition: "background-color 120ms",
        cursor: "pointer",
      }}
    >
      <span
        style={{
          position: "absolute",
          top: 2,
          left: checked ? 16 : 2,
          width: 14,
          height: 14,
          borderRadius: 7,
          // Off: a muted knob reads on both themes' grey track; on: panel colour on the accent.
          background: checked ? "var(--bg-panel)" : "var(--text-muted)",
          boxShadow: "var(--shadow-segment-active)",
          transition: "left 120ms, background-color 120ms",
        }}
      />
    </button>
  );
}

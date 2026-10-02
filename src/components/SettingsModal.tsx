import { useEffect, useId, useRef, useState, type CSSProperties, type KeyboardEvent as ReactKeyboardEvent } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Check, X } from "lucide-react";
import type { ThemePreference } from "../theme/theme";
import { ThemeMonitorIcon, ThemeMoonIcon, ThemeSunIcon } from "../redesign/icons";

const DEFAULT_LOG_PATH = "~/.claude/muya-debug.log";

const THEMES: { value: ThemePreference; label: string; Icon: typeof ThemeSunIcon }[] = [
  { value: "system", label: "System", Icon: ThemeMonitorIcon },
  { value: "light", label: "Light", Icon: ThemeSunIcon },
  { value: "dark", label: "Dark", Icon: ThemeMoonIcon },
];

const labelStyle: CSSProperties = {
  fontSize: 11,
  fontWeight: 600,
  letterSpacing: ".06em",
  textTransform: "uppercase",
  color: "var(--text-muted)",
  whiteSpace: "nowrap",
};
const helperStyle: CSSProperties = { fontSize: 12, color: "var(--text-faint)", lineHeight: 1.45 };
const groupStyle: CSSProperties = { display: "flex", flexDirection: "column", gap: 8, minWidth: 0 };
const ghostBtn: CSSProperties = {
  height: 32,
  padding: "0 12px",
  borderRadius: 7,
  border: "1px solid var(--border-control)",
  background: "var(--bg-control)",
  color: "var(--text)",
  fontSize: 13,
  whiteSpace: "nowrap",
  cursor: "pointer",
};

const FOCUSABLE = 'button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex="-1"])';

/**
 * App Settings, in the v0.4 design (tokens only, same shell as NewAgentModal):
 * appearance (applies immediately) and debug logging for the CyberArk + SSH flows
 * (toggle + log-file path, saved with Save). The backend (`debug_log_set`) persists
 * the choice to ~/.claude/muya-settings.json and NEVER logs secret values — only
 * step metadata (usernames, URLs, HTTP status, counts).
 *
 * `role="dialog"` + a fixed backdrop, so the Terminal key-guard suppresses PTY
 * input while it is open (same as NewAgentModal / ScheduledPromptModal).
 */
export default function SettingsModal({
  open,
  onClose,
  themePreference,
  onThemePreferenceChange,
}: {
  open: boolean;
  onClose: () => void;
  /** App theme preference; the appearance group renders only when both are given. */
  themePreference?: ThemePreference;
  onThemePreferenceChange?: (pref: ThemePreference) => void;
}) {
  const uid = useId();
  const id = (s: string) => `${uid}-${s}`;
  const [enabled, setEnabled] = useState(false);
  const [path, setPath] = useState(DEFAULT_LOG_PATH);
  // What the backend holds — Save is enabled only when the form differs from it.
  const [stored, setStored] = useState<{ enabled: boolean; path: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  const dialogRef = useRef<HTMLDivElement>(null);

  // Load current settings whenever the modal opens.
  useEffect(() => {
    if (!open) return;
    setError("");
    setSaved(false);
    setStored(null);
    invoke<{ enabled: boolean; path: string }>("debug_log_get")
      .then((v) => {
        const cur = { enabled: !!v.enabled, path: v.path || DEFAULT_LOG_PATH };
        setEnabled(cur.enabled);
        setPath(cur.path);
        setStored(cur);
      })
      .catch((e) => setError(String(e)));
    const t = setTimeout(() => dialogRef.current?.querySelector<HTMLElement>('[role="radio"][aria-checked="true"], [role="switch"]')?.focus(), 0);
    return () => clearTimeout(t);
  }, [open]);

  // Esc closes (capture: a focused xterm would otherwise see it first).
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.stopPropagation();
      onClose();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [open, onClose]);

  if (!open) return null;

  const cleanPath = path.trim() || DEFAULT_LOG_PATH;
  const dirty = stored !== null && (stored.enabled !== enabled || stored.path !== cleanPath);

  const save = async () => {
    if (!dirty || busy) return;
    setBusy(true);
    setError("");
    setSaved(false);
    try {
      await invoke("debug_log_set", { enabled, path: cleanPath });
      setStored({ enabled, path: cleanPath });
      setPath(cleanPath);
      setSaved(true);
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  };

  const edit = () => setSaved(false);

  // Focus trap + ⌘Enter saves.
  const onDialogKey = (e: ReactKeyboardEvent) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      void save();
      return;
    }
    if (e.key !== "Tab" || !dialogRef.current) return;
    const els = Array.from(dialogRef.current.querySelectorAll<HTMLElement>(FOCUSABLE));
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

  // Arrow keys move through the theme segment (radiogroup pattern).
  const onThemeKey = (e: ReactKeyboardEvent, i: number) => {
    if (!onThemePreferenceChange) return;
    const step = e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : 0;
    if (!step) return;
    e.preventDefault();
    const next = THEMES[(i + step + THEMES.length) % THEMES.length].value;
    onThemePreferenceChange(next);
    requestAnimationFrame(() => document.getElementById(id(`theme-${next}`))?.focus());
  };

  return (
    <div style={{ position: "fixed", inset: 0, zIndex: 100, background: "rgba(0,0,0,0.5)", display: "flex", alignItems: "center", justifyContent: "center", padding: 24 }}>
      <style>{`
        .st-root input:focus-visible, .st-root button:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
        .st-root input::placeholder { color: var(--text-faint); }
        .st-btn:not(:disabled):hover { background: var(--bg-segment); }
        .st-seg:not([aria-checked="true"]):hover { color: var(--text); }
        .st-primary:not(:disabled):hover { filter: brightness(0.92); }
      `}</style>
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={id("title")}
        className="st-root"
        onKeyDown={onDialogKey}
        style={{
          width: 480,
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
        {/* Header */}
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "14px 20px", borderBottom: "1px solid var(--border)", flexShrink: 0 }}>
          <h2 id={id("title")} style={{ margin: 0, fontSize: 15, fontWeight: 600 }}>Settings</h2>
          <button type="button" aria-label="Close" onClick={onClose} className="st-btn" style={{ width: 28, height: 28, borderRadius: 7, border: "none", background: "transparent", color: "var(--text-muted)", display: "inline-flex", alignItems: "center", justifyContent: "center", cursor: "pointer" }}>
            <X size={16} />
          </button>
        </div>

        {/* Body */}
        <div style={{ flex: 1, minHeight: 0, overflowY: "auto", padding: 20, display: "flex", flexDirection: "column", gap: 20 }}>
          {themePreference && onThemePreferenceChange && (
            <div style={groupStyle}>
              <span id={id("theme")} style={labelStyle}>Appearance</span>
              <div role="radiogroup" aria-labelledby={id("theme")} style={{ display: "flex", padding: 3, gap: 2, borderRadius: 9, background: "var(--bg-segment)" }}>
                {THEMES.map(({ value, label, Icon }, i) => {
                  const active = themePreference === value;
                  return (
                    <button
                      key={value}
                      id={id(`theme-${value}`)}
                      type="button"
                      role="radio"
                      aria-checked={active}
                      tabIndex={active ? 0 : -1}
                      onClick={() => onThemePreferenceChange(value)}
                      onKeyDown={(e) => onThemeKey(e, i)}
                      className="st-seg"
                      style={{
                        flex: 1,
                        height: 30,
                        display: "inline-flex",
                        alignItems: "center",
                        justifyContent: "center",
                        gap: 7,
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
                      <Icon size={14} />
                      {label}
                    </button>
                  );
                })}
              </div>
              <div style={helperStyle}>System follows your macOS appearance.</div>
            </div>
          )}

          <div style={groupStyle}>
            <span style={labelStyle}>Debug logging</span>
            <div style={{ border: "1px solid var(--border)", borderRadius: 10, overflow: "hidden" }}>
              <div style={{ display: "flex", alignItems: "flex-start", gap: 12, padding: "12px 14px" }}>
                <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 4 }}>
                  <span id={id("log")} style={{ fontSize: 13, fontWeight: 600, whiteSpace: "nowrap" }}>Log CyberArk + SSH connection steps</span>
                  <span style={helperStyle}>
                    Each CyberArk logon/list/retrieve and SSH connect step is appended with a timestamp. Metadata only —{" "}
                    <span style={{ color: "var(--text-muted)", fontWeight: 600 }}>never passwords, tokens or account secrets</span>.
                  </span>
                </div>
                <Switch
                  checked={enabled}
                  labelledBy={id("log")}
                  onChange={(v) => {
                    setEnabled(v);
                    edit();
                  }}
                />
              </div>
              <div style={{ display: "flex", flexDirection: "column", gap: 6, padding: "12px 14px", borderTop: "1px solid var(--border)", background: "var(--bg-control)" }}>
                <label htmlFor={id("path")} style={{ ...labelStyle, opacity: enabled ? 1 : 0.6 }}>Log file</label>
                <input
                  id={id("path")}
                  value={path}
                  onChange={(e) => {
                    setPath(e.target.value);
                    edit();
                  }}
                  placeholder={DEFAULT_LOG_PATH}
                  spellCheck={false}
                  style={{
                    width: "100%",
                    boxSizing: "border-box",
                    height: 32,
                    padding: "0 10px",
                    borderRadius: 7,
                    border: "1px solid var(--border-control)",
                    background: "var(--bg-panel)",
                    color: enabled ? "var(--text)" : "var(--text-muted)",
                    fontFamily: "var(--font-mono)",
                    fontSize: 12,
                    minWidth: 0,
                  }}
                />
              </div>
            </div>
          </div>

          {error && (
            <div role="alert" style={{ fontSize: 12, color: "var(--danger-text)", overflowWrap: "anywhere" }}>
              {error}
            </div>
          )}

          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12, fontSize: 12, color: "var(--text-muted)" }}>
            <span>Muya is built on open-source software.</span>
            <button
              type="button"
              onClick={() => void invoke("open_third_party_licenses").catch((e) => setError(`Couldn't open the license notices: ${e}`))}
              className="st-btn"
              style={{ ...ghostBtn, height: 28, fontSize: 12 }}
            >
              Open-source licenses
            </button>
          </div>
        </div>

        {/* Footer */}
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, padding: "12px 20px", borderTop: "1px solid var(--border)", flexShrink: 0 }}>
          <span aria-live="polite" style={{ fontSize: 12, whiteSpace: "nowrap", display: "inline-flex", alignItems: "center", gap: 6, color: saved ? "var(--success-text)" : "var(--text-faint)" }}>
            {saved ? (
              <>
                <Check size={13} /> Saved
              </>
            ) : dirty ? (
              "Unsaved changes · ⌘ Enter to save"
            ) : (
              "Theme changes apply right away"
            )}
          </span>
          <div style={{ display: "flex", gap: 8 }}>
            <button type="button" onClick={onClose} className="st-btn" style={ghostBtn}>Close</button>
            <button
              type="button"
              onClick={() => void save()}
              disabled={!dirty || busy}
              aria-busy={busy}
              className="st-primary"
              style={{ height: 32, padding: "0 14px", borderRadius: 7, border: "none", background: "var(--primary-bg)", color: "var(--primary-fg)", fontSize: 13, fontWeight: 600, whiteSpace: "nowrap", opacity: !dirty || busy ? 0.45 : 1, cursor: !dirty || busy ? "default" : "pointer" }}
            >
              {busy ? "Saving…" : "Save"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

/** A 32×18 on/off switch (role="switch"), accent track when on. */
function Switch({ checked, onChange, labelledBy }: { checked: boolean; onChange: (v: boolean) => void; labelledBy: string }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-labelledby={labelledBy}
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

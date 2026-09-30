import { useState, useEffect, useRef, useId, type CSSProperties, type KeyboardEvent as ReactKeyboardEvent } from "react";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { X, Plus, FileText, FolderSearch, ChevronDown, ChevronRight, RotateCcw } from "lucide-react";
import { AGENT_BASE_COMMAND, buildAgentCommand } from "../lib/agent";

export interface NewAgentSpec {
  type: "claude" | "opencode" | "terminal";
  workspace: string;
  branch: string;
  title: string;
  command: string;
  prompt: string;
  files: string[];
}

type AgentType = NewAgentSpec["type"];

const TYPES: { value: AgentType; label: string }[] = [
  { value: "claude", label: "Claude Code" },
  { value: "opencode", label: "opencode" },
  { value: "terminal", label: "Terminal" },
];

/** Claude permission modes. Flags verified against `claude --help`
 *  (--permission-mode choices: acceptEdits, auto, bypassPermissions, manual, dontAsk, plan;
 *  bypass keeps its long-standing dedicated flag so the default command is unchanged). */
export type ClaudeMode = "manual" | "acceptEdits" | "plan" | "auto" | "bypass";

export const CLAUDE_MODES: { value: ClaudeMode; label: string; hint: string; flag: string }[] = [
  { value: "manual", label: "Manual", hint: "Ask before every action", flag: "--permission-mode manual" },
  { value: "acceptEdits", label: "Accept edits", hint: "Edits are auto-approved, other actions ask", flag: "--permission-mode acceptEdits" },
  { value: "plan", label: "Plan", hint: "Read-only planning, no changes", flag: "--permission-mode plan" },
  { value: "auto", label: "Auto", hint: "A classifier approves safe actions", flag: "--permission-mode auto" },
  { value: "bypass", label: "Bypass permissions", hint: "Skip every permission check", flag: "--dangerously-skip-permissions" },
];

/** The base command (no prompt/files) for a type + option. */
export function baseCommand(type: AgentType, mode: ClaudeMode, autoApprove: boolean, agentsManager = false): string {
  if (type === "terminal") return "";
  if (type === "opencode") return autoApprove ? AGENT_BASE_COMMAND.opencode : "opencode";
  // The pre-v0.4 "claude agents" preset: Claude's own agent manager instead of a session.
  if (agentsManager) return "claude agents";
  const flag = CLAUDE_MODES.find((m) => m.value === mode)!.flag;
  return `claude ${flag}`;
}

const fieldStyle: CSSProperties = {
  width: "100%",
  boxSizing: "border-box",
  height: 32,
  padding: "0 10px",
  borderRadius: 7,
  border: "1px solid var(--border-control)",
  background: "var(--bg-control)",
  color: "var(--text)",
  fontFamily: "var(--font-sans)",
  fontSize: 13,
  minWidth: 0,
};
const monoStyle: CSSProperties = { fontFamily: "var(--font-mono)", fontSize: 12 };
const labelStyle: CSSProperties = {
  fontSize: 11,
  fontWeight: 600,
  letterSpacing: ".06em",
  textTransform: "uppercase",
  color: "var(--text-muted)",
  whiteSpace: "nowrap",
};
const helperStyle: CSSProperties = { fontSize: 12, color: "var(--text-faint)", lineHeight: 1.4 };
const groupStyle: CSSProperties = { display: "flex", flexDirection: "column", gap: 6, minWidth: 0 };
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
  display: "inline-flex",
  alignItems: "center",
  justifyContent: "center",
  gap: 6,
  flexShrink: 0,
};

const FOCUSABLE = 'button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])';

export default function NewAgentModal({
  open,
  onClose,
  workspaces,
  defaultWorkspace,
  onLaunch,
}: {
  open: boolean;
  onClose: () => void;
  workspaces: string[];
  /** Pre-selected workspace (the root the user selected in the tree). */
  defaultWorkspace?: string;
  onLaunch: (spec: NewAgentSpec) => Promise<void>;
}) {
  const defaultWs = defaultWorkspace ?? workspaces[0] ?? "";
  const uid = useId();
  const id = (s: string) => `${uid}-${s}`;

  const [type, setType] = useState<AgentType>("claude");
  const [mode, setMode] = useState<ClaudeMode>("bypass");
  const [autoApprove, setAutoApprove] = useState(true);
  const [agentsManager, setAgentsManager] = useState(false);
  const [workspace, setWorkspace] = useState(defaultWs);
  const [wsOpen, setWsOpen] = useState(false);
  const [title, setTitle] = useState("");
  const [branch, setBranch] = useState("");
  const [prompt, setPrompt] = useState("");
  const [files, setFiles] = useState<string[]>([]);
  const [advanced, setAdvanced] = useState(false);
  const [cmdEdit, setCmdEdit] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [wsError, setWsError] = useState("");

  const dialogRef = useRef<HTMLDivElement>(null);
  const wsRef = useRef<HTMLInputElement>(null);

  // Fresh form + tree-selected workspace + focus on the first field each open.
  useEffect(() => {
    if (!open) return;
    setWorkspace(defaultWs);
    setWsError("");
    setError("");
    setWsOpen(false);
    const t = setTimeout(() => wsRef.current?.focus(), 0);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, defaultWorkspace]);

  // Esc closes (a stray click outside does NOT — too easy to lose a filled form).
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.stopPropagation();
      if (wsOpen) setWsOpen(false);
      else onClose();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [open, onClose, wsOpen]);

  if (!open) return null;

  const isTerminal = type === "terminal";
  const activeWorkspace = workspace.trim();
  const base = baseCommand(type, mode, autoApprove, agentsManager);
  // The agents manager is an interactive picker — a prompt/files would be meaningless there.
  const takesInput = !isTerminal && !(type === "claude" && agentsManager);
  const generated = isTerminal ? "" : buildAgentCommand({ command: base, prompt: takesInput ? prompt : "", files: takesInput ? files : [] });
  const shownCommand = cmdEdit ?? generated;
  const overridden = cmdEdit !== null && cmdEdit !== generated;

  const pickType = (t: AgentType) => {
    setType(t);
    setCmdEdit(null);
    setWsError("");
  };

  const onTabKey = (e: ReactKeyboardEvent, i: number) => {
    if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
    e.preventDefault();
    const next = TYPES[(i + (e.key === "ArrowRight" ? 1 : TYPES.length - 1)) % TYPES.length].value;
    pickType(next);
    requestAnimationFrame(() => document.getElementById(id(`tab-${next}`))?.focus());
  };

  const addFiles = async () => {
    const sel = await openDialog({ multiple: true, title: "Select file(s)" });
    if (Array.isArray(sel)) setFiles((p) => [...new Set([...p, ...sel])]);
    else if (typeof sel === "string") setFiles((p) => [...new Set([...p, sel])]);
  };

  const browse = async () => {
    const sel = await openDialog({ directory: true, multiple: false, title: "Select workspace folder" });
    if (typeof sel === "string") {
      setWorkspace(sel);
      setWsError("");
    }
  };

  const launch = async () => {
    if (busy) return;
    if (!isTerminal && !activeWorkspace) {
      setWsError("Choose a workspace folder to run the agent in.");
      wsRef.current?.focus();
      return;
    }
    setBusy(true);
    setError("");
    try {
      // An edited command is the whole command: the prompt/files are already in it.
      const edited = overridden;
      await onLaunch({
        type,
        workspace: isTerminal ? activeWorkspace || defaultWs : activeWorkspace,
        branch: isTerminal ? "" : branch,
        title,
        command: isTerminal ? "" : edited ? (cmdEdit as string) : base,
        prompt: !takesInput || edited ? "" : prompt,
        files: !takesInput || edited ? [] : files,
      });
      setTitle("");
      setBranch("");
      setPrompt("");
      setFiles([]);
      setCmdEdit(null);
      onClose();
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  };

  const onDialogKey = (e: ReactKeyboardEvent) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      void launch();
      return;
    }
    if (e.key !== "Tab") return;
    const nodes = Array.from(dialogRef.current?.querySelectorAll<HTMLElement>(FOCUSABLE) ?? []).filter(
      (n) => n.offsetParent !== null || n === document.activeElement,
    );
    if (nodes.length === 0) return;
    const first = nodes[0];
    const last = nodes[nodes.length - 1];
    const active = document.activeElement;
    if (e.shiftKey && (active === first || !dialogRef.current?.contains(active))) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && (active === last || !dialogRef.current?.contains(active))) {
      e.preventDefault();
      first.focus();
    }
  };

  const modeInfo = CLAUDE_MODES.find((m) => m.value === mode)!;
  const showWs = true;

  return (
    <div
      style={{ position: "fixed", inset: 0, zIndex: 100, background: "rgba(0,0,0,0.5)", display: "flex", alignItems: "center", justifyContent: "center", padding: 24 }}
    >
      <style>{`
        .na-root input:focus-visible, .na-root textarea:focus-visible, .na-root select:focus-visible,
        .na-root button:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
        .na-root input::placeholder, .na-root textarea::placeholder { color: var(--text-faint); }
        .na-btn:not(:disabled):hover { background: var(--bg-segment); }
        .na-opt:hover { background: var(--bg-segment); }
        .na-primary:not(:disabled):hover { filter: brightness(0.92); }
      `}</style>
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={id("title")}
        className="na-root"
        onKeyDown={onDialogKey}
        style={{
          width: 520,
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
          <h2 id={id("title")} style={{ margin: 0, fontSize: 15, fontWeight: 600 }}>
            {isTerminal ? "New terminal" : "New agent"}
          </h2>
          <button type="button" aria-label="Close" onClick={onClose} className="na-btn" style={{ width: 28, height: 28, borderRadius: 7, border: "none", background: "transparent", color: "var(--text-muted)", display: "inline-flex", alignItems: "center", justifyContent: "center", cursor: "pointer" }}>
            <X size={16} />
          </button>
        </div>

        {/* Body (the only scrolling region) */}
        <div style={{ flex: 1, minHeight: 0, overflowY: "auto", padding: 20, display: "flex", flexDirection: "column", gap: 16 }}>
          {/* Agent type */}
          <div
            role="tablist"
            aria-label="Agent type"
            style={{ display: "flex", padding: 3, gap: 2, borderRadius: 9, background: "var(--bg-segment)", flexShrink: 0 }}
          >
            {TYPES.map((t, i) => {
              const active = t.value === type;
              return (
                <button
                  key={t.value}
                  id={id(`tab-${t.value}`)}
                  type="button"
                  role="tab"
                  aria-selected={active}
                  tabIndex={active ? 0 : -1}
                  onClick={() => pickType(t.value)}
                  onKeyDown={(e) => onTabKey(e, i)}
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
                  {t.label}
                </button>
              );
            })}
          </div>

          {/* Workspace */}
          {showWs && (
            <div style={groupStyle}>
              <label htmlFor={id("ws")} style={labelStyle}>
                Workspace{isTerminal ? " (optional)" : ""}
              </label>
              <div style={{ display: "flex", gap: 6, position: "relative" }}>
                <div style={{ position: "relative", flex: 1, minWidth: 0 }}>
                  <input
                    id={id("ws")}
                    ref={wsRef}
                    value={workspace}
                    onChange={(e) => {
                      setWorkspace(e.target.value);
                      if (wsError) setWsError("");
                    }}
                    placeholder={workspaces.length === 0 ? "Type or paste a folder path" : "/path/to/project"}
                    aria-invalid={wsError ? true : undefined}
                    aria-describedby={wsError ? id("ws-err") : undefined}
                    spellCheck={false}
                    style={{ ...fieldStyle, ...monoStyle, paddingRight: 34, borderColor: wsError ? "var(--danger-border)" : "var(--border-control)" }}
                  />
                  <button
                    type="button"
                    aria-label="Known workspaces"
                    aria-haspopup="listbox"
                    aria-expanded={wsOpen}
                    onClick={() => setWsOpen((o) => !o)}
                    disabled={workspaces.length === 0}
                    className="na-btn"
                    style={{ position: "absolute", right: 2, top: 2, width: 28, height: 28, borderRadius: 6, border: "none", background: "transparent", color: "var(--text-muted)", display: "inline-flex", alignItems: "center", justifyContent: "center", cursor: workspaces.length ? "pointer" : "default", opacity: workspaces.length ? 1 : 0.4 }}
                  >
                    <ChevronDown size={14} />
                  </button>
                  {wsOpen && (
                    <ul
                      role="listbox"
                      aria-label="Known workspaces"
                      style={{ position: "absolute", left: 0, right: 0, top: 36, zIndex: 5, margin: 0, padding: 4, listStyle: "none", maxHeight: 176, overflowY: "auto", borderRadius: 8, border: "1px solid var(--border-strong)", background: "var(--bg-control)" }}
                    >
                      {workspaces.map((w) => (
                        <li
                          key={w}
                          role="option"
                          aria-selected={w === workspace}
                          className="na-opt"
                          onMouseDown={(e) => e.preventDefault()}
                          onClick={() => {
                            setWorkspace(w);
                            setWsError("");
                            setWsOpen(false);
                            wsRef.current?.focus();
                          }}
                          style={{ ...monoStyle, padding: "6px 8px", borderRadius: 6, cursor: "pointer", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", color: w === workspace ? "var(--accent)" : "var(--text)" }}
                          title={w}
                        >
                          {w}
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
                <button type="button" onClick={() => void browse()} className="na-btn" style={ghostBtn}>
                  <FolderSearch size={14} /> Browse
                </button>
              </div>
              {wsError && (
                <div id={id("ws-err")} role="alert" style={{ fontSize: 12, color: "var(--danger-text)" }}>
                  {wsError}
                </div>
              )}
            </div>
          )}

          {/* Tab name */}
          <div style={groupStyle}>
            <label htmlFor={id("name")} style={labelStyle}>Name (optional)</label>
            <input id={id("name")} value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Tab name" style={fieldStyle} />
          </div>

          {/* Permission mode */}
          {type === "claude" && (
            <div style={groupStyle}>
              <label htmlFor={id("mode")} style={labelStyle}>Permission mode</label>
              <div style={{ position: "relative" }}>
                <select
                  id={id("mode")}
                  value={mode}
                  disabled={agentsManager}
                  onChange={(e) => {
                    setMode(e.target.value as ClaudeMode);
                    setCmdEdit(null);
                  }}
                  style={{ ...fieldStyle, appearance: "none", WebkitAppearance: "none", paddingRight: 30, cursor: "pointer" }}
                >
                  {CLAUDE_MODES.map((m) => (
                    <option key={m.value} value={m.value}>{m.label}</option>
                  ))}
                </select>
                <ChevronDown size={14} style={{ position: "absolute", right: 10, top: 9, color: "var(--text-muted)", pointerEvents: "none" }} />
              </div>
              <div style={helperStyle}>{agentsManager ? "Not used by the agents manager" : modeInfo.hint}</div>
              <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: "var(--text)", cursor: "pointer", whiteSpace: "nowrap", marginTop: 2 }}>
                <input
                  type="checkbox"
                  checked={agentsManager}
                  onChange={(e) => {
                    setAgentsManager(e.target.checked);
                    setCmdEdit(null);
                  }}
                  style={{ width: 15, height: 15, margin: 0, accentColor: "var(--accent)" }}
                />
                Open the agents manager instead
                <span style={{ ...monoStyle, color: "var(--text-faint)" }}>claude agents</span>
              </label>
            </div>
          )}
          {type === "opencode" && (
            <div style={groupStyle}>
              <span style={labelStyle}>Permissions</span>
              <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, cursor: "pointer" }}>
                <input
                  type="checkbox"
                  checked={autoApprove}
                  onChange={(e) => {
                    setAutoApprove(e.target.checked);
                    setCmdEdit(null);
                  }}
                  style={{ width: 15, height: 15, margin: 0, accentColor: "var(--accent)" }}
                />
                Auto-approve
              </label>
              <div style={helperStyle}>Approves every permission that is not explicitly denied</div>
            </div>
          )}

          {!isTerminal && (
            <>
              {/* Branch */}
              <div style={groupStyle}>
                <label htmlFor={id("branch")} style={labelStyle}>Branch (optional)</label>
                <input id={id("branch")} value={branch} onChange={(e) => setBranch(e.target.value)} placeholder="feature/my-task" spellCheck={false} style={{ ...fieldStyle, ...monoStyle }} />
                <div style={helperStyle}>Creates an isolated git worktree</div>
              </div>

              {/* Prompt */}
              {takesInput && (<>
              <div style={groupStyle}>
                <label htmlFor={id("prompt")} style={labelStyle}>Initial prompt (optional)</label>
                <textarea
                  id={id("prompt")}
                  value={prompt}
                  onChange={(e) => setPrompt(e.target.value)}
                  placeholder="Sent to the agent as soon as it starts"
                  rows={3}
                  style={{ ...fieldStyle, height: "auto", padding: "8px 10px", resize: "vertical", lineHeight: 1.45 }}
                />
              </div>

              {/* Files */}
              <div style={groupStyle}>
                <span style={labelStyle}>Files (optional)</span>
                <div style={{ display: "flex", flexWrap: "wrap", gap: 6, alignItems: "center" }}>
                  {files.map((f) => (
                    <span
                      key={f}
                      title={f}
                      style={{ display: "inline-flex", alignItems: "center", gap: 6, height: 26, maxWidth: "100%", padding: "0 4px 0 8px", borderRadius: 7, border: "1px solid var(--border-control)", background: "var(--bg-control)", fontSize: 12, ...monoStyle }}
                    >
                      <FileText size={12} style={{ flexShrink: 0, color: "var(--text-faint)" }} />
                      <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", maxWidth: 300 }}>{f.split("/").pop() || f}</span>
                      <button
                        type="button"
                        aria-label={`Remove ${f}`}
                        onClick={() => setFiles((p) => p.filter((x) => x !== f))}
                        className="na-btn"
                        style={{ width: 18, height: 18, borderRadius: 5, border: "none", background: "transparent", color: "var(--text-muted)", display: "inline-flex", alignItems: "center", justifyContent: "center", cursor: "pointer", flexShrink: 0 }}
                      >
                        <X size={12} />
                      </button>
                    </span>
                  ))}
                  <button type="button" onClick={() => void addFiles()} className="na-btn" style={{ ...ghostBtn, height: 26, padding: "0 10px", fontSize: 12 }}>
                    <Plus size={12} /> Add file
                  </button>
                </div>
              </div>
              </>)}

              {/* Advanced */}
              <div style={groupStyle}>
                <button
                  type="button"
                  aria-expanded={advanced}
                  aria-controls={id("adv")}
                  onClick={() => setAdvanced((a) => !a)}
                  style={{ alignSelf: "flex-start", display: "inline-flex", alignItems: "center", gap: 4, padding: 0, border: "none", background: "transparent", color: "var(--text-muted)", ...labelStyle, cursor: "pointer" }}
                >
                  {advanced ? <ChevronDown size={14} /> : <ChevronRight size={14} />} Advanced
                </button>
                {advanced && (
                  <div id={id("adv")} style={groupStyle}>
                    <label htmlFor={id("cmd")} style={{ fontSize: 12, color: "var(--text-muted)" }}>Command that will run</label>
                    <textarea
                      id={id("cmd")}
                      value={shownCommand}
                      onChange={(e) => setCmdEdit(e.target.value)}
                      rows={3}
                      spellCheck={false}
                      style={{ ...fieldStyle, ...monoStyle, height: "auto", padding: "8px 10px", resize: "vertical", lineHeight: 1.45 }}
                    />
                    <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, minHeight: 26 }}>
                      <span style={helperStyle}>{overridden ? "Edited: this replaces the generated command" : "Edit to override the generated command"}</span>
                      {overridden && (
                        <button type="button" onClick={() => setCmdEdit(null)} className="na-btn" style={{ ...ghostBtn, height: 26, padding: "0 10px", fontSize: 12 }}>
                          <RotateCcw size={12} /> Reset
                        </button>
                      )}
                    </div>
                  </div>
                )}
              </div>
            </>
          )}

          {error && (
            <div role="alert" style={{ fontSize: 12, color: "var(--danger-text)", background: "var(--danger-btn-bg)", border: "1px solid var(--danger-border)", borderRadius: 7, padding: "8px 10px", overflowWrap: "anywhere" }}>
              {error}
            </div>
          )}
        </div>

        {/* Footer */}
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, padding: "12px 20px", borderTop: "1px solid var(--border)", flexShrink: 0 }}>
          <span style={{ fontSize: 12, color: "var(--text-faint)", whiteSpace: "nowrap" }}>⌘ Enter to launch</span>
          <div style={{ display: "flex", gap: 8 }}>
            <button type="button" onClick={onClose} className="na-btn" style={ghostBtn}>Cancel</button>
            <button
              type="button"
              onClick={() => void launch()}
              disabled={busy}
              aria-busy={busy}
              className="na-primary"
              style={{ height: 32, padding: "0 14px", borderRadius: 7, border: "none", background: "var(--primary-bg)", color: "var(--primary-fg)", fontSize: 13, fontWeight: 600, whiteSpace: "nowrap", opacity: busy ? 0.6 : 1, cursor: busy ? "default" : "pointer" }}
            >
              {busy ? "Launching…" : isTerminal ? "Open terminal" : "Launch agent"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

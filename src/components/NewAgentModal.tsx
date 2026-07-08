import { useState, useEffect } from "react";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { X, Plus, FileText } from "lucide-react";

export interface NewAgentSpec {
  type: "claude" | "terminal";
  workspace: string;
  branch: string;
  title: string;
  command: string;
  prompt: string;
  files: string[];
}

type Preset = "skip-permissions" | "agents" | "blank";

const PRESETS: { value: Preset; label: string; command: string }[] = [
  { value: "skip-permissions", label: "claude --dangerously-skip-permissions", command: "claude --dangerously-skip-permissions" },
  { value: "agents",           label: "claude agents",                         command: "claude agents" },
  { value: "blank",            label: "Blank Terminal",                        command: "" },
];

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

  const [workspace, setWorkspace] = useState(defaultWs);
  // Re-sync the selection to the tree's selected root each time the modal opens.
  useEffect(() => {
    if (open) setWorkspace(defaultWs);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, defaultWorkspace]);
  const [title, setTitle] = useState("");
  const [preset, setPreset] = useState<Preset>("skip-permissions");
  const [commandText, setCommandText] = useState(PRESETS[0].command);
  const [branch, setBranch] = useState("");
  const [prompt, setPrompt] = useState("");
  const [files, setFiles] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  if (!open) return null;

  // workspace state may be "" if workspaces weren't loaded when this component first mounted
  const activeWorkspace = workspace || defaultWs;
  const isBlank = preset === "blank";

  const handlePresetChange = (v: Preset) => {
    setPreset(v);
    const p = PRESETS.find((p) => p.value === v)!;
    setCommandText(p.command);
  };

  const addFiles = async () => {
    const sel = await openDialog({ multiple: true, title: "Select file(s)" });
    if (Array.isArray(sel)) setFiles((p) => [...new Set([...p, ...sel])]);
    else if (typeof sel === "string") setFiles((p) => [...new Set([...p, sel])]);
  };

  const launch = async () => {
    setBusy(true);
    setError("");
    try {
      await onLaunch({
        type: isBlank ? "terminal" : "claude",
        workspace: isBlank ? defaultWs : activeWorkspace,
        branch,
        title,
        command: commandText,
        prompt,
        files,
      });
      setTitle("");
      setBranch("");
      setPrompt("");
      setFiles([]);
      onClose();
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  };

  const field =
    "w-full text-xs font-mono px-2 py-1.5 rounded border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-[#25272b] text-neutral-800 dark:text-neutral-200 focus:outline-none focus:border-indigo-400 dark:focus:border-indigo-400";
  const lbl =
    "text-[10px] font-mono uppercase tracking-wider font-bold text-neutral-500 dark:text-neutral-400";

  return (
    <div
      className="fixed inset-0 z-50 bg-black/40 flex items-center justify-center p-6"
      onClick={onClose}
    >
      <div
        className="w-[460px] max-h-[85vh] overflow-y-auto bg-white dark:bg-[#25272b] rounded-xl shadow-2xl border border-neutral-200 dark:border-neutral-700"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-4 py-3 border-b border-neutral-200 dark:border-neutral-700">
          <h2 className="text-sm font-display font-bold text-neutral-800 dark:text-neutral-200">
            New terminal
          </h2>
          <button
            type="button"
            onClick={onClose}
            className="text-neutral-400 dark:text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300 cursor-pointer"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="p-4 space-y-3">
          {/* Title */}
          <div className="space-y-1">
            <span className={lbl}>Title (optional)</span>
            <input
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="Tab name"
              className={field}
            />
          </div>

          {/* Workspace — only for Claude commands */}
          {!isBlank && (
            <div className="space-y-1">
              <span className={lbl}>Workspace</span>
              <select
                value={activeWorkspace}
                onChange={(e) => setWorkspace(e.target.value)}
                className={field}
              >
                {workspaces.length === 0 && (
                  <option value="">Add a workspace first (+ Workspace)</option>
                )}
                {workspaces.map((w) => (
                  <option key={w} value={w}>
                    {w}
                  </option>
                ))}
              </select>
            </div>
          )}

          {/* Command preset */}
          <div className="space-y-1">
            <span className={lbl}>Command</span>
            <select
              value={preset}
              onChange={(e) => handlePresetChange(e.target.value as Preset)}
              className={field}
            >
              {PRESETS.map((p) => (
                <option key={p.value} value={p.value}>
                  {p.label}
                </option>
              ))}
            </select>
            {/* Editable command preview */}
            {!isBlank && (
              <input
                value={commandText}
                onChange={(e) => setCommandText(e.target.value)}
                className={`${field} mt-1 text-neutral-500 dark:text-neutral-400`}
              />
            )}
          </div>

          {/* Claude-only fields */}
          {!isBlank && (
            <>
              <div className="space-y-1">
                <span className={lbl}>Branch (optional → isolated worktree)</span>
                <input
                  value={branch}
                  onChange={(e) => setBranch(e.target.value)}
                  placeholder="feature/my-task"
                  className={field}
                />
              </div>

              <div className="space-y-1">
                <span className={lbl}>Prompt (optional)</span>
                <textarea
                  value={prompt}
                  onChange={(e) => setPrompt(e.target.value)}
                  placeholder="Initial prompt sent to the agent"
                  rows={3}
                  className={`${field} resize-y`}
                />
              </div>

              <div className="space-y-1">
                <div className="flex items-center justify-between">
                  <span className={lbl}>Files (optional)</span>
                  <button
                    type="button"
                    onClick={() => void addFiles()}
                    className="text-[10px] font-mono font-bold text-indigo-600 dark:text-indigo-400 hover:text-indigo-800 flex items-center gap-1 cursor-pointer"
                  >
                    <Plus className="h-3 w-3" /> Add file
                  </button>
                </div>
                {files.length > 0 && (
                  <div className="space-y-1">
                    {files.map((f) => (
                      <div
                        key={f}
                        className="flex items-center justify-between gap-2 text-[10px] font-mono bg-neutral-50 dark:bg-[#25272b] border border-neutral-200 dark:border-neutral-700 rounded px-2 py-1"
                      >
                        <span className="flex items-center gap-1 truncate text-neutral-700 dark:text-neutral-300">
                          <FileText className="h-3 w-3 shrink-0 text-neutral-400 dark:text-neutral-500" />
                          {f}
                        </span>
                        <button
                          type="button"
                          onClick={() => setFiles((p) => p.filter((x) => x !== f))}
                          className="text-neutral-400 hover:text-rose-600 dark:hover:text-red-400 shrink-0 cursor-pointer"
                        >
                          <X className="h-3 w-3" />
                        </button>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </>
          )}

          {error && (
            <div className="text-[11px] font-mono text-rose-600 dark:text-red-400 break-words">
              {error}
            </div>
          )}
        </div>

        <div className="flex items-center justify-end gap-2 px-4 py-3 border-t border-neutral-200 dark:border-neutral-700">
          <button
            type="button"
            onClick={onClose}
            className="text-xs font-mono px-3 py-1.5 rounded border border-neutral-200 dark:border-neutral-700 text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-pointer"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={() => void launch()}
            disabled={busy || (!isBlank && !activeWorkspace)}
            className="text-xs font-mono font-bold px-3 py-1.5 rounded border border-indigo-200 dark:border-indigo-800 bg-indigo-600 text-white hover:bg-indigo-700 disabled:opacity-50 cursor-pointer"
          >
            {busy ? "Launching…" : isBlank ? "Open Terminal" : "Launch Agent"}
          </button>
        </div>
      </div>
    </div>
  );
}

import { useState, useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";
import { X } from "lucide-react";

const DEFAULT_LOG_PATH = "~/.claude/muya-debug.log";

/**
 * App Settings. Currently exposes debug logging for the CyberArk + SSH flows:
 * a toggle plus the target log-file path. The backend (`debug_log_set`) persists
 * the choice to ~/.claude/muya-settings.json and NEVER logs secret values — only
 * step metadata (usernames, URLs, HTTP status, counts).
 *
 * Uses the app-wide modal convention: a `fixed inset-0 z-50` backdrop + a
 * `role="dialog"` panel, so the Terminal key-guard suppresses PTY input while it
 * is open (same as NewAgentModal / ScheduledPromptModal).
 */
export default function SettingsModal({
  open,
  onClose,
}: {
  open: boolean;
  onClose: () => void;
}) {
  const [enabled, setEnabled] = useState(false);
  const [path, setPath] = useState(DEFAULT_LOG_PATH);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);

  // Load current settings whenever the modal opens.
  useEffect(() => {
    if (!open) return;
    setError("");
    setSaved(false);
    invoke<{ enabled: boolean; path: string }>("debug_log_get")
      .then((v) => {
        setEnabled(!!v.enabled);
        setPath(v.path || DEFAULT_LOG_PATH);
      })
      .catch((e) => setError(String(e)));
  }, [open]);

  // Esc closes the modal.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onClose]);

  if (!open) return null;

  const save = async () => {
    setBusy(true);
    setError("");
    setSaved(false);
    try {
      await invoke("debug_log_set", {
        enabled,
        path: path.trim() || DEFAULT_LOG_PATH,
      });
      setSaved(true);
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
    <div className="fixed inset-0 z-50 bg-black/40 flex items-center justify-center p-6">
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Settings"
        className="w-[460px] max-h-[85vh] overflow-y-auto bg-white dark:bg-[#25272b] rounded-xl shadow-2xl border border-neutral-200 dark:border-neutral-700"
      >
        {/* Header */}
        <div className="flex items-center justify-between px-4 py-3 border-b border-neutral-200 dark:border-neutral-700">
          <h2 className="text-sm font-display font-bold text-neutral-800 dark:text-neutral-200">
            Settings
          </h2>
          <button
            type="button"
            onClick={onClose}
            className="text-neutral-400 dark:text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300 cursor-pointer"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="p-4 space-y-4">
          <div className="space-y-1">
            <span className={lbl}>Debug logging</span>
            <label className="flex items-center gap-2 cursor-pointer select-none">
              <input
                type="checkbox"
                checked={enabled}
                onChange={(e) => setEnabled(e.target.checked)}
                className="h-4 w-4 accent-indigo-600 cursor-pointer"
              />
              <span className="text-xs font-mono text-neutral-700 dark:text-neutral-300">
                Log CyberArk + SSH connection steps
              </span>
            </label>
            <p className="text-[10px] leading-relaxed text-neutral-500 dark:text-neutral-400">
              When on, each CyberArk logon/list/retrieve and SSH connect step is
              appended to the log file with a timestamp. Only metadata is written
              (usernames, URLs, HTTP status, method names, counts) —{" "}
              <span className="font-bold">never passwords, tokens, or retrieved
              account secrets</span>. Useful for diagnosing the CyberArk RADIUS
              push and SSH connect flow.
            </p>
          </div>

          <div className="space-y-1">
            <span className={lbl}>Log file path</span>
            <input
              value={path}
              onChange={(e) => setPath(e.target.value)}
              placeholder={DEFAULT_LOG_PATH}
              className={field}
            />
          </div>

          {error && (
            <div className="text-[11px] font-mono text-rose-600 dark:text-red-400 break-words">
              {error}
            </div>
          )}
          {saved && !error && (
            <div className="text-[11px] font-mono text-emerald-600 dark:text-emerald-400">
              Saved.
            </div>
          )}
        </div>

        <div className="flex items-center justify-end gap-2 px-4 py-3 border-t border-neutral-200 dark:border-neutral-700">
          <button
            type="button"
            onClick={onClose}
            className="text-xs font-mono px-3 py-1.5 rounded border border-neutral-200 dark:border-neutral-700 text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-pointer"
          >
            Close
          </button>
          <button
            type="button"
            onClick={() => void save()}
            disabled={busy}
            className="text-xs font-mono font-bold px-3 py-1.5 rounded border border-indigo-200 dark:border-indigo-800 bg-indigo-600 text-white hover:bg-indigo-700 disabled:opacity-50 cursor-pointer"
          >
            {busy ? "Saving…" : "Save"}
          </button>
        </div>
      </div>
    </div>
  );
}

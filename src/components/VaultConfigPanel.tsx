import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { Settings, X, FolderSearch, Check, AlertCircle, RefreshCw } from "lucide-react";

interface VaultStatus {
  configuredPath: string | null;
  resolvedPath: string | null;
  serverInstalled: boolean;
}

/** Settings popover for the vault RAG source — lets the user point Muya at
 * their own Obsidian vault instead of relying on a hardcoded machine path. */
export default function VaultConfigPanel({ onChanged }: { onChanged?: () => void }) {
  const [open, setOpen] = useState(false);
  const [status, setStatus] = useState<VaultStatus | null>(null);
  const [candidates, setCandidates] = useState<string[]>([]);
  const [customPath, setCustomPath] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refreshStatus = useCallback(async () => {
    try {
      const s = await invoke<VaultStatus>("vault_get_status");
      setStatus(s);
    } catch {
      setStatus(null);
    }
  }, []);

  useEffect(() => {
    if (open) {
      void refreshStatus();
      invoke<string[]>("vault_detect_candidates").then(setCandidates).catch(() => setCandidates([]));
      setError(null);
    }
  }, [open, refreshStatus]);

  const applyPath = async (path: string) => {
    setBusy(true);
    setError(null);
    try {
      await invoke("vault_set_path", { path });
      await invoke("vault_restart");
      await refreshStatus();
      onChanged?.();
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  };

  const pickFolder = async () => {
    const sel = await openDialog({ directory: true, multiple: false, title: "Select your Obsidian vault folder" });
    if (typeof sel === "string") void applyPath(sel);
  };

  // Esc closes the modal (consistent with the app's other modals). Outside
  // click closes too — this settings panel has no free-text form worth losing.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        title="Vault kaynağını ayarla"
        className="p-0.5 rounded text-neutral-400 hover:text-violet-500 dark:hover:text-violet-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 transition-colors cursor-pointer"
      >
        <Settings className="h-3 w-3" />
      </button>

      {open && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm p-6"
          onClick={() => setOpen(false)}
        >
          <div
            className="w-[440px] max-w-full max-h-[85vh] overflow-y-auto bg-white dark:bg-[#25272b] border border-neutral-200 dark:border-neutral-700 rounded-xl shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between px-4 py-3 border-b border-neutral-200 dark:border-neutral-700">
              <span className="text-sm font-display font-bold text-neutral-800 dark:text-neutral-200 flex items-center gap-2">
                <Settings className="h-4 w-4 text-violet-500 dark:text-violet-400" /> Vault Source
              </span>
              <button type="button" onClick={() => setOpen(false)} className="text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200 cursor-pointer">
                <X className="h-4 w-4" />
              </button>
            </div>

            <div className="p-4 space-y-3">
              {status && !status.serverInstalled && (
                <p className="text-[11px] font-mono text-amber-600 dark:text-amber-400 flex items-start gap-1.5 bg-amber-50 dark:bg-amber-950/30 rounded p-2">
                  <AlertCircle className="h-3.5 w-3.5 shrink-0 mt-0.5" />
                  smart-connections-mcp not installed at ~/smart-connections-mcp — vault search will stay unavailable regardless of path.
                </p>
              )}

              <div>
                <p className="text-[10px] font-mono font-bold uppercase text-neutral-500 dark:text-neutral-400 mb-1">Current</p>
                <div className="text-[11px] font-mono">
                  {status?.resolvedPath ? (
                    <span className="flex items-center gap-1.5 text-emerald-600 dark:text-emerald-400">
                      <Check className="h-3.5 w-3.5 shrink-0" /> <span className="break-all" title={status.resolvedPath}>{status.resolvedPath}</span>
                    </span>
                  ) : (
                    <span className="text-neutral-400 dark:text-neutral-500 italic">Not configured — no vault detected.</span>
                  )}
                </div>
              </div>

              {candidates.length > 0 && (
                <div className="space-y-1">
                  <p className="text-[10px] font-mono font-bold uppercase text-neutral-500 dark:text-neutral-400">Auto-detected</p>
                  {candidates.map((c) => (
                    <button
                      key={c}
                      type="button"
                      disabled={busy}
                      onClick={() => void applyPath(c)}
                      className="w-full text-left px-2.5 py-1.5 rounded text-[11px] font-mono break-all border border-neutral-200 dark:border-neutral-700 hover:bg-violet-50 dark:hover:bg-violet-950/30 hover:border-violet-300 dark:hover:border-violet-700 cursor-pointer disabled:opacity-50 transition-colors"
                      title={c}
                    >
                      {c}
                    </button>
                  ))}
                </div>
              )}

              <div>
                <p className="text-[10px] font-mono font-bold uppercase text-neutral-500 dark:text-neutral-400 mb-1">Custom path</p>
                <div className="flex gap-1.5">
                  <input
                    value={customPath}
                    onChange={(e) => setCustomPath(e.target.value)}
                    placeholder="/path/to/vault"
                    className="flex-1 min-w-0 px-2.5 py-1.5 text-[11px] font-mono rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 focus:outline-none focus:border-violet-400"
                  />
                  <button
                    type="button"
                    disabled={busy || !customPath.trim()}
                    onClick={() => void applyPath(customPath.trim())}
                    className="px-3 py-1.5 rounded text-[11px] font-mono font-bold bg-violet-600 hover:bg-violet-700 disabled:opacity-40 text-white cursor-pointer disabled:cursor-not-allowed transition-colors"
                  >
                    Set
                  </button>
                  <button
                    type="button"
                    onClick={() => void pickFolder()}
                    disabled={busy}
                    title="Browse…"
                    className="px-2.5 py-1.5 rounded border border-neutral-200 dark:border-neutral-700 text-neutral-500 hover:text-violet-500 cursor-pointer disabled:opacity-40 transition-colors"
                  >
                    <FolderSearch className="h-3.5 w-3.5" />
                  </button>
                </div>
              </div>

              {busy && (
                <p className="text-[10px] font-mono text-neutral-400 flex items-center gap-1.5">
                  <RefreshCw className="h-3 w-3 animate-spin" /> Applying…
                </p>
              )}
              {error && <p className="text-[10px] font-mono text-rose-500 break-words">{error}</p>}
            </div>
          </div>
        </div>
      )}
    </>
  );
}

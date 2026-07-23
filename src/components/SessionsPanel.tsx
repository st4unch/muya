import { useEffect, useRef, useState } from "react";
import { Terminal, GripHorizontal, Pencil, X, Plus, Sparkles } from "lucide-react";

interface TerminalEntry {
  key: string;
  name: string;
  cwd?: string;
  /** Claude session tab (vs plain shell) — selects the row icon. */
  isClaude?: boolean;
}

interface Props {
  terminals: TerminalEntry[];
  activeKey: string | null;
  terminalPtyIds: Record<string, string>;
  /** terminalKey → the shell's CURRENT working directory (polled). Falls back to the spawn cwd. */
  liveCwds?: Record<string, string>;
  renamingKey: string | null;
  renameValue: string;
  setRenamingKey: (k: string | null) => void;
  setRenameValue: (v: string) => void;
  onActivate: (key: string) => void;
  onClose: (key: string) => void;
  onReorder: (fromKey: string, toKey: string) => void;
  onRename: (key: string, name: string) => void;
  onNewTerminal?: () => void;
}

export default function SessionsPanel({
  terminals, activeKey, terminalPtyIds, liveCwds,
  renamingKey, renameValue, setRenamingKey, setRenameValue,
  onActivate, onClose, onReorder, onRename, onNewTerminal,
}: Props) {
  const dragFromRef = useRef<string | null>(null);
  const [dragOver, setDragOver] = useState<string | null>(null);

  useEffect(() => {
    const onGlobalMouseUp = () => {
      if (dragFromRef.current) {
        dragFromRef.current = null;
        setDragOver(null);
      }
    };
    window.addEventListener("mouseup", onGlobalMouseUp);
    return () => window.removeEventListener("mouseup", onGlobalMouseUp);
  }, []);

  const handleGripMouseDown = (e: React.MouseEvent, key: string) => {
    e.preventDefault();
    e.stopPropagation();
    dragFromRef.current = key;
  };

  const handleDragEnter = (key: string) => {
    if (dragFromRef.current && dragFromRef.current !== key) setDragOver(key);
  };

  const handleDrop = (toKey: string) => {
    if (dragFromRef.current && dragFromRef.current !== toKey) {
      onReorder(dragFromRef.current, toKey);
    }
    dragFromRef.current = null;
    setDragOver(null);
  };

  const handleMouseUp = () => {
    dragFromRef.current = null;
    setDragOver(null);
  };

  const commitRename = (key: string) => {
    if (renameValue.trim()) onRename(key, renameValue.trim());
    setRenamingKey(null);
  };

  const cancelRename = () => setRenamingKey(null);

  return (
    <div className="flex-1 overflow-y-auto p-2" onMouseUp={handleMouseUp}>
      <div className="flex items-center justify-between px-1 mb-2">
        <p className="text-[9px] font-mono uppercase tracking-widest font-bold text-neutral-400 dark:text-neutral-500">
          Terminals ({terminals.length})
        </p>
        {onNewTerminal && (
          <button
            type="button"
            onClick={onNewTerminal}
            className="p-0.5 rounded text-neutral-400 hover:text-indigo-500 dark:text-neutral-500 dark:hover:text-indigo-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 transition-colors cursor-pointer"
            title="New Terminal (⌘T)"
          >
            <Plus className="h-3 w-3" />
          </button>
        )}
      </div>

      {terminals.length === 0 ? (
        <p className="text-[10px] font-mono text-neutral-400 dark:text-neutral-500 italic px-1">No open terminals</p>
      ) : (
        <div className="space-y-1">
          {terminals.map(t => {
            const isActive = t.key === activeKey;
            const isDragOver = dragOver === t.key;
            const hasPty = Boolean(terminalPtyIds[t.key]);

            return (
              <div
                key={t.key}
                onMouseEnter={() => handleDragEnter(t.key)}
                onMouseUp={() => handleDrop(t.key)}
                className={`group flex items-center gap-1 rounded border text-[10px] font-mono transition-colors ${
                  isDragOver
                    ? "border-indigo-400 bg-indigo-50 dark:bg-indigo-900/20"
                    : isActive
                    ? "border-indigo-300 dark:border-indigo-700 bg-indigo-50 dark:bg-indigo-950/30"
                    : "border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 hover:bg-neutral-50 dark:hover:bg-neutral-800"
                }`}
              >
                {/* Drag grip */}
                <div
                  onMouseDown={(e) => handleGripMouseDown(e, t.key)}
                  className="pl-1.5 pr-0.5 py-2 cursor-grab active:cursor-grabbing text-neutral-300 dark:text-neutral-600 hover:text-neutral-500 dark:hover:text-neutral-400 shrink-0"
                >
                  <GripHorizontal className="h-3 w-3" />
                </div>

                {/* Main clickable area */}
                <button
                  type="button"
                  onClick={() => { if (renamingKey !== t.key) onActivate(t.key); }}
                  className="flex-1 min-w-0 text-left py-1.5 pr-1"
                >
                  <div className="flex items-center gap-1.5">
                    {/* Claude sessions get the Claude mark; plain shells the
                        terminal glyph — so the two are told apart at a glance. */}
                    {t.isClaude ? (
                      <Sparkles
                        className={`h-3 w-3 shrink-0 ${isActive ? "text-amber-500" : "text-amber-500/80 dark:text-amber-400/80"}`}
                        aria-label="Claude session"
                      />
                    ) : (
                      <Terminal
                        className={`h-3 w-3 shrink-0 ${isActive ? "text-indigo-500" : "text-indigo-400 dark:text-indigo-500"}`}
                        aria-label="Terminal"
                      />
                    )}

                    {renamingKey === t.key ? (
                      <input
                        autoFocus
                        value={renameValue}
                        onChange={(e) => setRenameValue(e.target.value)}
                        onKeyDown={(e) => {
                          if (e.key === "Enter") commitRename(t.key);
                          else if (e.key === "Escape") cancelRename();
                          e.stopPropagation();
                        }}
                        onBlur={() => commitRename(t.key)}
                        onClick={(e) => e.stopPropagation()}
                        className={`text-[10px] font-mono bg-transparent border-b outline-none w-full ${
                          isActive ? "border-indigo-400 text-indigo-800 dark:text-indigo-200" : "border-neutral-400 text-neutral-800 dark:text-neutral-200"
                        }`}
                      />
                    ) : (
                      <span className={`truncate font-semibold ${isActive ? "text-indigo-800 dark:text-indigo-200" : "text-neutral-700 dark:text-neutral-300"}`}>
                        {t.name}
                      </span>
                    )}

                    {hasPty && renamingKey !== t.key && (
                      <span className="ml-auto shrink-0 w-1.5 h-1.5 rounded-full bg-emerald-400" title="PTY active" />
                    )}
                  </div>

                  {/* Show where the shell IS now (live cwd), not where it was
                      spawned; fall back to the spawn cwd until the first poll. */}
                  {(() => {
                    const shownCwd = liveCwds?.[t.key] ?? t.cwd;
                    if (!shownCwd || renamingKey === t.key) return null;
                    return (
                      <p
                        title={shownCwd}
                        className={`text-[9px] truncate mt-0.5 pl-4 ${isActive ? "text-indigo-400 dark:text-indigo-400" : "text-neutral-400 dark:text-neutral-500"}`}
                      >
                        {shownCwd.replace(/^\/Users\/[^/]+/, "~")}
                      </p>
                    );
                  })()}
                </button>

                {/* Rename + close buttons */}
                <div className="flex items-center gap-0.5 pr-1.5 shrink-0 opacity-0 group-hover:opacity-100 transition-opacity">
                  {renamingKey !== t.key && (
                    <button
                      type="button"
                      onClick={(e) => { e.stopPropagation(); setRenamingKey(t.key); setRenameValue(t.name); }}
                      className="p-0.5 text-neutral-400 hover:text-indigo-500 cursor-pointer"
                      title="Rename"
                    >
                      <Pencil className="h-2.5 w-2.5" />
                    </button>
                  )}
                  <button
                    type="button"
                    onMouseDown={(e) => e.preventDefault()}
                    onClick={(e) => { e.stopPropagation(); onClose(t.key); }}
                    className="p-0.5 text-neutral-400 hover:text-rose-500 cursor-pointer"
                    title="Close"
                  >
                    <X className="h-2.5 w-2.5" />
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

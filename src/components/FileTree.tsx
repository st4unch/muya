import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import {
  ChevronRight,
  ChevronDown,
  Folder,
  FolderOpen,
  FileText,
} from "lucide-react";

export interface Entry {
  name: string;
  path: string;
  isDirectory: boolean;
}

type ContextMenu = { x: number; y: number; path: string } | null;

function TreeNode({
  entry,
  depth,
  onOpenFile,
  refreshSignal,
  onContextMenu,
}: {
  entry: Entry;
  depth: number;
  onOpenFile?: (path: string) => void;
  refreshSignal?: number;
  onContextMenu?: (e: React.MouseEvent, path: string) => void;
}) {
  const [open, setOpen] = useState(depth === 0);
  const [children, setChildren] = useState<Entry[] | null>(null);
  const [loading, setLoading] = useState(false);
  const first = useRef(true);

  // Live refresh: re-read an open, already-loaded directory on a filesystem change.
  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    if (entry.isDirectory && open && children !== null) void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refreshSignal]);

  const load = async () => {
    setLoading(true);
    try {
      setChildren(await invoke<Entry[]>("list_dir", { path: entry.path }));
    } catch {
      setChildren([]);
    } finally {
      setLoading(false);
    }
  };

  const toggle = () => {
    if (!entry.isDirectory) {
      onOpenFile?.(entry.path);
      return;
    }
    const next = !open;
    setOpen(next);
    if (next && children === null) void load();
  };

  // Root nodes auto-expand once on mount.
  if (depth === 0 && open && children === null && !loading) void load();

  return (
    <div>
      <button
        type="button"
        onClick={toggle}
        onContextMenu={onContextMenu ? (e) => onContextMenu(e, entry.path) : undefined}
        style={{ paddingLeft: depth * 12 + 8 }}
        className="w-full flex items-center gap-1 py-0.5 pr-2 text-left hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded transition-colors"
      >
        {entry.isDirectory ? (
          open ? (
            <ChevronDown className="h-3 w-3 text-neutral-400 dark:text-neutral-500 shrink-0" />
          ) : (
            <ChevronRight className="h-3 w-3 text-neutral-400 dark:text-neutral-500 shrink-0" />
          )
        ) : (
          <span className="w-3 shrink-0" />
        )}
        {entry.isDirectory ? (
          open ? (
            <FolderOpen className="h-3.5 w-3.5 text-indigo-500 dark:text-indigo-400 shrink-0" />
          ) : (
            <Folder className="h-3.5 w-3.5 text-indigo-400 dark:text-indigo-400 shrink-0" />
          )
        ) : (
          <FileText className="h-3.5 w-3.5 text-neutral-400 dark:text-neutral-500 shrink-0" />
        )}
        <span className="truncate text-neutral-700 dark:text-neutral-300">{entry.name}</span>
      </button>
      {open && children?.map((c) => (
        <TreeNode
          key={c.path}
          entry={c}
          depth={depth + 1}
          onOpenFile={onOpenFile}
          refreshSignal={refreshSignal}
        />
      ))}
      {open && loading && (
        <div
          style={{ paddingLeft: (depth + 1) * 12 + 8 }}
          className="text-[10px] text-neutral-400 dark:text-neutral-500 py-0.5"
        >
          …
        </div>
      )}
      {open && children?.length === 0 && !loading && (
        <div
          style={{ paddingLeft: (depth + 1) * 12 + 8 }}
          className="text-[10px] text-neutral-300 dark:text-neutral-600 py-0.5 italic"
        >
          empty
        </div>
      )}
    </div>
  );
}

/** Lazy, real file tree over user-picked workspace roots (backend `list_dir`). */
export default function FileTree({
  roots,
  removableRoots,
  onOpenFile,
  onRemoveRoot,
  refreshSignal,
}: {
  roots: string[];
  /** Subset of roots that can be removed (manually-pinned workspaces). */
  removableRoots?: Set<string>;
  onOpenFile?: (path: string) => void;
  onRemoveRoot?: (path: string) => void;
  refreshSignal?: number;
}) {
  const [menu, setMenu] = useState<ContextMenu>(null);

  // Close menu on any click outside.
  useEffect(() => {
    if (!menu) return;
    const close = () => setMenu(null);
    window.addEventListener("click", close);
    return () => window.removeEventListener("click", close);
  }, [menu]);

  const handleContextMenu = (e: React.MouseEvent, path: string) => {
    if (!removableRoots?.has(path)) return;
    e.preventDefault();
    e.stopPropagation();
    setMenu({ x: e.clientX, y: e.clientY, path });
  };

  if (!roots.length)
    return (
      <div className="p-3 text-[11px] text-neutral-400 dark:text-neutral-500 font-mono leading-relaxed">
        No workspace yet. Add a project folder with{" "}
        <span className="font-bold">+ Workspace</span> above.
      </div>
    );
  return (
    <div className="font-mono text-xs py-1 relative">
      {roots.map((r) => {
        const name = r.split("/").filter(Boolean).pop() || r;
        return (
          <TreeNode
            key={r}
            entry={{ name, path: r, isDirectory: true }}
            depth={0}
            onOpenFile={onOpenFile}
            refreshSignal={refreshSignal}
            onContextMenu={removableRoots?.has(r) ? handleContextMenu : undefined}
          />
        );
      })}

      {/* Custom context menu */}
      {menu && (
        <div
          style={{ position: "fixed", top: menu.y, left: menu.x, zIndex: 9999 }}
          className="min-w-[180px] bg-white dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-700 rounded shadow-lg py-1 text-xs font-mono"
          onClick={(e) => e.stopPropagation()}
        >
          <button
            type="button"
            className="w-full text-left px-3 py-1.5 text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/20 cursor-pointer transition-colors"
            onClick={() => {
              onRemoveRoot?.(menu.path);
              setMenu(null);
            }}
          >
            Remove from Workspace
          </button>
        </div>
      )}
    </div>
  );
}

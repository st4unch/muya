import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import {
  ChevronRight,
  ChevronDown,
  Folder,
  FolderOpen,
  FileText,
  Search,
  X,
} from "lucide-react";

export interface Entry {
  name: string;
  path: string;
  isDirectory: boolean;
}

interface CtxMenu {
  x: number;
  y: number;
  path: string;
  isDir: boolean;
  isRoot: boolean;
  rootPath: string;
  confirmDelete?: boolean;
}

type GitStatusMap = Map<string, string>;

const STATUS_COLOR: Record<string, string> = {
  M: "text-amber-500",
  A: "text-green-500",
  D: "text-rose-500",
  "?": "text-neutral-400 dark:text-neutral-500",
};

function shortPath(p: string): string {
  const home = p.match(/^\/Users\/([^/]+)\//)?.[0];
  return home ? p.replace(home, "~/") : p;
}

function TreeNode({
  entry,
  depth,
  root,
  onOpenFile,
  refreshSignal,
  onContextMenu,
  gitStatus,
  renamingPath,
  onRenameCommit,
}: {
  entry: Entry;
  depth: number;
  root: string;
  onOpenFile?: (path: string) => void;
  refreshSignal?: number;
  onContextMenu: (e: React.MouseEvent, entry: Entry, root: string) => void;
  gitStatus: GitStatusMap;
  renamingPath: string | null;
  onRenameCommit: (oldPath: string, newName: string) => void;
}) {
  const [open, setOpen] = useState(depth === 0);
  const [children, setChildren] = useState<Entry[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [renameVal, setRenameVal] = useState(entry.name);
  const first = useRef(true);

  useEffect(() => {
    if (first.current) { first.current = false; return; }
    if (entry.isDirectory && open && children !== null) void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refreshSignal]);

  const load = async () => {
    setLoading(true);
    try {
      setChildren(await invoke<Entry[]>("list_dir", { path: entry.path }));
    } catch { setChildren([]); }
    finally { setLoading(false); }
  };

  const toggle = () => {
    if (!entry.isDirectory) { onOpenFile?.(entry.path); return; }
    const next = !open;
    setOpen(next);
    if (next && children === null) void load();
  };

  if (depth === 0 && open && children === null && !loading) void load();

  const status = gitStatus.get(entry.path);
  const isRenaming = renamingPath === entry.path;

  return (
    <div>
      <div
        style={{ paddingLeft: depth * 12 + 8 }}
        className="group flex items-center gap-1 py-0.5 pr-2 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded transition-colors cursor-pointer"
        onClick={isRenaming ? undefined : toggle}
        onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); onContextMenu(e, entry, root); }}
      >
        {entry.isDirectory ? (
          open ? <ChevronDown className="h-3 w-3 text-neutral-400 dark:text-neutral-500 shrink-0" />
               : <ChevronRight className="h-3 w-3 text-neutral-400 dark:text-neutral-500 shrink-0" />
        ) : (
          <span className="w-3 shrink-0" />
        )}
        {entry.isDirectory
          ? open ? <FolderOpen className="h-3.5 w-3.5 text-indigo-500 dark:text-indigo-400 shrink-0" />
                 : <Folder className="h-3.5 w-3.5 text-indigo-400 dark:text-indigo-400 shrink-0" />
          : <FileText className="h-3.5 w-3.5 text-neutral-400 dark:text-neutral-500 shrink-0" />
        }

        {isRenaming ? (
          <input
            autoFocus
            className="flex-1 min-w-0 text-xs font-mono bg-white dark:bg-neutral-700 border border-indigo-400 rounded px-1 outline-none"
            value={renameVal}
            onChange={(e) => setRenameVal(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") { e.preventDefault(); onRenameCommit(entry.path, renameVal); }
              if (e.key === "Escape") { onRenameCommit(entry.path, ""); }
              e.stopPropagation();
            }}
            onBlur={() => onRenameCommit(entry.path, renameVal)}
            onClick={(e) => e.stopPropagation()}
          />
        ) : (
          <span className="truncate text-neutral-700 dark:text-neutral-300 text-xs font-mono select-none">
            {entry.name}
          </span>
        )}

        {status && !isRenaming && (
          <span className={`text-[9px] font-mono font-bold ml-auto shrink-0 ${STATUS_COLOR[status] ?? ""}`}>
            {status}
          </span>
        )}
      </div>

      {open && children?.map((c) => (
        <TreeNode
          key={c.path}
          entry={c}
          depth={depth + 1}
          root={root}
          onOpenFile={onOpenFile}
          refreshSignal={refreshSignal}
          onContextMenu={onContextMenu}
          gitStatus={gitStatus}
          renamingPath={renamingPath}
          onRenameCommit={onRenameCommit}
        />
      ))}
      {open && loading && (
        <div style={{ paddingLeft: (depth + 1) * 12 + 8 }} className="text-[10px] text-neutral-400 py-0.5">…</div>
      )}
      {open && children?.length === 0 && !loading && (
        <div style={{ paddingLeft: (depth + 1) * 12 + 8 }} className="text-[10px] text-neutral-300 dark:text-neutral-600 py-0.5 italic">empty</div>
      )}
    </div>
  );
}

interface Agent { id: string; name: string; worktree: string; }

export default function FileTree({
  roots,
  removableRoots,
  onOpenFile,
  onRemoveRoot,
  onOpenTerminalHere,
  onAddAtRef,
  agents,
  activeCwd,
  selectedRoot,
  onSelectRoot,
  refreshSignal,
}: {
  roots: string[];
  removableRoots?: Set<string>;
  onOpenFile?: (path: string) => void;
  onRemoveRoot?: (path: string) => void;
  onOpenTerminalHere?: (cwd: string) => void;
  onAddAtRef?: (path: string) => void;
  agents?: Agent[];
  activeCwd?: string;
  /** Workspace root the user explicitly selected — new terminals/agents open here. */
  selectedRoot?: string;
  onSelectRoot?: (root: string) => void;
  refreshSignal?: number;
}) {
  const [menu, setMenu] = useState<CtxMenu | null>(null);
  const [gitStatus, setGitStatus] = useState<GitStatusMap>(new Map());
  const [searchOpen, setSearchOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [renamingPath, setRenamingPath] = useState<string | null>(null);
  // flat file list for search
  const [allFiles, setAllFiles] = useState<Entry[]>([]);
  const searchInputRef = useRef<HTMLInputElement>(null);

  // Close menu on outside click
  useEffect(() => {
    if (!menu) return;
    const close = () => setMenu(null);
    window.addEventListener("click", close);
    return () => window.removeEventListener("click", close);
  }, [menu]);

  // Focus search input when opened
  useEffect(() => {
    if (searchOpen) requestAnimationFrame(() => searchInputRef.current?.focus());
  }, [searchOpen]);

  // Poll git status for all roots
  const refreshGitStatus = useCallback(async () => {
    const entries: [string, string][] = [];
    for (const root of roots) {
      try {
        const pairs = await invoke<[string, string][]>("git_status", { root });
        entries.push(...pairs);
      } catch { /* not a git repo */ }
    }
    setGitStatus(new Map(entries));
  }, [roots]);

  useEffect(() => {
    void refreshGitStatus();
    const t = setInterval(() => void refreshGitStatus(), 5000);
    return () => clearInterval(t);
  }, [refreshGitStatus]);

  // Build flat file list for search
  const buildFileList = useCallback(async () => {
    const collect = async (path: string, depth: number): Promise<Entry[]> => {
      if (depth > 6) return [];
      try {
        const entries = await invoke<Entry[]>("list_dir", { path });
        const all: Entry[] = [];
        for (const e of entries) {
          all.push(e);
          if (e.isDirectory) all.push(...await collect(e.path, depth + 1));
        }
        return all;
      } catch { return []; }
    };
    const all: Entry[] = [];
    for (const root of roots) all.push(...await collect(root, 0));
    setAllFiles(all);
  }, [roots]);

  useEffect(() => {
    if (searchOpen) void buildFileList();
  }, [searchOpen, buildFileList, refreshSignal]);

  const handleContextMenu = (e: React.MouseEvent, entry: Entry, root: string) => {
    e.preventDefault();
    e.stopPropagation();
    setMenu({
      x: Math.min(e.clientX, window.innerWidth - 220),
      y: Math.min(e.clientY, window.innerHeight - 260),
      path: entry.path,
      isDir: entry.isDirectory,
      isRoot: roots.includes(entry.path),
      rootPath: root,
    });
  };

  const handleRenameCommit = async (oldPath: string, newName: string) => {
    setRenamingPath(null);
    if (!newName || newName === oldPath.split("/").pop()) return;
    try {
      await invoke("rename_entry", { oldPath, newName });
    } catch (e) { console.warn("rename failed:", e); }
  };

  const deleteEntry = async (path: string) => {
    try {
      await invoke("delete_entry", { path });
    } catch (e) { console.warn("delete failed:", e); }
    setMenu(null);
  };

  const requestDelete = (path: string) => {
    setMenu((prev) => prev ? { ...prev, confirmDelete: true } : null);
  };

  const MenuItem = ({ label, onClick, danger }: { label: string; onClick: () => void; danger?: boolean }) => (
    <button
      type="button"
      className={`w-full text-left px-3 py-1.5 flex items-center gap-2 text-xs font-mono cursor-pointer transition-colors ${
        danger
          ? "text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/20"
          : "text-neutral-700 dark:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-700"
      }`}
      onClick={(e) => { e.stopPropagation(); onClick(); }}
    >
      {label}
    </button>
  );

  const Sep = () => <div className="border-t border-neutral-100 dark:border-neutral-700 my-1" />;

  if (!roots.length)
    return (
      <div className="p-3 text-[11px] text-neutral-400 dark:text-neutral-500 font-mono leading-relaxed">
        No workspace yet. Add a project folder with <span className="font-bold">+ Workspace</span> above.
      </div>
    );

  const filteredFiles = searchQuery
    ? allFiles.filter((f) => f.name.toLowerCase().includes(searchQuery.toLowerCase()))
    : [];

  return (
    <div className="font-mono text-xs relative flex flex-col">
      {/* Search bar toggle */}
      <div className="flex items-center gap-1 px-2 py-1 border-b border-neutral-100 dark:border-neutral-800">
        {searchOpen ? (
          <>
            <Search className="h-3 w-3 text-neutral-400 dark:text-neutral-500 shrink-0" />
            <input
              ref={searchInputRef}
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder="Filter files…"
              className="flex-1 min-w-0 text-[11px] font-mono bg-transparent outline-none text-neutral-800 dark:text-neutral-200 placeholder-neutral-400"
            />
            <button
              type="button"
              onClick={() => { setSearchOpen(false); setSearchQuery(""); }}
              className="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 cursor-pointer"
            >
              <X className="h-3 w-3" />
            </button>
          </>
        ) : (
          <button
            type="button"
            onClick={() => setSearchOpen(true)}
            className="ml-auto text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 cursor-pointer p-0.5"
            title="Filter files"
          >
            <Search className="h-3 w-3" />
          </button>
        )}
      </div>

      {/* Flat search results */}
      {searchOpen && searchQuery && (
        <div className="overflow-y-auto max-h-[300px] py-1">
          {filteredFiles.length === 0 ? (
            <div className="px-3 py-2 text-[10px] text-neutral-400 dark:text-neutral-500">No matches</div>
          ) : filteredFiles.map((f) => {
            const status = gitStatus.get(f.path);
            return (
              <button
                key={f.path}
                type="button"
                onClick={() => { if (!f.isDirectory) onOpenFile?.(f.path); }}
                onContextMenu={(e) => handleContextMenu(e, f, roots.find((r) => f.path.startsWith(r)) ?? roots[0])}
                className="w-full flex items-center gap-2 px-3 py-1 hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-pointer text-left"
              >
                {f.isDirectory
                  ? <Folder className="h-3 w-3 text-indigo-400 shrink-0" />
                  : <FileText className="h-3 w-3 text-neutral-400 shrink-0" />
                }
                <span className="truncate text-neutral-700 dark:text-neutral-300 text-[11px]">{f.name}</span>
                {status && (
                  <span className={`ml-auto text-[9px] font-bold shrink-0 ${STATUS_COLOR[status] ?? ""}`}>{status}</span>
                )}
              </button>
            );
          })}
        </div>
      )}

      {/* Tree view */}
      {(!searchOpen || !searchQuery) && (
        <div className="py-1">
          {roots.map((r) => {
            const name = r.split("/").filter(Boolean).pop() || r;
            const matchedAgent = agents?.find((a) => a.worktree === r || r.startsWith(a.worktree));
            const isSelected = selectedRoot === r;
            const isActive = isSelected || (activeCwd ? (r === activeCwd || activeCwd.startsWith(r)) : false);

            return (
              <div
                key={r}
                className={`border-l-2 mb-1 ${isActive ? "border-indigo-500" : "border-transparent"}`}
              >
                {/* Root header — click to select as the target workspace */}
                <div
                  className={`flex items-center gap-1.5 px-2 py-0.5 group cursor-pointer rounded ${
                    isSelected
                      ? "bg-indigo-100 dark:bg-indigo-500/25 ring-1 ring-inset ring-indigo-400/60"
                      : "hover:bg-neutral-100 dark:hover:bg-neutral-800"
                  }`}
                  onClick={() => onSelectRoot?.(r)}
                  onContextMenu={(e) => handleContextMenu(e, { name, path: r, isDirectory: true }, r)}
                >
                  <FolderOpen className="h-3.5 w-3.5 text-indigo-500 dark:text-indigo-400 shrink-0" />
                  <span className="text-[11px] font-bold text-neutral-700 dark:text-neutral-300 truncate">{name}</span>
                  {matchedAgent && (
                    <span className="text-[8px] font-mono px-1 py-0.5 rounded bg-indigo-100 dark:bg-indigo-950/50 text-indigo-700 dark:text-indigo-300 border border-indigo-200 dark:border-indigo-800 shrink-0 truncate max-w-[80px]">
                      {matchedAgent.name}
                    </span>
                  )}
                  <span className="text-[9px] text-neutral-400 dark:text-neutral-600 truncate ml-auto hidden group-hover:block">
                    {shortPath(r)}
                  </span>
                </div>

                <TreeNode
                  entry={{ name, path: r, isDirectory: true }}
                  depth={0}
                  root={r}
                  onOpenFile={onOpenFile}
                  refreshSignal={refreshSignal}
                  onContextMenu={handleContextMenu}
                  gitStatus={gitStatus}
                  renamingPath={renamingPath}
                  onRenameCommit={handleRenameCommit}
                />
              </div>
            );
          })}
        </div>
      )}

      {/* Context menu */}
      {menu && (
        <div
          style={{ position: "fixed", top: menu.y, left: menu.x, zIndex: 9999 }}
          className="min-w-[210px] bg-white dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-700 rounded shadow-xl py-1 text-xs font-mono"
          onClick={(e) => e.stopPropagation()}
        >
          {/* File-only */}
          {!menu.isDir && (
            <>
              {/* Opens EDITABLE in Muya's centre editor — every file type,
                  markdown included (there is no separate preview panel). */}
              <MenuItem label="Open in Muya" onClick={() => { onOpenFile?.(menu.path); setMenu(null); }} />
              <MenuItem label="Open in Terminal Here" onClick={() => {
                const dir = menu.path.split("/").slice(0, -1).join("/");
                onOpenTerminalHere?.(dir); setMenu(null);
              }} />
              <Sep />
              <MenuItem label="Add as @ Reference" onClick={() => {
                void navigator.clipboard.writeText(`@${menu.path}`);
                onAddAtRef?.(menu.path); setMenu(null);
              }} />
              <MenuItem label="Copy Path" onClick={() => { void navigator.clipboard.writeText(menu.path); setMenu(null); }} />
              <MenuItem label="Copy Relative Path" onClick={() => {
                const rel = menu.path.startsWith(menu.rootPath)
                  ? menu.path.slice(menu.rootPath.length + 1)
                  : menu.path;
                void navigator.clipboard.writeText(rel); setMenu(null);
              }} />
              <Sep />
              <MenuItem label="Reveal in Finder" onClick={() => { void invoke("reveal_in_finder", { path: menu.path }); setMenu(null); }} />
              <Sep />
              <MenuItem label="Rename" onClick={() => { setRenamingPath(menu.path); setMenu(null); }} />
              {menu.confirmDelete ? (
                <div className="px-3 py-2 border-t border-neutral-100 dark:border-neutral-700">
                  <p className="text-[10px] text-neutral-500 dark:text-neutral-400 mb-1.5 font-mono">Delete forever?</p>
                  <div className="flex gap-1.5">
                    <button type="button" onClick={() => void deleteEntry(menu.path)}
                      className="flex-1 text-[11px] px-2 py-1 rounded bg-red-500 text-white hover:bg-red-600 cursor-pointer font-mono font-bold">
                      Delete
                    </button>
                    <button type="button" onClick={() => setMenu(null)}
                      className="flex-1 text-[11px] px-2 py-1 rounded bg-neutral-100 dark:bg-neutral-700 text-neutral-700 dark:text-neutral-300 hover:bg-neutral-200 dark:hover:bg-neutral-600 cursor-pointer font-mono">
                      Cancel
                    </button>
                  </div>
                </div>
              ) : (
                <MenuItem label="Delete" danger onClick={() => requestDelete(menu.path)} />
              )}
            </>
          )}

          {/* Folder (non-root) */}
          {menu.isDir && !menu.isRoot && (
            <>
              <MenuItem label="Open in Terminal Here" onClick={() => { onOpenTerminalHere?.(menu.path); setMenu(null); }} />
              <Sep />
              <MenuItem label="Copy Path" onClick={() => { void navigator.clipboard.writeText(menu.path); setMenu(null); }} />
              <MenuItem label="Reveal in Finder" onClick={() => { void invoke("reveal_in_finder", { path: menu.path }); setMenu(null); }} />
              <Sep />
              <MenuItem label="Rename" onClick={() => { setRenamingPath(menu.path); setMenu(null); }} />
              {menu.confirmDelete ? (
                <div className="px-3 py-2 border-t border-neutral-100 dark:border-neutral-700">
                  <p className="text-[10px] text-neutral-500 dark:text-neutral-400 mb-1.5 font-mono">Delete folder + contents?</p>
                  <div className="flex gap-1.5">
                    <button type="button" onClick={() => void deleteEntry(menu.path)}
                      className="flex-1 text-[11px] px-2 py-1 rounded bg-red-500 text-white hover:bg-red-600 cursor-pointer font-mono font-bold">
                      Delete
                    </button>
                    <button type="button" onClick={() => setMenu(null)}
                      className="flex-1 text-[11px] px-2 py-1 rounded bg-neutral-100 dark:bg-neutral-700 text-neutral-700 dark:text-neutral-300 hover:bg-neutral-200 dark:hover:bg-neutral-600 cursor-pointer font-mono">
                      Cancel
                    </button>
                  </div>
                </div>
              ) : (
                <MenuItem label="Delete Folder" danger onClick={() => requestDelete(menu.path)} />
              )}
            </>
          )}

          {/* Root */}
          {menu.isRoot && (
            <>
              <MenuItem label="Open in Terminal Here" onClick={() => { onOpenTerminalHere?.(menu.path); setMenu(null); }} />
              <MenuItem label="Reveal in Finder" onClick={() => { void invoke("reveal_in_finder", { path: menu.path }); setMenu(null); }} />
              <MenuItem label="Copy Path" onClick={() => { void navigator.clipboard.writeText(menu.path); setMenu(null); }} />
              {removableRoots?.has(menu.path) && (
                <>
                  <Sep />
                  <MenuItem label="Remove from Workspace" danger onClick={() => { onRemoveRoot?.(menu.path); setMenu(null); }} />
                </>
              )}
            </>
          )}
        </div>
      )}
    </div>
  );
}

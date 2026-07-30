import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { marked } from "marked";
import DOMPurify from "dompurify";
import { FileText, Pencil } from "lucide-react";

/**
 * Read-only RENDERED markdown view. A single-click on a .md file in the tree opens
 * this (nice for reading docs); "Open in Muya" (right-click) opens the editable
 * Monaco editor instead. Content is loaded via the backend `read_file` command,
 * parsed with `marked`, and SANITIZED with DOMPurify before it is injected — so a
 * malicious `.md` (embedded <script>, onerror handlers, javascript: URLs) can never
 * execute inside the webview.
 */
export default function MarkdownView({
  filePath,
  onEdit,
  active = true,
  reloadTick = 0,
}: {
  filePath: string;
  /** "Edit" button → open the same file in the Monaco editor (editable). */
  onEdit?: (path: string) => void;
  /** Whether this tab is the visible one. Only the visible tab reloads on disk
   *  changes — hidden tabs are never re-read in the background (they refresh when
   *  you switch to them). */
  active?: boolean;
  /** Bumps on any watched-workspace change (App's fsTick). */
  reloadTick?: number;
}) {
  const [html, setHtml] = useState<string>("");
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [error, setError] = useState<string>("");

  // Load on open, and — ONLY while visible — reload when the workspace changes (an
  // agent or an external editor wrote the file). The dep is `active ? reloadTick : 0`
  // so a hidden tab never re-reads; becoming active flips the dep and catches it up.
  // A short debounce coalesces the burst of events from a single save/agent write.
  useEffect(() => {
    let cancelled = false;
    const load = () => {
      invoke<string>("read_file", { path: filePath })
        .then((raw) => {
          if (cancelled) return;
          // marked → raw HTML, then DOMPurify strips scripts/handlers/js: URLs.
          const dirty = marked.parse(raw, { async: false }) as string;
          setHtml(DOMPurify.sanitize(dirty));
          setStatus("ready");
        })
        .catch((e) => {
          if (cancelled) return;
          setError(String(e));
          setStatus("error");
        });
    };
    if (html === "") setStatus("loading");
    const t = setTimeout(load, 200);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filePath, active ? reloadTick : 0]);

  const name = filePath.split("/").pop() ?? filePath;

  return (
    <div className="h-full flex flex-col bg-white dark:bg-[#1e1f23]">
      <div className="flex items-center justify-between px-3 py-1.5 border-b border-neutral-200 dark:border-[#3d3f44] shrink-0">
        <span className="text-[11px] font-mono text-neutral-500 dark:text-neutral-400 flex items-center gap-1.5 truncate">
          <FileText className="h-3.5 w-3.5 text-indigo-500 shrink-0" /> {name}
          <span className="text-neutral-400 dark:text-neutral-600">· reading</span>
        </span>
        {onEdit && (
          <button
            type="button"
            onClick={() => onEdit(filePath)}
            title="Open in Muya (editable)"
            className="flex items-center gap-1 text-[11px] font-mono px-2 py-0.5 rounded border border-neutral-200 dark:border-neutral-700 text-neutral-600 dark:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-pointer transition-colors shrink-0"
          >
            <Pencil className="h-3 w-3" /> Edit
          </button>
        )}
      </div>
      <div className="flex-1 overflow-auto px-6 py-4">
        {status === "loading" && (
          <p className="text-[11px] font-mono text-neutral-400 animate-pulse">Loading…</p>
        )}
        {status === "error" && (
          <p className="text-[11px] font-mono text-rose-500">Could not read file: {error}</p>
        )}
        {status === "ready" && (
          <div className="md-body max-w-3xl" dangerouslySetInnerHTML={{ __html: html }} />
        )}
      </div>
    </div>
  );
}

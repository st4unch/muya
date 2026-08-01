import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import Editor, { DiffEditor, loader } from "@monaco-editor/react";
import * as monaco from "monaco-editor";
import { langFromPath } from "../lib/format";
import editorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";
import jsonWorker from "monaco-editor/esm/vs/language/json/json.worker?worker";
import cssWorker from "monaco-editor/esm/vs/language/css/css.worker?worker";
import htmlWorker from "monaco-editor/esm/vs/language/html/html.worker?worker";
import tsWorker from "monaco-editor/esm/vs/language/typescript/ts.worker?worker";

// Use the locally-bundled Monaco (no CDN fetch — matters for an offline, security-
// conscious desktop app) and wire its web workers through Vite.
self.MonacoEnvironment = {
  getWorker(_: unknown, label: string) {
    if (label === "json") return new jsonWorker();
    if (label === "css" || label === "scss" || label === "less") return new cssWorker();
    if (label === "html" || label === "handlebars" || label === "razor")
      return new htmlWorker();
    if (label === "typescript" || label === "javascript") return new tsWorker();
    return new editorWorker();
  },
};
loader.config({ monaco });

/** Monaco-backed file editor. Loads via the backend `read_file`; Cmd/Ctrl+S saves
 *  via `write_file`. Language is inferred from the file path. */
export default function FileEditor({
  path,
  theme = "light",
  onDirtyChange,
  active = true,
  reloadTick = 0,
}: {
  path: string;
  theme?: "dark" | "light";
  onDirtyChange?: (dirty: boolean) => void;
  /** Visible tab? Only the visible editor reloads on disk changes. */
  active?: boolean;
  /** Bumps on any watched-workspace change (App's fsTick). */
  reloadTick?: number;
}) {
  const monacoTheme = theme === "dark" ? "vs-dark" : "light";
  const [value, setValue] = useState<string>("");
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [error, setError] = useState<string>("");
  const [dirty, setDirty] = useState(false);
  const dirtyRef = useRef(dirty);
  dirtyRef.current = dirty;
  // Set when the file changed on disk but the editor has UNSAVED edits — we don't
  // clobber the user's work; a badge offers a manual reload instead.
  const [diskChanged, setDiskChanged] = useState(false);
  const [saving, setSaving] = useState(false);
  const [mode, setMode] = useState<"edit" | "diff">("edit");
  const [head, setHead] = useState<string | null>(null);
  const [wordWrap, setWordWrap] = useState(false);
  const [minimap, setMinimap] = useState(false);
  const editorRef = useRef<monaco.editor.IStandaloneCodeEditor | null>(null);
  const valueRef = useRef(value);
  valueRef.current = value;

  const toggleDiff = async () => {
    if (mode === "diff") {
      setMode("edit");
      return;
    }
    if (head === null) {
      try {
        setHead(await invoke<string>("read_head_file", { path }));
      } catch {
        setHead(""); // untracked/new → diff against empty
      }
    }
    setMode("diff");
  };

  // Load on open, and — ONLY while visible — reload when the file changes on disk
  // (agent / external edit). A hidden tab never re-reads (dep collapses to 0);
  // switching to it flips the dep and catches it up. If the editor has UNSAVED
  // edits when the disk changes, we do NOT overwrite them — a badge offers reload.
  const prevPathRef = useRef<string | null>(null);
  useEffect(() => {
    const pathChanged = prevPathRef.current !== path;
    prevPathRef.current = path;
    let cancelled = false;
    const doLoad = () => {
      if (pathChanged) setStatus("loading");
      invoke<string>("read_file", { path })
        .then((c) => {
          if (cancelled) return;
          setValue(c);
          setDirty(false);
          onDirtyChange?.(false);
          setDiskChanged(false);
          setStatus("ready");
        })
        .catch((e) => {
          if (cancelled) return;
          setError(String(e));
          setStatus("error");
        });
    };
    const t = setTimeout(() => {
      if (cancelled) return;
      // Disk changed for the SAME file while the user has unsaved edits → don't
      // clobber; flag it. Otherwise (new file, or clean editor) reload.
      if (!pathChanged && dirtyRef.current) setDiskChanged(true);
      else doLoad();
    }, pathChanged ? 0 : 200);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [path, active ? reloadTick : 0]);

  /** Manual reload from the "disk changed" badge — discards unsaved edits. */
  const reloadFromDisk = () => {
    invoke<string>("read_file", { path })
      .then((c) => {
        setValue(c);
        setDirty(false);
        onDirtyChange?.(false);
        setDiskChanged(false);
      })
      .catch((e) => setError(String(e)));
  };

  const save = async () => {
    setSaving(true);
    try {
      // Format document before saving if a formatter is available
      await editorRef.current?.getAction("editor.action.formatDocument")?.run();
      await invoke("write_file", { path, content: valueRef.current });
      setDirty(false);
      onDirtyChange?.(false);
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  };

  const fileName = path.split("/").pop() || path;

  return (
    <div className="flex flex-col h-full w-full">
      <div className="px-3 py-1 border-b border-neutral-200 dark:border-[#3d3f44] bg-neutral-50 dark:bg-[#1e1f23] text-[10px] font-mono text-neutral-500 dark:text-neutral-400 shrink-0 flex items-center justify-between">
        <span className="truncate">{path}</span>
        <span className="flex items-center gap-2 shrink-0">
          {diskChanged && (
            <button
              type="button"
              onClick={reloadFromDisk}
              title="This file changed on disk while you had unsaved edits. Reload discards your edits."
              className="text-rose-600 dark:text-rose-400 hover:underline cursor-pointer"
            >
              ⟳ changed on disk — reload
            </button>
          )}
          {dirty && <span className="text-amber-600 dark:text-amber-400">● unsaved</span>}
          <button
            type="button"
            onClick={() => {
              const next = !wordWrap;
              setWordWrap(next);
              editorRef.current?.updateOptions({ wordWrap: next ? "on" : "off" });
            }}
            className={`px-2 py-0.5 rounded border cursor-pointer transition-colors ${
              wordWrap
                ? "border-indigo-700 dark:border-indigo-400 bg-indigo-600 dark:bg-indigo-500 text-white font-bold shadow-sm"
                : "border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800"
            }`}
            title="Toggle word wrap"
          >
            Wrap
          </button>
          <button
            type="button"
            onClick={() => {
              const next = !minimap;
              setMinimap(next);
              editorRef.current?.updateOptions({ minimap: { enabled: next } });
            }}
            className={`px-2 py-0.5 rounded border cursor-pointer transition-colors ${
              minimap
                ? "border-indigo-700 dark:border-indigo-400 bg-indigo-600 dark:bg-indigo-500 text-white font-bold shadow-sm"
                : "border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800"
            }`}
            title="Toggle minimap"
          >
            Map
          </button>
          <button
            type="button"
            onClick={() => void toggleDiff()}
            className={`px-2 py-0.5 rounded border cursor-pointer transition-colors ${
              mode === "diff"
                ? "border-amber-300 dark:border-amber-600 bg-amber-50 dark:bg-amber-900/25 text-amber-700 dark:text-amber-400 font-bold"
                : "border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800"
            }`}
            title="Show diff against HEAD"
          >
            Diff
          </button>
          <button
            type="button"
            onClick={() => void save()}
            disabled={!dirty || saving}
            className="px-2 py-0.5 rounded border border-indigo-700 dark:border-indigo-400 bg-indigo-600 dark:bg-indigo-500 text-white font-bold disabled:opacity-40 disabled:cursor-default cursor-pointer hover:bg-indigo-700 dark:hover:bg-indigo-400 transition-colors shadow-sm"
            title="Save (Cmd/Ctrl+S)"
          >
            {saving ? "…" : "Save"}
          </button>
        </span>
      </div>
      <div className="flex-1 overflow-hidden">
        {status === "error" ? (
          <div className="p-4 text-xs font-mono text-rose-600 dark:text-red-400">{error}</div>
        ) : mode === "diff" ? (
          <DiffEditor
            original={head ?? ""}
            modified={value}
            theme={monacoTheme}
            language={langFromPath(path)}
            loading={<div className="p-4 text-xs font-mono text-neutral-400 dark:text-neutral-500">diff…</div>}
            options={{
              fontSize: 12,
              fontFamily: '"JetBrains Mono", ui-monospace, monospace',
              renderSideBySide: true,
              readOnly: true,
              minimap: { enabled: false },
              automaticLayout: true,
              unicodeHighlight: {
                ambiguousCharacters: false,
                invisibleCharacters: false,
                nonBasicASCII: false,
              },
            }}
          />
        ) : (
          <Editor
            key={path}
            path={fileName}
            value={value}
            theme={monacoTheme}
            loading={<div className="p-4 text-xs font-mono text-neutral-400 dark:text-neutral-500">loading…</div>}
            onChange={(v) => {
              setValue(v ?? "");
              setDirty(true);
              onDirtyChange?.(true);
            }}
            onMount={(editor) => {
              editorRef.current = editor;
              editor.addCommand(
                monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS,
                () => void save()
              );
            }}
            options={{
              fontSize: 12,
              fontFamily: '"JetBrains Mono", ui-monospace, monospace',
              minimap: { enabled: minimap },
              wordWrap: wordWrap ? "on" : "off",
              scrollBeyondLastLine: false,
              automaticLayout: true,
              bracketPairColorization: { enabled: true },
              renderWhitespace: "selection",
              // Turkish text (ı/ş/ğ/ç…) is legitimate content, not a homoglyph
              // attack — don't flag it as "confusable with ASCII".
              unicodeHighlight: {
                ambiguousCharacters: false,
                invisibleCharacters: false,
                nonBasicASCII: false,
              },
            }}
          />
        )}
      </div>
    </div>
  );
}

import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import Editor, { DiffEditor } from "@monaco-editor/react";
import * as monaco from "monaco-editor";
import { langFromPath, monacoModelPath } from "../lib/format";
import "./monacoSetup";
import { appModalOpen } from "../lib/modalOpen";
import { decideOpen, formatSize, HEAD_BYTES, LARGE_EDITOR_OPTIONS, type FileProbe } from "../lib/largeFile";
import { AUTO_SAVE_EVENT, AUTO_SAVE_MS, DRAFT_MS, loadAutoSave, snapshotVersion } from "../lib/fileVersions";

/** Nobody visible holds the keyboard: it sits on the page, or in a terminal parked
 *  off screen (a closing dialog hands it back to whatever had it before). */
function keyboardIsFree(): boolean {
  const a = document.activeElement;
  return !a || a === document.body || !!a.closest("[aria-hidden='true']");
}

/** What the probe decided for the file on screen (docs/prd-large-file-open.md). */
type Gate =
  | { kind: "ok"; large: boolean; readOnly: boolean; size: number; truncated: boolean }
  | { kind: "binary" }
  | { kind: "prompt"; size: number };

/** Probe first (cheap), then read only what the policy allows. Never reads a binary
 *  file as text, never loads a huge one unasked. */
async function readGated(path: string, force: boolean): Promise<{ gate: Gate; text: string }> {
  const probe = await invoke<FileProbe>("file_probe", { path });
  const mode = decideOpen(probe);
  if (mode === "binary") return { gate: { kind: "binary" }, text: "" };
  if (mode === "prompt") {
    if (!force) return { gate: { kind: "prompt", size: probe.size }, text: "" };
    const text = await invoke<string>("read_file_prefix", { path, maxBytes: HEAD_BYTES });
    return { gate: { kind: "ok", large: true, readOnly: true, size: probe.size, truncated: true }, text };
  }
  const text = await invoke<string>("read_file", { path });
  return { gate: { kind: "ok", large: mode === "large", readOnly: false, size: probe.size, truncated: false }, text };
}

/** Monaco-backed file editor. Loads via the backend `read_file`; Cmd/Ctrl+S saves
 *  via `write_file`. Language is inferred from the file path. */
export default function FileEditor({
  path,
  theme = "light",
  onDirtyChange,
  active = true,
  reloadTick = 0,
  fileTick = 0,
  startInDiff = false,
}: {
  path: string;
  theme?: "dark" | "light";
  onDirtyChange?: (dirty: boolean) => void;
  /** Visible tab? Only the visible editor reloads on disk changes. */
  active?: boolean;
  /** Bumps on any watched-workspace change (App's fsTick). */
  reloadTick?: number;
  /** Bumps when THIS file changed on disk — reload right away, even while hidden. */
  fileTick?: number;
  /** Open straight into the diff-against-HEAD view ("Review diff"). */
  startInDiff?: boolean;
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
  const [gate, setGate] = useState<Gate | null>(null);
  const forceRef = useRef(false); // "Open anyway" was chosen for this path
  const large = gate?.kind === "ok" && gate.large;
  const largeRef = useRef(false);
  largeRef.current = large;
  const editorRef = useRef<monaco.editor.IStandaloneCodeEditor | null>(null);
  const valueRef = useRef(value);
  valueRef.current = value;
  /** Text of our last write to disk (save / auto-save). */
  const lastWrittenRef = useRef<string | null>(null);

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

  useEffect(() => {
    if (startInDiff) void toggleDiff();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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
      if (pathChanged) {
        forceRef.current = false;
        setGate(null);
        setStatus("loading");
      }
      readGated(path, forceRef.current)
        .then(({ gate: g, text: c }) => {
          if (cancelled) return;
          setGate(g);
          setValue(c);
          setDirty(false);
          onDirtyChange?.(false);
          setDiskChanged(false);
          setStatus("ready");
          // The text as it is on disk now is a version (docs/prd-file-versions.md).
          if (g.kind === "ok" && !g.large) void snapshotVersion(path, c, "opened");
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
      if (!pathChanged && dirtyRef.current) {
        // Our own (auto-)save also fires this. If the disk holds exactly what we last
        // wrote, nothing outside changed it — no warning.
        invoke<string>("read_file", { path })
          .then((c) => { if (!cancelled && c !== lastWrittenRef.current) setDiskChanged(true); })
          .catch(() => { if (!cancelled) setDiskChanged(true); });
      } else doLoad();
    }, pathChanged ? 0 : 200);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [path, active ? reloadTick : 0, fileTick]);

  /** Manual reload from the "disk changed" badge — discards unsaved edits. */
  const reloadFromDisk = () => {
    readGated(path, forceRef.current)
      .then(({ gate: g, text: c }) => {
        setGate(g);
        setValue(c);
        setDirty(false);
        onDirtyChange?.(false);
        setDiskChanged(false);
      })
      .catch((e) => setError(String(e)));
  };

  /** "Open anyway" on the too-big prompt: the head of the file, read-only. */
  const openAnyway = () => {
    forceRef.current = true;
    setStatus("loading");
    readGated(path, true)
      .then(({ gate: g, text: c }) => {
        setGate(g);
        setValue(c);
        setStatus("ready");
      })
      .catch((e) => {
        setError(String(e));
        setStatus("error");
      });
  };

  const save = async () => {
    setSaving(true);
    try {
      // Format document before saving if a formatter is available
      if (!largeRef.current) await editorRef.current?.getAction("editor.action.formatDocument")?.run();
      lastWrittenRef.current = valueRef.current;
      await invoke("write_file", { path, content: valueRef.current });
      setDirty(false);
      onDirtyChange?.(false);
      if (!largeRef.current) void snapshotVersion(path, valueRef.current, "saved");
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  };

  // Auto-save (Settings): write 1 s after typing stops, without formatting so the
  // caret never jumps. With it off, a pause still keeps the unsaved text as a version.
  const [autoSave, setAutoSave] = useState(loadAutoSave);
  useEffect(() => {
    const on = () => setAutoSave(loadAutoSave());
    window.addEventListener(AUTO_SAVE_EVENT, on);
    return () => window.removeEventListener(AUTO_SAVE_EVENT, on);
  }, []);
  useEffect(() => {
    if (!dirty || status !== "ready") return;
    const t = setTimeout(() => {
      const text = valueRef.current;
      if (!autoSave) {
        if (!largeRef.current) void snapshotVersion(path, text, "draft");
        return;
      }
      lastWrittenRef.current = text;
      invoke("write_file", { path, content: text })
        .then(() => {
          // Typing may have continued while the write was in flight.
          if (valueRef.current === text) {
            setDirty(false);
            onDirtyChange?.(false);
          }
          if (!largeRef.current) void snapshotVersion(path, text, "saved");
        })
        .catch((e) => setError(String(e)));
    }, autoSave ? AUTO_SAVE_MS : DRAFT_MS);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value, dirty, autoSave, status, path]);

  // Opening or picking a file hands it the keyboard, as picking a terminal does. Before,
  // keys went to the page until the operator clicked into the text.
  const activeRef = useRef(active);
  activeRef.current = active;
  const focusTimerRef = useRef<number | undefined>(undefined);
  const focusEditor = (tries = 20) => {
    window.clearTimeout(focusTimerRef.current);
    const editor = editorRef.current;
    if (!editor || !activeRef.current) return;
    // The ⌘K palette (or another dialog) is still closing: wait for it to go.
    if (appModalOpen()) {
      if (tries > 0) focusTimerRef.current = window.setTimeout(() => focusEditor(tries - 1), 50);
      return;
    }
    if (keyboardIsFree()) editor.focus();
  };
  // A passive effect runs after App's layout effect has moved this host on screen.
  useEffect(() => {
    if (active && mode === "edit" && status === "ready") focusEditor();
    return () => window.clearTimeout(focusTimerRef.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active, mode, status]);


  return (
    <div className="flex flex-col h-full w-full">
      <div className="px-3 py-1 border-b border-[var(--border)] bg-[var(--bg-panel)] text-[10px] font-mono text-neutral-500 dark:text-neutral-400 shrink-0 flex items-center justify-between">
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
            className={`px-2 py-0.5 rounded border cursor-pointer transition-colors disabled:opacity-40 disabled:cursor-default ${
              wordWrap
                ? "border-indigo-700 dark:border-indigo-400 bg-indigo-600 dark:bg-indigo-500 text-white font-bold shadow-sm"
                : "border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800"
            }`}
            disabled={large}
            title={large ? "Off for large files" : "Toggle word wrap"}
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
            className={`px-2 py-0.5 rounded border cursor-pointer transition-colors disabled:opacity-40 disabled:cursor-default ${
              minimap
                ? "border-indigo-700 dark:border-indigo-400 bg-indigo-600 dark:bg-indigo-500 text-white font-bold shadow-sm"
                : "border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800"
            }`}
            disabled={large}
            title={large ? "Off for large files" : "Toggle minimap"}
          >
            Map
          </button>
          <button
            type="button"
            onClick={() => void toggleDiff()}
            className={`px-2 py-0.5 rounded border cursor-pointer transition-colors disabled:opacity-40 disabled:cursor-default ${
              mode === "diff"
                ? "border-amber-300 dark:border-amber-600 bg-amber-50 dark:bg-amber-900/25 text-amber-700 dark:text-amber-400 font-bold"
                : "border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800"
            }`}
            disabled={large}
            title={large ? "Off for large files" : "Show diff against HEAD"}
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
      {gate?.kind === "ok" && gate.large && (
        <div
          data-testid="large-file-banner"
          className="px-3 py-1 text-[11px] border-b border-[var(--border)] bg-[var(--bg-panel)] text-[var(--text-muted)] shrink-0"
        >
          <span className="text-amber-600 dark:text-amber-400 font-bold">Large file ({formatSize(gate.size)})</span>
          {gate.truncated
            ? ` — showing the first ${formatSize(HEAD_BYTES)}, read-only.`
            : " — shown as plain text; highlighting, minimap, wrap and diff are off to keep the editor responsive."}
        </div>
      )}
      <div className="flex-1 overflow-hidden">
        {gate?.kind === "prompt" ? (
          <div data-testid="large-file-prompt" className="p-4 flex flex-col items-start gap-2">
            <p className="text-xs font-mono text-[var(--text)]">
              This file is large ({formatSize(gate.size)}).
            </p>
            <p className="text-xs font-mono text-[var(--text-muted)]">
              Loading it all would freeze the window. Open the first {formatSize(HEAD_BYTES)} read-only, or use another app.
            </p>
            <div className="flex gap-2">
              <button
                type="button"
                onClick={openAnyway}
                className="px-2 py-1 text-xs rounded border border-indigo-700 dark:border-indigo-400 bg-indigo-600 dark:bg-indigo-500 text-white font-bold cursor-pointer hover:bg-indigo-700 dark:hover:bg-indigo-400"
              >
                Open anyway
              </button>
              <button
                type="button"
                onClick={() => void import("@tauri-apps/plugin-opener").then((m) => m.openPath(path))}
                className="px-2 py-1 text-xs rounded border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-pointer"
              >
                Open in default app
              </button>
            </div>
          </div>
        ) : gate?.kind === "binary" || (status === "error" && error.includes("valid UTF-8")) ? (
          <div data-testid="binary-file" className="p-4 flex flex-col items-start gap-2">
            <p className="text-xs font-mono text-neutral-500 dark:text-neutral-400">
              This file isn&apos;t text — it can&apos;t be previewed here.
            </p>
            <button
              type="button"
              onClick={() => void import("@tauri-apps/plugin-opener").then((m) => m.openPath(path))}
              className="px-2 py-1 text-xs rounded border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-pointer"
            >
              Open in default app
            </button>
          </div>
        ) : status === "error" ? (
          <div className="p-4 text-xs font-mono text-rose-600 dark:text-red-400">{error}</div>
        ) : mode === "diff" ? (
          <DiffEditor
            // Closing the file while the diff is showing used to throw "TextModel got
            // disposed before DiffEditorWidget model got reset" — keep the models.
            keepCurrentOriginalModel
            keepCurrentModifiedModel
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
            path={monacoModelPath(path)}
            value={value}
            theme={monacoTheme}
            language={large ? "plaintext" : undefined}
            loading={<div className="p-4 text-xs font-mono text-neutral-400 dark:text-neutral-500">loading…</div>}
            onChange={(v) => {
              setValue(v ?? "");
              setDirty(true);
              onDirtyChange?.(true);
            }}
            onMount={(editor) => {
              editorRef.current = editor;
              focusEditor();
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
              ...(large ? { ...LARGE_EDITOR_OPTIONS, readOnly: gate?.kind === "ok" && gate.readOnly } : {}),
            }}
          />
        )}
      </div>
    </div>
  );
}

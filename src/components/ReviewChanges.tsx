// Created by Claude — Classification: INTERNAL
//
// Review changes: every changed file of a working tree or a branch, one diff at a
// time, with Prev/Next (docs/prd-review-changes.md). Read-only.
import { lazy, Suspense, useEffect, useState } from "react";
import { ModalShell, ghostBtn } from "./modalKit";

const ReviewDiffPane = lazy(() => import("./ReviewDiffPane"));

export interface ReviewFile {
  /** git status code: M, A, D, ? (untracked) — or M for a branch file. */
  code: string;
  /** Shown path, relative to the repo. */
  path: string;
  /** Absolute path, when the file can be opened in the editor (working tree). */
  abs?: string;
}

export interface ReviewSource {
  title: string;
  files: ReviewFile[];
  load: (file: ReviewFile) => Promise<{ original: string; modified: string }>;
}

const CODE_COLOR: Record<string, string> = { M: "var(--warning)", A: "var(--success)", D: "var(--danger-text)", "?": "var(--success)" };

const isDir = (f: ReviewFile) => f.path.endsWith("/");

export function ReviewChanges({ source, startIndex = 0, theme, onClose, onOpenFile }: {
  source: ReviewSource;
  startIndex?: number;
  theme: "light" | "dark";
  onClose: () => void;
  onOpenFile?: (abs: string) => void;
}) {
  const { files } = source;
  const [index, setIndex] = useState(Math.min(Math.max(0, startIndex), Math.max(0, files.length - 1)));
  const [pair, setPair] = useState<{ original: string; modified: string } | null>(null);
  const [error, setError] = useState("");
  const file = files[index];

  useEffect(() => {
    setPair(null);
    setError("");
    if (!file || isDir(file)) return;
    let live = true;
    source.load(file).then(
      (p) => { if (live) setPair(p); },
      (e) => { if (live) setError(String(e)); },
    );
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [file?.path, source]);

  const canPrev = index > 0;
  const canNext = index < files.length - 1;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === "[" && index > 0) { e.preventDefault(); setIndex(index - 1); }
      if (e.key === "]" && index < files.length - 1) { e.preventDefault(); setIndex(index + 1); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [index, files.length]);

  const footer = (
    <>
      <span style={{ fontSize: 12, color: "var(--text-muted)" }}>
        {files.length === 0 ? "No changes" : `File ${index + 1} of ${files.length} · [ and ] to move`}
      </span>
      <div style={{ display: "flex", gap: 8 }}>
        {file?.abs && onOpenFile && !isDir(file) && file.code !== "D" && (
          <button type="button" style={ghostBtn} onClick={() => { onOpenFile(file.abs!); onClose(); }}>Open in editor</button>
        )}
        <button type="button" style={ghostBtn} disabled={!canPrev} onClick={() => setIndex(index - 1)}>← Prev</button>
        <button type="button" style={ghostBtn} disabled={!canNext} onClick={() => setIndex(index + 1)}>Next →</button>
      </div>
    </>
  );

  return (
    <ModalShell title={source.title} onClose={onClose} width={1240} footer={footer}>
      <div style={{ display: "flex", gap: 12, height: "64vh", minHeight: 0, margin: -8 }}>
        <div role="listbox" aria-label="Changed files" style={{ width: 260, flexShrink: 0, overflowY: "auto", border: "1px solid var(--border)", borderRadius: 8, padding: 4, fontFamily: "var(--font-mono)", fontSize: 12 }}>
          {files.map((f, i) => (
            <button
              key={f.path}
              type="button"
              role="option"
              aria-selected={i === index}
              onClick={() => setIndex(i)}
              title={f.path}
              style={{ display: "flex", gap: 8, width: "100%", alignItems: "center", padding: "6px 8px", borderRadius: 6, border: "none", textAlign: "left", fontFamily: "inherit", fontSize: "inherit", cursor: "pointer", color: "var(--text)", background: i === index ? "var(--bg-selected)" : "transparent" }}
            >
              <span style={{ color: CODE_COLOR[f.code] ?? "var(--text-muted)", width: 12, flexShrink: 0 }}>{f.code}</span>
              <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", direction: "rtl", textAlign: "left" }}>{f.path}</span>
            </button>
          ))}
        </div>
        <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", border: "1px solid var(--border)", borderRadius: 8, overflow: "hidden" }}>
          <div style={{ padding: "8px 12px", borderBottom: "1px solid var(--border)", fontFamily: "var(--font-mono)", fontSize: 12, color: "var(--text-muted)", display: "flex", justifyContent: "space-between", gap: 12 }}>
            <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{file?.path ?? ""}</span>
            <span style={{ flexShrink: 0 }}>before · after</span>
          </div>
          <div style={{ flex: 1, minHeight: 0 }} data-testid="review-diff">
            {!file ? null : isDir(file) ? (
              <Note>A new folder — open it in the file tree to see what's inside.</Note>
            ) : error ? (
              <Note>{error}</Note>
            ) : !pair ? (
              <Note>Loading…</Note>
            ) : (
              <Suspense fallback={<Note>Loading…</Note>}>
                <ReviewDiffPane path={file.path} original={pair.original} modified={pair.modified} theme={theme} />
              </Suspense>
            )}
          </div>
        </div>
      </div>
    </ModalShell>
  );
}

function Note({ children }: { children: string }) {
  return <div style={{ padding: 16, fontSize: 12, color: "var(--text-muted)" }}>{children}</div>;
}

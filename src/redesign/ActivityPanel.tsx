// Created by Claude — Classification: INTERNAL
//
// Inspector "Activity" tab: the files the selected session's agent read and changed
// (from its transcript, docs/prd-activity-agent-files.md) — click one to open it — and
// the lock/edit telemetry the old left panel carried: which files are being edited in
// more than one worktree, and how many uncommitted changes the watcher tracks.

import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";

export interface TouchedFile {
  path: string;
  action: "modified" | "read";
  count: number;
  lastAt: string;
}

export interface ActivityPanelProps {
  collisions: { file: string; worktrees: string[] }[];
  editedFiles: number;
  worktreesWatched: number;
  /** Claude session of the selected terminal tab, if it runs one. */
  sessionId?: string;
  /** Folder that session started in (its transcript dir and the base for relative paths). */
  sessionCwd?: string;
  onOpenFile: (path: string) => void;
}

const POLL_MS = 4000;
const heading = { fontSize: 11, fontWeight: 600, letterSpacing: "0.06em" } as const;

/** Show paths inside the session folder relative to it; others as they are. */
export function displayPath(path: string, cwd?: string): string {
  if (cwd && path.startsWith(cwd.endsWith("/") ? cwd : cwd + "/")) return path.slice(cwd.replace(/\/$/, "").length + 1);
  return path;
}

function useTouchedFiles(sessionId?: string, cwd?: string) {
  const [files, setFiles] = useState<TouchedFile[]>([]);
  const [error, setError] = useState<string>();
  useEffect(() => {
    setFiles([]);
    setError(undefined);
    if (!sessionId) return;
    let alive = true;
    const load = () =>
      invoke<TouchedFile[]>("session_touched_files", { cwd: cwd ?? "", sessionId })
        .then((f) => alive && (setFiles(f), setError(undefined)))
        .catch((e) => alive && setError(String(e)));
    load();
    const t = setInterval(load, POLL_MS);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [sessionId, cwd]);
  return { files, error };
}

function FileGroup({ title, files, cwd, onOpenFile }: { title: string; files: TouchedFile[]; cwd?: string; onOpenFile: (p: string) => void }) {
  if (files.length === 0) return null;
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
      <div style={{ ...heading, fontSize: 10, marginBottom: 2 }}>
        {title} · {files.length}
      </div>
      {files.map((f) => {
        const rel = displayPath(f.path, cwd);
        const slash = rel.lastIndexOf("/");
        return (
          <button
            key={f.path}
            className="rd-change-row"
            title={f.path}
            onClick={() => onOpenFile(f.path)}
            style={{ display: "flex", gap: 8, alignItems: "baseline", padding: "5px 8px", borderRadius: 6, border: "none", background: "transparent", color: "var(--text)", textAlign: "left", fontFamily: "inherit", fontSize: "inherit", cursor: "pointer" }}
          >
            <span style={{ width: 7, height: 7, borderRadius: 4, flexShrink: 0, alignSelf: "center", background: f.action === "modified" ? "var(--warning)" : "var(--text-muted)" }} />
            <span className="rd-ellipsis" style={{ flexGrow: 1, fontFamily: "var(--font-mono)" }}>
              {rel.slice(slash + 1)}
              {slash > 0 && <span style={{ color: "var(--text-muted)" }}> {rel.slice(0, slash)}</span>}
            </span>
            {f.count > 1 && <span style={{ color: "var(--text-muted)", flexShrink: 0 }}>×{f.count}</span>}
          </button>
        );
      })}
    </div>
  );
}

export function ActivityPanel({ collisions, editedFiles, worktreesWatched, sessionId, sessionCwd, onOpenFile }: ActivityPanelProps) {
  const { files, error } = useTouchedFiles(sessionId, sessionCwd);
  const modified = files.filter((f) => f.action === "modified");
  const read = files.filter((f) => f.action === "read");
  return (
    <div style={{ padding: 16, display: "flex", flexDirection: "column", gap: 10, fontSize: 12, color: "var(--text-muted)" }}>
      <div style={heading}>AGENT FILES</div>
      {!sessionId ? (
        <div>Select a Claude session tab to see the files its agent read and changed.</div>
      ) : error ? (
        <div style={{ color: "var(--danger-text)" }}>{error}</div>
      ) : files.length === 0 ? (
        <div>This session hasn't read or changed any files yet.</div>
      ) : (
        <>
          <FileGroup title="MODIFIED" files={modified} cwd={sessionCwd} onOpenFile={onOpenFile} />
          <FileGroup title="READ" files={read} cwd={sessionCwd} onOpenFile={onOpenFile} />
        </>
      )}

      <div style={{ ...heading, marginTop: 8 }}>LOCK / EDIT TELEMETRY</div>
      <div>
        {worktreesWatched} worktrees watched · {editedFiles} uncommitted {editedFiles === 1 ? "change" : "changes"} tracked
      </div>
      {collisions.length === 0 ? (
        <div style={{ color: "var(--success-card-text)" }}>No file collisions across worktrees.</div>
      ) : (
        collisions.map((c) => (
          <div key={c.file} style={{ display: "flex", flexDirection: "column", gap: 2, padding: 10, borderRadius: 8, background: "var(--danger-btn-bg)", border: "1px solid var(--danger-border)" }}>
            <span className="rd-ellipsis" style={{ fontFamily: "var(--font-mono)", color: "var(--danger-text)" }}>{c.file}</span>
            <span className="rd-ellipsis">edited in: {c.worktrees.join(" · ")}</span>
          </div>
        ))
      )}
    </div>
  );
}

// Created by Claude — Classification: INTERNAL
//
// Inspector "Activity" tab: the lock/edit telemetry the old left panel carried —
// which files are being edited in more than one worktree, and how many uncommitted
// changes the watcher tracks. Read-only view of App's existing pm_collisions state.

export interface ActivityPanelProps {
  collisions: { file: string; worktrees: string[] }[];
  editedFiles: number;
  worktreesWatched: number;
}

export function ActivityPanel({ collisions, editedFiles, worktreesWatched }: ActivityPanelProps) {
  return (
    <div style={{ padding: 16, display: "flex", flexDirection: "column", gap: 10, fontSize: 12, color: "var(--text-muted)" }}>
      <div style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.06em" }}>LOCK / EDIT TELEMETRY</div>
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

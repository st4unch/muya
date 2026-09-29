// Created by Claude — Classification: INTERNAL
//
// Thin status strip under the terminal (PROMPT.md §3): current verb, mono
// elapsed/tokens/thinking, and — when a build is ready — an update prompt.

export interface ProgressStripProps {
  verb?: string;
  elapsed?: string;
  tokens?: string;
  thought?: string;
  updateReady?: boolean;
  onRestart: () => void;
}

export function ProgressStrip({ verb, elapsed, tokens, thought, updateReady, onRestart }: ProgressStripProps) {
  const monoParts = [elapsed, tokens ? `↓ ${tokens}` : undefined, thought ? `thought for ${thought}` : undefined].filter(Boolean);
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 12,
        padding: "8px 28px",
        background: "var(--bg-terminal)",
        borderTop: "1px solid var(--border-subtle)",
        fontSize: 12,
        color: "var(--text-muted)",
        minWidth: 0,
      }}
    >
      {verb && (
        <span style={{ display: "flex", alignItems: "center", gap: 8, color: "var(--success-text)", flexShrink: 0 }}>
          <span style={{ width: 6, height: 6, borderRadius: 3, background: "var(--success)", flexShrink: 0 }} />
          {verb}
        </span>
      )}
      {monoParts.length > 0 && <span style={{ fontFamily: "var(--font-mono)" }}>{monoParts.join(" · ")}</span>}
      <div style={{ flexGrow: 1 }} />
      {updateReady && (
        <>
          <span>Update ready</span>
          <button
            type="button"
            onClick={onRestart}
            className="rd-btn2"
            style={{
              height: 26,
              padding: "0 10px",
              borderRadius: 6,
              border: "1px solid var(--border-control)",
              background: "var(--bg-control)",
              color: "var(--text)",
              fontSize: 12,
              flexShrink: 0,
            }}
          >
            Restart
          </button>
        </>
      )}
    </div>
  );
}

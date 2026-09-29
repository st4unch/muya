// Created by Claude — Classification: INTERNAL
//
// Confirmation modal before "Broadcast to all…" sends the same message to
// every open grid panel (PROMPT.md §4). Not in either reference — kept in the
// same visual language as the rest of the redesign.

export interface BroadcastModalProps {
  open: boolean;
  panelCount: number;
  value: string;
  onChange: (value: string) => void;
  onCancel: () => void;
  onConfirm: () => void;
}

export function BroadcastModal({ open, panelCount, value, onChange, onCancel, onConfirm }: BroadcastModalProps) {
  if (!open) return null;
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Broadcast to all panels"
      style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.5)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 100 }}
    >
      <div style={{ width: 420, borderRadius: 12, border: "1px solid var(--border)", background: "var(--bg-panel)", padding: 20, display: "flex", flexDirection: "column", gap: 12 }}>
        <h2 style={{ margin: 0, fontSize: 15, fontWeight: 600 }}>Broadcast to all panels</h2>
        <p style={{ margin: 0, fontSize: 13, color: "var(--text-muted)" }}>Send this message to every open panel ({panelCount}).</p>
        <textarea
          rows={3}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          style={{ resize: "none", border: "1px solid var(--border-strong)", borderRadius: 8, background: "var(--bg-input)", color: "var(--text)", fontFamily: "var(--font-sans)", fontSize: 14, padding: 10 }}
        />
        <div style={{ display: "flex", justifyContent: "flex-end", gap: 8 }}>
          <button type="button" onClick={onCancel} className="rd-btn2" style={{ height: 32, padding: "0 14px", borderRadius: 7, border: "1px solid var(--border-control)", background: "var(--bg-control)", color: "var(--text)", fontSize: 13 }}>
            Cancel
          </button>
          <button
            type="button"
            onClick={onConfirm}
            disabled={!value.trim()}
            style={{ height: 32, padding: "0 14px", borderRadius: 7, border: "none", background: "var(--primary-bg)", color: "var(--primary-fg)", fontSize: 13, fontWeight: 600, opacity: value.trim() ? 1 : 0.5 }}
          >
            Send to {panelCount} panels
          </button>
        </div>
      </div>
    </div>
  );
}

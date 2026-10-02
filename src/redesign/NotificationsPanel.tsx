// Created by Claude — Classification: INTERNAL
//
// Header-bell notifications as message bubbles ("muya-all — Session finished"). The
// list keeps every event until the operator dismisses it or clears all; a new event
// also pops a short-lived bubble under the bell.

import type { ReactNode } from "react";
import type { AgentNotification } from "../lib/agentNotifications";
import { MenuPopover, type Anchor } from "./Menus";

export interface NotificationItem {
  n: AgentNotification;
  /** Workspace name, "SSH", or "closed" when the agent's tab is gone. */
  where: string;
  /** The agent's tab still exists, so the bubble can open it. */
  openable: boolean;
}

const MESSAGE: Record<AgentNotification["kind"], string> = {
  waiting: "Waiting for your input",
  finished: "Session finished",
};
const DOT: Record<AgentNotification["kind"], string> = {
  waiting: "var(--warning)",
  finished: "var(--success)",
};

/** "just now", "4m ago", "2h ago", "3d ago". */
export function timeAgo(at: number, now = Date.now()): string {
  const m = Math.floor((now - at) / 60_000);
  if (m < 1) return "just now";
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h ago` : `${Math.floor(h / 24)}d ago`;
}

function DismissButton({ onClick, label }: { onClick: () => void; label: string }) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={(e) => {
        e.stopPropagation();
        onClick();
      }}
      className="rd-icon-btn"
      style={{ width: 20, height: 20, borderRadius: 5, border: "none", background: "transparent", color: "var(--text-muted)", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0, padding: 0 }}
    >
      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2.2} strokeLinecap="round" aria-hidden="true">
        <path d="M18 6 6 18M6 6l12 12" />
      </svg>
    </button>
  );
}

/** One message bubble. */
export function NotificationBubble({ item, onOpen, onDismiss, trailing }: { item: NotificationItem; onOpen: () => void; onDismiss: () => void; trailing?: ReactNode }) {
  const { n, where, openable } = item;
  return (
    <div
      role="button"
      tabIndex={openable ? 0 : -1}
      aria-disabled={!openable}
      aria-label={`${n.name}: ${MESSAGE[n.kind]}`}
      onClick={openable ? onOpen : undefined}
      onKeyDown={(e) => {
        if (openable && (e.key === "Enter" || e.key === " ")) {
          e.preventDefault();
          onOpen();
        }
      }}
      className="rd-notif-bubble"
      style={{
        display: "flex",
        gap: 10,
        padding: "10px 10px 10px 12px",
        borderRadius: 10,
        border: "1px solid var(--border)",
        background: "var(--bg-control)",
        cursor: openable ? "pointer" : "default",
        opacity: openable ? 1 : 0.6,
      }}
    >
      <span style={{ width: 8, height: 8, borderRadius: 4, background: DOT[n.kind], flexShrink: 0, marginTop: 5 }} />
      <div style={{ display: "flex", flexDirection: "column", gap: 2, flexGrow: 1, minWidth: 0 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 8, minWidth: 0 }}>
          <span className="rd-ellipsis" style={{ fontWeight: 600, fontSize: 13, minWidth: 0 }}>{n.name}</span>
          <span style={{ marginLeft: "auto", fontSize: 11, color: "var(--text-muted)", whiteSpace: "nowrap", flexShrink: 0 }}>{timeAgo(n.at)}</span>
        </div>
        <span style={{ fontSize: 13, color: "var(--text-secondary)" }}>{MESSAGE[n.kind]}</span>
        <span className="rd-ellipsis" style={{ fontSize: 11, color: "var(--text-muted)" }}>{where}</span>
      </div>
      {trailing}
      <DismissButton onClick={onDismiss} label="Dismiss notification" />
    </div>
  );
}

export function NotificationsPopover(props: {
  anchor: Anchor;
  items: NotificationItem[];
  onOpen: (key: string) => void;
  onDismiss: (id: string) => void;
  onClearAll: () => void;
  onClose: () => void;
}) {
  const { anchor, items, onOpen, onDismiss, onClearAll, onClose } = props;
  return (
    <MenuPopover anchor={anchor} width={380} label="Notifications" onClose={onClose}>
      <div style={{ display: "flex", alignItems: "center", padding: "6px 8px 6px 10px" }}>
        <span style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.06em", color: "var(--text-muted)" }}>NOTIFICATIONS</span>
        {items.length > 0 && (
          <button
            type="button"
            onClick={onClearAll}
            className="rd-btn2"
            style={{ marginLeft: "auto", height: 24, padding: "0 8px", borderRadius: 6, border: "none", background: "transparent", color: "var(--text-secondary)", fontSize: 12 }}
          >
            Clear all
          </button>
        )}
      </div>
      {items.length === 0 ? (
        <div style={{ padding: "8px 10px 12px", color: "var(--text-muted)" }}>No notifications.</div>
      ) : (
        <div style={{ maxHeight: 440, overflowY: "auto", display: "flex", flexDirection: "column", gap: 6, padding: "0 4px 4px" }}>
          {items.map((it) => (
            <NotificationBubble key={it.n.id} item={it} onOpen={() => onOpen(it.n.key)} onDismiss={() => onDismiss(it.n.id)} />
          ))}
        </div>
      )}
    </MenuPopover>
  );
}

/** The short-lived bubble under the bell for a new event. */
export function NotificationToast({ item, onOpen, onDismiss }: { item: NotificationItem; onOpen: () => void; onDismiss: () => void }) {
  return (
    <div
      className="rd-root"
      role="status"
      aria-live="polite"
      style={{
        position: "fixed",
        top: 52,
        right: 16,
        width: 340,
        zIndex: 140,
        borderRadius: 12,
        boxShadow: "var(--shadow-popover, 0 12px 40px rgba(0,0,0,0.35))",
        background: "var(--bg-panel)",
      }}
    >
      <NotificationBubble item={item} onOpen={onOpen} onDismiss={onDismiss} />
    </div>
  );
}

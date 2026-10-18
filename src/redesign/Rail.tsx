// Created by Claude — Classification: INTERNAL
//
// Left navigation rail (PROMPT.md §2), identical on Control and Grid. 64px wide,
// 7 items (Settings icon-only, pinned to the bottom via a flex spacer).

import type { RailItem } from "./types";
import RailPanda from "./RailPanda";
import {
  ControlRailIcon,
  FilesRailIcon,
  KanbanRailIcon,
  QueueRailIcon,
  ResourcesRailIcon,
  SessionsRailIcon,
  SettingsRailIcon,
  SshRailIcon,
  SchedulesRailIcon,
} from "./icons";

export interface RailProps {
  /** null on pages that have no rail item (Branches). */
  active: RailItem | null;
  onNavigate: (item: RailItem) => void;
  /** Some agent is working — the panda gets busy too. */
  busy?: boolean;
  /** What the working agent is doing ("Thinking…"): the panda's teacher points at it. */
  status?: string;
}

const ITEMS: { item: RailItem; label: string; Icon: typeof ControlRailIcon }[] = [
  { item: "control", label: "Control", Icon: ControlRailIcon },
  { item: "files", label: "Files", Icon: FilesRailIcon },
  { item: "sessions", label: "Sessions", Icon: SessionsRailIcon },
  { item: "queue", label: "Queue", Icon: QueueRailIcon },
  { item: "kanban", label: "Kanban", Icon: KanbanRailIcon },
  { item: "resources", label: "Resources", Icon: ResourcesRailIcon },
  { item: "ssh", label: "SSH", Icon: SshRailIcon },
  { item: "schedules", label: "Schedules", Icon: SchedulesRailIcon },
];

export function Rail({ active, onNavigate, busy = false, status }: RailProps) {
  return (
    <nav
      aria-label="Main navigation"
      style={{
        width: 64,
        flexShrink: 0,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        gap: 6,
        padding: "12px 0",
        borderRight: "1px solid var(--border)",
        background: "var(--bg-chrome)",
      }}
    >
      {ITEMS.map(({ item, label, Icon }) => {
        const isActive = active === item;
        return (
          <button
            key={item}
            type="button"
            aria-label={label}
            aria-current={isActive ? "page" : undefined}
            onClick={() => onNavigate(item)}
            className="rd-rail-item"
            style={{
              width: 48,
              height: 48,
              borderRadius: 10,
              border: "none",
              background: isActive ? "var(--bg-rail-active)" : "transparent",
              color: isActive ? "var(--text-strong)" : "var(--text-muted)",
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              justifyContent: "center",
              gap: 3,
              fontSize: 10,
              fontFamily: "var(--font-sans)",
            }}
          >
            <Icon size={18} />
            {label}
          </button>
        );
      })}
      <RailPanda busy={busy} status={status} />
      <button
        type="button"
        aria-label="Settings"
        aria-current={active === "settings" ? "page" : undefined}
        onClick={() => onNavigate("settings")}
        className="rd-rail-item"
        style={{
          width: 48,
          height: 48,
          borderRadius: 10,
          border: "none",
          background: active === "settings" ? "var(--bg-rail-active)" : "transparent",
          color: active === "settings" ? "var(--text-strong)" : "var(--text-muted)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <SettingsRailIcon size={18} />
      </button>
    </nav>
  );
}

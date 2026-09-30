// Created by Claude — Classification: INTERNAL
//
// Inline SVG icons copied verbatim (path data, stroke-width, viewBox) from
// docs/design/redesign-v0.4/{control,grid}.reference.html. Each icon is a tiny
// presentational component; size/color are set by the caller via props so the
// same icon can be reused at different sizes without duplicating path data.
//
// The one exception: ThemeMonitorIcon/ThemeSunIcon/ThemeMoonIcon are NOT in the
// reference (PROMPT.md §6 — the one element the operator approved adding). They
// follow the same 24-viewBox/round-cap/round-join convention as the reference
// icons so they read as part of the same icon family.

import type { SVGProps } from "react";

interface IconProps extends SVGProps<SVGSVGElement> {
  size?: number;
}

function base(size: number, strokeWidth: number, props: SVGProps<SVGSVGElement>): SVGProps<SVGSVGElement> {
  return {
    width: size,
    height: size,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth,
    strokeLinecap: "round",
    strokeLinejoin: "round",
    "aria-hidden": true,
    ...props,
  };
}

export function ChevronDownIcon({ size = 14, ...p }: IconProps) {
  return (
    <svg {...base(size, 2, p)}>
      <path d="m6 9 6 6 6-6" />
    </svg>
  );
}

export function SearchIcon({ size = 15, ...p }: IconProps) {
  return (
    <svg {...base(size, 2, p)}>
      <circle cx="11" cy="11" r="7" />
      <path d="m20 20-3.5-3.5" />
    </svg>
  );
}

export function BellIcon({ size = 16, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9" />
      <path d="M10.3 21a1.94 1.94 0 0 0 3.4 0" />
    </svg>
  );
}

export function ControlRailIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <rect x="3" y="4" width="18" height="16" rx="2" />
      <path d="m7 9 3 3-3 3" />
      <path d="M13 15h4" />
    </svg>
  );
}

export function QueueRailIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01" />
    </svg>
  );
}

export function KanbanRailIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <rect x="3" y="3" width="5" height="18" rx="1" />
      <rect x="10" y="3" width="5" height="12" rx="1" />
      <rect x="17" y="3" width="4" height="8" rx="1" />
    </svg>
  );
}

export function ResourcesRailIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <path d="M22 12h-4l-3 9L9 3l-3 9H2" />
    </svg>
  );
}

export function SshRailIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <rect x="2" y="4" width="20" height="7" rx="2" />
      <rect x="2" y="13" width="20" height="7" rx="2" />
      <path d="M6 7.5h.01M6 16.5h.01" />
    </svg>
  );
}

export function ChatRailIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
    </svg>
  );
}

export function SettingsRailIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
    </svg>
  );
}

export function BypassWarningIcon({ size = 12, ...p }: IconProps) {
  return (
    <svg {...base(size, 2.2, p)}>
      <path d="M12 9v4M12 17h.01" />
      <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
    </svg>
  );
}

export function SendIcon({ size = 16, ...p }: IconProps) {
  return (
    <svg {...base(size, 2.2, p)}>
      <path d="M12 19V5M5 12l7-7 7 7" />
    </svg>
  );
}

export function MaximizeIcon({ size = 14, ...p }: IconProps) {
  return (
    <svg {...base(size, 2, p)}>
      <path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7" />
    </svg>
  );
}

export function CheckIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base(size, 2, p)}>
      <path d="M20 6 9 17l-5-5" />
    </svg>
  );
}

export function MoreIcon({ size = 16, ...p }: IconProps) {
  return (
    <svg {...base(size, 2, p)}>
      <path d="M5 12h.01M12 12h.01M19 12h.01" />
    </svg>
  );
}

// --- The one addition not present in either reference (PROMPT.md §6). ---

export function ThemeMonitorIcon({ size = 16, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <rect x="2" y="3" width="20" height="14" rx="2" />
      <path d="M8 21h8M12 17v4" />
    </svg>
  );
}

export function ThemeSunIcon({ size = 16, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" />
    </svg>
  );
}

export function ThemeMoonIcon({ size = 16, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
    </svg>
  );
}

/** Lucide "panel-left" / "panel-right": a window with the left / right rail marked. */
export function PanelLeftIcon({ size = 16, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <rect width="18" height="18" x="3" y="3" rx="2" />
      <path d="M9 3v18" />
    </svg>
  );
}

export function PanelRightIcon({ size = 16, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <rect width="18" height="18" x="3" y="3" rx="2" />
      <path d="M15 3v18" />
    </svg>
  );
}

export function ChevronRightIcon({ size = 14, ...p }: IconProps) {
  return (
    <svg {...base(size, 2, p)}>
      <path d="m9 6 6 6-6 6" />
    </svg>
  );
}

/* Not in the reference: icon-only forms of "Compact" / "Split to grid" for a narrow
 * main area (SessionHeader). Same 24-viewBox, round-cap family as the rest. */
export function CompactIcon({ size = 15, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <path d="m4 14 6 0 0 6" />
      <path d="m20 10-6 0 0-6" />
      <path d="m14 10 7-7" />
      <path d="m3 21 7-7" />
    </svg>
  );
}

export function GridSplitIcon({ size = 15, ...p }: IconProps) {
  return (
    <svg {...base(size, 1.8, p)}>
      <rect width="7" height="7" x="3" y="3" rx="1.5" />
      <rect width="7" height="7" x="14" y="3" rx="1.5" />
      <rect width="7" height="7" x="3" y="14" rx="1.5" />
      <rect width="7" height="7" x="14" y="14" rx="1.5" />
    </svg>
  );
}

export function PlusIcon({ size = 14, ...p }: IconProps) {
  return (
    <svg {...base(size, 2, p)}>
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

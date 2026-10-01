// Created by Claude — Classification: INTERNAL
//
// App header for both screens' shared chrome (PROMPT.md §2, §3, §6). The theme
// button (32×32, left of the bell) is the one element not in either reference.

import { onTitleBarMouseDown } from "./titleBar";
import type { MouseEvent } from "react";
import type { HeaderVM, ThemePreference } from "./types";
import { useLiveMetrics } from "./useLiveMetrics";
import { BellIcon, ChevronDownIcon, PanelLeftIcon, PanelRightIcon, SearchIcon, ThemeMonitorIcon, ThemeMoonIcon, ThemeSunIcon } from "./icons";

/** Its own component so a metrics tick re-renders these three spans, nothing else. */
function MetricsReadout({ cpu, ram, clock }: Pick<HeaderVM, "cpu" | "ram" | "clock">) {
  const live = useLiveMetrics(cpu === undefined);
  return (
    <>
      <span>
        CPU <span style={{ color: "var(--text)" }}>{cpu ?? live.cpu}</span>
      </span>
      <span>
        RAM <span style={{ color: "var(--text)" }}>{ram ?? live.ram}</span>
      </span>
      <span style={{ color: "var(--text)" }}>{clock ?? live.clock}</span>
    </>
  );
}

export interface ControlHeaderProps {
  header: HeaderVM;
  themePreference: ThemePreference;
  onThemeCycle: () => void;
  onNotificationsClick: () => void;
  /** Receives the click so the caller can anchor a menu under the button. */
  onWorkspaceClick: (e: MouseEvent<HTMLElement>) => void;
  onOpenPalette: () => void;
  /** Panel toggles (docs/prd-v04-followups.md §1). Omitted = the button isn't drawn. */
  agentsOpen?: boolean;
  onToggleAgents?: () => void;
  inspectorOpen?: boolean;
  onToggleInspector?: () => void;
}

const TOGGLE_STYLE = {
  width: 32,
  height: 32,
  borderRadius: 8,
  border: "1px solid var(--border-control)",
  background: "var(--bg-control)",
  color: "var(--text)",
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  flexShrink: 0,
} as const;

const THEME_LABEL: Record<ThemePreference, string> = {
  system: "Theme: system",
  light: "Theme: light",
  dark: "Theme: dark",
};

function ThemeIcon({ pref }: { pref: ThemePreference }) {
  if (pref === "light") return <ThemeSunIcon size={16} />;
  if (pref === "dark") return <ThemeMoonIcon size={16} />;
  return <ThemeMonitorIcon size={16} />;
}

export function ControlHeader({
  header,
  themePreference,
  onThemeCycle,
  onNotificationsClick,
  onWorkspaceClick,
  onOpenPalette,
  agentsOpen = true,
  onToggleAgents,
  inspectorOpen = true,
  onToggleInspector,
}: ControlHeaderProps) {
  return (
    <header
      onMouseDown={onTitleBarMouseDown}
      style={{
        userSelect: "none",
        WebkitUserSelect: "none",
        height: 48,
        flexShrink: 0,
        display: "flex",
        alignItems: "center",
        gap: 16,
        padding: "0 16px 0 88px",
        borderBottom: "1px solid var(--border)",
        background: "var(--bg-chrome)",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 10, flexShrink: 0 }}>
        <div
          style={{
            width: 26,
            height: 26,
            borderRadius: 7,
            background: "var(--primary-bg)",
            color: "var(--primary-fg)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontWeight: 700,
            fontSize: 14,
          }}
        >
          M
        </div>
        <span style={{ fontWeight: 600, fontSize: 15 }}>Muya</span>
      </div>

      {onToggleAgents && (
        <button
          type="button"
          aria-label={agentsOpen ? "Hide agents panel" : "Show agents panel"}
          title={`${agentsOpen ? "Hide" : "Show"} agents panel (⌘B)`}
          aria-pressed={agentsOpen}
          onClick={onToggleAgents}
          className="rd-icon-btn"
          style={TOGGLE_STYLE}
        >
          <PanelLeftIcon size={16} />
        </button>
      )}

      <button
        type="button"
        onClick={onWorkspaceClick}
        className="rd-btn2"
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          height: 32,
          padding: "0 12px",
          borderRadius: 8,
          border: "1px solid var(--border-control)",
          background: "var(--bg-control)",
          color: "var(--text)",
          fontSize: 13,
          flexShrink: 0,
        }}
      >
        <span style={{ color: "var(--text-muted)" }}>Workspace</span>
        <span style={{ fontWeight: 500 }}>{header.workspaceName}</span>
        <span style={{ color: "var(--text-muted)" }}>· {header.workspaceCount}</span>
        <ChevronDownIcon size={14} />
      </button>

      <div style={{ flexGrow: 1, display: "flex", justifyContent: "center", minWidth: 0 }}>
        <button
          type="button"
          onClick={onOpenPalette}
          style={{
            width: 440,
            maxWidth: "100%",
            height: 32,
            display: "flex",
            alignItems: "center",
            gap: 10,
            padding: "0 12px",
            borderRadius: 8,
            border: "1px solid var(--border-control)",
            background: "var(--bg-input)",
            color: "var(--text-muted)",
            fontSize: 13,
          }}
        >
          <SearchIcon size={15} />
          <span className="rd-ellipsis" style={{ flexGrow: 1, textAlign: "left" }}>
            Search agents, files or commands…
          </span>
          <span
            style={{
              fontFamily: "var(--font-mono)",
              fontSize: 11,
              padding: "2px 6px",
              borderRadius: 4,
              border: "1px solid var(--border-strong)",
              color: "var(--text-tertiary)",
              flexShrink: 0,
            }}
          >
            ⌘K
          </span>
        </button>
      </div>

      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 14,
          fontSize: 12,
          color: "var(--text-muted)",
          fontFamily: "var(--font-mono)",
          flexShrink: 0,
        }}
      >
        <MetricsReadout cpu={header.cpu} ram={header.ram} clock={header.clock} />
      </div>

      <button
        type="button"
        aria-label={THEME_LABEL[themePreference]}
        title={THEME_LABEL[themePreference]}
        onClick={onThemeCycle}
        className="rd-icon-btn"
        style={{
          width: 32,
          height: 32,
          borderRadius: 8,
          border: "1px solid var(--border-control)",
          background: "var(--bg-control)",
          color: "var(--text)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          flexShrink: 0,
        }}
      >
        <ThemeIcon pref={themePreference} />
      </button>

      <button
        type="button"
        aria-label="Notifications"
        onClick={onNotificationsClick}
        className="rd-icon-btn"
        style={{
          position: "relative",
          width: 32,
          height: 32,
          borderRadius: 8,
          border: "1px solid var(--border-control)",
          background: "var(--bg-control)",
          color: "var(--text)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          flexShrink: 0,
        }}
      >
        <BellIcon size={16} />
        {header.hasNotifications && (
          <span
            style={{
              position: "absolute",
              top: 5,
              right: 6,
              width: 8,
              height: 8,
              borderRadius: 4,
              background: "var(--warning)",
            }}
          />
        )}
      </button>

      {onToggleInspector && (
        <button
          type="button"
          aria-label={inspectorOpen ? "Hide inspector" : "Show inspector"}
          title={`${inspectorOpen ? "Hide" : "Show"} inspector (⌥⌘B)`}
          aria-pressed={inspectorOpen}
          onClick={onToggleInspector}
          className="rd-icon-btn"
          style={TOGGLE_STYLE}
        >
          <PanelRightIcon size={16} />
        </button>
      )}
    </header>
  );
}

// Created by Claude — Classification: INTERNAL
//
// Composes the Control screen (PROMPT.md §3) from AppFrame + Rail + Footer +
// ControlHeader + AgentList + (SessionHeader|FileHeader) + terminal slot +
// ProgressStrip + Composer + Inspector. Purely presentational: every user
// action is one of the callback props, no Tauri calls, no global state.

import type { MouseEvent, ReactNode } from "react";
import { AppFrame } from "./AppFrame";
import { Rail } from "./Rail";
import { Footer } from "./Footer";
import { ControlHeader } from "./ControlHeader";
import { AgentList, type AgentFilter } from "./AgentList";
import { SessionHeader } from "./SessionHeader";
import { FileHeader } from "./FileHeader";
import { ProgressStrip } from "./ProgressStrip";
import { Composer } from "./Composer";
import { Inspector, type InspectorTab } from "./Inspector";
import type { AgentVM, FileVM, FooterVM, HeaderVM, InspectorVM, PermissionMode, RailItem, ThemePreference } from "./types";

export interface ControlScreenProps {
  header: HeaderVM;
  footer: FooterVM;
  themePreference: ThemePreference;
  onThemeCycle: () => void;
  onNotificationsClick: () => void;
  onWorkspaceClick: (e: MouseEvent<HTMLElement>) => void;
  onOpenPalette: () => void;

  railActive: RailItem;
  onRailNavigate: (item: RailItem) => void;

  agents: AgentVM[];
  selectedAgentKey: string | null;
  agentFilter: AgentFilter;
  onAgentFilterChange: (filter: AgentFilter) => void;
  onSelectAgent: (key: string) => void;
  onNewAgent: () => void;
  onReorderAgents: (fromKey: string, toKey: string) => void;

  /** null = the selected agent's terminal is shown; set = a file replaces it. */
  openFile: FileVM | null;
  onCloseFile: () => void;
  /** The viewer/editor for `openFile`, rendered where the terminal slot would be. */
  fileSlot?: ReactNode;

  onCompact: () => void;
  onSplitToGrid: () => void;
  onStop: () => void;
  onMoreActions: (e: MouseEvent<HTMLElement>) => void;

  composerValue: string;
  onComposerChange: (value: string) => void;
  onSendMessage: (text: string) => void;
  onCycleMode: () => void;
  onModeMenu?: (e: MouseEvent<HTMLElement>) => void;
  onAttachFile: () => void;
  onOpenCommands: () => void;

  updateReady: boolean;
  onRestartForUpdate: () => void;

  inspector: InspectorVM;
  inspectorTab: InspectorTab;
  onInspectorTabChange: (tab: InspectorTab) => void;
  onApprove: (key: string) => void;
  onDeny: (key: string) => void;
  onOpenApproval: (key: string) => void;
  onReviewDiff: () => void;
  onCommit: () => void;
  onOpenChange?: (path: string) => void;
  filesSlot?: ReactNode;
  activitySlot?: ReactNode;

  /** window.innerWidth-driven: PROMPT.md §5 responsive breakpoints. */
  inspectorOpen: boolean;
}

export function ControlScreen(props: ControlScreenProps) {
  const selected = props.agents.find((a) => a.key === props.selectedAgentKey) ?? null;
  const waitingAgents = props.agents.filter((a) => a.status === "waiting" && a.approval);

  return (
    <AppFrame
      header={
        <ControlHeader
          header={props.header}
          themePreference={props.themePreference}
          onThemeCycle={props.onThemeCycle}
          onNotificationsClick={props.onNotificationsClick}
          onWorkspaceClick={props.onWorkspaceClick}
          onOpenPalette={props.onOpenPalette}
        />
      }
      rail={<Rail active={props.railActive} onNavigate={props.onRailNavigate} />}
      footer={<Footer {...props.footer} />}
    >
      <AgentList
        agents={props.agents}
        selectedKey={props.selectedAgentKey}
        filter={props.agentFilter}
        onFilterChange={props.onAgentFilterChange}
        onSelectAgent={props.onSelectAgent}
        onNewAgent={props.onNewAgent}
        onReorder={props.onReorderAgents}
      />

      <main style={{ flexGrow: 1, minWidth: 0, display: "flex", flexDirection: "column", background: "var(--bg-app)", minHeight: 0 }}>
        {props.openFile ? (
          <FileHeader file={props.openFile} onClose={props.onCloseFile} />
        ) : selected ? (
          <SessionHeader agent={selected} onCompact={props.onCompact} onSplitToGrid={props.onSplitToGrid} onStop={props.onStop} onMore={props.onMoreActions} />
        ) : null}

        {/* The real xterm instance is adopted into this slot by the orchestrator — it
            owns no styling here beyond filling the region edge-to-edge with the
            terminal background; the xterm host itself carries the 20px/28px padding. */}
        {props.openFile ? (
          <div style={{ flexGrow: 1, minHeight: 0, minWidth: 0, overflow: "hidden", display: "flex", flexDirection: "column", background: "var(--bg-app)" }}>
            {props.fileSlot}
          </div>
        ) : (
          <div
            data-terminal-slot={selected?.key ?? "none"}
            data-diff-mask
            style={{ flexGrow: 1, minHeight: 0, overflow: "hidden", background: "var(--bg-terminal)" }}
          />
        )}

        {selected && !props.openFile && (
          <ProgressStrip
            verb={selected.progress?.verb}
            elapsed={selected.progress?.elapsed}
            tokens={selected.progress?.tokens}
            thought={selected.progress?.thought}
            updateReady={props.updateReady}
            onRestart={props.onRestartForUpdate}
          />
        )}

        {selected && !props.openFile && (
          <Composer
            agentName={selected.name}
            value={props.composerValue}
            onChange={props.onComposerChange}
            onSend={props.onSendMessage}
            mode={selected.mode as PermissionMode}
            onCycleMode={props.onCycleMode}
            onModeMenu={props.onModeMenu}
            onAttachFile={props.onAttachFile}
            onCommands={props.onOpenCommands}
          />
        )}
      </main>

      {props.inspectorOpen && (
        <Inspector
          waitingAgents={waitingAgents}
          onApprove={props.onApprove}
          onDeny={props.onDeny}
          onOpen={props.onOpenApproval}
          activeTab={props.inspectorTab}
          onTabChange={props.onInspectorTabChange}
          inspector={props.inspector}
          onReviewDiff={props.onReviewDiff}
          onCommit={props.onCommit}
          onOpenChange={props.onOpenChange}
          filesSlot={props.filesSlot}
          activitySlot={props.activitySlot}
        />
      )}
    </AppFrame>
  );
}

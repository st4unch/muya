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
import { FilesSection } from "./FilesSection";
import { OpenFilesList } from "./OpenFilesList";
import { ResizeHandle } from "./ResizeHandle";
import { AGENTS_W, INSPECTOR_W, usePanelLayout } from "./usePanelLayout";
import type { AgentVM, FileVM, FooterVM, HeaderVM, InspectorVM, OpenFileVM, PermissionMode, RailItem, ThemePreference } from "./types";

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
  /** Empty-state "New terminal" (⌘T). */
  onNewTerminal?: () => void;
  /** The file tree, shown in the Files section under the agents list. */
  filesSlot?: ReactNode;
  /** How many roots the tree shows (the count next to FILES). */
  filesCount?: number;
  activitySlot?: ReactNode;

  /** Rename a session (double-click in the list, header or grid). */
  onRenameAgent?: (key: string, name: string) => void;
  /** Right-click on a session in the list. */
  onAgentContextMenu?: (key: string, e: MouseEvent) => void;
  /** Agents pinned to the top of the list (PINNED group). */
  pinnedAgentKeys?: ReadonlySet<string>;
  /** The message box under the terminal; hidden from the footer's chat toggle. */
  composerOpen?: boolean;
  /** window.innerWidth-driven: PROMPT.md §5 responsive breakpoints. */
  inspectorOpen: boolean;

  /** "files" = the Files rail: the left column lists open files and the main area shows
   *  the selected one. "agents" = terminals only (an open file waits in Files).
   *  Omitted: the older behavior, where an open file replaces the terminal. */
  mode?: "agents" | "files";
  openFiles?: OpenFileVM[];
  selectedFileKey?: string | null;
  onSelectFile?: (key: string) => void;
  onCloseOpenFile?: (key: string) => void;
}

export function ControlScreen(props: ControlScreenProps) {
  const layout = usePanelLayout(!props.inspectorOpen);
  const selected = props.agents.find((a) => a.key === props.selectedAgentKey) ?? null;
  const waitingAgents = props.agents.filter((a) => a.status === "waiting" && a.approval);
  const filesMode = props.mode === "files";
  // Which main area: the open file (Files rail, or the legacy no-mode behavior) or the
  // selected agent's terminal.
  const file = filesMode || props.mode === undefined ? props.openFile : null;
  const agent = filesMode ? null : selected;
  const filesSection = (
    <FilesSection
      open={layout.filesOpen}
      onToggle={layout.toggleFiles}
      count={props.filesCount ?? 0}
      height={layout.filesH}
      onHeightChange={layout.setFilesH}
      onHeightReset={() => layout.setFilesH(null)}
    >
      {props.filesSlot}
    </FilesSection>
  );
  const listResize = (label: string) => (
    <ResizeHandle
      side="right"
      label={label}
      min={AGENTS_W.min}
      max={AGENTS_W.max}
      onResize={layout.setAgentsW}
      onReset={() => layout.setAgentsW(null)}
    />
  );

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
          agentsOpen={layout.agentsOpen}
          onToggleAgents={layout.toggleAgents}
          inspectorOpen={layout.inspectorOpen}
          onToggleInspector={layout.toggleInspector}
        />
      }
      rail={<Rail active={props.railActive} onNavigate={props.onRailNavigate} />}
      footer={<Footer {...props.footer} />}
    >
      {layout.agentsOpen && filesMode && (
        <OpenFilesList
          files={props.openFiles ?? []}
          selectedKey={props.selectedFileKey ?? null}
          onSelect={(key) => props.onSelectFile?.(key)}
          onClose={(key) => props.onCloseOpenFile?.(key)}
          width={layout.agentsW ?? undefined}
          resizeHandle={listResize("Resize files panel")}
          filesFill={layout.filesOpen && layout.filesH === null}
          filesSection={filesSection}
        />
      )}
      {layout.agentsOpen && !filesMode && (
      <AgentList
        width={layout.agentsW ?? undefined}
        resizeHandle={listResize("Resize agents panel")}
        filesFill={layout.filesOpen && layout.filesH === null}
        onRenameAgent={props.onRenameAgent}
        onAgentContextMenu={props.onAgentContextMenu}
        pinnedKeys={props.pinnedAgentKeys}
        filesSection={filesSection}
        agents={props.agents}
        selectedKey={props.selectedAgentKey}
        filter={props.agentFilter}
        onFilterChange={props.onAgentFilterChange}
        onSelectAgent={props.onSelectAgent}
        onNewAgent={props.onNewAgent}
        onReorder={props.onReorderAgents}
      />
      )}

      <main style={{ flexGrow: 1, minWidth: 0, display: "flex", flexDirection: "column", background: "var(--bg-app)", minHeight: 0 }}>
        {file ? (
          <FileHeader file={file} onClose={props.onCloseFile} />
        ) : agent ? (
          <SessionHeader agent={agent} onRename={props.onRenameAgent ? (name) => props.onRenameAgent!(agent.key, name) : undefined} onCompact={props.onCompact} onSplitToGrid={props.onSplitToGrid} onStop={props.onStop} onMore={props.onMoreActions} />
        ) : null}

        {/* The real xterm instance is adopted into this slot by the orchestrator — it
            owns no styling here beyond filling the region edge-to-edge with the
            terminal background; the xterm host itself carries the 20px/28px padding. */}
        {file ? (
          <div style={{ flexGrow: 1, minHeight: 0, minWidth: 0, overflow: "hidden", display: "flex", flexDirection: "column", background: "var(--bg-app)" }}>
            {props.fileSlot}
          </div>
        ) : filesMode ? (
          <div style={{ flexGrow: 1, minHeight: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 8, color: "var(--text-muted)", fontSize: 13, background: "var(--bg-app)" }}>
            <span style={{ fontSize: 15, fontWeight: 600, color: "var(--text)" }}>No file open</span>
            <span>Pick a file in the tree on the left, or search with ⌘K.</span>
            <span>Images and PDFs open here too.</span>
          </div>
        ) : agent ? (
          <div
            data-terminal-slot={agent.key}
            data-diff-mask
            style={{ flexGrow: 1, minHeight: 0, overflow: "hidden", background: "var(--bg-terminal)" }}
          />
        ) : (
          // No agent at all (first launch, or every tab closed): say what to do instead
          // of leaving a blank pane that reads as broken.
          <div style={{ flexGrow: 1, minHeight: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 10, color: "var(--text-muted)", fontSize: 13, background: "var(--bg-terminal)" }}>
            <span style={{ fontSize: 15, fontWeight: 600, color: "var(--text)" }}>No agents yet</span>
            <span>Open a terminal or start an agent to begin.</span>
            <div style={{ display: "flex", gap: 8, marginTop: 4 }}>
              {props.onNewTerminal && (
                <button type="button" onClick={props.onNewTerminal} className="rd-btn2" style={{ height: 32, padding: "0 12px", borderRadius: 7, border: "1px solid var(--border-control)", background: "var(--bg-control)", color: "var(--text)", fontSize: 13 }}>
                  New terminal <span style={{ fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--text-muted)" }}>⌘T</span>
                </button>
              )}
              <button type="button" onClick={props.onNewAgent} style={{ height: 32, padding: "0 12px", borderRadius: 7, border: "none", background: "var(--primary-bg)", color: "var(--primary-fg)", fontSize: 13, fontWeight: 600 }}>
                + New agent
              </button>
            </div>
          </div>
        )}

        {agent && !file && (
          // Turn progress belongs to the chat box: with it closed the strip only echoed
          // Claude's own spinner, and showing/hiding it each turn resized the terminal.
          <ProgressStrip
            {...(props.composerOpen !== false ? agent.progress : undefined)}
            updateReady={props.updateReady}
            onRestart={props.onRestartForUpdate}
          />
        )}

        {agent && !file && props.composerOpen !== false && (
          <Composer
            agentName={agent.name}
            target={agent.agentRunning ? "agent" : "shell"}
            value={props.composerValue}
            onChange={props.onComposerChange}
            onSend={props.onSendMessage}
            mode={agent.mode as PermissionMode}
            onCycleMode={props.onCycleMode}
            onModeMenu={props.onModeMenu}
            onAttachFile={props.onAttachFile}
            onCommands={props.onOpenCommands}
            slashAgent={agent.kind === "opencode" ? "opencode" : "claude"}
            slashCwd={agent.cwd}
          />
        )}
      </main>

      {layout.inspectorOpen && (
        <Inspector
          width={layout.inspectorW ?? undefined}
          resizeHandle={
            <ResizeHandle
              side="left"
              label="Resize inspector"
              min={INSPECTOR_W.min}
              max={INSPECTOR_W.max}
              onResize={layout.setInspectorW}
              onReset={() => layout.setInspectorW(null)}
            />
          }
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
          activitySlot={props.activitySlot}
        />
      )}
    </AppFrame>
  );
}

// Created by Claude — Classification: INTERNAL
//
// Full-window harness for the visual pixel-diff check (PROMPT.md §7) and manual
// QA. Owns just enough local state to make the screens interactive; this is
// test scaffolding, not part of the app — App.tsx never imports it.

import { useState } from "react";
import { ControlScreen } from "./ControlScreen";
import { GridScreen } from "./GridScreen";
import type { InspectorTab } from "./Inspector";
import type { AgentFilter } from "./AgentList";
import { previewAgents, previewFooter, previewHeader, previewInspector, previewLongNameAgent } from "./previewFixture";
import type { FileVM, GridLayout, RailItem, ThemePreference } from "./types";

export interface PreviewProps {
  screen: "control" | "grid";
  theme: ThemePreference;
  /** Swaps muya-all for a long-name/path fixture — the nowrap/ellipsis stress check. */
  stress?: boolean;
}

export function Preview({ screen, theme: initialTheme, stress = false }: PreviewProps) {
  const [themePreference, setThemePreference] = useState<ThemePreference>(initialTheme);
  const [railActive, setRailActive] = useState<RailItem>("control");
  const [selectedAgentKey, setSelectedAgentKey] = useState<string>(stress ? previewLongNameAgent.key : "muya-all");
  const [agentFilter, setAgentFilter] = useState<AgentFilter>("all");
  const [agents, setAgents] = useState(stress ? [previewLongNameAgent, ...previewAgents.slice(1)] : previewAgents);
  const [openFile, setOpenFile] = useState<FileVM | null>(null);
  const [composerValue, setComposerValue] = useState("");
  const [inspectorTab, setInspectorTab] = useState<InspectorTab>("changes");
  const [layout, setLayout] = useState<GridLayout>("2x2");
  const [focusedKey, setFocusedKey] = useState<string | null>("documents-44");
  const [gridComposerValues, setGridComposerValues] = useState<Record<string, string>>({});

  function reorder(fromKey: string, toKey: string) {
    setAgents((prev) => {
      const list = [...prev];
      const fromIdx = list.findIndex((a) => a.key === fromKey);
      const toIdx = list.findIndex((a) => a.key === toKey);
      if (fromIdx < 0 || toIdx < 0) return prev;
      const [moved] = list.splice(fromIdx, 1);
      list.splice(toIdx, 0, moved);
      return list;
    });
  }

  const themeCycle = () => setThemePreference((p) => (p === "system" ? "light" : p === "light" ? "dark" : "system"));

  if (screen === "grid") {
    const panels = layout === "1" ? agents.slice(1, 2) : layout === "1x2" ? agents.slice(0, 2) : layout === "3x2" ? agents.slice(0, 6) : agents.slice(0, 4);
    return (
      <GridScreen
        railActive={railActive}
        onRailNavigate={setRailActive}
        footer={{ ...previewFooter, variant: "grid" }}
        panels={panels}
        layout={layout}
        onLayoutChange={setLayout}
        onWaitingFirst={() => setAgents((prev) => [...prev].sort((a, b) => (a.status === "waiting" ? -1 : 0) - (b.status === "waiting" ? -1 : 0)))}
        onBroadcastOpen={() => {}}
        focusedKey={focusedKey}
        onFocusPanel={setFocusedKey}
        onMaximizePanel={() => {}}
        onApprove={() => {}}
        onDeny={() => {}}
        onAlwaysAllow={() => {}}
        composerValues={gridComposerValues}
        onComposerChange={(key, value) => setGridComposerValues((prev) => ({ ...prev, [key]: value }))}
        onSendMessage={() => {}}
        onAssignFromQueue={() => {}}
        onReplacePanel={() => {}}
      />
    );
  }

  return (
    <>
      <ControlScreen
        header={previewHeader}
        footer={previewFooter}
        themePreference={themePreference}
        onThemeCycle={themeCycle}
        onNotificationsClick={() => {}}
        onWorkspaceClick={() => {}}
        onOpenPalette={() => {}}
        railActive={railActive}
        onRailNavigate={setRailActive}
        agents={agents}
        selectedAgentKey={selectedAgentKey}
        agentFilter={agentFilter}
        onAgentFilterChange={setAgentFilter}
        onSelectAgent={setSelectedAgentKey}
        onNewAgent={() => {}}
        onReorderAgents={reorder}
        openFile={openFile}
        onCloseFile={() => setOpenFile(null)}
        onCompact={() => {}}
        onSplitToGrid={() => {}}
        onStop={() => {}}
        onMoreActions={() => {}}
        composerValue={composerValue}
        onComposerChange={setComposerValue}
        onSendMessage={() => setComposerValue("")}
        onCycleMode={() => {}}
        onAttachFile={() => {}}
        onOpenCommands={() => {}}
        updateReady
        onRestartForUpdate={() => {}}
        inspector={previewInspector}
        inspectorTab={inspectorTab}
        onInspectorTabChange={setInspectorTab}
        onApprove={() => {}}
        onDeny={() => {}}
        onOpenApproval={() => {}}
        onReviewDiff={() => {}}
        onCommit={() => {}}
        inspectorOpen
      />
    </>
  );
}

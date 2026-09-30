// Created by Claude — Classification: INTERNAL
//
// Grid screen (PROMPT.md §4): AppFrame + Rail (with Settings — the grid
// reference had dropped it, operator note) + Footer + GridHeader + a CSS grid
// of GridPanels. Tab moves panel focus, ⌘Enter maximizes the focused panel;
// Y/N approve/deny are handled per-panel (GridPanel.tsx) once it has focus.

import { useEffect, useRef } from "react";
import { GridHeader } from "./GridHeader";
import { EmptyGridPanel, GridPanel } from "./GridPanel";
import { AppFrame } from "./AppFrame";
import { Rail } from "./Rail";
import { Footer } from "./Footer";
import type { AgentVM, FooterVM, GridLayout, RailItem } from "./types";

export interface GridScreenProps {
  railActive: RailItem;
  onRailNavigate: (item: RailItem) => void;
  footer: FooterVM;

  panels: AgentVM[];
  layout: GridLayout;
  onLayoutChange: (layout: GridLayout) => void;
  onWaitingFirst: () => void;
  onBroadcastOpen: () => void;

  focusedKey: string | null;
  onFocusPanel: (key: string) => void;
  onMaximizePanel: (key: string) => void;

  onApprove: (key: string) => void;
  onDeny: (key: string) => void;
  onAlwaysAllow: (key: string) => void;

  composerValues: Record<string, string>;
  onComposerChange: (key: string, value: string) => void;
  onSendMessage: (key: string, text: string) => void;

  onAssignFromQueue: (key: string) => void;
  onReplacePanel: (key: string) => void;
}

const GRID_TEMPLATE: Record<GridLayout, { columns: string; rows: string }> = {
  "1": { columns: "1fr", rows: "1fr" },
  "1x2": { columns: "repeat(2, minmax(0, 1fr))", rows: "1fr" },
  "2x2": { columns: "repeat(2, minmax(0, 1fr))", rows: "repeat(2, minmax(0, 1fr))" },
  "3x2": { columns: "repeat(3, minmax(0, 1fr))", rows: "repeat(2, minmax(0, 1fr))" },
};

/** How many cells each layout shows. */
export const LAYOUT_CAPACITY: Record<GridLayout, number> = { "1": 1, "1x2": 2, "2x2": 4, "3x2": 6 };

export function GridScreen(props: GridScreenProps) {
  const rootRef = useRef<HTMLDivElement>(null);
  const template = GRID_TEMPLATE[props.layout];

  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (e.key === "Tab") {
        const idx = props.panels.findIndex((p) => p.key === props.focusedKey);
        const next = props.panels[(idx + 1 + props.panels.length) % props.panels.length];
        if (next) {
          e.preventDefault();
          props.onFocusPanel(next.key);
        }
      } else if (e.key === "Enter" && e.metaKey) {
        if (props.focusedKey) {
          e.preventDefault();
          props.onMaximizePanel(props.focusedKey);
        }
      }
    }
    const node = rootRef.current;
    node?.addEventListener("keydown", onKeyDown);
    return () => node?.removeEventListener("keydown", onKeyDown);
  }, [props]);

  return (
    <div ref={rootRef} style={{ width: "100%", height: "100%" }}>
      <AppFrame
        header={
          <GridHeader
            panelCount={props.panels.length}
            layout={props.layout}
            onLayoutChange={props.onLayoutChange}
            onWaitingFirst={props.onWaitingFirst}
            onBroadcast={props.onBroadcastOpen}
          />
        }
        rail={<Rail active={props.railActive} onNavigate={props.onRailNavigate} />}
        footer={<Footer {...props.footer} variant="grid" />}
      >
        <div
          style={{
            flexGrow: 1,
            minWidth: 0,
            padding: 16,
            display: "grid",
            gridTemplateColumns: template.columns,
            gridTemplateRows: template.rows,
            gap: 12,
          }}
        >
          {props.panels.map((agent) => (
            <GridPanel
              key={agent.key}
              agent={agent}
              focused={agent.key === props.focusedKey}
              onFocus={() => props.onFocusPanel(agent.key)}
              onMaximize={() => props.onMaximizePanel(agent.key)}
              onApprove={() => props.onApprove(agent.key)}
              onDeny={() => props.onDeny(agent.key)}
              onAlwaysAllow={() => props.onAlwaysAllow(agent.key)}
              composerValue={props.composerValues[agent.key] ?? ""}
              onComposerChange={(value) => props.onComposerChange(agent.key, value)}
              onSendMessage={(text) => props.onSendMessage(agent.key, text)}
            />
          ))}
          {/* Cells the layout has room for but no agent fills. Their key is
              "empty:<n>"; picking an agent for one ADDS it to the grid. */}
          {Array.from({ length: Math.max(0, LAYOUT_CAPACITY[props.layout] - props.panels.length) }, (_, i) => {
            const key = `empty:${i}`;
            return (
              <EmptyGridPanel
                key={key}
                onAssignFromQueue={() => props.onAssignFromQueue(key)}
                onPickAgent={() => props.onReplacePanel(key)}
              />
            );
          })}
        </div>
      </AppFrame>
    </div>
  );
}

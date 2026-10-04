// Created by Claude — Classification: INTERNAL
//
// ⌘K palette (PROMPT.md §3) built on `cmdk`. Opening/closing (the ⌘K shortcut
// itself) is the orchestrator's job — this component just renders when `open`.

import { Command } from "cmdk";
import type { AgentVM } from "./types";

export interface PaletteFile {
  path: string;
}

/** A file Spotlight found elsewhere on the Mac ("On this Mac"). */
export interface PaletteMacFile {
  path: string;
  name: string;
  /** Parent folder, home-abbreviated, for display. */
  dir: string;
}

export interface PaletteCommand {
  id: string;
  label: string;
}

export interface CommandPaletteProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  agents: AgentVM[];
  files: PaletteFile[];
  commands: PaletteCommand[];
  onSelectAgent: (key: string) => void;
  onOpenFile: (path: string) => void;
  onRunCommand: (id: string) => void;
  /** Spotlight results for the current query (the orchestrator runs the search). */
  macFiles?: PaletteMacFile[];
  /** The typed query, so the orchestrator can search the Mac for it. */
  onQueryChange?: (query: string) => void;
}

export function CommandPalette({ open, onOpenChange, agents, files, commands, onSelectAgent, onOpenFile, onRunCommand, macFiles = [], onQueryChange }: CommandPaletteProps) {
  return (
    <Command.Dialog
      className="rd-palette"
      open={open}
      onOpenChange={onOpenChange}
      label="Command palette"
      style={{
        position: "fixed",
        top: "20%",
        left: "50%",
        transform: "translateX(-50%)",
        width: 560,
        maxHeight: "55vh",
        borderRadius: 12,
        border: "1px solid var(--border-strong)",
        background: "var(--bg-panel)",
        color: "var(--text)",
        boxShadow: "0 20px 60px rgba(0,0,0,0.4)",
        overflow: "hidden",
        zIndex: 200,
      }}
    >
      <Command.Input
        onValueChange={onQueryChange}
        placeholder="Search agents, files, commands — or files on this Mac…"
        style={{ width: "100%", height: 44, border: "none", borderBottom: "1px solid var(--border)", background: "var(--bg-input)", color: "var(--text)", padding: "0 14px", fontSize: 14, outline: "none", boxSizing: "border-box" }}
      />
      <Command.List style={{ maxHeight: "calc(55vh - 44px)", overflow: "auto", padding: 8 }}>
        <Command.Empty style={{ padding: "16px 12px", fontSize: 13, color: "var(--text-muted)" }}>No results</Command.Empty>

        {agents.length > 0 && (
        <Command.Group heading="Agents">
          {agents.map((agent) => (
            <Command.Item key={agent.key} value={agent.name} onSelect={() => onSelectAgent(agent.key)} style={{ padding: "8px 10px", borderRadius: 6, fontSize: 13, cursor: "pointer" }}>
              {agent.name} <span style={{ color: "var(--text-muted)", fontFamily: "var(--font-mono)", fontSize: 11 }}>{agent.path}</span>
            </Command.Item>
          ))}
        </Command.Group>
        )}

        {/* A group with nothing in it still printed its heading ("Files" over an empty
            list) — groups render only when they have items. */}
        {files.length > 0 && (
        <Command.Group heading="Files">
          {files.map((file) => (
            <Command.Item key={file.path} value={file.path} onSelect={() => onOpenFile(file.path)} style={{ padding: "8px 10px", borderRadius: 6, fontSize: 13, fontFamily: "var(--font-mono)", cursor: "pointer" }}>
              {file.path}
            </Command.Item>
          ))}
        </Command.Group>
        )}

        {/* Spotlight, by file name, like Finder's search box. Values are prefixed so a
            path that is also under Files can't collide with that item. */}
        {macFiles.length > 0 && (
        <Command.Group heading="On this Mac">
          {macFiles.map((file) => (
            <Command.Item key={file.path} value={`mac:${file.path}`} onSelect={() => onOpenFile(file.path)} style={{ padding: "8px 10px", borderRadius: 6, fontSize: 13, cursor: "pointer", display: "flex", gap: 8, alignItems: "baseline", minWidth: 0 }}>
              <span style={{ flexShrink: 0 }}>{file.name}</span>
              <span style={{ color: "var(--text-muted)", fontFamily: "var(--font-mono)", fontSize: 11, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{file.dir}</span>
            </Command.Item>
          ))}
        </Command.Group>
        )}

        <Command.Group heading="Commands">
          {commands.map((cmd) => (
            <Command.Item key={cmd.id} value={cmd.label} onSelect={() => onRunCommand(cmd.id)} style={{ padding: "8px 10px", borderRadius: 6, fontSize: 13, cursor: "pointer" }}>
              {cmd.label}
            </Command.Item>
          ))}
        </Command.Group>
      </Command.List>
    </Command.Dialog>
  );
}

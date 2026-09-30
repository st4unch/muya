// Created by Claude — Classification: INTERNAL
//
// Message box at the bottom of Control (PROMPT.md §3). Controlled textarea:
// Enter sends, Shift+Enter inserts a newline. The mode chip switches to the
// danger palette only in bypass mode (Shift+Tab cycles modes — exposed as a
// callback, the actual cycle order is the caller's call).

import { useRef, useState } from "react";
import type { KeyboardEvent, MouseEvent } from "react";
import type { PermissionMode } from "./types";
import { messageHint, shortName } from "./text";
import { SlashCommandsPopover } from "./SlashCommandsPopover";
import { useSlashCommands } from "./useSlashCommands";
import type { SlashAgent } from "./slashBuiltins";

export interface ComposerProps {
  /** "shell" when no agent CLI is running in the terminal (see AgentVM.agentRunning). */
  target?: "agent" | "shell";
  agentName: string;
  value: string;
  onChange: (value: string) => void;
  onSend: (text: string) => void;
  mode: PermissionMode;
  onCycleMode: () => void;
  /** When given, clicking the mode chip opens a picker instead of cycling once
   *  (Shift+Tab in the box still cycles). */
  onModeMenu?: (e: MouseEvent<HTMLElement>) => void;
  onAttachFile: () => void;
  onCommands: () => void;
  /** Agent CLI running in this terminal. When set, "/ Commands" opens the slash-command
   *  popover (built-ins + this machine's custom commands/skills) instead of `onCommands`. */
  slashAgent?: SlashAgent;
  /** Working directory of the terminal, for project-level custom commands. */
  slashCwd?: string;
}

/** Put `/name ` at the start of the message, replacing a half-typed leading `/word`. */
export function insertSlash(value: string, name: string): string {
  const rest = value.replace(/^\/\S*\s?/, "");
  return `/${name} ${rest}`;
}

const MODE_LABEL: Record<PermissionMode, string> = {
  default: "manual",
  acceptEdits: "accept edits",
  plan: "plan",
  auto: "auto",
  bypass: "bypass",
};

export function Composer({ agentName, value, onChange, onSend, mode, onCycleMode, onModeMenu, onAttachFile, onCommands, slashAgent, slashCwd, target = "agent" }: ComposerProps) {
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const [slashAnchor, setSlashAnchor] = useState<DOMRect | null>(null);
  const slash = useSlashCommands(slashAgent ?? "claude", slashCwd, slashAnchor !== null && slashAgent !== undefined);
  const closeSlash = () => {
    setSlashAnchor(null);
    textareaRef.current?.focus();
  };
  // A plain shell runs whatever is sent as a command (live: an English sentence went
  // to zsh and ran `write`). Say where the text goes, and drop the agent-only controls.
  const shell = target === "shell";
  function handleKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      const trimmed = value.trim();
      if (trimmed) onSend(trimmed);
      return;
    }
    if (e.key === "Tab" && e.shiftKey && !shell) {
      e.preventDefault();
      onCycleMode();
    }
  }

  const bypass = mode === "bypass";

  return (
    <div style={{ padding: "14px 20px 16px", borderTop: "1px solid var(--border)", background: "var(--bg-chrome)" }}>
      <div
        style={{
          border: "1px solid var(--border-strong)",
          borderRadius: 12,
          background: "var(--bg-input)",
          padding: "10px 12px",
          display: "flex",
          flexDirection: "column",
          gap: 10,
        }}
      >
        <label htmlFor="rd-composer" style={{ position: "absolute", width: 1, height: 1, overflow: "hidden", clip: "rect(0 0 0 0)" }}>
          {shell ? `Shell command for ${agentName}` : `Message ${agentName}`}
        </label>
        <textarea
          id="rd-composer"
          ref={textareaRef}
          rows={2}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={shell ? `Run a shell command in ${shortName(agentName)}…` : `${messageHint(agentName)} ( / commands, @ files )`}
          style={{
            resize: "none",
            border: "none",
            background: "transparent",
            color: "var(--text)",
            fontFamily: "var(--font-sans)",
            fontSize: 14,
            outline: "none",
            whiteSpace: "pre-wrap",
          }}
        />
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          {!shell && (
          <button
            type="button"
            onClick={(e) => (onModeMenu ? onModeMenu(e) : onCycleMode())}
            className="rd-chip"
            style={{
              height: 26,
              padding: "0 10px",
              borderRadius: 13,
              border: `1px solid ${bypass ? "var(--danger-border)" : "var(--border-control)"}`,
              background: bypass ? "var(--danger-btn-bg)" : "transparent",
              color: bypass ? "var(--danger-text)" : "var(--text-tertiary)",
              fontSize: 12,
              flexShrink: 0,
            }}
          >
            Mode: {MODE_LABEL[mode]} ▾
          </button>
          )}
          <button
            type="button"
            onClick={onAttachFile}
            className="rd-chip"
            style={{ height: 26, padding: "0 10px", borderRadius: 13, border: "1px solid var(--border-control)", background: "transparent", color: "var(--text-tertiary)", fontSize: 12, flexShrink: 0 }}
          >
            {shell ? "Add path" : "@ Add file"}
          </button>
          {!shell && (
          <button
            type="button"
            onClick={(e) => (slashAgent ? setSlashAnchor(e.currentTarget.getBoundingClientRect()) : onCommands())}
            aria-haspopup={slashAgent ? "dialog" : undefined}
            aria-expanded={slashAgent ? slashAnchor !== null : undefined}
            className="rd-chip"
            style={{ height: 26, padding: "0 10px", borderRadius: 13, border: "1px solid var(--border-control)", background: "transparent", color: "var(--text-tertiary)", fontSize: 12, flexShrink: 0 }}
          >
            / Commands
          </button>
          )}
          <div style={{ flexGrow: 1 }} />
          <span style={{ fontSize: 12, color: "var(--text-muted)", flexShrink: 0 }}>{shell ? "⏎ run · ⇧⏎ newline" : "⏎ send · ⇧⏎ newline"}</span>
          <button
            type="button"
            aria-label="Send"
            onClick={() => {
              const trimmed = value.trim();
              if (trimmed) onSend(trimmed);
            }}
            className="rd-icon-btn"
            style={{ width: 32, height: 32, borderRadius: 8, border: "none", background: "var(--primary-bg)", color: "var(--primary-fg)", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2.2} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <path d="M12 19V5M5 12l7-7 7 7" />
            </svg>
          </button>
        </div>
      </div>
      {slashAnchor && slashAgent && (
        <SlashCommandsPopover
          anchor={slashAnchor}
          items={slash.items}
          loading={slash.loading}
          onPick={(name) => {
            onChange(insertSlash(value, name));
            closeSlash();
          }}
          onClose={closeSlash}
        />
      )}
    </div>
  );
}

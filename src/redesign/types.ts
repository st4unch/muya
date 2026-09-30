// Created by Claude — Classification: INTERNAL
//
// The view model the redesigned screens render from. Screens are presentational:
// they receive these objects and report user intent through callbacks — they never
// call Tauri themselves. App.tsx builds the model from real state (tabs, session
// status, the terminal screen parser) so every screen, the footer and the command
// palette read the SAME numbers.

export type AgentStatus = "waiting" | "working" | "idle";

/** Claude Code's permission mode, as shown in its footer. Measured on Claude Code
 *  2.1.285 (src/lib/__fixtures__/claude-screens): "default" is what Claude now labels
 *  "manual"; Shift+Tab cycles default → acceptEdits → plan → auto → default; bypass is
 *  only reachable by launching with --dangerously-skip-permissions. */
export type PermissionMode = "default" | "acceptEdits" | "plan" | "auto" | "bypass";

export interface PendingApproval {
  /** Tool the agent wants to run, e.g. "Write", "Bash", "fs_write_file". */
  tool?: string;
  /** What it wants to touch: a path or a command. */
  target?: string;
  /** Fallback text when the dialog couldn't be read, e.g. "permission prompt". */
  summary: string;
  /** false = the dialog's options could not be parsed, so Allow/Deny are disabled. */
  actionable?: boolean;
}

export interface AgentVM {
  /** Stable tab key — the identity used for selection, ordering and callbacks. */
  key: string;
  name: string;
  status: AgentStatus;
  /** Human duration for the status, already formatted ("1 dk", "4m 15s"). */
  since?: string;
  /** Second line of a waiting/working card ("Unfurling… · 16.9k token"). */
  activity?: string;
  /** Display path (home abbreviated to ~). */
  path: string;
  branch?: string;
  mode: PermissionMode;
  approval?: PendingApproval;
  /** Progress strip details, when the terminal shows them. */
  progress?: { verb?: string; elapsed?: string; tokens?: string; thought?: string };
  /** Which CLI runs in it: drives nothing visual today, kept for actions. */
  kind: "claude" | "opencode" | "shell" | "ssh";
  /** An agent CLI owns this terminal RIGHT NOW (vs a plain shell prompt). Drives what
   *  the composer and header offer: text typed into a shell runs as a command, and
   *  "/compact" or a permission-mode switch mean nothing there. */
  agentRunning: boolean;
}

export interface ChangeVM {
  /** Git porcelain letter: M, A, D, R, ?… */
  code: string;
  path: string;
}

export interface InspectorVM {
  changes: ChangeVM[];
  worktreesWatched: number;
  collisions: { file: string; worktrees: string[] }[];
}

export interface HeaderVM {
  workspaceName: string;
  workspaceCount: number;
  cpu: string;
  ram: string;
  clock: string;
  hasNotifications: boolean;
}

export interface FooterVM {
  workspaceCount: number;
  agents: number;
  working: number;
  waiting: number;
  collisions: number;
  version: string;
  /** Grid shows its keyboard hint instead of the encoding. */
  variant: "control" | "grid";
}

export type ThemePreference = "system" | "light" | "dark";

export type RailItem = "control" | "queue" | "kanban" | "resources" | "ssh" | "chat" | "settings";

export type GridLayout = "1" | "1x2" | "2x2" | "3x2";

/** A file open in the Control main area instead of the terminal (FileHeader). */
export interface FileVM {
  name: string;
  path: string;
}

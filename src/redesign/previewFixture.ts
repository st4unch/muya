// Created by Claude — Classification: INTERNAL
//
// Fixture reproducing the reference texts EXACTLY, translated to English per
// scripts/redesign/strings.mjs (the UI is English — see coordinator note).
// Used by Preview.tsx for the visual pixel-diff check and by the vitest suite.

import type { AgentVM, FooterVM, HeaderVM, InspectorVM } from "./types";

export const previewHeader: HeaderVM = {
  workspaceName: "claude-control-plane",
  workspaceCount: 3,
  cpu: "2%",
  ram: "111 MB",
  clock: "23:21",
  hasNotifications: true,
};

export const previewFooter: FooterVM = {
  workspaceCount: 3,
  agents: 7,
  working: 2,
  waiting: 1,
  collisions: 0,
  version: "0.3.0",
  variant: "control",
};

export const previewAgents: AgentVM[] = [
  {
    key: "documents-44",
    name: "documents-44",
    status: "waiting",
    since: "1m",
    activity: "Needs permission: fs_write_file",
    path: "~/Documents/claude-control-plane",
    mode: "default",
    approval: { tool: "fs_write_file", target: "docs/[dosya yolu]", summary: "wants to write a file" },
    kind: "claude",
  },
  {
    key: "muya-all",
    name: "muya-all",
    status: "working",
    since: "4m 15s",
    activity: "Unfurling… · 16.9k tokens",
    path: "~/Documents/claude-control-plane",
    branch: "main",
    mode: "bypass",
    progress: { verb: "Unfurling…", elapsed: "4m 15s", tokens: "16.9k tokens", thought: "3s" },
    kind: "claude",
  },
  {
    key: "opencode-review",
    name: "opencode-review",
    status: "working",
    since: "[duration]",
    activity: "[last activity line]",
    path: "~/Documents/claude-control-plane",
    mode: "default",
    kind: "opencode",
  },
  { key: "iptv-2a", name: "iptv-2a", status: "idle", path: "~/Documents/iptv", mode: "default", kind: "shell" },
  { key: "numbat-c3", name: "numbat-c3", status: "idle", path: "~/Documents/numbat", mode: "default", kind: "shell" },
  { key: "skills-envanter", name: "skills-envanter", status: "idle", path: "control-plane", mode: "default", kind: "shell" },
  { key: "serbest", name: "serbest", status: "idle", path: "~", mode: "default", kind: "shell" },
];

export const previewInspector: InspectorVM = {
  changes: [
    { code: "M", path: "src-tauri/src/pty.rs" },
    { code: "M", path: "src-tauri/src/agents.rs" },
    { code: "M", path: "tasks/todo.md" },
    ...Array.from({ length: 11 }, (_, i) => ({ code: "M", path: `docs/prd-verify/file-${i + 1}.md` })),
  ],
  worktreesWatched: 3,
  collisions: [],
};

/** A long name/path pair for the wrap/ellipsis stress check (operator note). */
export const previewLongNameAgent: AgentVM = {
  key: "very-long-agent-name-for-overflow-check",
  name: "a-very-long-agent-name-that-should-truncate-with-an-ellipsis-not-wrap",
  status: "working",
  since: "12h 41m",
  activity: "A long activity line that must also truncate instead of wrapping onto a second line",
  path: "~/Documents/some/very/deeply/nested/workspace/path/that/is/quite/long/indeed",
  branch: "feat/a-rather-long-branch-name-for-testing",
  mode: "bypass",
  progress: { verb: "Unfurling…", elapsed: "12h 41m", tokens: "184.2k tokens", thought: "41s" },
  kind: "claude",
};

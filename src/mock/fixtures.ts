// Representative dataset for the browser-only mock backend (see installMock.ts).
//
// Values here are picked to match the v0.4 redesign references exactly —
// docs/design/redesign-v0.4/control.reference.html and grid.reference.html — so a
// Playwright screenshot of `?mock=1` can be pixel-compared against them. Visible
// copy is ENGLISH (the references were drawn with Turkish placeholder copy; the
// English source of truth is scripts/redesign/strings.mjs). Paths use "~" rather
// than a real machine path: nothing in mock mode touches the filesystem, and a
// literal `/Users/<someone>` here would make this fixture non-portable (and this
// file DOES ship in the repo, even though it never runs outside `?mock=1`).
//
// Kept as plain typed data (not wired into any component) so both installMock.ts
// and any test that wants the same dataset can import it directly.

/** Mirrors the Rust `AgentSession` struct (src-tauri/src/agents.rs), camelCase via
 *  serde. The frontend's own `AgentSession` interface (src/App.tsx) only declares a
 *  subset of these fields — the extra ones (parentId, waitingFor, agent) are still
 *  sent by the real backend and are harmless for a consumer that ignores them. */
export interface MockAgentSession {
  id: string;
  name: string;
  branch: string;
  worktree: string;
  status: "working" | "waiting-for-input" | "idle" | "stopped";
  activeTask: string;
  activeFile: string;
  tokensUsed: number;
  modelsUsed: string;
  quotaBurn: number;
  duration: string;
  createdAt: string;
  attachable: boolean;
  attachId: string;
  pid: number | null;
  parentId: string | null;
  waitingFor: string | null;
  agent: string;
}

const CCP = "~/Documents/claude-control-plane";
const IPTV = "~/Documents/iptv";
const NUMBAT = "~/Documents/numbat";
const CONTROL_PLANE_SHORT = "control-plane";
const HOME = "~";

// Frozen "now" (see installMock.ts freezeClock) — 2026-09-30T23:21:00 local.
const NOW_ISO = "2026-09-30T23:21:00";

/** `muya-all` is listed FIRST: App.tsx's `list_agent_sessions` poll falls back to
 *  `live[0].id` whenever the previously-selected agent id isn't in the new list
 *  (true on first load, since it starts from a hardcoded placeholder id) — so the
 *  first entry here is the one the Control view opens by default, matching the
 *  reference (muya-all is the active/highlighted card + open conversation). */
export const MOCK_AGENTS: MockAgentSession[] = [
  {
    id: "muya-all",
    name: "muya-all",
    branch: "main",
    worktree: CCP,
    status: "working",
    activeTask: "Unfurling… · 16.9k tokens",
    activeFile: "",
    tokensUsed: 16900,
    modelsUsed: "claude-sonnet-4.5",
    quotaBurn: 0,
    duration: "4m 15s",
    createdAt: "2026-09-30T23:16:45",
    attachable: true,
    attachId: "muya-all",
    pid: 51234,
    parentId: null,
    waitingFor: null,
    agent: "claude",
  },
  {
    id: "documents-44",
    name: "documents-44",
    branch: "main",
    worktree: CCP,
    status: "waiting-for-input",
    activeTask: "Needs permission: fs_write_file",
    activeFile: "docs/[file path]",
    tokensUsed: 4200,
    modelsUsed: "claude-sonnet-4.5",
    quotaBurn: 0,
    duration: "1m",
    createdAt: "2026-09-30T23:20:00",
    attachable: true,
    attachId: "documents-44",
    pid: 51235,
    parentId: null,
    waitingFor: "permission prompt",
    agent: "claude",
  },
  {
    id: "opencode-review",
    name: "opencode-review",
    branch: "main",
    worktree: CCP,
    status: "working",
    activeTask: "[last activity line]",
    activeFile: "",
    tokensUsed: 0,
    modelsUsed: "",
    quotaBurn: 0,
    duration: "[duration]",
    createdAt: "2026-09-30T23:15:00",
    attachable: true,
    attachId: "opencode-review",
    pid: 51236,
    parentId: null,
    waitingFor: null,
    agent: "opencode",
  },
  {
    id: "iptv-2a",
    name: "iptv-2a",
    branch: "main",
    worktree: IPTV,
    status: "idle",
    activeTask: "",
    activeFile: "",
    tokensUsed: 0,
    modelsUsed: "",
    quotaBurn: 0,
    duration: "",
    createdAt: NOW_ISO,
    attachable: false,
    attachId: "iptv-2a",
    pid: null,
    parentId: null,
    waitingFor: null,
    agent: "claude",
  },
  {
    id: "numbat-c3",
    name: "numbat-c3",
    branch: "main",
    worktree: NUMBAT,
    status: "idle",
    activeTask: "",
    activeFile: "",
    tokensUsed: 0,
    modelsUsed: "",
    quotaBurn: 0,
    duration: "",
    createdAt: NOW_ISO,
    attachable: false,
    attachId: "numbat-c3",
    pid: null,
    parentId: null,
    waitingFor: null,
    agent: "claude",
  },
  {
    id: "skills-envanter",
    name: "skills-envanter",
    branch: "main",
    worktree: CONTROL_PLANE_SHORT,
    status: "idle",
    activeTask: "",
    activeFile: "",
    tokensUsed: 0,
    modelsUsed: "",
    quotaBurn: 0,
    duration: "",
    createdAt: NOW_ISO,
    attachable: false,
    attachId: "skills-envanter",
    pid: null,
    parentId: null,
    waitingFor: null,
    agent: "claude",
  },
  {
    id: "serbest",
    name: "serbest",
    branch: "main",
    worktree: HOME,
    status: "idle",
    activeTask: "",
    activeFile: "",
    tokensUsed: 0,
    modelsUsed: "",
    quotaBurn: 0,
    duration: "",
    createdAt: NOW_ISO,
    attachable: false,
    attachId: "serbest",
    pid: null,
    parentId: null,
    waitingFor: null,
    agent: "claude",
  },
];

/** The 3 tracked workspace roots (`apex.workspaces`). First one's basename is
 *  "claude-control-plane" — the workspace name shown in the header dropdown
 *  ("claude-control-plane · 3"). `apex.worktrees` is seeded empty so the tracked-
 *  path count (workspaces ∪ worktrees) stays at 3, matching "3 worktrees watched"
 *  in the reference footer/inspector without double-counting. */
export const MOCK_WORKSPACES = [CCP, IPTV, NUMBAT];

/** git_status(root) — Vec<(String,String)> tuples serialize as 2-element arrays:
 *  [repo-relative path, status char] (src-tauri/src/fs.rs). First 3 are pinned by the
 *  reference design; the rest just need to exist so "+ 11 more files" (14 - 3) has
 *  something to count. */
export const MOCK_GIT_STATUS: [string, string][] = [
  ["src-tauri/src/pty.rs", "M"],
  ["src-tauri/src/agents.rs", "M"],
  ["tasks/todo.md", "M"],
  ["src/App.tsx", "M"],
  ["src/components/Terminal.tsx", "M"],
  ["src/components/FileTree.tsx", "M"],
  ["docs/prd-redesign-v0.4.md", "A"],
  ["src-tauri/src/fs.rs", "M"],
  ["src-tauri/src/ssh.rs", "M"],
  ["docs/handoff-2026-09-30.md", "?"],
  ["package.json", "M"],
  ["src/lib/tabs.ts", "M"],
  ["src-tauri/Cargo.lock", "M"],
  ["README.md", "M"],
];

/** pm_status(paths) — one ProjectStatus per tracked workspace root. */
export const MOCK_PROJECT_STATUS: Record<string, {
  path: string;
  name: string;
  isGit: boolean;
  branch: string;
  base: string;
  ahead: number;
  behind: number;
  dirty: number;
  changed: number;
  lastActivity: number;
}> = {
  [CCP]: {
    path: CCP,
    name: "claude-control-plane",
    isGit: true,
    branch: "main",
    base: "main",
    ahead: 0,
    behind: 0,
    dirty: MOCK_GIT_STATUS.length,
    changed: 0,
    lastActivity: Math.floor(Date.parse(NOW_ISO) / 1000) - 300,
  },
  [IPTV]: {
    path: IPTV,
    name: "iptv",
    isGit: true,
    branch: "main",
    base: "main",
    ahead: 0,
    behind: 0,
    dirty: 0,
    changed: 0,
    lastActivity: Math.floor(Date.parse(NOW_ISO) / 1000) - 86400,
  },
  [NUMBAT]: {
    path: NUMBAT,
    name: "numbat",
    isGit: true,
    branch: "main",
    base: "main",
    ahead: 0,
    behind: 0,
    dirty: 0,
    changed: 0,
    lastActivity: Math.floor(Date.parse(NOW_ISO) / 1000) - 172800,
  },
};

/** pm_collisions(paths) — CollisionReport: 0 collisions, 14 edited files total
 *  (matches "No file conflicts" / "3 worktrees watched · 14 changes"). */
export const MOCK_COLLISION_REPORT = {
  collisions: [] as { file: string; worktrees: string[] }[],
  editedFiles: MOCK_GIT_STATUS.length,
};

/** list_branches(repo) — just enough for the Queue page not to be empty. */
export const MOCK_BRANCHES = [
  {
    name: "main",
    type: "PRD",
    lastCommit: "chore(redesign): add v0.4 reference designs, plan and dependencies",
    author: "staunch",
    status: "synced",
    parent: null as string | null,
  },
];

/** app_metrics — AppMetrics { cpu, memMb }. */
export const MOCK_APP_METRICS = { cpu: 2, memMb: 111 };

export const MOCK_APP_VERSION = "0.3.0";

/** plugin:updater|check response (Update metadata) — an update IS available. */
export const MOCK_UPDATE_METADATA = {
  rid: 1,
  currentVersion: MOCK_APP_VERSION,
  version: "0.4.0",
  date: "2026-09-30 12:00:00",
  body: "Redesigned Control and Grid views.",
  rawJson: {},
};

/** Deterministic terminal output fed into every spawned PTY's Channel — this is
 *  raw terminal text (not UI chrome), so it stays as-is rather than following the
 *  English-copy requirement that applies to on-screen UI strings. */
export const MOCK_TERMINAL_LINES = [
  "$ claude",
  "Welcome back — resuming session.",
  "> Reading project files…",
  "> 3 files changed since last run.",
  "Ready.",
];

/** The 7 terminal tabs the mock app restores, in the reference's list order. `cwd`
 *  values are the reference's display paths (mock mode never touches the filesystem). */
export const MOCK_TABS: { key: string; cwd: string; agent?: "claude" | "opencode"; session?: "working" | "waiting-for-input" }[] = [
  { key: "documents-44", cwd: CCP, session: "waiting-for-input" },
  { key: "muya-all", cwd: CCP, session: "working" },
  { key: "opencode-review", cwd: CCP, agent: "opencode", session: "working" },
  { key: "iptv-2a", cwd: IPTV },
  { key: "numbat-c3", cwd: NUMBAT },
  { key: "skills-envanter", cwd: CONTROL_PLANE_SHORT },
  { key: "serbest", cwd: HOME },
];

const RULE = "─".repeat(60);
const DASH = "╌".repeat(60);

/** What each mock terminal prints. These are the REAL Claude Code 2.1.285 screen
 *  shapes (see src/lib/__fixtures__/claude-screens) so the screen parser has something
 *  to read: a permission dialog, a spinner line with metrics, a mode footer. */
export const MOCK_SCREENS: Record<string, string[]> = {
  "documents-44": [
    "❯ write the design notes",
    "⏺ fs_write_file(docs/[file path])",
    RULE,
    " fs_write_file",
    " docs/[file path]",
    DASH,
    "  1 # Design notes",
    DASH,
    " Do you want to write docs/[file path]?",
    " ❯ 1. Yes",
    "   2. Yes, and don't ask again for this session",
    "   3. No",
    " Esc to cancel · Tab to amend",
  ],
  "muya-all": [
    "❯ refactor the agent list",
    "⏺ Reading src/App.tsx",
    "",
    "✻ Unfurling… (4m 15s · ↓ 16.9k tokens · thought for 3s)",
    "",
    RULE,
    "❯ ",
    RULE,
    "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents",
  ],
  "opencode-review": ["opencode", "reviewing the diff…"],
};

import React, { useState, useEffect, useRef } from "react";
import appIconUrl from "./assets/app-icon.png";
import {
  Folder,
  FileCode,
  Terminal,
  Layers,
  Sparkles,
  GitBranch,
  Settings,
  Cpu,
  Search,
  ChevronDown,
  ChevronRight,
  ChevronLeft,
  Database,
  Play,
  Pause,
  RefreshCw,
  X,
  Plus,
  GitCommit,
  GitPullRequest,
  CheckCircle2,
  AlertTriangle,
  TerminalSquare,
  Network,
  Users,
  HardDrive,
  Clock,
  ArrowRight,
  Info,
  ShieldCheck,
  Zap,
  Tag,
  Bookmark,
  Share2,
  Trash2,
  ExternalLink,
  Code2,
  PanelLeft,
  PanelRight,
  Sun,
  Moon,
  LayoutGrid
} from "lucide-react";
import BranchDAG from "./components/BranchDAG";
import AgentTerminal from "./components/Terminal";
import FileTree from "./components/FileTree";
import SessionsPage from "./components/SessionsPage";
import FileEditor from "./components/FileEditor";
import SessionMonitor from "./components/SessionMonitor";
import NewAgentModal, { type NewAgentSpec } from "./components/NewAgentModal";
import QueuePage from "./components/QueuePage";
import ResourcesPage from "./components/ResourcesPage";
import TerminalGrid from "./components/TerminalGrid";
import { buildAgentCommand } from "./lib/agent";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getVersion } from "@tauri-apps/api/app";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { open as openDialog, save as saveDialog } from "@tauri-apps/plugin-dialog";

// Types matching the user's workflow model
interface AgentSession {
  id: string;
  name: string;
  branch: string;
  worktree: string;
  status: "working" | "waiting-for-input" | "idle" | "stopped";
  activeTask: string;
  activeFile: string;
  tokensUsed: number;
  modelsUsed: string;
  quotaBurn: number; // in $
  duration: string;
  createdAt: string;
  attachable?: boolean; // background sessions can be `claude attach`ed
  attachId?: string; // id to pass to `claude attach`
  pid?: number; // OS pid (for killing interactive sessions)
}

// One open, persistent tab — a terminal or a file editor. Kept alive across switches.
interface OpenTerminal {
  key: string; // unique tab id (session id, "resume:<id>", or "edit:<path>")
  name: string;
  kind: "terminal" | "editor";
  cwd?: string;
  initialCommand?: string; // terminals: auto-run on spawn, e.g. `claude attach <id>`
  filePath?: string; // editors: absolute file path
}

interface GitBranchState {
  name: string;
  type: "PRD" | "WIP" | "OPEN";
  lastCommit: string;
  author: string;
  associatedAgent?: string;
  status: "synced" | "ahead" | "diverged" | "conflict";
  parent?: string; // real lineage: branch this forked from
}

interface FileItem {
  name: string;
  path: string;
  isDirectory: boolean;
  isModified?: boolean;
  hasConflict?: boolean;
  content?: string;
  lockedByAgentId?: string; // Tracks which agent is active on this file
}

/** Load a persisted string[] from localStorage (last-session memory). */
function loadList(key: string): string[] {
  try {
    const v = JSON.parse(localStorage.getItem(key) || "[]");
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

/** Restore open tabs. Editors re-open their file; terminals re-open as a fresh shell
 *  in their folder (initialCommand dropped so we never auto re-launch/attach). */
function loadTabs(): OpenTerminal[] {
  try {
    const v = JSON.parse(localStorage.getItem("apex.openTabs") || "[]");
    if (!Array.isArray(v)) return [];
    return (v as OpenTerminal[]).map((t) =>
      t.kind === "terminal" ? { ...t, initialCommand: undefined } : t
    );
  } catch {
    return [];
  }
}

export default function App() {
  // Navigation & UI Panels
  const [activeTab, setActiveTab] = useState<"terminal" | "supervisor" | "history">("terminal");
  const [selectedFile, setSelectedFile] = useState<string>("src/api/stripe.ts");
  const [isSidebarOpen, setIsSidebarOpen] = useState(true);

  // Simulated metrics
  const [cpuUsage, setCpuUsage] = useState(0); // app process CPU %
  const [ramUsage, setRamUsage] = useState(0); // app process RAM, MB
  const [localTime, setLocalTime] = useState("");

  // Claude Agent Sessions (kapanmamış background session list)
  const [agents, setAgents] = useState<AgentSession[]>([
    {
      id: "agent-jwt",
      name: "apex-auth-jwt",
      branch: "feature/auth-jwt",
      worktree: "~/apex-wt/auth-jwt",
      status: "waiting-for-input",
      activeTask: "Add RS256 token rollover in login handlers",
      activeFile: "src/api/auth.ts",
      tokensUsed: 142050,
      modelsUsed: "Claude 3.7 Sonnet",
      quotaBurn: 4.26,
      duration: "14m 20s",
      createdAt: "10:14:02 UTC"
    },
    {
      id: "agent-stripe",
      name: "apex-stripe-hooks",
      branch: "feature/stripe-webhooks",
      worktree: "~/apex-wt/stripe-webhooks",
      status: "working",
      activeTask: "Set up Stripe tax calculation router hooks",
      activeFile: "src/api/stripe.ts",
      tokensUsed: 89300,
      modelsUsed: "Claude 3.7 Sonnet",
      quotaBurn: 2.68,
      duration: "08m 12s",
      createdAt: "10:20:15 UTC"
    },
    {
      id: "agent-checkout",
      name: "apex-checkout-v2",
      branch: "feature/checkout-flow",
      worktree: "~/apex-wt/checkout-flow",
      status: "working",
      activeTask: "Review shopping cart calculation total layout",
      activeFile: "src/api/stripe.ts",
      tokensUsed: 65120,
      modelsUsed: "Claude 3.5 Sonnet",
      quotaBurn: 1.95,
      duration: "05m 40s",
      createdAt: "10:22:50 UTC"
    },
    {
      id: "agent-eslint",
      name: "apex-eslint-fix",
      branch: "fix/eslint-warnings",
      worktree: "~/apex-wt/eslint-warnings",
      status: "idle",
      activeTask: "Clean unused react dependencies & imports",
      activeFile: "src/main.tsx",
      tokensUsed: 231400,
      modelsUsed: "Claude 3.5 Haiku",
      quotaBurn: 1.15,
      duration: "21m 15s",
      createdAt: "09:55:00 UTC"
    }
  ]);

  // Selected Active Agent context
  const [selectedAgentId, setSelectedAgentId] = useState<string>("agent-stripe");

  // LIVE: replace mock sessions with real `claude agents --json` data from the Rust
  // backend (PRD AC-13). Polls every 3s (PRD §14). Falls back to mock on error so the
  // UI never goes blank if the `claude` CLI can't be found.
  useEffect(() => {
    let active = true;
    const load = () => {
      if (document.hidden) return; // don't poll while the window is in the background
      invoke<AgentSession[]>("list_agent_sessions")
        .then((live) => {
          if (!active || !live.length) return;
          setAgents(live);
          setSelectedAgentId((prev) =>
            live.some((a) => a.id === prev) ? prev : live[0].id
          );
        })
        .catch((e) => console.warn("[apex] list_agent_sessions failed:", e));
    };
    load();
    const t = setInterval(load, 3000);
    return () => {
      active = false;
      clearInterval(t);
    };
  }, []);

  // Open, persistent terminal tabs — one PTY per session, stays alive when you
  // switch tabs (hidden, not torn down).
  const [openTerminals, setOpenTerminals] = useState<OpenTerminal[]>(loadTabs);
  const [activeTerminalKey, setActiveTerminalKey] = useState<string | null>(
    () => loadTabs()[0]?.key ?? null
  );
  // Grid view mode — shows up to 4 terminals simultaneously
  const [viewMode, setViewMode] = useState<"tabs" | "grid">(
    () => (localStorage.getItem("apex.viewMode") as "tabs" | "grid") ?? "tabs"
  );
  const [gridKeys, setGridKeys] = useState<string[]>(() => {
    try { return JSON.parse(localStorage.getItem("apex.gridKeys") ?? "[]"); } catch { return []; }
  });

  // Open (or focus) a persistent terminal tab. Used by session cards and the
  // Sessions page (attach / resume).
  const openTerminal = (spec: OpenTerminal) => {
    setOpenTerminals((prev) =>
      prev.some((tm) => tm.key === spec.key) ? prev : [...prev, spec]
    );
    setActiveTerminalKey(spec.key);
  };

  const openTerminalForAgent = (a: AgentSession) => {
    const cwd = a.worktree && a.worktree.startsWith("/") ? a.worktree : undefined;
    if (cwd) ensureWorktreeTracked(cwd);
    const initialCommand =
      a.attachable && a.attachId ? `claude attach ${a.attachId}` : undefined;
    openTerminal({ key: a.id, name: a.name, kind: "terminal", cwd, initialCommand });
  };

  // Open a file from the tree in a Monaco editor tab.
  const openEditor = (filePath: string) => {
    openTerminal({
      key: `edit:${filePath}`,
      name: filePath.split("/").pop() || filePath,
      kind: "editor",
      filePath,
    });
  };

  const closeTerminal = (key: string) => {
    setOpenTerminals((prev) => {
      const next = prev.filter((tm) => tm.key !== key);
      setActiveTerminalKey((cur) =>
        cur === key ? next[next.length - 1]?.key ?? null : cur
      );
      return next;
    });
    setGridKeys((prev) => prev.filter((k) => k !== key));
  };

  // Top-level view switch: the IDE control plane vs the full Sessions page.
  const [view, setView] = useState<"control" | "sessions" | "queue" | "tools">("control");
  // Right panel tab: branch matrix vs live session monitor.
  const [rightTab, setRightTab] = useState<"branch" | "sessions">("sessions");
  // Branch picked for inspection — shown as a detail card on the Queue page.
  const [branchInspect, setBranchInspect] = useState<{ repo: string; name: string } | null>(null);
  // App-wide color theme. "system" follows the OS until the user explicitly toggles.
  // The resolved effectiveTheme drives the `.dark` class on <html>, the terminal, and
  // the Monaco editor — so one toggle themes the whole app together.
  const [themeMode, setThemeMode] = useState<"system" | "light" | "dark">(
    () => (localStorage.getItem("apex.theme") as "system" | "light" | "dark") || "system"
  );
  const [systemDark, setSystemDark] = useState(
    () => window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false
  );
  useEffect(() => {
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = (e: MediaQueryListEvent) => setSystemDark(e.matches);
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);
  const effectiveTheme: "dark" | "light" =
    themeMode === "system" ? (systemDark ? "dark" : "light") : themeMode;
  useEffect(() => {
    localStorage.setItem("apex.theme", themeMode);
  }, [themeMode]);
  useEffect(() => {
    document.documentElement.classList.toggle("dark", effectiveTheme === "dark");
    void getCurrentWindow().setTheme(effectiveTheme === "dark" ? "dark" : "light");
  }, [effectiveTheme]);
  // Collapsible side panels (toggle only, not resizable — focus mode).
  const [leftOpen, setLeftOpen] = useState(true);
  const [rightOpen, setRightOpen] = useState(true);
  // Worktrees created via New agent — tracked in the Queue alongside workspaces.
  const [worktrees, setWorktrees] = useState<string[]>(() => loadList("apex.worktrees"));
  // Bumped on a real filesystem change (notify) so views refresh immediately.
  const [fsTick, setFsTick] = useState(0);

  // Real app version from tauri.conf.json (stays in sync with the build).
  const [appVersion, setAppVersion] = useState("");
  useEffect(() => {
    getVersion().then(setAppVersion).catch(() => {});
  }, []);

  useEffect(() => {
    const un = listen("fs-changed", () => setFsTick((t) => t + 1));
    return () => {
      void un.then((f) => f());
    };
  }, []);


  const killAgent = async (a: AgentSession) => {
    try {
      await invoke("kill_session", {
        id: a.attachable && a.attachId ? a.attachId : null,
        pid: a.pid ?? null,
      });
    } catch (e) {
      console.warn("[apex] kill_session failed:", e);
    }
  };

  // Workspace roots — user-picked project folders shown in the file tree.
  // Persisted to localStorage so they reload on app restart (last-session memory).
  const [workspaces, setWorkspaces] = useState<string[]>(() => loadList("apex.workspaces"));

  // All paths the PM/watcher tracks: workspaces + created worktrees.
  const trackedPaths = [...new Set([...workspaces, ...worktrees])];

  // Adds a session's cwd to the worktree panel if not already tracked.
  const ensureWorktreeTracked = (cwd: string) => {
    if (!trackedPaths.includes(cwd)) {
      setWorktrees((prev) => [...new Set([...prev, cwd])]);
    }
  };

  // Watch tracked projects in real time (notify); refresh views on change.
  useEffect(() => {
    void invoke("start_watching", { paths: trackedPaths }).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspaces, worktrees]);

  // Persist tracked roots so they reload on app restart.
  useEffect(() => {
    localStorage.setItem("apex.workspaces", JSON.stringify(workspaces));
  }, [workspaces]);

  // Native File > New File (⌘N): the backend menu emits "menu:new-file". Pick a path
  // via the save dialog, create the (empty) file, and open it in an editor tab.
  // Subscribe ONCE (empty deps) and read the latest workspaces via a ref, so adding a
  // workspace doesn't tear down/recreate the listener (which briefly risks a double
  // save dialog on ⌘N during the async unlisten).
  const workspacesRef = useRef(workspaces);
  workspacesRef.current = workspaces;
  useEffect(() => {
    const un = listen("menu:new-file", async () => {
      const path = await saveDialog({
        title: "New File",
        defaultPath: workspacesRef.current[0],
      });
      if (typeof path !== "string") return;
      try {
        await invoke("create_file", { path });
        openEditor(path);
        setFsTick((t) => t + 1);
      } catch (e) {
        console.warn("[apex] create_file failed:", e);
      }
    });
    return () => {
      void un.then((f) => f());
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  // Native File > Close Tab (⌘W): the backend owns ⌘W (so it never closes the window)
  // and emits "menu:close-tab". Close the active tab; no-op when none is open (the app
  // then only quits via ⌘Q / the red close button). Subscribe once, read latest active
  // key via a ref — same pattern as ⌘N above.
  const activeKeyRef = useRef(activeTerminalKey);
  const tabScrollRef = useRef<HTMLDivElement>(null);
  const tabDragFromRef = useRef<string | null>(null);
  const [tabDragOver, setTabDragOver] = useState<string | null>(null);
  activeKeyRef.current = activeTerminalKey;
  useEffect(() => {
    const un = listen("menu:close-tab", () => {
      const key = activeKeyRef.current;
      if (key) closeTerminal(key);
    });
    return () => {
      void un.then((f) => f());
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // File association: open files passed via "Open With" or double-click in Finder.
  useEffect(() => {
    // Files opened before webview was ready (startup).
    void invoke<string[]>("get_startup_files").then((files) => {
      files.forEach((p) => { openEditor(p); setView("control"); });
    });
    // Files opened while app is already running.
    const un = listen<string>("apex://open-file", (e) => {
      openEditor(e.payload);
      setView("control");
    });
    return () => { void un.then((f) => f()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => {
    localStorage.setItem("apex.worktrees", JSON.stringify(worktrees));
  }, [worktrees]);
  useEffect(() => {
    localStorage.setItem("apex.openTabs", JSON.stringify(openTerminals));
  }, [openTerminals]);
  useEffect(() => {
    localStorage.setItem("apex.viewMode", viewMode);
  }, [viewMode]);
  useEffect(() => {
    localStorage.setItem("apex.gridKeys", JSON.stringify(gridKeys));
  }, [gridKeys]);

  // Sync terminal tab CWDs → worktrees so the file panel stays up-to-date.
  // Also covers restored tabs from localStorage on startup.
  useEffect(() => {
    const cwds = openTerminals
      .map((t) => t.cwd)
      .filter((c): c is string => typeof c === "string" && c.startsWith("/"));
    if (cwds.length === 0) return;
    setWorktrees((prev) => {
      const next = [...new Set([...prev, ...cwds])];
      return next.length === prev.length ? prev : next;
    });
  }, [openTerminals]);

  // New-agent modal (app-managed: optional git worktree + command in a PTY).
  const [newAgentOpen, setNewAgentOpen] = useState(false);

  const launchAgent = async (spec: NewAgentSpec) => {
    const ws = spec.workspace || workspaces[0];
    if (!ws) throw new Error("Pick a workspace first (+ Workspace).");
    let cwd = ws;
    if (spec.branch.trim()) {
      cwd = await invoke<string>("create_worktree", { repo: ws, branch: spec.branch.trim() });
      setWorktrees((prev) => (prev.includes(cwd) ? prev : [...prev, cwd]));
    }
    const initialCommand = buildAgentCommand(spec);
    openTerminal({
      key: `new:${Date.now()}`,
      name: spec.title.trim() || spec.branch.trim() || ws.split("/").filter(Boolean).pop() || "agent",
      kind: "terminal",
      cwd,
      initialCommand,
    });
    setView("control");
  };

  // LIVE: real branch topology for the selected agent's repo (else first workspace).
  // Derive `repo` as a stable string so the poll doesn't re-subscribe on every
  // 3s `agents` refresh — it only restarts when the actual repo path changes.
  const selectedAgentWorktree = agents.find((a) => a.id === selectedAgentId)?.worktree;
  const branchRepo =
    selectedAgentWorktree && selectedAgentWorktree.startsWith("/")
      ? selectedAgentWorktree
      : workspaces.find((w) => w.startsWith("/")) ?? "";
  useEffect(() => {
    if (!branchRepo) return;
    let active = true;
    const load = () => {
      if (document.hidden) return;
      invoke<GitBranchState[]>("list_branches", { repo: branchRepo })
        .then((b) => {
          if (active) setBranchList(b);
        })
        .catch(() => {});
    };
    load();
    const t = setInterval(load, 5000);
    return () => {
      active = false;
      clearInterval(t);
    };
  }, [branchRepo, fsTick]);

  // LIVE: real, hook-free file collisions — same repo-relative file edited in 2+
  // worktrees of a repo (git working-tree based).
  const [collisionReport, setCollisionReport] = useState<{
    collisions: { file: string; worktrees: string[] }[];
    editedFiles: number;
  }>({ collisions: [], editedFiles: 0 });
  useEffect(() => {
    if (!trackedPaths.length) return;
    const load = () => {
      if (document.hidden) return;
      invoke<{ collisions: { file: string; worktrees: string[] }[]; editedFiles: number }>(
        "pm_collisions",
        { paths: trackedPaths }
      )
        .then(setCollisionReport)
        .catch(() => {});
    };
    load();
    const t = setInterval(load, 5000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspaces, worktrees, fsTick]);

  // Refresh once when the window becomes visible again (polls were paused while hidden).
  useEffect(() => {
    const onVis = () => {
      if (!document.hidden) setFsTick((t) => t + 1);
    };
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, []);

  const addWorkspace = async () => {
    const sel = await openDialog({
      directory: true,
      multiple: false,
      title: "Select project / workspace folder",
    });
    if (typeof sel === "string") {
      setWorkspaces((prev) => (prev.includes(sel) ? prev : [...prev, sel]));
    }
  };

  // Open Branches / WIP / PRD listing
  const [branchList, setBranchList] = useState<GitBranchState[]>([
    {
      name: "main",
      type: "PRD",
      lastCommit: "Merge pull request #452 from feature/checkout-flow",
      author: "Senior Dev",
      status: "synced"
    },
    {
      name: "release/v1.4",
      type: "PRD",
      lastCommit: "Bump node workspace schema versions to 2026",
      author: "ReleaseBot",
      status: "synced"
    },
    {
      name: "feature/stripe-webhooks",
      type: "WIP",
      lastCommit: "Implement domestic VAT calculator integration",
      author: "Claude Agent (stripe)",
      associatedAgent: "agent-stripe",
      status: "ahead"
    },
    {
      name: "feature/auth-jwt",
      type: "WIP",
      lastCommit: "Draft JWT middleware handler endpoints",
      author: "Claude Agent (jwt)",
      associatedAgent: "agent-jwt",
      status: "diverged"
    },
    {
      name: "feature/checkout-flow",
      type: "WIP",
      lastCommit: "Refactor total container layout coordinates",
      author: "Claude Agent (checkout)",
      associatedAgent: "agent-checkout",
      status: "ahead"
    },
    {
      name: "fix/eslint-warnings",
      type: "WIP",
      lastCommit: "Remove legacy unused framework indicators",
      author: "Claude Agent (eslint)",
      associatedAgent: "agent-eslint",
      status: "synced"
    },
    {
      name: "feature/redis-telemetry",
      type: "OPEN",
      lastCommit: "Setup redis pub/sub test scripts",
      author: "Developer (Local)",
      status: "diverged"
    },
    {
      name: "feature/docker-supervisor-image",
      type: "OPEN",
      lastCommit: "Standardize Caddy proxy configurations",
      author: "DevOps Lead",
      status: "synced"
    }
  ]);

  // File explorer definitions
  const files: FileItem[] = [
    {
      name: "src/api/stripe.ts",
      path: "src/api/stripe.ts",
      isDirectory: false,
      isModified: true,
      hasConflict: true,
      lockedByAgentId: "agent-stripe", // Locked by Stripe Agent!
      content: `// Stripe Integration Controller - CONCURRENT FILE ACCESS ALERT!
import Stripe from 'stripe';

export async function processCharge(amount: number) {
  if (amount <= 0) throw new Error('Invalid price');
  console.log('Processed static payment request');
  return { success: true };
}`
    },
    {
      name: "src/api/auth.ts",
      path: "src/api/auth.ts",
      isDirectory: false,
      isModified: true,
      hasConflict: false,
      lockedByAgentId: "agent-jwt", // Locked by JWT rollover Agent!
      content: `// Auth Gateway Middleware
import jwt from 'jsonwebtoken';
export const loginHandler = async (req, res) => {
  // Locked by apex-auth-jwt session
};`
    },
    {
      name: "src/main.tsx",
      path: "src/main.tsx",
      isDirectory: false,
      isModified: false,
      lockedByAgentId: "agent-eslint",
      content: `import React from 'react';\nimport ReactDOM from 'react-dom/client';\nimport App from './App';`
    },
    {
      name: "src/types.ts",
      path: "src/types.ts",
      isDirectory: false,
      isModified: false,
      content: `export interface User { id: string; name: string; email: string; }`
    },
    {
      name: "vite.config.ts",
      path: "vite.config.ts",
      isDirectory: false,
      isModified: false,
      content: `export default defineConfig({ server: { port: 3000 } });`
    },
    {
      name: "package.json",
      path: "package.json",
      isDirectory: false,
      isModified: false,
      content: `{\n  "dependencies": {\n    "stripe": "^14.0.0"\n  }\n}`
    }
  ];

  // Shell Console state
  const [terminalInput, setTerminalInput] = useState("");
  const [terminalHistory, setTerminalHistory] = useState<string[]>([
    "=== Claude Code Daemon Multiplexer Console v2.1.1 ===",
    "[Supervisor] Scanning ~/.claude/projects/ list of running daemons...",
    "[Supervisor] Loaded worktree database. Connected on port 3000.",
    "[Warp-Bridge] Warp detected: Tab auto-configs synced. 4 active worktree routes available.",
    "Type 'help' list commands or click command templates below to dispatch.",
    ""
  ]);

  // Handle local simulation commands
  const handleTerminalSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!terminalInput.trim()) return;

    const command = terminalInput.trim();
    let responseLines: string[] = [`$ ${command}`];

    if (command === "claude agents" || command === "claude agents --json") {
      responseLines = [
        ...responseLines,
        `ID              SESSION-NAME        BRANCH                       STATE            LOCK-FILE`,
        `-------------------------------------------------------------------------------------------------------`,
        `agent-jwt       apex-auth-jwt       feature/auth-jwt             Blocked (黃)     src/api/auth.ts`,
        `agent-stripe    apex-stripe-hooks   feature/stripe-webhooks      Working (綠)     src/api/stripe.ts`,
        `agent-checkout  apex-checkout-v2    feature/checkout-flow        Working (綠)     src/api/stripe.ts <CONFLICT>`,
        `agent-eslint    apex-eslint-fix     fix/eslint-warnings          Idle (藍)        src/main.tsx`,
        ``,
        `💡 Running background supervisor monitor via standard "~/.claude/jobs/state.json" file stream.`
      ];
    } else if (command === "help") {
      responseLines = [
        ...responseLines,
        "Simulated Control Commands:",
        "  claude agents      Fetch running backgrounds unclosed server-side container states",
        "  git worktree list  Show current isolated workspaces directory structures mapped",
        "  clear              Clear terminal logs text panels",
        "  resolve            Clear worktree lock/overlap file collision simulation flags"
      ];
    } else if (command === "git worktree list") {
      responseLines = [
        ...responseLines,
        "Git Worktree Isolation Folders:",
        "  ~/apex-parent-dir (main repo path)         -> main [PRD synced]",
        "  ~/apex-wt/auth-jwt                         -> feature/auth-jwt [WIP divergent]",
        "  ~/apex-wt/stripe-webhooks                  -> feature/stripe-webhooks [WIP ahead]",
        "  ~/apex-wt/checkout-flow                    -> feature/checkout-flow [WIP ahead]",
        "  ~/apex-wt/eslint-warnings                  -> fix/eslint-warnings [WIP synced]"
      ];
    } else if (command === "resolve") {
      // Clear conflicts
      responseLines = [
        ...responseLines,
        "[Supervisor] Recalculating workspace collisions locks...",
        "[Status] Collision on src/api/stripe.ts resolved automatically!"
      ];
    } else if (command === "clear") {
      setTerminalHistory([]);
      setTerminalInput("");
      return;
    } else {
      responseLines = [
        ...responseLines,
        `Executing generic PTY command: "${command}"...`,
        "Success."
      ];
    }

    setTerminalHistory((prev) => [...prev, ...responseLines, ""]);
    setTerminalInput("");
  };

  const handleCreateBranchAndAgent = () => {
    // Spawn custom demo branch
    const demoBranchName = `feature/redis-${Math.floor(Math.random() * 900) + 100}`;
    const agentId = `agent-redis-${Date.now().toString().slice(-4)}`;
    
    // Add to WIP list
    const newWip: GitBranchState = {
      name: demoBranchName,
      type: "WIP",
      lastCommit: "Supervisor initial workspace checkout setup",
      author: "System Auto-Dispatch",
      associatedAgent: agentId,
      status: "synced"
    };
    
    // Add to Active Agents
    const newAgent: AgentSession = {
      id: agentId,
      name: `apex-${demoBranchName.split("/")[1]}`,
      branch: demoBranchName,
      worktree: `~/apex-wt/${demoBranchName.split("/")[1]}`,
      status: "working",
      activeTask: "Configure high speed key invalidation strategies",
      activeFile: "src/main.tsx",
      tokensUsed: 0,
      modelsUsed: "Claude 3.7 Sonnet",
      quotaBurn: 0.0,
      duration: "00m 01s",
      createdAt: new Date().toTimeString().split(" ")[0]
    };

    setBranchList((prev) => [newWip, ...prev]);
    setAgents((prev) => [newAgent, ...prev]);
    setSelectedAgentId(agentId);

    setTerminalHistory((prev) => [
      ...prev,
      `$ git worktree add ${newAgent.worktree} -b ${newAgent.branch}`,
      `[Supervisor] Spawned fresh Claude Code session inside isolating worktree.`,
      `[Daemon] Session ID: ${agentId} registered. Tracking ~/.claude/tasks board list.`,
      ""
    ]);
  };

  // Clock Update
  useEffect(() => {
    const timer = setInterval(() => {
      const now = new Date();
      setLocalTime(now.toTimeString().split(" ")[0] + " UTC");
    }, 1000);

    // Live resource usage of the app's own process (not the machine).
    const pollMetrics = () => {
      if (document.hidden) return;
      invoke<{ cpu: number; memMb: number }>("app_metrics")
        .then((m) => {
          setCpuUsage(Math.round(m.cpu));
          setRamUsage(m.memMb);
        })
        .catch(() => {});
    };
    pollMetrics();
    const cpuTimer = setInterval(pollMetrics, 2500);

    return () => {
      clearInterval(timer);
      clearInterval(cpuTimer);
    };
  }, []);

  // Dev-only perf harness hook (src/perf/harness.ts): lets the stress test
  // inflate render load with synthetic branches to measure main-thread blocking.
  // No-op unless VITE_APEX_PERF=1 — stripped from prod builds.
  useEffect(() => {
    if (import.meta.env.VITE_APEX_PERF !== "1") return;
    const synth = (i: number): GitBranchState => ({
      name: `perf/synthetic-${i}`,
      type: i % 3 === 0 ? "PRD" : i % 3 === 1 ? "WIP" : "OPEN",
      lastCommit: `${i % 60}m ago`,
      author: "perf-harness",
      status: (["synced", "ahead", "diverged", "conflict"] as const)[i % 4],
      parent: i > 0 ? `perf/synthetic-${i - 1}` : "main",
    });
    const isSynth = (b: GitBranchState) => b.name.startsWith("perf/synthetic-");
    const isSynthTab = (t: OpenTerminal) => t.key.startsWith("perf-term-");
    window.__apexPerf = {
      inflateBranches: (n: number) =>
        setBranchList((prev) => [
          ...prev.filter((b) => !isSynth(b)),
          ...Array.from({ length: n }, (_, i) => synth(i)),
        ]),
      resetBranches: () => setBranchList((prev) => prev.filter((b) => !isSynth(b))),
      openTerminals: (n: number) =>
        setOpenTerminals((prev) => [
          ...prev.filter((t) => !isSynthTab(t)),
          ...Array.from({ length: n }, (_, i) => ({
            key: `perf-term-${i}`,
            name: `perf-${i}`,
            kind: "terminal" as const,
          })),
        ]),
      closeTerminals: () => setOpenTerminals((prev) => prev.filter((t) => !isSynthTab(t))),
    };
  }, []);

  // Find info about active agent working on selected file
  const activeFileObject = files.find((f) => f.path === selectedFile);
  const lockAgent = activeFileObject?.lockedByAgentId 
    ? agents.find((a) => a.id === activeFileObject.lockedByAgentId)
    : null;

  const renderSyncStatusBadge = (status: "synced" | "ahead" | "diverged" | "conflict" | string) => {
    switch (status) {
      case "synced":
        return (
          <span className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[9px] font-mono font-bold bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300 border border-emerald-250 dark:border-emerald-800 shrink-0">
            <span className="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse shrink-0" />
            <span>SYNCED</span>
          </span>
        );
      case "ahead":
        return (
          <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[9px] font-mono font-bold bg-indigo-50 dark:bg-indigo-950/40 text-indigo-700 dark:text-indigo-300 border border-indigo-200 dark:border-indigo-800 shrink-0">
            <span className="w-1.5 h-1.5 rounded-full bg-indigo-500 shrink-0" />
            <span>AHEAD</span>
          </span>
        );
      case "diverged":
        return (
          <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[9px] font-mono font-bold bg-amber-50 dark:bg-amber-950/40 text-amber-700 dark:text-amber-300 border border-amber-250 dark:border-amber-800 shrink-0 animate-pulse">
            <AlertTriangle className="h-2.5 w-2.5 text-amber-500 dark:text-amber-400 shrink-0" />
            <span>DIVERGED</span>
          </span>
        );
      case "conflict":
        return (
          <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[9px] font-mono font-bold bg-rose-50 dark:bg-rose-950/40 text-rose-750 dark:text-rose-300 border border-rose-250 dark:border-rose-800 shrink-0 animate-bounce">
            <AlertTriangle className="h-2.5 w-2.5 text-rose-500 dark:text-rose-400 shrink-0" />
            <span>CONFLICT</span>
          </span>
        );
      default:
        return (
          <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[9px] font-mono font-bold bg-neutral-55 dark:bg-neutral-900 bg-neutral-100 dark:bg-neutral-800 text-neutral-600 dark:text-neutral-400 border border-neutral-250 dark:border-neutral-700 shrink-0">
            <span className="w-1.5 h-1.5 rounded-full bg-neutral-300 dark:bg-neutral-600 shrink-0" />
            <span>{status.toUpperCase()}</span>
          </span>
        );
    }
  };

  return (
    <div id="vs-ctrl-plane" className="min-h-screen bg-neutral-50 dark:bg-neutral-900 text-neutral-800 dark:text-neutral-200 flex flex-col font-sans select-none overflow-hidden h-screen text-xs">
      
      {/* ================= TOP CUSTOM VS CODE STATUS BRANDING BAR ================= */}
      <header className="h-10 border-b border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 px-3 flex items-center justify-between shrink-0 select-none shadow-sm">
        <div className="flex items-center space-x-3">
          <button
            type="button"
            onClick={() => setLeftOpen((o) => !o)}
            title="Toggle left panel"
            className={`p-1 rounded cursor-pointer transition-colors ${
              leftOpen ? "text-indigo-600 dark:text-indigo-400 hover:bg-indigo-50 dark:hover:bg-indigo-900/40" : "text-neutral-400 dark:text-neutral-500 hover:bg-neutral-100 dark:hover:bg-neutral-800"
            }`}
          >
            <PanelLeft className="h-4 w-4" />
          </button>
          <img src={appIconUrl} className="h-8 w-8 rounded select-none" alt="" />
          <div className="flex items-center space-x-1">
            <span className="font-semibold text-neutral-900 dark:text-neutral-100 font-display">Apex Agent Control IDE</span>
          </div>
        </div>

        {/* Primary navigation */}
        <div className="hidden md:flex items-center space-x-1 text-[11px] font-mono">
          <button
            type="button"
            onClick={() => setView("control")}
            className={`px-2.5 py-1 rounded transition-colors cursor-pointer ${
              view === "control"
                ? "bg-indigo-50 dark:bg-indigo-950/40 text-indigo-700 dark:text-indigo-300 font-bold border border-indigo-200 dark:border-indigo-800"
                : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
            }`}
          >
            Control
          </button>
          <button
            type="button"
            onClick={() => setView("sessions")}
            className={`px-2.5 py-1 rounded transition-colors cursor-pointer ${
              view === "sessions"
                ? "bg-indigo-50 dark:bg-indigo-950/40 text-indigo-700 dark:text-indigo-300 font-bold border border-indigo-200 dark:border-indigo-800"
                : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
            }`}
          >
            Sessions
          </button>
          <button
            type="button"
            onClick={() => setView("queue")}
            className={`px-2.5 py-1 rounded transition-colors cursor-pointer ${
              view === "queue"
                ? "bg-indigo-50 dark:bg-indigo-950/40 text-indigo-700 dark:text-indigo-300 font-bold border border-indigo-200 dark:border-indigo-800"
                : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
            }`}
          >
            Queue
          </button>
          <button
            type="button"
            onClick={() => setView("tools")}
            className={`px-2.5 py-1 rounded transition-colors cursor-pointer ${
              view === "tools"
                ? "bg-indigo-50 dark:bg-indigo-950/40 text-indigo-700 dark:text-indigo-300 font-bold border border-indigo-200 dark:border-indigo-800"
                : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
            }`}
          >
            Resources
          </button>
        </div>

        {/* System telemetry ticks right side */}
        <div className="flex items-center space-x-4 font-mono text-[10px] text-neutral-600 dark:text-neutral-400">
          <div className="flex items-center space-x-1.5">
            <Cpu className="h-3 w-3 text-emerald-600 dark:text-emerald-300" />
            <span>CPU:</span>
            <span className={cpuUsage > 75 ? "text-rose-600 dark:text-rose-300" : "text-emerald-600 dark:text-emerald-300 font-bold"}>
              {cpuUsage}%
            </span>
          </div>
          <div className="flex items-center space-x-1.5">
            <HardDrive className="h-3 w-3 text-indigo-500 dark:text-indigo-400" />
            <span title="App memory (RSS)">RAM:</span>
            <span className="text-neutral-800 dark:text-neutral-200 font-medium">
              {ramUsage < 1024 ? `${Math.round(ramUsage)} MB` : `${(ramUsage / 1024).toFixed(1)} GB`}
            </span>
          </div>
          <span className="border-l border-neutral-200 dark:border-neutral-700 pl-3 text-neutral-700 dark:text-neutral-300 font-bold bg-neutral-100 dark:bg-neutral-800 px-1.5 py-0.5 rounded border border-neutral-200 dark:border-neutral-700">
            {localTime}
          </span>
          <button
            type="button"
            onClick={() => setThemeMode(effectiveTheme === "dark" ? "light" : "dark")}
            title={`Theme: ${themeMode}${themeMode === "system" ? ` (${effectiveTheme})` : ""} — click to switch`}
            className="p-1 rounded cursor-pointer transition-colors text-neutral-400 hover:bg-neutral-100 hover:text-indigo-600 dark:text-neutral-500 dark:hover:bg-neutral-800 dark:hover:text-indigo-400"
          >
            {effectiveTheme === "dark" ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
          </button>
          <button
            type="button"
            onClick={() => setRightOpen((o) => !o)}
            title="Toggle right panel"
            className={`p-1 rounded cursor-pointer transition-colors ${
              rightOpen ? "text-indigo-600 dark:text-indigo-400 hover:bg-indigo-50 dark:hover:bg-indigo-900/40" : "text-neutral-400 dark:text-neutral-500 hover:bg-neutral-100 dark:hover:bg-neutral-800"
            }`}
          >
            <PanelRight className="h-4 w-4" />
          </button>
        </div>
      </header>

      {/* ================= MAIN AREA: Sessions page OR three-panel control plane ================= */}
      {view === "sessions" && (
        <SessionsPage
          onOpen={(spec) => {
            if (spec.cwd) ensureWorktreeTracked(spec.cwd);
            openTerminal({ ...spec, kind: "terminal" });
            setView("control");
          }}
        />
      )}
      {view === "tools" && (
        <ResourcesPage
          onOpenTerminal={(spec) => {
            openTerminal({ ...spec, kind: "terminal" });
            setView("control");
          }}
        />
      )}
      {view === "queue" && (
        <QueuePage
          paths={trackedPaths}
          worktrees={worktrees}
          refreshSignal={fsTick}
          onWorktreeRemoved={(p) => setWorktrees((prev) => prev.filter((x) => x !== p))}
          inspect={branchInspect}
          onClearInspect={() => setBranchInspect(null)}
        />
      )}
      {/* Control plane — ALWAYS mounted; hidden (not unmounted) on other views so the
          terminal PTYs and any running sessions survive page navigation. xterm guards
          0×0 resize (Terminal.tsx), so display:none is safe. */}
      <div className={`flex-1 flex overflow-hidden ${view !== "control" ? "hidden" : ""}`}>

        {/* ----------------- Panel 1: LEFT SIDEBAR (File Tree Explorer & Workspace Locker) ----------------- */}
        {leftOpen && (
        <aside id="tree-explorer-sidebar" className="w-72 border-r border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 flex flex-col shrink-0 overflow-hidden">
          
          {/* Header Title bar */}
          <div className="p-3 border-b border-neutral-200 dark:border-neutral-700 flex items-center justify-between bg-neutral-50/50 dark:bg-neutral-900">
            <h2 className="text-[10px] font-mono tracking-widest uppercase font-bold text-neutral-500 dark:text-neutral-400 flex items-center gap-1.5">
              <Folder className="h-3.5 w-3.5 text-indigo-500 dark:text-indigo-400" /> Workspace Files ({trackedPaths.length})
            </h2>
            <button
              type="button"
              onClick={addWorkspace}
              title="Add project / workspace folder"
              className="text-[10px] font-mono font-bold px-1.5 py-0.5 rounded border border-indigo-200 dark:border-indigo-800 bg-indigo-50 dark:bg-indigo-950/40 text-indigo-700 dark:text-indigo-300 hover:bg-indigo-100 dark:hover:bg-indigo-900/40 cursor-pointer transition-colors"
            >
              + Workspace
            </button>
          </div>

          {/* Real, lazy file tree over the user's workspace roots (backend list_dir) */}
          <div className="flex-1 overflow-y-auto">
            <FileTree
              roots={trackedPaths}
              removableRoots={new Set(workspaces)}
              onOpenFile={openEditor}
              onRemoveRoot={(path) => {
                setWorkspaces((prev) => prev.filter((w) => w !== path));
                setWorktrees((prev) => prev.filter((w) => w !== path));
              }}
              refreshSignal={fsTick}
            />
          </div>

          {/* BOTTOM ATTACHMENT: ACTIVE CLAUDE AGENT FILE-WATCHER */}
          <div className="border-t border-neutral-200 dark:border-neutral-700 bg-neutral-50/50 dark:bg-neutral-900 p-3 select-none">
            <div className="flex items-center justify-between mb-2">
              <h3 className="text-[10px] uppercase font-mono text-neutral-500 dark:text-neutral-400 tracking-wider font-bold">
                Lock/Edit File Telemetry
              </h3>
              <span className="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse"></span>
            </div>

            {collisionReport.collisions.length > 0 ? (
              <div className="space-y-1.5">
                {collisionReport.collisions.map((c) => (
                  <div
                    key={c.file}
                    className="bg-rose-50 dark:bg-rose-950/40 border border-rose-200 dark:border-rose-800 rounded p-2 text-[10px] font-mono shadow-sm"
                  >
                    <div className="flex items-center gap-1.5 text-rose-700 dark:text-rose-300 font-bold">
                      <AlertTriangle className="h-3 w-3 shrink-0" />
                      <span className="truncate">{c.file}</span>
                    </div>
                    <div className="text-[9px] text-rose-600 dark:text-rose-300 mt-0.5 truncate">
                      edited in: {c.worktrees.join(" · ")}
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <div className="p-3 bg-white dark:bg-neutral-900 rounded border border-neutral-200 dark:border-neutral-700 text-center shadow-sm">
                <CheckCircle2 className="h-4 w-4 mx-auto mb-1 text-emerald-500 dark:text-emerald-400" />
                <p className="text-[10px] font-mono leading-tight text-neutral-500 dark:text-neutral-400">
                  No file collisions across worktrees.
                </p>
                <p className="text-[9px] font-mono text-neutral-400 dark:text-neutral-500 mt-0.5">
                  {collisionReport.editedFiles} uncommitted change
                  {collisionReport.editedFiles === 1 ? "" : "s"} tracked
                </p>
              </div>
            )}
          </div>
        </aside>
        )}

        {/* ----------------- Panel 2: CENTER WORKSPACE (Sessions Agent Board + Multi-Console PTY) ----------------- */}
        <section className="flex-1 flex flex-col overflow-hidden bg-neutral-50/50 dark:bg-neutral-900">

          {/* CENTER: Persistent per-session terminals + editors (session monitor moved
              to the right panel's Sessions tab) */}
          <div className="flex-1 flex flex-col overflow-hidden bg-white dark:bg-neutral-900">

            {/* Dynamic terminal tabs — one per open session, kept alive across switches */}
            <header className="h-9 px-2 bg-neutral-50 dark:bg-neutral-900 border-b border-neutral-200 dark:border-neutral-700 flex items-center justify-between shrink-0">
              {/* Left scroll arrow */}
              <button
                type="button"
                onClick={() => { tabScrollRef.current?.scrollBy({ left: -120, behavior: "smooth" }); }}
                className="shrink-0 h-full px-0.5 text-neutral-400 dark:text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-200 cursor-pointer"
              >
                <ChevronLeft className="h-3.5 w-3.5" />
              </button>
              <div ref={tabScrollRef} className="flex items-center space-x-0.5 h-full overflow-x-auto flex-1 min-w-0 scroll-smooth" style={{ scrollbarWidth: "none" }}>
                {viewMode === "tabs" && openTerminals.length === 0 && (
                  <span className="px-2 text-[11px] font-mono text-neutral-400 dark:text-neutral-500 flex items-center gap-1.5">
                    <Terminal className="h-3.5 w-3.5" /> Select a session to open a terminal tab
                  </span>
                )}
                {viewMode === "tabs" && openTerminals.map((tm) => {
                  const isActive = tm.key === activeTerminalKey;
                  return (
                    <div
                      key={tm.key}
                      draggable
                      onDragStart={(e) => { e.dataTransfer.effectAllowed = "move"; tabDragFromRef.current = tm.key; }}
                      onDragOver={(e) => { e.preventDefault(); e.dataTransfer.dropEffect = "move"; setTabDragOver(tm.key); }}
                      onDragLeave={(e) => { if (!e.currentTarget.contains(e.relatedTarget as Node)) setTabDragOver(null); }}
                      onDrop={(e) => {
                        e.preventDefault();
                        const from = tabDragFromRef.current;
                        if (from && from !== tm.key) {
                          setOpenTerminals(prev => {
                            const next = [...prev];
                            const fromIdx = next.findIndex(t => t.key === from);
                            const toIdx   = next.findIndex(t => t.key === tm.key);
                            if (fromIdx !== -1 && toIdx !== -1) {
                              const [moved] = next.splice(fromIdx, 1);
                              next.splice(toIdx, 0, moved);
                            }
                            return next;
                          });
                        }
                        tabDragFromRef.current = null; setTabDragOver(null);
                      }}
                      onDragEnd={() => { tabDragFromRef.current = null; setTabDragOver(null); }}
                      onClick={() => setActiveTerminalKey(tm.key)}
                      className={`group flex items-center gap-1.5 px-2.5 h-full border-b-2 cursor-grab active:cursor-grabbing transition-colors shrink-0 ${
                        tabDragOver === tm.key ? "border-indigo-400 bg-indigo-50 dark:bg-indigo-900/20" :
                        isActive
                          ? "border-indigo-600 bg-white dark:bg-neutral-900 text-indigo-950 dark:text-indigo-300 font-semibold"
                          : "border-transparent text-neutral-500 dark:text-neutral-400 hover:text-neutral-800 dark:hover:text-neutral-200"
                      }`}
                    >
                      {tm.kind === "editor" ? (
                        <FileCode className="h-3.5 w-3.5 text-amber-500 dark:text-amber-400 shrink-0" />
                      ) : (
                        <Terminal className="h-3.5 w-3.5 text-indigo-500 dark:text-indigo-400 shrink-0" />
                      )}
                      <span className="text-xs font-display truncate max-w-[160px]">{tm.name}</span>
                      {tm.initialCommand && (
                        <span className="h-1.5 w-1.5 rounded-full bg-emerald-500 shrink-0" title={tm.initialCommand} />
                      )}
                      <button
                        type="button"
                        onClick={(e) => {
                          e.stopPropagation();
                          closeTerminal(tm.key);
                        }}
                        className="ml-0.5 text-neutral-400 dark:text-neutral-500 hover:text-rose-600 dark:hover:text-rose-300 opacity-60 group-hover:opacity-100 transition-opacity cursor-pointer"
                        title="Close tab"
                      >
                        <X className="h-3 w-3" />
                      </button>
                    </div>
                  );
                })}
                {viewMode === "grid" && (
                  <span className="px-2 text-[11px] font-mono text-indigo-500 dark:text-indigo-400 flex items-center gap-1.5">
                    <LayoutGrid className="h-3.5 w-3.5" />
                    Grid — {gridKeys.filter(k => openTerminals.some(t => t.key === k)).length} terminals
                  </span>
                )}
              </div>

              {/* Right scroll arrow */}
              <button
                type="button"
                onClick={() => { tabScrollRef.current?.scrollBy({ left: 120, behavior: "smooth" }); }}
                className="shrink-0 h-full px-0.5 text-neutral-400 dark:text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-200 cursor-pointer"
              >
                <ChevronRight className="h-3.5 w-3.5" />
              </button>

              <div className="flex items-center gap-2 shrink-0 pr-1">
                {/* Grid toggle button */}
                <button
                  type="button"
                  title={viewMode === "grid" ? "Switch to tab view" : "Switch to grid view (show up to 4 terminals)"}
                  onClick={() => {
                    if (viewMode === "tabs") {
                      // Enter grid mode: populate gridKeys with up to 4 terminal tabs
                      const termKeys = openTerminals.filter(t => t.kind === "terminal").map(t => t.key).slice(0, 4);
                      setGridKeys(termKeys);
                      setViewMode("grid");
                      setLeftOpen(false);
                      setRightOpen(false);
                    } else {
                      setViewMode("tabs");
                      setLeftOpen(true);
                      setRightOpen(true);
                    }
                  }}
                  className={`flex items-center gap-1 px-2 py-1 rounded text-[10px] font-mono font-bold transition-colors cursor-pointer ${
                    viewMode === "grid"
                      ? "bg-indigo-600 text-white hover:bg-indigo-700"
                      : "text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 hover:text-neutral-800 dark:hover:text-neutral-200"
                  }`}
                >
                  <LayoutGrid className="h-3 w-3" />
                  <span>Grid</span>
                </button>

                {/* Console Badge metrics */}
                <div className="flex items-center space-x-1.5 text-[10px] font-mono text-neutral-500 dark:text-neutral-400">
                  <span>DAEMON:</span>
                  <span className="bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300 border border-emerald-200 dark:border-emerald-800 px-1.5 py-0.5 rounded font-bold uppercase shadow-sm">
                    Connected
                  </span>
                </div>
              </div>
            </header>

            {/* Terminal surfaces — tab mode: only active shown (Terax pattern).
                Grid mode: TerminalGrid renders up to 4 simultaneously. */}
            <div className="flex-1 overflow-hidden relative">
              {viewMode === "grid" && (
                <div className="absolute inset-0">
                  <TerminalGrid
                    terminals={openTerminals.filter(t => t.kind === "terminal")}
                    gridKeys={gridKeys.filter(k => openTerminals.some(t => t.key === k))}
                    onGridKeysChange={setGridKeys}
                    theme={effectiveTheme}
                  />
                </div>
              )}
              {/* Keep tab terminals mounted even in grid mode (PTY stays alive) */}
              {viewMode === "grid" ? null : openTerminals.length === 0 ? (
                <div className="h-full flex items-center justify-center text-neutral-400 dark:text-neutral-500 text-xs font-mono">
                  No active tab — click a session (terminal) or open a file from the
                  left (editor).
                </div>
              ) : (
                openTerminals.map((tm) =>
                  tm.kind === "editor" ? (
                    <div
                      key={tm.key}
                      style={{ display: tm.key === activeTerminalKey ? "flex" : "none" }}
                      className="absolute inset-3 flex-col overflow-hidden bg-white dark:bg-neutral-900 rounded-lg border border-neutral-200 dark:border-neutral-700 shadow-inner"
                    >
                      <FileEditor path={tm.filePath!} theme={effectiveTheme} />
                    </div>
                  ) : (
                    <div
                      key={tm.key}
                      style={{ display: tm.key === activeTerminalKey ? "flex" : "none" }}
                      className="absolute inset-3 flex-col overflow-hidden bg-[#25272b] rounded-lg border border-neutral-800 shadow-inner"
                    >
                      <div className="px-3 py-1 border-b border-neutral-800 text-[10px] font-mono text-neutral-400 shrink-0 truncate flex items-center justify-between">
                        <span>{tm.cwd ?? "~ (home)"}</span>
                        {tm.initialCommand && (
                          <span className="text-emerald-400">● {tm.initialCommand}</span>
                        )}
                      </div>
                      <div className="flex-1 overflow-hidden p-2">
                        <AgentTerminal
                          cwd={tm.cwd}
                          initialCommand={tm.initialCommand}
                          theme={effectiveTheme}
                          active={tm.key === activeTerminalKey}
                        />
                      </div>
                    </div>
                  )
                )
              )}
            </div>
          </div>
        </section>

        {/* ----------------- Panel 3: RIGHT SIDEBAR (Open Branch / WIP / PRD Release Tracker) ----------------- */}
        {rightOpen && (
        <aside id="branch-wip-prd-tracker" className="w-80 border-l border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 flex flex-col shrink-0 overflow-y-auto">

          {/* Tabbed header: live session monitor + branch matrix */}
          <div className="flex border-b border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-900 shrink-0">
            <button
              type="button"
              onClick={() => setRightTab("sessions")}
              className={`flex-1 px-3 py-2 text-[10px] font-mono tracking-wider uppercase font-bold flex items-center justify-center gap-1.5 border-b-2 transition-colors cursor-pointer ${
                rightTab === "sessions"
                  ? "border-indigo-600 text-indigo-700 dark:text-indigo-300 bg-white dark:bg-neutral-900"
                  : "border-transparent text-neutral-500 dark:text-neutral-400 hover:text-neutral-800 dark:hover:text-neutral-200"
              }`}
            >
              <Layers className="h-3.5 w-3.5" /> Sessions ({agents.length})
            </button>
            <button
              type="button"
              onClick={() => setRightTab("branch")}
              className={`flex-1 px-3 py-2 text-[10px] font-mono tracking-wider uppercase font-bold flex items-center justify-center gap-1.5 border-b-2 transition-colors cursor-pointer ${
                rightTab === "branch"
                  ? "border-indigo-600 text-indigo-700 dark:text-indigo-300 bg-white dark:bg-neutral-900"
                  : "border-transparent text-neutral-500 dark:text-neutral-400 hover:text-neutral-800 dark:hover:text-neutral-200"
              }`}
            >
              <GitBranch className="h-3.5 w-3.5" /> Branch & WIP
            </button>
          </div>

          {rightTab === "sessions" ? (
            <div className="p-3">
              <button
                type="button"
                onClick={() => setNewAgentOpen(true)}
                className="w-full mb-3 text-[11px] font-mono font-bold px-2 py-1.5 rounded border border-indigo-200 dark:border-indigo-800 bg-indigo-50 dark:bg-indigo-950/40 text-indigo-700 dark:text-indigo-300 hover:bg-indigo-100 dark:hover:bg-indigo-900/40 cursor-pointer transition-colors flex items-center justify-center gap-1.5"
              >
                <Plus className="h-3 w-3" /> New agent
              </button>
              <SessionMonitor
                agents={agents}
                selectedAgentId={selectedAgentId}
                onOpen={(a) => {
                  const full = agents.find((x) => x.id === a.id);
                  if (full) {
                    setSelectedAgentId(full.id);
                    openTerminalForAgent(full);
                  }
                }}
                onKill={(a) => {
                  const full = agents.find((x) => x.id === a.id);
                  if (full) void killAgent(full);
                }}
              />
            </div>
          ) : (
          <div className="p-3 space-y-4">
            
            {/* Visual DAG Representation showing commit lineage / status mapping */}
            <BranchDAG
              branchList={branchList}
              agents={agents}
              selectedAgentId={selectedAgentId}
              setSelectedAgentId={setSelectedAgentId}
              setTerminalHistory={setTerminalHistory}
            />
            
            {/* CATEGORY 1: PRODUCTION / RELEASE ENVS (PRD) */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-[10px] font-mono uppercase tracking-widest font-bold text-emerald-600 dark:text-emerald-300 flex items-center gap-1">
                  <ShieldCheck className="h-3 w-3" /> Production Branches (PRD)
                </span>
                <span className="text-[9px] font-mono bg-neutral-100 dark:bg-neutral-800 text-emerald-700 dark:text-emerald-300 px-1 border border-neutral-250 dark:border-neutral-700 rounded font-semibold">
                  {branchList.filter(b => b.type === "PRD").length}
                </span>
              </div>

              <div className="space-y-1.5">
                {branchList
                  .filter((b) => b.type === "PRD")
                  .map((branch) => (
                    <div
                      key={branch.name}
                      onClick={() => {
                        setTerminalHistory((prev) => [
                          ...prev,
                          `$ git checkout ${branch.name}`,
                          `[System] Warning: Branch '${branch.name}' is registered as active PRD core. Skipping automatic agent overrides.`,
                          ""
                        ]);
                        setBranchInspect({ repo: branchRepo, name: branch.name });
                        setView("queue");
                      }}
                      className="p-2 border border-emerald-100 dark:border-emerald-800 bg-emerald-50/10 dark:bg-emerald-950/40 hover:border-emerald-200 dark:hover:border-emerald-700 rounded cursor-pointer transition-colors shadow-sm"
                    >
                      <div className="flex items-start justify-between gap-1.5">
                        <span className="font-mono text-xs font-bold text-emerald-800 dark:text-emerald-300 truncate max-w-[140px]">
                          {branch.name}
                        </span>
                        <div className="flex items-center gap-1.5 shrink-0">
                          {renderSyncStatusBadge(branch.status || "synced")}
                        </div>
                      </div>
                      <p className="mt-1 text-[10px] text-neutral-600 dark:text-neutral-400 truncate">
                        {branch.lastCommit}
                      </p>
                      <div className="mt-1.5 flex items-center justify-between text-[9px] font-mono text-neutral-500 dark:text-neutral-400">
                        <span className="truncate">{branch.author}</span>
                      </div>
                    </div>
                  ))}
              </div>
            </div>

            {/* CATEGORY 2: WORK-IN-PROGRESS (WIP) */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-[10px] font-mono uppercase tracking-widest font-semibold text-amber-600 dark:text-amber-300 flex items-center gap-1">
                  <Zap className="h-3 w-3 animate-pulse" /> Active Workspace WIP
                </span>
                <span className="text-[9px] font-mono bg-neutral-100 dark:bg-neutral-800 text-amber-700 dark:text-amber-300 px-1 border border-neutral-250 dark:border-neutral-700 rounded font-semibold">
                  {branchList.filter(b => b.type === "WIP").length}
                </span>
              </div>

              <div className="space-y-1.5">
                {branchList
                  .filter((b) => b.type === "WIP")
                  .map((branch) => {
                    const agentObj = agents.find((a) => a.id === branch.associatedAgent);
                    return (
                      <div
                        id={`branch-row-${branch.name.replace(/\//g, "-")}`}
                        key={branch.name}
                        onClick={() => {
                          if (agentObj) {
                            setSelectedAgentId(agentObj.id);
                          }
                          setBranchInspect({ repo: branchRepo, name: branch.name });
                          setView("queue");
                        }}
                        className={`p-2 border rounded cursor-pointer transition-colors shadow-sm ${
                          agentObj?.id === selectedAgentId
                            ? "bg-amber-50/40 dark:bg-amber-950/40 border-amber-500"
                            : "border-neutral-200 dark:border-neutral-700 hover:border-neutral-300 dark:hover:border-neutral-700 bg-white dark:bg-neutral-900"
                        }`}
                      >
                        <div className="flex items-start justify-between gap-1.5">
                          <span className="font-mono text-xs font-bold text-neutral-800 dark:text-neutral-200 truncate max-w-[150px]">
                            {branch.name}
                          </span>
                          {renderSyncStatusBadge(branch.status)}
                        </div>
                        
                        <p className="mt-1 text-[10px] text-neutral-650 dark:text-neutral-400 truncate">
                          {branch.lastCommit}
                        </p>

                        {agentObj && (
                          <div className="mt-2 p-1 bg-neutral-50 dark:bg-neutral-900 rounded border border-neutral-200 dark:border-neutral-700 flex items-center justify-between text-[9px] font-mono text-neutral-600 dark:text-neutral-400">
                            <span className="text-indigo-650 dark:text-indigo-300 font-bold">
                              🤖 {agentObj.name}
                            </span>
                            <span className="text-[8px] uppercase font-bold text-neutral-550 dark:text-neutral-400">{agentObj.status}</span>
                          </div>
                        )}
                      </div>
                    );
                  })}
              </div>
            </div>

            {/* CATEGORY 3: OPEN PENDING / STALE BRANCHES */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-[10px] font-mono uppercase tracking-widest font-bold text-indigo-550 dark:text-indigo-400 flex items-center gap-1">
                  <GitPullRequest className="h-3 w-3" /> Open Pending (PR/stale)
                </span>
                <span className="text-[9px] font-mono bg-neutral-100 dark:bg-neutral-800 text-indigo-700 dark:text-indigo-300 px-1 border border-neutral-250 dark:border-neutral-700 rounded font-semibold">
                  {branchList.filter(b => b.type === "OPEN").length}
                </span>
              </div>

              <div className="space-y-1.5">
                {branchList
                  .filter((b) => b.type === "OPEN")
                  .map((branch) => (
                    <div
                      key={branch.name}
                      onClick={() => {
                        setTerminalHistory((prev) => [
                          ...prev,
                          `$ git checkout ${branch.name}`,
                          `[System] Switch checkout worktree root index to ${branch.name}.`,
                          ""
                        ]);
                        setBranchInspect({ repo: branchRepo, name: branch.name });
                        setView("queue");
                      }}
                      className="p-2 border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 hover:border-neutral-300 dark:hover:border-neutral-700 rounded cursor-pointer transition-colors shadow-sm"
                    >
                      <div className="flex items-start justify-between gap-1.5">
                        <span className="font-mono text-xs text-neutral-700 dark:text-neutral-300 truncate max-w-[140px]">
                          {branch.name}
                        </span>
                        <div className="flex items-center gap-1.5 shrink-0">
                          {renderSyncStatusBadge(branch.status || "synced")}
                        </div>
                      </div>
                      <p className="mt-1 text-[10px] text-neutral-500 dark:text-neutral-400 truncate">
                        {branch.lastCommit}
                      </p>
                      <div className="mt-1.5 flex items-center justify-between text-[9px] font-mono text-neutral-500 dark:text-neutral-400">
                        <span className="truncate">{branch.author}</span>
                      </div>
                    </div>
                  ))}
              </div>
            </div>

          </div>
          )}
        </aside>
        )}

      </div>

      {/* ================= FOOTER / STATUS TRAY BAR ================= */}
      <footer className="h-7 border-t border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 px-3 flex items-center justify-between z-10 shrink-0 text-[10px] font-mono text-neutral-500 dark:text-neutral-400 select-none shadow-sm">
        <div className="flex items-center space-x-4">
          <div className="flex items-center space-x-1.5 text-neutral-600 dark:text-neutral-400">
            <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse"></span>
            <span>Ready</span>
          </div>
          <span>|</span>
          <span>Workspaces: <strong className="text-neutral-700 dark:text-neutral-300">{workspaces.length}</strong></span>
          <span>|</span>
          <span>Sessions: <strong className="text-neutral-700 dark:text-neutral-300">{agents.length}</strong></span>
          <span>|</span>
          <span>
            Collisions:{" "}
            <strong className={collisionReport.collisions.length > 0 ? "text-rose-600 dark:text-rose-300" : "text-neutral-700 dark:text-neutral-300"}>
              {collisionReport.collisions.length}
            </strong>
          </span>
        </div>

        <div className="flex items-center space-x-4 text-neutral-600 dark:text-neutral-400">
          <span>Apex Mission Control <strong className="text-indigo-600 dark:text-indigo-300 font-semibold">v{appVersion || "…"}</strong></span>
          <span className="text-neutral-300 dark:text-neutral-600">|</span>
          <span>UTF-8</span>
        </div>
      </footer>

      <NewAgentModal
        open={newAgentOpen}
        onClose={() => setNewAgentOpen(false)}
        workspaces={workspaces}
        onLaunch={launchAgent}
      />
    </div>
  );
}

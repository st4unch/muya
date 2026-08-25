import React, { useState, useEffect, useRef, useCallback, useMemo, lazy, Suspense } from "react";
import { nextAcked, deriveBlinkKeys } from "./lib/blink";
import { pickNextActiveKey, newSshTabKey, addSshSession, canResumeTab } from "./lib/tabs";
import { installNoAutocorrect } from "./lib/noAutocorrect";
import appIconUrl from "./assets/app-icon.png";
import {
  Folder,
  FileCode,
  FileText,
  Image as ImageIcon,
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
  LayoutGrid,
  GripHorizontal,
  CalendarClock,
  Lock,
  Unlock,
  Pencil,
} from "lucide-react";
import BranchDAG from "./components/BranchDAG";
import AgentTerminal from "./components/Terminal";
import FileTree from "./components/FileTree";
import ChatView from "./components/ChatView";
import SessionsPage from "./components/SessionsPage";
import SessionsPanel from "./components/SessionsPanel";
const FileEditor = lazy(() => import("./components/FileEditor"));
const MarkdownView = lazy(() => import("./components/MarkdownView"));
const ImageViewer = lazy(() => import("./components/ImageViewer"));
const PdfViewer = lazy(() => import("./components/PdfViewer"));
import SessionMonitor from "./components/SessionMonitor";
import NewAgentModal, { type NewAgentSpec } from "./components/NewAgentModal";
import QueuePage from "./components/QueuePage";
import ResourcesPage from "./components/ResourcesPage";
import SshPage from "./components/SshPage";
import PrdBoard from "./components/PrdBoard";
import ScheduledPromptModal, { type ScheduledPrompt } from "./components/ScheduledPromptModal";
import SettingsModal from "./components/SettingsModal";
import { buildAgentCommand, singleQuote } from "./lib/agent";
import { invoke } from "@tauri-apps/api/core";
import { copyToClipboard } from "./lib/clipboard";
import { viewerKindFor } from "./lib/format";
import { listen } from "@tauri-apps/api/event";
import { getVersion } from "@tauri-apps/api/app";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { open as openDialog, save as saveDialog, confirm as confirmDialog } from "@tauri-apps/plugin-dialog";
import { check } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";

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
  kind: "terminal" | "editor" | "mdview" | "imgview" | "pdfview";
  cwd?: string;
  initialCommand?: string; // terminals: auto-run on spawn, e.g. `claude attach <id>`
  filePath?: string; // editors + mdview + imgview + pdfview: absolute file path
  /** This tab runs a Claude session (vs a plain shell) — drives the icon + resume. */
  isClaude?: boolean;
  /** The Claude session THIS tab was running, captured live and persisted so a
   *  restored tab resumes its own conversation (not merely the newest one). */
  sessionId?: string;
  /** Restored tab whose Claude session hasn't been resumed yet — resume on click. */
  needsResume?: boolean;
  /** The operator renamed this tab by hand — never overwrite it with the
   *  Claude session's own name. */
  userRenamed?: boolean;
  /** SSH tab: the server id to connect to. When set, the terminal spawns the
   *  `ssh` process directly via `ssh_pty_connect` (Rust builds the command and
   *  injects the stored/CyberArk password into the PTY — the secret never
   *  reaches JS) instead of running a login shell + initialCommand. */
  sshServerId?: string;
  /** open_session-opened tab (PRD agent-session-open, close-session): auto-accept the
   *  "is this folder trusted?" prompt claude shows on a cwd it's never seen before —
   *  otherwise a freshly opened session can sit stuck waiting for a keypress before
   *  it's even discoverable via `claude agents --json` for an agent to answer it. */
  autoAcceptTrust?: boolean;
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
      t.kind === "terminal"
        // Never auto-run on startup; but remember this was a Claude tab and which
        // session it held, so clicking it resumes exactly that conversation.
        // sshServerId dropped too: a restored SSH tab is an inert shell, never an
        // auto-reconnect on startup (which would re-prompt / re-inject unexpectedly).
        // Resumability is gated on `sessionId` ALONE, never on `isClaude`.
        // `isClaude` means "Claude is running in this tab RIGHT NOW" — it drives
        // the icon and the ~15s poll flips it to false the moment Claude isn't
        // running, which is precisely the state a restored tab is in. Gating a
        // DURABLE capability on that VOLATILE display flag meant: any period where
        // the poll couldn't see sessions (e.g. the v0.2.41 stale-CLI regression)
        // persisted isClaude:false onto every tab, and clicking them then silently
        // did nothing. `sessionId` is the durable fact — it is only ever written
        // from real session discovery, so its presence alone means "this tab held
        // conversation X and can rejoin it".
        ? { ...t, initialCommand: undefined, sshServerId: undefined, needsResume: canResumeTab(t) }
        : t
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

  // macOS WKWebView autocorrect/autocapitalize silently rewrites what the
  // operator types into any <input>/<textarea> (hostnames, paths, branch
  // names, SSH aliases, commands) — disable it globally, once, for the whole
  // app's lifetime. See src/lib/noAutocorrect.ts.
  useEffect(() => {
    const stop = installNoAutocorrect();
    return stop;
  }, []);

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
    // 8s (was 3s): `list_agent_sessions` spawns a `claude` subprocess each call; 3s
    // was needless churn. The subprocess now also runs on the blocking pool so it
    // never starves the tokio worker pool that fs commands share (L31).
    const t = setInterval(load, 8000);
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
    const withKind: OpenTerminal = spec.isClaude === undefined && spec.kind === "terminal"
      ? { ...spec, isClaude: /(^|\s)claude(\s|$)/.test(spec.initialCommand ?? "") }
      : spec;
    setOpenTerminals((prev) =>
      prev.some((tm) => tm.key === withKind.key) ? prev : [...prev, withKind]
    );
    setActiveTerminalKey(withKind.key);
  };

  /** Activate a tab; if it was restored from a previous run, resume ITS OWN
   *  Claude session (with --dangerously-skip-permissions) instead of leaving an
   *  empty shell. Runs once per tab — the flag clears after the command is sent. */
  const activateTerminal = (key: string) => {
    setActiveTerminalKey(key);
    const tab = openTerminalsRef.current.find((t) => t.key === key);
    if (!tab?.needsResume || !tab.sessionId) return;
    const ptyId = terminalPtyIdsRef.current[key];
    if (!ptyId) return; // shell not ready yet — try again on the next click
    setOpenTerminals((prev) =>
      prev.map((t) => (t.key === key ? { ...t, needsResume: false } : t))
    );
    void invoke("pty_write", {
      id: ptyId,
      data: `claude --resume ${tab.sessionId} --dangerously-skip-permissions\r`,
    }).catch(() => {});
  };

  /** Duplicate a terminal tab into a fresh tab, re-running its command so an SSH
   *  tab reconnects and a Claude tab re-resumes (operator chose "re-run command").
   *  Opens at the shell's CURRENT cwd (liveCwds) when known. */
  const duplicateTerminal = (key: string) => {
    const t = openTerminalsRef.current.find((x) => x.key === key);
    if (!t) return;
    const ts = Date.now();
    // A restored Claude tab has its initialCommand stripped (needsResume); rebuild
    // the resume command from its session id so "re-run" actually reconnects.
    let initialCommand = t.initialCommand;
    // Same rule as the restore gate above: `sessionId` alone decides, not the
    // volatile `isClaude` (which is false for exactly the tabs that need resuming).
    if (!initialCommand && t.sessionId)
      initialCommand = `claude --resume ${t.sessionId} --dangerously-skip-permissions`;
    const newKey = t.sshServerId ? `ssh:${t.sshServerId}:${ts}` : `term-copy-${ts}`;
    openTerminal({
      key: newKey,
      name: `${t.name} (copy)`,
      kind: "terminal",
      cwd: liveCwds[key] ?? t.cwd,
      initialCommand,
      sshServerId: t.sshServerId,
      isClaude: t.isClaude,
    });
  };

  /** Reveal a terminal's current working directory in Finder. */
  const revealTerminalInFinder = (key: string) => {
    const t = openTerminalsRef.current.find((x) => x.key === key);
    const cwd = liveCwds[key] ?? t?.cwd;
    if (cwd) void invoke("reveal_in_finder", { path: cwd }).catch(() => {});
  };

  const openTerminalForAgent = (a: AgentSession) => {
    const cwd = a.worktree && a.worktree.startsWith("/") ? a.worktree : undefined;
    if (cwd) ensureWorktreeTracked(cwd);
    const initialCommand =
      a.attachable && a.attachId ? `claude attach ${a.attachId} --dangerously-skip-permissions` : undefined;
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

  /** Default open (single-click / dispatch): markdown opens as a RENDERED read view,
   *  images/PDFs open in their own viewer (Monaco can't render them — `read_file`
   *  requires UTF-8 text), everything else opens editable in Monaco. "Open in Muya"
   *  (right-click) always routes to openEditor, so any of these can still be forced
   *  open as text on demand (unchanged pre-existing semantic for .md). */
  const openFile = (filePath: string) => {
    const kind = viewerKindFor(filePath);
    if (kind === "editor") {
      openEditor(filePath);
      return;
    }
    const prefix = kind === "mdview" ? "mdview" : kind === "imgview" ? "img" : "pdf";
    openTerminal({
      key: `${prefix}:${filePath}`,
      name: filePath.split("/").pop() || filePath,
      kind,
      filePath,
    });
  };

  const [dirtyTabs, setDirtyTabs] = useState<Record<string, boolean>>({});

  const closeTerminal = async (key: string) => {
    if (dirtyTabs[key]) {
      const tab = openTerminals.find(t => t.key === key);
      const name = tab?.name ?? key;
      const ok = await confirmDialog(
        `"${name}" dosyasında kaydedilmemiş değişiklikler var. Yine de kapat?`,
        { title: "Kaydedilmemiş Değişiklikler", kind: "warning", okLabel: "Kapat", cancelLabel: "İptal" }
      );
      if (!ok) return;
    }
    // If this was an agent-opened ssh_open session, tell the broker it's gone so a
    // later ssh_send to this id is refused (not written to a recycled/dead PTY).
    if (key.startsWith("ssh:")) void invoke("ssh_release_session", { sessionId: key }).catch(() => {});
    // Same idea for open_session tabs (PRD close-session) — release the ownership
    // entry on ANY close (agent-initiated via close_session, or the operator closing
    // it by hand), so a stale name never stays falsely "closable".
    if (key.startsWith("aopen:")) {
      // Ref, not the `openTerminals` state closure — this can run from a mount-once
      // listener (muya://close-agent-session) whose captured `openTerminals` would
      // otherwise be stale from before this tab ever existed.
      const openedTab = openTerminalsRef.current.find((t) => t.key === key);
      if (openedTab?.name) void invoke("release_agent_session", { name: openedTab.name }).catch(() => {});
    }
    setOpenTerminals((prev) => {
      // Focus a neighbouring tab of the SAME kind — closing a file must not jump
      // focus onto a terminal (where the next ⌘W would kill a Claude session). L19.
      setActiveTerminalKey((cur) => (cur === key ? pickNextActiveKey(prev, key) : cur));
      return prev.filter((tm) => tm.key !== key);
    });
    setGridKeys((prev) => prev.filter((k) => k !== key));
    setDirtyTabs((prev) => { const n = { ...prev }; delete n[key]; return n; });
  };

  // Top-level view switch: the IDE control plane vs the full Sessions page.
  const [view, setView] = useState<"control" | "sessions" | "queue" | "tools" | "prd" | "ssh" | "chat">("control");
  // Mount-on-first-visit + keep-alive (L32): a panel is rendered only once its view
  // has been visited, then stays mounted (hidden) so its state survives navigation.
  // "control" is mounted from the start (the terminals must live immediately); the
  // heavy secondary panels (Sessions/Queue/Resources/PRD/SSH/Chat) defer their mount
  // + data-fetch off startup so they don't all contend for the single JS thread and
  // slow terminal open / SSH connect / chat load.
  const [mountedViews, setMountedViews] = useState<Set<string>>(() => new Set(["control"]));
  useEffect(() => {
    setMountedViews((prev) => (prev.has(view) ? prev : new Set(prev).add(view)));
  }, [view]);
  // Action menu for a path clicked in a terminal's output.
  const [pathMenu, setPathMenu] = useState<{ resolved: string; kind: "file" | "dir"; x: number; y: number } | null>(null);
  // Right panel tab: branch matrix vs markdown viewer.
  const [rightTab, setRightTab] = useState<"branch" | "sessions">("branch");
  // Markdown file currently shown in the right panel viewer.
  // Resizable sidebar widths — persisted to localStorage.
  const [leftWidth, setLeftWidth] = useState(() => Number(localStorage.getItem("muya.leftWidth")) || 288);
  const [rightWidth, setRightWidth] = useState(() => Number(localStorage.getItem("muya.rightWidth")) || 320);
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

  // Track fullscreen state in a ref so the ESC handler can check it synchronously.
  const isFullscreenRef = useRef(false);
  useEffect(() => {
    const win = getCurrentWindow();
    void win.isFullscreen().then((fs) => { isFullscreenRef.current = fs; });
    // Resize fires on fullscreen transitions — refresh the cached state.
    const onResize = () => void win.isFullscreen().then((fs) => { isFullscreenRef.current = fs; });
    window.addEventListener("resize", onResize);

    // Double-press ESC guard: only arms when the window is already in fullscreen.
    // First ESC re-enters fullscreen to cancel the macOS exit animation;
    // second ESC within 700 ms lets the exit proceed.
    let lastEscMs = 0;
    const THRESHOLD = 700;
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      if (!isFullscreenRef.current) return; // not fullscreen — let ESC propagate normally
      // A modal/dialog is open → this ESC is meant to close IT, not exit
      // fullscreen. Re-enter fullscreen to cancel macOS's exit and let the
      // modal's own ESC handler close it. Do NOT arm the double-press exit, so
      // a following ESC still needs two presses to leave fullscreen.
      // Detect BOTH the semantic marker (role="dialog") and the app-wide modal
      // backdrop convention (a full-screen `fixed inset-0 z-50` overlay), so
      // every modal is covered without tagging each one.
      if (document.querySelector('[role="dialog"], .fixed.inset-0.z-50')) {
        void win.setFullscreen(true);
        lastEscMs = 0;
        return;
      }
      const now = Date.now();
      if (now - lastEscMs < THRESHOLD) {
        lastEscMs = 0; // second press — exit proceeds
      } else {
        lastEscMs = now;
        void win.setFullscreen(true); // re-enter to cancel the first press
      }
    };
    window.addEventListener("keydown", handleKeyDown, { capture: true });
    return () => {
      window.removeEventListener("resize", onResize);
      window.removeEventListener("keydown", handleKeyDown, { capture: true });
    };
  }, []);
  const effectiveTheme: "dark" | "light" =
    themeMode === "system" ? (systemDark ? "dark" : "light") : themeMode;
  useEffect(() => {
    localStorage.setItem("apex.theme", themeMode);
  }, [themeMode]);
  useEffect(() => {
    document.documentElement.classList.toggle("dark", effectiveTheme === "dark");
    getCurrentWindow()
      .setTheme(effectiveTheme === "dark" ? "dark" : "light")
      .catch((e) => console.warn("[apex] window setTheme failed (native title bar/menu bar may stay light):", e));
  }, [effectiveTheme]);
  // Collapsible side panels.
  const [leftOpen, setLeftOpen] = useState(true);
  const [rightOpen, setRightOpen] = useState(true);
  // Hover-reveal: while the right panel is collapsed, nudging the mouse to
  // the far right edge shows a floating Sessions flyout so terminals can be
  // switched without permanently reopening the panel.
  const [rightPeek, setRightPeek] = useState(false);

  // Drag-to-resize panels. Saves widths to localStorage when drag ends.
  const startDragPanel = (
    side: "left" | "right",
    startX: number,
    startWidth: number
  ) => {
    const onMove = (e: MouseEvent) => {
      const delta = e.clientX - startX;
      if (side === "left") {
        const w = Math.min(480, Math.max(180, startWidth + delta));
        setLeftWidth(w);
      } else {
        const w = Math.min(520, Math.max(220, startWidth - delta));
        setRightWidth(w);
      }
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      // Persist after drag ends
      setLeftWidth((w) => { localStorage.setItem("muya.leftWidth", String(w)); return w; });
      setRightWidth((w) => { localStorage.setItem("muya.rightWidth", String(w)); return w; });
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };
  // Worktrees created via New agent — tracked in the Queue alongside workspaces.
  const [worktrees, setWorktrees] = useState<string[]>(() => loadList("apex.worktrees"));
  // Bumped on a real filesystem change (notify) so views refresh immediately.
  const [fsTick, setFsTick] = useState(0);

  // Real app version from tauri.conf.json (stays in sync with the build).
  const [appVersion, setAppVersion] = useState("");
  const [updateAvailable, setUpdateAvailable] = useState<{ version: string; body: string } | null>(null);
  const [updateProgress, setUpdateProgress] = useState<string | null>(null);
  useEffect(() => {
    getVersion().then(setAppVersion).catch(() => {});
    check().then((update) => {
      if (update?.available) {
        setUpdateAvailable({ version: update.version, body: update.body ?? "" });
      }
    }).catch(() => {});
  }, []);

  useEffect(() => {
    const un = listen("fs-changed", () => setFsTick((t) => t + 1));
    return () => {
      void un.then((f) => f());
    };
  }, []);

  // ── Sequential 60-min auto-refresh coordinator ────────────────────────────
  // The 4 secondary pages are always mounted (hidden off-view) so they load
  // ONCE and no longer poll on short intervals. Instead each page registers its
  // own refresh fn here, and a single hourly timer runs them ONE AT A TIME
  // (awaited in order) so the backend is never hit by all four at once.
  const pageRefreshers = useRef<Map<string, () => Promise<void>>>(new Map());
  const registerSessionsRefresh = useCallback((fn: () => Promise<void>) => { pageRefreshers.current.set("sessions", fn); }, []);
  const registerToolsRefresh    = useCallback((fn: () => Promise<void>) => { pageRefreshers.current.set("tools", fn); }, []);
  const registerQueueRefresh    = useCallback((fn: () => Promise<void>) => { pageRefreshers.current.set("queue", fn); }, []);
  const registerPrdRefresh      = useCallback((fn: () => Promise<void>) => { pageRefreshers.current.set("prd", fn); }, []);
  useEffect(() => {
    const ORDER = ["sessions", "tools", "queue", "prd"];
    const t = setInterval(async () => {
      for (const key of ORDER) {
        const fn = pageRefreshers.current.get(key);
        if (!fn) continue; // page not ready yet — skip
        try { await fn(); } catch { /* keep going with the next page */ }
      }
    }, 60 * 60 * 1000); // 60 minutes
    return () => clearInterval(t);
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

  // Workspace root the user explicitly selected in the tree. New terminals and
  // agents open here (falls back to the active terminal's cwd, then first workspace).
  const [selectedRoot, setSelectedRoot] = useState<string | undefined>(
    () => localStorage.getItem("apex.selectedRoot") || undefined
  );
  useEffect(() => {
    if (selectedRoot) localStorage.setItem("apex.selectedRoot", selectedRoot);
  }, [selectedRoot]);
  // Drop the selection if its workspace was removed.
  useEffect(() => {
    if (selectedRoot && !trackedPaths.includes(selectedRoot)) setSelectedRoot(undefined);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [trackedPaths.join("|")]);

  // Adds a session's cwd to the worktree panel if not already tracked.
  const ensureWorktreeTracked = (cwd: string) => {
    if (!trackedPaths.includes(cwd)) {
      setWorktrees((prev) => [...new Set([...prev, cwd])]);
    }
  };

  // Files opened OUTSIDE any tracked workspace/worktree root (OS "Open With Muya",
  // clicking a path in terminal output, a startup file-association open, …) fall
  // outside the notify watcher's roots — an external edit to them never fires
  // `fs-changed`, so Monaco silently keeps showing the stale content. Rather than
  // remembering to call a tracker at every openEditor()/openFile() call site (the
  // actual bug — some forgot to), derive the extra watch paths straight from the
  // open tabs: it self-heals for every current and future call site, including
  // tabs restored from a previous session. Deliberately NOT folded into
  // `trackedPaths` — that also drives the ssh_scp local-path guardrail and the
  // sidebar's workspace list, and an incidentally-opened file shouldn't widen
  // either of those.
  const openedFilePaths = useMemo(
    () => [
      ...new Set(
        openTerminals
          .filter((t): t is OpenTerminal & { filePath: string } =>
            (t.kind === "editor" || t.kind === "mdview") && Boolean(t.filePath),
          )
          .map((t) => t.filePath)
          .filter((p) => !trackedPaths.some((root) => p === root || p.startsWith(`${root}/`))),
      ),
    ],
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [openTerminals, trackedPaths.join("|")],
  );

  // Watch tracked projects in real time (notify); refresh views on change.
  useEffect(() => {
    void invoke("start_watching", { paths: [...trackedPaths, ...openedFilePaths] }).catch(() => {});
    // Mirror the same tracked paths to the Rust side as the `ssh_scp` MCP tool's
    // local-filesystem guardrail (PRD ssh-scp, AC3): agents may only read/write
    // localPath inside one of these roots. No secret involved — plain folder paths.
    // Deliberately excludes `openedFilePaths` — that would widen the guardrail to
    // wherever the operator happened to click a file, not a chosen workspace.
    void invoke("set_workspace_roots", { roots: trackedPaths }).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspaces, worktrees, openedFilePaths.join("|")]);

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
  // Native File > Close Tab (⌘W/Ctrl+W via CmdOrCtrl accelerator): the backend owns
  // this shortcut (so it never closes the window) and emits "menu:close-tab". Closes
  // the active tab — terminal or editor — same as clicking that tab's own X button
  // (no confirmation for terminals, matching existing per-tab close behavior; editor
  // tabs still get the unsaved-changes prompt via closeTerminal's dirtyTabs check).
  // No-op when none is open (the app then only quits via ⌘Q / the red close button).
  // Subscribe once, read latest active key via a ref — same pattern as ⌘N above.
  const activeKeyRef = useRef(activeTerminalKey);
  const openTerminalsRef = useRef(openTerminals);
  openTerminalsRef.current = openTerminals;
  const tabScrollRef = useRef<HTMLDivElement>(null);
  const tabDragFromRef = useRef<string | null>(null);
  const [tabDragOver, setTabDragOver] = useState<string | null>(null);
  const [renamingKey, setRenamingKey] = useState<string | null>(null);
  // Layout lock: true = locked (rename enabled, drag disabled), false = unlocked (drag enabled, rename disabled)
  const [layoutLocked, setLayoutLocked] = useState(true);
  const layoutLockedRef = useRef(true);
  useEffect(() => { layoutLockedRef.current = layoutLocked; }, [layoutLocked]);

  // Pointer-based tab drag (works in WKWebView unlike HTML5 DnD)
  const tabDragOverRef = useRef<string | null>(null);
  const tabDragHappenedRef = useRef(false);
  useEffect(() => {
    const onMove = (e: MouseEvent) => {
      if (!tabDragFromRef.current) return;
      tabDragHappenedRef.current = true;
      const el = document.elementFromPoint(e.clientX, e.clientY);
      const tabEl = el?.closest("[data-tabkey]") as HTMLElement | null;
      const overKey = tabEl?.dataset.tabkey ?? null;
      const next = overKey !== tabDragFromRef.current ? overKey : null;
      if (next !== tabDragOverRef.current) {
        tabDragOverRef.current = next;
        setTabDragOver(next);
      }
    };
    const onUp = () => {
      const from = tabDragFromRef.current;
      const to = tabDragOverRef.current;
      tabDragFromRef.current = null;
      tabDragOverRef.current = null;
      setTabDragOver(null);
      if (from && to && from !== to) {
        setOpenTerminals(prev => {
          const next = [...prev];
          const fi = next.findIndex(t => t.key === from);
          const ti = next.findIndex(t => t.key === to);
          if (fi !== -1 && ti !== -1) { const [m] = next.splice(fi, 1); next.splice(ti, 0, m); }
          return next;
        });
      }
      // Reset after click fires (click comes right after mouseup)
      setTimeout(() => { tabDragHappenedRef.current = false; }, 0);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
    return () => { window.removeEventListener("mousemove", onMove); window.removeEventListener("mouseup", onUp); };
  }, []);
  const [renameValue, setRenameValue] = useState("");
  // Grid resize splits (percentage)
  const [gridColSplit, setGridColSplit] = useState(50);
  const [gridRowSplit, setGridRowSplit] = useState(50);
  const gridContainerRef = useRef<HTMLDivElement>(null);
  const gridDragFromRef = useRef<string | null>(null);
  const [gridDragOver, setGridDragOver] = useState<string | null>(null);
  activeKeyRef.current = activeTerminalKey;
  useEffect(() => {
    const un = listen("menu:close-tab", () => {
      const key = activeKeyRef.current;
      const tab = openTerminalsRef.current.find(t => t.key === key);
      if (key && tab) void closeTerminal(key);
    });
    return () => {
      void un.then((f) => f());
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // First ⌘Q shows a transient "press ⌘Q again to quit" hint (VS Code style); the
  // backend's double-press guard does the actual quitting. The hint auto-hides so
  // the window match the ~700ms quit window loosely (kept longer for readability).
  const [quitHint, setQuitHint] = useState(false);
  const quitHintTimer = useRef<number | null>(null);
  useEffect(() => {
    const un = listen("menu:quit-hint", () => {
      setQuitHint(true);
      if (quitHintTimer.current) window.clearTimeout(quitHintTimer.current);
      quitHintTimer.current = window.setTimeout(() => setQuitHint(false), 2200);
    });
    return () => { void un.then((f) => f()); };
  }, []);

  // Muya > Check for Updates menu item
  useEffect(() => {
    const un = listen("menu:check-update", async () => {
      try {
        setUpdateProgress("Checking for updates...");
        setUpdateAvailable({ version: "", body: "" });
        const update = await check();
        if (update?.available) {
          setUpdateAvailable({ version: update.version, body: update.body ?? "" });
          setUpdateProgress(null);
        } else {
          setUpdateProgress("You're on the latest version.");
          setTimeout(() => { setUpdateAvailable(null); setUpdateProgress(null); }, 3000);
        }
      } catch {
        setUpdateProgress("Update check failed.");
        setTimeout(() => { setUpdateAvailable(null); setUpdateProgress(null); }, 3000);
      }
    });
    return () => { void un.then((f) => f()); };
  }, []);

  // Open a blank terminal. cwd priority: user-selected workspace root → active
  // tab's cwd → first workspace. This is why the request "open in the selected
  // workspace, not Documents" is honored.
  const openBlankTerminal = useCallback(() => {
    const cwd =
      selectedRoot ??
      openTerminals.find((t) => t.key === activeKeyRef.current)?.cwd ??
      workspaces[0] ??
      undefined;
    const key = `terminal-${Date.now()}`;
    openTerminal({ key, name: cwd ? cwd.split("/").pop() ?? "Terminal" : "Terminal", kind: "terminal", cwd });
    setView("control");
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [openTerminals, workspaces, selectedRoot]);

  // Cmd+T → open a blank terminal in the current active path
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "t" && e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey) {
        e.preventDefault();
        openBlankTerminal();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [openBlankTerminal]);

  // File association: open files passed via "Open With" or double-click in Finder.
  useEffect(() => {
    // Files opened before webview was ready (startup).
    void invoke<string[]>("get_startup_files").then((files) => {
      files.forEach((p) => { openFile(p); setView("control"); });
    });
    // Files opened while app is already running.
    const un = listen<string>("apex://open-file", (e) => {
      openFile(e.payload);
      setView("control");
    });
    return () => { void un.then((f) => f()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // OS drag-and-drop INTO the window: a dropped file opens in the editor, a dropped
  // folder is added as a workspace root. Tauri v2 captures the OS drop (dragDropEnabled
  // defaults true) and fires onDragDropEvent — the webview never sees an HTML5 drop, so
  // this listener is the only path. `dropActive` drives a full-window drop hint.
  const [dropActive, setDropActive] = useState(false);
  useEffect(() => {
    const webview = getCurrentWebview();
    const un = webview.onDragDropEvent(async (event) => {
      const p = event.payload;
      if (p.type === "enter" || p.type === "over") { setDropActive(true); return; }
      if (p.type === "leave") { setDropActive(false); return; }
      if (p.type === "drop") {
        setDropActive(false);
        let openedAny = false;
        for (const path of p.paths) {
          try {
            const kind = await invoke<string>("path_kind", { path });
            if (kind === "dir") {
              setWorkspaces((prev) => (prev.includes(path) ? prev : [...prev, path]));
            } else if (kind === "file") {
              openFile(path);
              openedAny = true;
            }
          } catch { /* ignore unreadable drops */ }
        }
        if (openedAny) setView("control");
      }
    });
    return () => { void un.then((f) => f()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Open an SSH server in a fresh terminal tab (fresh key per attempt so React
  // remounts a live PTY that actually re-runs ssh). Shared by the SSH page's
  // Connect button and the muya-ssh MCP broker's `ssh-broker-open` event.
  const openSshServer = useCallback((serverId: string, label: string, explicitKey?: string) => {
    // Each Connect opens a NEW, independent terminal — supporting multiple parallel
    // sessions to the same host (and to different hosts). addSshSession never filters
    // the server's existing tabs (L28); the key is unique per click. Broker-initiated
    // opens (ssh_open) pass their own session id as the key so ssh_send can target it.
    const key = explicitKey ?? newSshTabKey(serverId);
    setOpenTerminals((prev) =>
      addSshSession(prev, { key, name: label, kind: "terminal", sshServerId: serverId }),
    );
    setActiveTerminalKey(key);
    setView("control");
  }, []);

  // muya-mcp → app: agent asked to open a server by alias. Rust validated
  // opt-in + store-unlock and resolved the id; the password stays Rust-side.
  // The broker's `sessionId` becomes the tab key so a later ssh_send reaches this PTY.
  useEffect(() => {
    const un = listen<{ serverId: string; label?: string; sessionId?: string }>("ssh-broker-open", (e) => {
      const { serverId, label, sessionId } = e.payload;
      openSshServer(serverId, label || serverId, sessionId);
    });
    return () => { void un.then((f) => f()); };
  }, [openSshServer]);

  // muya-mcp → app: agent asked to open a NEW local Claude session (open_session,
  // PRD agent-session-open — the local analog of ssh_open). Reuses the exact same
  // command-building `launchAgent` uses for the "+ New Agent" button (buildAgentCommand
  // + singleQuote) so an MCP-triggered open and a UI-clicked one behave identically.
  useEffect(() => {
    const un = listen<{ name: string; cwd?: string; initialMessage?: string }>(
      "muya://open-agent-session",
      (e) => {
        const { name, cwd, initialMessage } = e.payload;
        const ws = cwd || selectedRoot || workspaces[0];
        if (!ws) return; // no workspace to run in — nothing sensible to open
        const initialCommand = buildAgentCommand({
          command: `claude --dangerously-skip-permissions --name ${singleQuote(name)}`,
          prompt: initialMessage ?? "",
          files: [],
        });
        // "aopen:" (not "ssh:"/"new:") marks this tab as MCP-opened via open_session —
        // closeTerminal uses the prefix to know it must release the broker's ownership
        // registry entry (PRD close-session) when this tab closes, by any means.
        const key = `aopen:${Date.now()}:${Math.random().toString(36).slice(2, 7)}`;
        openTerminal({ key, name, kind: "terminal", cwd: ws, initialCommand, autoAcceptTrust: true });
        setView("control");
      },
    );
    return () => { void un.then((f) => f()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedRoot, workspaces]);

  // muya-mcp → app: an agent asked to close a session IT opened with open_session
  // (close_session, PRD close-session — the broker already checked ownership before
  // emitting this). Resolve the real Claude session id to this tab's key via the same
  // sessionIdToKeyRef send_to_session(deliver:"muya") uses, then reuse closeTerminal
  // verbatim — no separate kill path.
  useEffect(() => {
    const un = listen<{ sessionId: string }>("muya://close-agent-session", (e) => {
      const key = sessionIdToKeyRef.current[e.payload.sessionId];
      if (!key) return; // not (yet) discovered as one of this app's own tabs
      void closeTerminal(key);
    });
    return () => { void un.then((f) => f()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Auto-lock the password vault after 15 minutes of no interaction ANYWHERE in
  // Muya (PRD vault-touchid-autolock) — not just while the SSH page is open, so
  // walking away from an unlocked Mac doesn't leave secrets exposed indefinitely.
  // A ref (not state) tracks last-activity so listeners never need to re-attach;
  // the 1-minute poll is cheap and avoids a setTimeout-per-keystroke reset dance.
  useEffect(() => {
    const IDLE_LOCK_MS = 15 * 60 * 1000;
    const lastActivity = { current: Date.now() };
    const bump = () => { lastActivity.current = Date.now(); };
    const events: (keyof WindowEventMap)[] = ["mousemove", "mousedown", "keydown", "wheel"];
    events.forEach((ev) => window.addEventListener(ev, bump, { passive: true }));
    const timer = window.setInterval(() => {
      if (Date.now() - lastActivity.current < IDLE_LOCK_MS) return;
      // credstore_lock is a cheap no-op when already locked — never worth guarding
      // with a status check first (that's itself an extra round-trip per tick).
      void invoke("credstore_lock").catch(() => {});
    }, 60_000);
    return () => {
      events.forEach((ev) => window.removeEventListener(ev, bump));
      window.clearInterval(timer);
    };
  }, []);

  // muya-mcp → app: one session sent a message (or raw keystrokes) to ANOTHER
  // session with send_to_session(deliver:"muya"|"keys"). "muya" wraps the text as a
  // tagged chat message the receiving Claude reads as ordinary input; "keys" (PRD
  // close-session's answer-a-prompt follow-up) types `text` VERBATIM — no wrapping —
  // for answering an interactive screen (a permission prompt, trust-folder dialog)
  // where any extra characters would be typed into the menu itself.
  useEffect(() => {
    const un = listen<{ sessionId: string; text: string; from?: string; raw?: boolean }>(
      "muya://deliver-message",
      (e) => {
        const { sessionId, text, from, raw } = e.payload;
        const key = sessionIdToKeyRef.current[sessionId];
        const ptyId = key ? terminalPtyIdsRef.current[key] : undefined;
        if (!ptyId) return; // target tab not open here
        const data = raw ? text : `[message${from ? ` from ${from}` : ""} via Muya] ${text}\n`;
        void invoke("pty_write", { id: ptyId, data }).catch(() => {});
      },
    );
    return () => { void un.then((f) => f()); };
  }, []);

  // muya-mcp → app: agent typed into an ssh_open terminal it owns (ssh_send). The
  // broker already checked the session id is one the agent opened; we just write the
  // text to that tab's PTY (as if the user typed it). Unknown/closed key → ignored.
  useEffect(() => {
    const un = listen<{ sessionId: string; text: string }>("ssh-broker-send", (e) => {
      const { sessionId, text } = e.payload;
      const ptyId = terminalPtyIdsRef.current[sessionId];
      if (ptyId) void invoke("pty_write", { id: ptyId, data: text }).catch(() => {});
    });
    return () => { void un.then((f) => f()); };
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

  // PTY id map: terminalKey → ptyId (populated by onPtyReady callbacks)
  const [terminalPtyIds, setTerminalPtyIds] = useState<Record<string, string>>({});

  // Scheduled prompts
  const [scheduledPrompts, setScheduledPrompts] = useState<ScheduledPrompt[]>([]);
  const [scheduleOpen, setScheduleOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);

  // Native Muya > Settings… (⌘,): the backend menu emits "menu:settings".
  // Opening the modal (a `fixed inset-0 z-50` + role="dialog" overlay) also lets
  // the Terminal key-guard suppress PTY input while it is open. Subscribe once.
  useEffect(() => {
    const un = listen("menu:settings", () => setSettingsOpen(true));
    return () => {
      void un.then((f) => f());
    };
  }, []);

  // Always-fresh refs so the timer closure never goes stale.
  const scheduledPromptsRef = useRef(scheduledPrompts);
  useEffect(() => { scheduledPromptsRef.current = scheduledPrompts; }, [scheduledPrompts]);
  /** claude session id → tab key, kept fresh by the session poll (message delivery). */
  const sessionIdToKeyRef = useRef<Record<string, string>>({});
  const terminalPtyIdsRef = useRef(terminalPtyIds);
  useEffect(() => { terminalPtyIdsRef.current = terminalPtyIds; }, [terminalPtyIds]);

  // Live working directory per terminal key. The list must show where each shell
  // IS now (after the user `cd`s), not the directory it was spawned in. One
  // backend call covers every shell, so polling cost doesn't grow with tab count.
  const [liveCwds, setLiveCwds] = useState<Record<string, string>>({});
  // The cwd probe is cheap (~10ms); the Claude-session probe spawns the CLI
  // (~180ms), so it only runs on every SESSION_EVERY-th tick.
  const SESSION_EVERY = 5; // 5 × 3s = ~15s
  const sessionTickRef = useRef(0);
  // Tab keys whose Claude session is waiting-for-input (needs an operator decision).
  const [waitingKeys, setWaitingKeys] = useState<Set<string>>(new Set());
  // Tab keys whose Claude session just STOPPED working (working → idle/stopped) —
  // a job finished. These pulse GREEN (vs orange for "needs a decision") until the
  // operator opens the tab. Detected by a status transition in the session poll.
  const [doneKeys, setDoneKeys] = useState<Set<string>>(new Set());
  // Tab keys whose Claude session is ACTIVELY working right now — their tab icon
  // pulses so "this agent is running" reads at a glance. Cleared the moment it goes
  // idle/waiting, so the animation isn't constant (only while actually working).
  const [workingKeys, setWorkingKeys] = useState<Set<string>>(new Set());
  // Previous polled session status per tab, to detect the working → done edge.
  const prevSessionStatusRef = useRef<Record<string, string>>({});
  // Waiting tabs the operator has already opened this episode — acknowledged, so
  // they stop blinking even before the ~15s poll notices the answer. Cleared for a
  // tab once it leaves the waiting set, so the NEXT prompt blinks again.
  const [ackedWaiting, setAckedWaiting] = useState<Set<string>>(new Set());
  useEffect(() => {
    setAckedWaiting((prev) => {
      const next = nextAcked(prev, activeTerminalKey, waitingKeys);
      const same = next.size === prev.size && [...next].every((k) => prev.has(k));
      return same ? prev : next;
    });
  }, [activeTerminalKey, waitingKeys]);
  // A tab blinks only while it needs a decision AND hasn't been opened yet: the
  // active tab and any acknowledged tab are excluded. Blink persists until the
  // operator makes that terminal active (i.e. goes to answer it).
  const blinkKeys = useMemo(
    () => deriveBlinkKeys(waitingKeys, activeTerminalKey, ackedWaiting),
    [waitingKeys, activeTerminalKey, ackedWaiting],
  );
  // Opening a done (green) tab clears it — you've seen that the job finished.
  useEffect(() => {
    if (!activeTerminalKey) return;
    setDoneKeys((prev) => {
      if (!prev.has(activeTerminalKey)) return prev;
      const next = new Set(prev);
      next.delete(activeTerminalKey);
      return next;
    });
  }, [activeTerminalKey]);
  // The green set the panel shows never includes the active tab.
  const doneBlinkKeys = useMemo(() => {
    if (!activeTerminalKey || !doneKeys.has(activeTerminalKey)) return doneKeys;
    const next = new Set(doneKeys);
    next.delete(activeTerminalKey);
    return next;
  }, [doneKeys, activeTerminalKey]);
  useEffect(() => {
    let cancelled = false;
    const tick = async () => {
      const entries = Object.entries(terminalPtyIdsRef.current);
      if (entries.length === 0) return;
      try {
        const byPty = await invoke<Record<string, string>>("pty_cwds", {
          ids: entries.map(([, ptyId]) => ptyId),
        });
        if (cancelled) return;
        const byKey: Record<string, string> = {};
        for (const [key, ptyId] of entries) {
          const cwd = byPty[ptyId];
          if (cwd) byKey[key] = cwd;
        }
        // Only write when a path actually changed — a fresh object every tick
        // would re-render this whole (large) component every 3s for nothing.
        setLiveCwds((prev) => {
          const keys = Object.keys(byKey);
          const same =
            keys.length === Object.keys(prev).length &&
            keys.every((k) => prev[k] === byKey[k]);
          return same ? prev : byKey;
        });

        // The session probe shells out to the Claude CLI (~180ms), so it must NOT
        // ride the fast cwd tick — run it every SESSION_EVERY ticks instead.
        sessionTickRef.current = (sessionTickRef.current + 1) % SESSION_EVERY;
        if (sessionTickRef.current !== 0) return;
        const byPtySession = await invoke<Record<string, { id: string; name: string; status: string }>>(
          "pty_session_ids", { ids: entries.map(([, ptyId]) => ptyId) });
        if (cancelled) return;
        // Tabs whose Claude session is paused waiting for the operator — the
        // TERMINALS panel blinks these so a decision isn't missed.
        const waiting = new Set<string>();
        const working = new Set<string>();
        for (const [key, ptyId] of entries) {
          const st = byPtySession[ptyId]?.status;
          if (st === "waiting-for-input") waiting.add(key);
          else if (st === "working") working.add(key);
        }
        setWaitingKeys((prev) => {
          const same = prev.size === waiting.size && [...waiting].every((k) => prev.has(k));
          return same ? prev : waiting;
        });
        setWorkingKeys((prev) => {
          const same = prev.size === working.size && [...working].every((k) => prev.has(k));
          return same ? prev : working;
        });
        // Green "job finished" edge: a tab that WAS "working" and is now "idle" or
        // "stopped" just completed → mark it done (pulses green). Starting work
        // again clears it. The active tab is never marked (you're watching it).
        setDoneKeys((prev) => {
          const next = new Set(prev);
          for (const [key, ptyId] of entries) {
            const cur = byPtySession[ptyId]?.status;
            const was = prevSessionStatusRef.current[key];
            if (cur === "working") next.delete(key);
            else if ((cur === "idle" || cur === "stopped") && was === "working" && key !== activeKeyRef.current) {
              next.add(key);
            }
          }
          const same = prev.size === next.size && [...next].every((k) => prev.has(k));
          return same ? prev : next;
        });
        for (const [key, ptyId] of entries) {
          const cur = byPtySession[ptyId]?.status;
          if (cur) prevSessionStatusRef.current[key] = cur;
        }
        const sessionByKey: Record<string, { id: string; name: string; status: string }> = {};
        for (const [key, ptyId] of entries) {
          const info = byPtySession[ptyId];
          if (info?.id) sessionByKey[key] = info;
        }
        // Reverse index (claude session id → tab key) so a message addressed to another
        // session (send_to_session, deliver:"muya") can be typed into its terminal.
        const byId: Record<string, string> = {};
        for (const [key, info] of Object.entries(sessionByKey)) byId[info.id] = key;
        sessionIdToKeyRef.current = byId;
        // `isClaude` reflects whether Claude is RUNNING in the tab RIGHT NOW —
        // it drives the icon. A polled tab with no live session flips back to the
        // terminal icon (Claude exited). `sessionId` is kept regardless so the tab
        // can still resume that conversation. Tabs not yet spawned are untouched.
        const polled = new Set(entries.map(([k]) => k));
        setOpenTerminals((prev) => {
          let changed = false;
          const next = prev.map((t) => {
            if (!polled.has(t.key)) return t;
            const info = sessionByKey[t.key];
            const running = Boolean(info);
            // Adopt Claude's session name so a name you give a session shows up LIVE
            // (no manual refresh). BUT keep the tab's OWN name when (a) you renamed it
            // in Muya (userRenamed) or (b) Claude's name is just the auto-generated
            // "<folder>-N" (which reads as the project name — the tab's original name
            // is nicer). This fixes the earlier over-correction that never adopted any
            // name, so a real rename only appeared after a Sessions refresh.
            const folder = (t.cwd ?? "").replace(/\/+$/, "").split("/").pop() ?? "";
            const looksAutoName =
              !!info?.name &&
              folder !== "" &&
              new RegExp(`^${folder.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}-\\d+$`).test(info!.name);
            const name =
              running && info!.name && !t.userRenamed && !looksAutoName ? info!.name : t.name;
            const sessionId = running ? info!.id : t.sessionId;
            if (t.isClaude === running && t.name === name && t.sessionId === sessionId) return t;
            changed = true;
            return { ...t, isClaude: running, name, sessionId };
          });
          return changed ? next : prev;
        });
      } catch {
        /* probe unavailable — list falls back to the spawn cwd, resume stays as-is */
      }
    };
    void tick();
    const t = setInterval(() => { if (!document.hidden) void tick(); }, 3000);
    return () => { cancelled = true; clearInterval(t); };
  }, []);

  // Timer: check every 2s for due scheduled prompts.
  // Side-effects (pty_write) run BEFORE state update — never inside a state updater.
  useEffect(() => {
    const tick = setInterval(() => {
      const now = Date.now();
      const due = scheduledPromptsRef.current.filter(p => !p.fired && p.scheduledAt <= now);
      if (due.length === 0) return;
      for (const p of due) {
        for (const key of p.terminalKeys) {
          const ptyId = terminalPtyIdsRef.current[key];
          if (!ptyId) continue;
          // BUG FIX: writing `prompt + "\r"` as ONE chunk gets wrapped in the
          // TUI's bracketed-paste, where \r is a literal newline (NOT submit) —
          // so the prompt was typed but never sent. Write the text first, then
          // send Enter as a SEPARATE keypress after the paste settles.
          void invoke("pty_write", { id: ptyId, data: p.prompt });
          const id = ptyId;
          setTimeout(() => { void invoke("pty_write", { id, data: "\r" }); }, 150);
        }
      }
      setScheduledPrompts(prev =>
        prev.map(p => (p.fired || p.scheduledAt > now ? p : { ...p, fired: true }))
      );
    }, 2000);
    return () => clearInterval(tick);
  }, []); // stable — reads only via refs

  // New-agent modal (app-managed: optional git worktree + command in a PTY).
  const [newAgentOpen, setNewAgentOpen] = useState(false);

  const launchAgent = async (spec: NewAgentSpec) => {
    const ws = spec.workspace || selectedRoot || workspaces[0];
    if (!ws) throw new Error("Pick a workspace first (+ Workspace).");
    let cwd = ws;
    if (spec.type === "claude" && spec.branch.trim()) {
      cwd = await invoke<string>("create_worktree", { repo: ws, branch: spec.branch.trim() });
      setWorktrees((prev) => (prev.includes(cwd) ? prev : [...prev, cwd]));
    }
    const initialCommand = spec.type === "claude" ? buildAgentCommand(spec) : undefined;
    const defaultName = spec.title.trim() || spec.branch.trim() || ws.split("/").filter(Boolean).pop() || (spec.type === "claude" ? "agent" : "terminal");
    openTerminal({
      key: `new:${Date.now()}`,
      name: defaultName,
      kind: "terminal",
      cwd,
      initialCommand,
    });
    setView("control");
  };

  // LIVE: branch topology for ALL workspace repos.
  // Each workspace that is a git repo gets its own branch list, keyed by path.
  const [branchMap, setBranchMap] = useState<Record<string, GitBranchState[]>>({});
  const [selectedBranchRepo, setSelectedBranchRepo] = useState<string>("");

  // Derive stable repo list from workspaces (only real paths).
  const repoList = workspaces.filter((w) => w.startsWith("/"));

  // Auto-select first repo or agent's worktree if nothing selected.
  const selectedAgentWorktree = agents.find((a) => a.id === selectedAgentId)?.worktree;
  const branchRepo =
    selectedBranchRepo ||
    (selectedAgentWorktree && selectedAgentWorktree.startsWith("/")
      ? selectedAgentWorktree
      : repoList[0] ?? "");

  useEffect(() => {
    if (!repoList.length) return;
    let active = true;
    const load = () => {
      if (document.hidden) return;
      for (const repo of repoList) {
        invoke<GitBranchState[]>("list_branches", { repo })
          .then((b) => {
            if (active) setBranchMap((prev) => ({ ...prev, [repo]: b }));
          })
          .catch(() => {});
      }
    };
    load();
    // 20s (was 5s) and NO `fsTick` dep: `git branch` per repo is a subprocess, and
    // having fsTick in the deps re-fired this whole burst on EVERY file change —
    // during active editing that was a git-subprocess storm (~20% CPU + stutter,
    // seen in a live sample). The interval is enough to keep branch data fresh. (L31)
    const t = setInterval(load, 20000);
    return () => {
      active = false;
      clearInterval(t);
    };
  }, [repoList.join(",")]);

  // branchList for the currently viewed repo (backwards compat with BranchDAG + cards).
  const branchList = branchMap[branchRepo] ?? [];

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
    // 20s (was 5s) and NO `fsTick` dep: pm_collisions runs `git` per worktree
    // (pm::status_for → pm::git in the sample = the top CPU cost). fsTick in the deps
    // re-fired it on every file change → subprocess storm while editing. (L31)
    const t = setInterval(load, 20000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspaces, worktrees]);

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
  // branchList is now derived from branchMap[branchRepo] above (multi-repo support).

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

    setBranchMap((prev) => ({ ...prev, [branchRepo]: [newWip, ...(prev[branchRepo] ?? [])] }));
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
        setBranchMap((prev) => ({
          ...prev,
          [branchRepo]: [
            ...(prev[branchRepo] ?? []).filter((b: GitBranchState) => !isSynth(b)),
            ...Array.from({ length: n }, (_, i) => synth(i)),
          ],
        })),
      resetBranches: () =>
        setBranchMap((prev) => ({
          ...prev,
          [branchRepo]: (prev[branchRepo] ?? []).filter((b: GitBranchState) => !isSynth(b)),
        })),
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
          <span className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[9px] font-mono font-bold bg-emerald-50 dark:bg-green-900/30 text-emerald-700 dark:text-green-400 border border-emerald-250 dark:border-green-700 shrink-0">
            <span className="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse shrink-0" />
            <span>SYNCED</span>
          </span>
        );
      case "ahead":
        return (
          <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[9px] font-mono font-bold bg-indigo-50 dark:bg-indigo-900/30 text-indigo-700 dark:text-indigo-400 border border-indigo-200 dark:border-indigo-600 shrink-0">
            <span className="w-1.5 h-1.5 rounded-full bg-indigo-500 shrink-0" />
            <span>AHEAD</span>
          </span>
        );
      case "diverged":
        return (
          <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[9px] font-mono font-bold bg-amber-50 dark:bg-amber-900/25 text-amber-700 dark:text-amber-400 border border-amber-250 dark:border-amber-600 shrink-0 animate-pulse">
            <AlertTriangle className="h-2.5 w-2.5 text-amber-500 dark:text-amber-400 shrink-0" />
            <span>DIVERGED</span>
          </span>
        );
      case "conflict":
        return (
          <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[9px] font-mono font-bold bg-rose-50 dark:bg-red-900/30 text-rose-750 dark:text-red-400 border border-rose-250 dark:border-red-700 shrink-0 animate-bounce">
            <AlertTriangle className="h-2.5 w-2.5 text-rose-500 dark:text-red-400 shrink-0" />
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
    <div id="vs-ctrl-plane" className="min-h-screen bg-neutral-50 dark:bg-[#25272b] text-neutral-800 dark:text-neutral-200 flex flex-col font-sans select-none overflow-hidden h-screen text-xs">

      {/* OS drag-drop hint: shown while a file/folder is dragged over the window. */}
      {dropActive && (
        <div className="fixed inset-0 z-[10000] flex items-center justify-center bg-indigo-500/10 backdrop-blur-[1px] pointer-events-none">
          <div className="px-6 py-4 rounded-xl border-2 border-dashed border-indigo-400 dark:border-indigo-300 bg-white/90 dark:bg-neutral-900/90 text-indigo-700 dark:text-indigo-300 font-mono text-sm shadow-xl">
            Drop to open — file → editor · folder → workspace
          </div>
        </div>
      )}

      {/* ================= TOP CUSTOM VS CODE STATUS BRANDING BAR ================= */}
      <header className="h-10 border-b border-neutral-200 dark:border-[#3d3f44] bg-white dark:bg-[#1e1f23] px-3 flex items-center justify-between shrink-0 select-none shadow-sm">
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
            <span className="font-semibold text-neutral-900 dark:text-neutral-100 font-display">Muya</span>
          </div>
        </div>

        {/* Primary navigation */}
        <div className="hidden md:flex items-center space-x-1 text-[11px] font-mono">
          <button
            type="button"
            onClick={() => setView("control")}
            className={`px-2.5 py-1 rounded transition-colors cursor-pointer ${
              view === "control"
                ? "bg-indigo-600 dark:bg-indigo-500 text-white font-bold border border-indigo-700 dark:border-indigo-400 shadow-sm"
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
                ? "bg-indigo-600 dark:bg-indigo-500 text-white font-bold border border-indigo-700 dark:border-indigo-400 shadow-sm"
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
                ? "bg-indigo-600 dark:bg-indigo-500 text-white font-bold border border-indigo-700 dark:border-indigo-400 shadow-sm"
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
                ? "bg-indigo-600 dark:bg-indigo-500 text-white font-bold border border-indigo-700 dark:border-indigo-400 shadow-sm"
                : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
            }`}
          >
            Resources
          </button>
          <button
            type="button"
            onClick={() => setView("prd")}
            className={`px-2.5 py-1 rounded transition-colors cursor-pointer ${
              view === "prd"
                ? "bg-indigo-600 dark:bg-indigo-500 text-white font-bold border border-indigo-700 dark:border-indigo-400 shadow-sm"
                : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
            }`}
          >
            Kanban
          </button>
          <button
            type="button"
            onClick={() => setView("ssh")}
            className={`px-2.5 py-1 rounded transition-colors cursor-pointer ${
              view === "ssh"
                ? "bg-indigo-600 dark:bg-indigo-500 text-white font-bold border border-indigo-700 dark:border-indigo-400 shadow-sm"
                : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
            }`}
          >
            SSH
          </button>
          <button
            type="button"
            onClick={() => setView("chat")}
            className={`px-2.5 py-1 rounded transition-colors cursor-pointer ${
              view === "chat"
                ? "bg-indigo-600 dark:bg-indigo-500 text-white font-bold border border-indigo-700 dark:border-indigo-400 shadow-sm"
                : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
            }`}
          >
            Chat
          </button>
        </div>

        {/* System telemetry ticks right side */}
        <div className="flex items-center space-x-4 font-mono text-[10px] text-neutral-600 dark:text-neutral-400">
          <div className="flex items-center space-x-1.5">
            <Cpu className="h-3 w-3 text-emerald-600 dark:text-green-400" />
            <span>CPU:</span>
            <span className={cpuUsage > 75 ? "text-rose-600 dark:text-red-400" : "text-emerald-600 dark:text-green-400 font-bold"}>
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

      {/* Update banner */}
      {updateAvailable && (
        <div className="px-4 py-2 bg-indigo-50 dark:bg-indigo-900/30 border-b border-indigo-200 dark:border-indigo-800 flex items-center justify-between text-[11px] font-mono">
          <span className="text-indigo-700 dark:text-indigo-300">
            {updateProgress ?? `New version available: v${updateAvailable.version}`}
          </span>
          {!updateProgress && (
            <div className="flex items-center gap-2">
              <button
                type="button"
                onClick={async () => {
                  try {
                    setUpdateProgress("Downloading...");
                    const update = await check();
                    if (update?.available) {
                      await update.downloadAndInstall((e) => {
                        if (e.event === "Started") setUpdateProgress(`Downloading (${((e.data as { contentLength?: number }).contentLength ?? 0) / 1024 / 1024 | 0} MB)...`);
                        else if (e.event === "Finished") setUpdateProgress("Installing...");
                      });
                      setUpdateProgress("Restarting...");
                      await relaunch();
                    }
                  } catch (err) {
                    // Keep the failure on screen (no auto-dismiss) and log it —
                    // a 5s toast hid the only clue about why updates fail.
                    console.error("[muya] update failed:", err);
                    const detail = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
                    setUpdateProgress(`Update failed — ${detail}`);
                  }
                }}
                className="px-2 py-0.5 bg-indigo-600 text-white rounded cursor-pointer hover:bg-indigo-700 transition-colors"
              >
                Update now
              </button>
              <button
                type="button"
                onClick={() => setUpdateAvailable(null)}
                className="text-indigo-400 hover:text-indigo-600 dark:hover:text-indigo-200 cursor-pointer"
              >
                <X className="h-3.5 w-3.5" />
              </button>
            </div>
          )}
        </div>
      )}

      {/* ================= MAIN AREA: secondary pages (ALWAYS mounted, hidden off-view) =================
          These 4 pages used to be conditionally rendered, so navigating away unmounted them and
          navigating back remounted them → a fresh fetch on every click. They are now always mounted
          and hidden (same pattern as SSH / Chat / Control below), so they load ONCE and refresh only
          via their manual Refresh button or the hourly sequential coordinator above. */}
      <div className={`flex-1 flex overflow-hidden ${view !== "sessions" ? "hidden" : ""}`}>
        {mountedViews.has("sessions") && (
          <SessionsPage
            onRegisterRefresh={registerSessionsRefresh}
            onOpen={(spec) => {
              if (spec.cwd) ensureWorktreeTracked(spec.cwd);
              openTerminal({ ...spec, kind: "terminal" });
              setView("control");
            }}
          />
        )}
      </div>
      <div className={`flex-1 flex overflow-hidden ${view !== "tools" ? "hidden" : ""}`}>
        {mountedViews.has("tools") && (
          <ResourcesPage
            onRegisterRefresh={registerToolsRefresh}
            onOpenTerminal={(spec) => {
              openTerminal({ ...spec, kind: "terminal" });
              setView("control");
            }}
          />
        )}
      </div>
      <div className={`flex-1 flex overflow-hidden ${view !== "queue" ? "hidden" : ""}`}>
        {mountedViews.has("queue") && (
          <QueuePage
            paths={trackedPaths}
            worktrees={worktrees}
            refreshSignal={fsTick}
            onRegisterRefresh={registerQueueRefresh}
            onWorktreeRemoved={(p) => setWorktrees((prev) => prev.filter((x) => x !== p))}
            inspect={branchInspect}
            onClearInspect={() => setBranchInspect(null)}
          />
        )}
      </div>
      <div className={`flex-1 flex overflow-hidden ${view !== "prd" ? "hidden" : ""}`}>
        {mountedViews.has("prd") && (
          <PrdBoard
            // Scan every known project root, not just user-added `workspaces`: agents
            // run in git WORKTREES and drop their PRDs in the worktree's docs/, so a
            // PRD created by an agent was invisible in the Kanban unless that worktree
            // happened to be a workspace. Union in worktrees + live agent cwds.
            workspaces={[...new Set([
              ...workspaces,
              ...worktrees,
              ...agents.map((a) => a.worktree).filter(Boolean),
            ])].filter((w) => w.startsWith("/")).sort()}
            onRegisterRefresh={registerPrdRefresh}
            onOpenFile={(path) => {
              openEditor(path);
              setView("control");
            }}
          />
        )}
      </div>
      {/* SSH config page — mounted on first visit, then kept alive (hidden off-view)
          so an in-progress add/edit-server form (or CyberArk session) survives
          navigation. Deferred off startup so its load doesn't contend (L32). */}
      <div className={`flex-1 flex overflow-hidden ${view !== "ssh" ? "hidden" : ""}`}>
        {mountedViews.has("ssh") && <SshPage onConnect={openSshServer} />}
      </div>
      {/* Claude-to-Claude chat bridge — mounted on first visit, then kept alive so an
          active pairing / conversation survives navigation. Its bridge data-fetches
          (peers/inbound/local_ip) no longer run at app startup (L32). */}
      <div className={`flex-1 flex overflow-hidden ${view !== "chat" ? "hidden" : ""}`}>
        {mountedViews.has("chat") && <ChatView />}
      </div>
      {/* Control plane — ALWAYS mounted; hidden (not unmounted) on other views so the
          terminal PTYs and any running sessions survive page navigation. xterm guards
          0×0 resize (Terminal.tsx), so display:none is safe. */}
      <div className={`flex-1 flex overflow-hidden ${view !== "control" ? "hidden" : ""}`}>

        {/* ----------------- Panel 1: LEFT SIDEBAR (File Tree Explorer & Workspace Locker) ----------------- */}
        {leftOpen && (
        <aside id="tree-explorer-sidebar" style={{ width: leftWidth }} className="border-r border-neutral-200 dark:border-[#3d3f44] bg-white dark:bg-[#25272b] flex flex-col shrink-0 overflow-hidden relative">
          
          {/* Header Title bar */}
          <div className="p-3 border-b border-neutral-200 dark:border-[#3d3f44] flex items-center justify-between bg-neutral-50/50 dark:bg-[#1e1f23]">
            <h2 className="text-[10px] font-mono tracking-widest uppercase font-bold text-neutral-500 dark:text-neutral-400 flex items-center gap-1.5">
              <Folder className="h-3.5 w-3.5 text-indigo-500 dark:text-indigo-400" /> Workspace Files ({trackedPaths.length})
            </h2>
            <button
              type="button"
              onClick={addWorkspace}
              title="Add project / workspace folder"
              className="text-[10px] font-mono font-bold px-1.5 py-0.5 rounded border border-indigo-700 dark:border-indigo-400 bg-indigo-600 dark:bg-indigo-500 text-white hover:bg-indigo-700 dark:hover:bg-indigo-400 cursor-pointer transition-colors shadow-sm"
            >
              + Workspace
            </button>
          </div>

          {/* Real, lazy file tree over the user's workspace roots (backend list_dir) */}
          <div className="flex-1 overflow-y-auto">
            <FileTree
              roots={trackedPaths}
              removableRoots={new Set(trackedPaths)}
              onOpenFile={(path) => {
                // Single-click: markdown opens as a RENDERED read view; other files
                // open editable in Monaco. (openFile branches on the extension.)
                openFile(path);
                setView("control");
              }}
              onOpenFileEditable={(path) => {
                // Right-click "Open in Muya" always opens editable in Monaco, even
                // for markdown.
                openEditor(path);
                setView("control");
              }}
              onRemoveRoot={(path) => {
                setWorkspaces((prev) => prev.filter((w) => w !== path));
                setWorktrees((prev) => prev.filter((w) => w !== path));
              }}
              onOpenTerminalHere={(cwd) => {
                const key = `term-${Date.now()}`;
                openTerminal({ key, name: cwd.split("/").pop() ?? "Terminal", kind: "terminal", cwd });
                setView("control");
              }}
              onOpenClaudeHere={(cwd) => {
                // Open a terminal in the folder and launch Claude straight away.
                // isClaude is derived from the command by openTerminal.
                const key = `claude-${Date.now()}`;
                openTerminal({
                  key,
                  name: cwd.split("/").pop() ?? "Claude",
                  kind: "terminal",
                  cwd,
                  initialCommand: "claude --dangerously-skip-permissions",
                });
                setView("control");
              }}
              onAddAtRef={(_path) => {
                // clipboard already written inside FileTree
              }}
              agents={agents}
              activeCwd={openTerminals.find((t) => t.key === activeTerminalKey)?.cwd}
              selectedRoot={selectedRoot}
              onSelectRoot={(r) => setSelectedRoot((prev) => (prev === r ? undefined : r))}
              refreshSignal={fsTick}
            />
          </div>


          {/* BOTTOM ATTACHMENT: ACTIVE CLAUDE AGENT FILE-WATCHER */}
          <div className="border-t border-neutral-200 dark:border-[#3d3f44] bg-neutral-50/50 dark:bg-[#1e1f23] p-3 select-none">
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
                    className="bg-rose-50 dark:bg-red-900/25 border border-rose-200 dark:border-red-800 rounded p-2 text-[10px] font-mono shadow-sm"
                  >
                    <div className="flex items-center gap-1.5 text-rose-700 dark:text-red-400 font-bold">
                      <AlertTriangle className="h-3 w-3 shrink-0" />
                      <span className="truncate">{c.file}</span>
                    </div>
                    <div className="text-[9px] text-rose-600 dark:text-red-400 mt-0.5 truncate">
                      edited in: {c.worktrees.join(" · ")}
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <div className="p-3 bg-white dark:bg-[#2d2f34] rounded border border-neutral-200 dark:border-neutral-700 text-center shadow-sm">
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
        {/* Left resize handle */}
        {leftOpen && (
          <div
            onMouseDown={(e) => startDragPanel("left", e.clientX, leftWidth)}
            className="w-1 shrink-0 cursor-col-resize hover:bg-indigo-400/40 active:bg-indigo-400/60 transition-colors z-10"
          />
        )}

        {/* ----------------- Panel 2: CENTER WORKSPACE (Sessions Agent Board + Multi-Console PTY) ----------------- */}
        <section className="flex-1 flex flex-col overflow-hidden bg-neutral-50/50 dark:bg-[#25272b]">

          {/* CENTER: Persistent per-session terminals + editors (session monitor moved
              to the right panel's Sessions tab) */}
          <div className="flex-1 flex flex-col overflow-hidden bg-white dark:bg-[#25272b]">

            {/* Dynamic terminal tabs — one per open session, kept alive across switches */}
            <header className="h-9 px-2 bg-neutral-50 dark:bg-[#1e1f23] border-b border-neutral-200 dark:border-[#3d3f44] flex items-center justify-between shrink-0">
              {/* Left scroll arrow */}
              <button
                type="button"
                onClick={() => { tabScrollRef.current?.scrollBy({ left: -120, behavior: "smooth" }); }}
                className="shrink-0 h-full px-0.5 text-neutral-400 dark:text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-200 cursor-pointer"
              >
                <ChevronLeft className="h-3.5 w-3.5" />
              </button>
              <div ref={tabScrollRef} className="flex items-center space-x-0.5 h-full overflow-x-auto flex-1 min-w-0 scroll-smooth" style={{ scrollbarWidth: "none" }}>
                {viewMode === "tabs" && openTerminals.filter(t => t.kind !== "terminal").length === 0 && (
                  <span className="px-2 text-[11px] font-mono text-neutral-400 dark:text-neutral-500 flex items-center gap-1.5">
                    <FileCode className="h-3.5 w-3.5" /> Open a file to add an editor tab
                  </span>
                )}
                {viewMode === "tabs" && openTerminals.filter(t => t.kind !== "terminal").map((tm) => {
                  const isActive = tm.key === activeTerminalKey;
                  const isDragging = tabDragFromRef.current === tm.key;
                  const isDragOver = tabDragOver === tm.key && tabDragFromRef.current !== tm.key;
                  return (
                    <div
                      key={tm.key}
                      data-tabkey={tm.key}
                      onMouseDown={!layoutLocked ? (e) => {
                        if ((e.target as HTMLElement).closest("button")) return;
                        e.preventDefault();
                        tabDragFromRef.current = tm.key;
                        setTabDragOver(null);
                      } : undefined}
                      onClick={() => { if (renamingKey !== tm.key && !tabDragHappenedRef.current) setActiveTerminalKey(tm.key); }}
                      className={`group flex items-center gap-1 px-2 h-full border-b-2 transition-colors shrink-0 select-none ${
                        !layoutLocked ? "cursor-grab active:cursor-grabbing" : "cursor-pointer"
                      } ${
                        isDragOver ? "border-indigo-400 bg-indigo-50 dark:bg-indigo-900/20" :
                        isDragging ? "opacity-50 border-dashed border-indigo-300" :
                        isActive
                          ? "border-indigo-600 bg-white dark:bg-[#25272b] text-indigo-950 dark:text-white font-semibold"
                          : "border-transparent text-neutral-500 dark:text-neutral-400 hover:text-neutral-800 dark:hover:text-neutral-200"
                      }`}
                    >
                      {tm.kind === "mdview" ? (
                        <FileText className="h-3.5 w-3.5 text-indigo-500 dark:text-indigo-400 shrink-0" />
                      ) : tm.kind === "imgview" || tm.kind === "pdfview" ? (
                        <ImageIcon className="h-3.5 w-3.5 text-emerald-500 dark:text-emerald-400 shrink-0" />
                      ) : (
                        <FileCode className="h-3.5 w-3.5 text-amber-500 dark:text-amber-400 shrink-0" />
                      )}

                      {renamingKey === tm.key ? (
                        <input
                          autoFocus
                          value={renameValue}
                          onChange={(e) => setRenameValue(e.target.value)}
                          onKeyDown={(e) => {
                            if (e.key === "Enter" || e.key === "Escape") {
                              if (e.key === "Enter" && renameValue.trim())
                                setOpenTerminals(prev => prev.map(t => t.key === tm.key ? { ...t, name: renameValue.trim() } : t));
                              setRenamingKey(null);
                            }
                            e.stopPropagation();
                          }}
                          onBlur={() => {
                            if (renameValue.trim())
                              setOpenTerminals(prev => prev.map(t => t.key === tm.key ? { ...t, name: renameValue.trim() } : t));
                            setRenamingKey(null);
                          }}
                          onClick={(e) => e.stopPropagation()}
                          className="text-xs font-display bg-transparent border-b border-indigo-400 outline-none w-28"
                        />
                      ) : (
                        <span className="text-xs font-display truncate max-w-[140px]">{tm.name}</span>
                      )}

                      {layoutLocked && renamingKey !== tm.key && (
                        <button
                          type="button"
                          onClick={(e) => { e.stopPropagation(); setRenamingKey(tm.key); setRenameValue(tm.name); }}
                          className="opacity-0 group-hover:opacity-100 transition-opacity text-neutral-400 hover:text-indigo-500 cursor-pointer shrink-0"
                          title="Rename"
                        >
                          <Pencil className="h-2.5 w-2.5" />
                        </button>
                      )}

                      {tm.initialCommand && <span className="h-1.5 w-1.5 rounded-full bg-emerald-500 shrink-0" />}
                      {dirtyTabs[tm.key] && <span className="h-1.5 w-1.5 rounded-full bg-amber-400 shrink-0" title="Kaydedilmemiş değişiklikler" />}

                      <button
                        type="button"
                        onClick={(e) => { e.stopPropagation(); void closeTerminal(tm.key); }}
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

                {/* New Terminal button — opens the same preset picker (NewAgentModal)
                    as the "+" button in the Sessions panel, not a blank terminal.
                    (⌘T still opens a quick blank terminal for the fast path.) */}
                <button
                  type="button"
                  title="New Terminal / Agent…"
                  onClick={() => setNewAgentOpen(true)}
                  className="flex items-center gap-0.5 px-2 py-1 rounded text-[10px] font-mono font-bold text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 hover:text-neutral-800 dark:hover:text-neutral-200 transition-colors cursor-pointer"
                >
                  <TerminalSquare className="h-3 w-3" />
                  <Plus className="h-2.5 w-2.5" />
                </button>

                {/* Scheduled Prompt button */}
                <button
                  type="button"
                  title="Scheduled Prompt"
                  onClick={() => setScheduleOpen(true)}
                  className={`flex items-center gap-1 px-2 py-1 rounded text-[10px] font-mono font-bold transition-colors cursor-pointer relative ${
                    scheduledPrompts.some(p => !p.fired)
                      ? "text-amber-600 dark:text-amber-400 hover:bg-amber-50 dark:hover:bg-amber-950/30"
                      : "text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 hover:text-neutral-800 dark:hover:text-neutral-200"
                  }`}
                >
                  <CalendarClock className="h-3 w-3" />
                  {scheduledPrompts.some(p => !p.fired) && (
                    <span className="absolute -top-0.5 -right-0.5 h-2 w-2 rounded-full bg-amber-500" />
                  )}
                </button>

                {/* Layout lock button */}
                <button
                  type="button"
                  title={layoutLocked ? "Layout kilitli — sürükle-bırak için kilidi aç" : "Layout kilitsiz — tab sırasını ayarla, sonra kilitle"}
                  onClick={() => { setLayoutLocked(l => !l); setRenamingKey(null); setTabDragOver(null); tabDragFromRef.current = null; }}
                  className={`flex items-center gap-1 px-2 py-1 rounded text-[10px] font-mono font-bold transition-colors cursor-pointer ${
                    layoutLocked
                      ? "text-neutral-400 dark:text-neutral-500 hover:bg-neutral-100 dark:hover:bg-neutral-800 hover:text-neutral-700 dark:hover:text-neutral-300"
                      : "bg-amber-100 dark:bg-amber-900/30 text-amber-700 dark:text-amber-400 border border-amber-300 dark:border-amber-700 hover:bg-amber-200 dark:hover:bg-amber-900/50"
                  }`}
                >
                  {layoutLocked ? <Lock className="h-3 w-3" /> : <Unlock className="h-3 w-3" />}
                  <span>Layout</span>
                </button>
              </div>
            </header>

            {/* Terminal surfaces — PTY instances NEVER unmount (display:none keeps them alive).
                Grid mode: CSS grid layout on the same container, no new instances. */}
            {(() => {
              const validGridKeys = gridKeys.filter(k => openTerminals.some(t => t.key === k && t.kind === "terminal")).slice(0, 4);
              const gridCount = viewMode === "grid" ? validGridKeys.length : 0;
              const colTemplate = gridCount >= 2 ? `${gridColSplit}fr ${100 - gridColSplit}fr` : "1fr";
              const rowTemplate = gridCount >= 3 ? `${gridRowSplit}fr ${100 - gridRowSplit}fr` : "1fr";
              return (
                <div
                  ref={gridContainerRef}
                  className="flex-1 overflow-hidden"
                  style={viewMode === "grid" ? {
                    position: "relative",
                    display: "grid",
                    gridTemplateColumns: colTemplate,
                    gridTemplateRows: rowTemplate,
                    gap: "6px",
                    padding: "8px",
                    background: "#09090b",
                  } : { position: "relative" }}
                  onMouseDown={viewMode === "grid" && gridCount >= 2 ? (e) => {
                    const rect = gridContainerRef.current!.getBoundingClientRect();
                    const rx = e.clientX - rect.left;
                    const ry = e.clientY - rect.top;
                    const THRESH = 10;
                    const colPx = rect.width * gridColSplit / 100;
                    const rowPx = rect.height * gridRowSplit / 100;
                    const isCol = Math.abs(rx - colPx) < THRESH;
                    const isRow = gridCount >= 3 && Math.abs(ry - rowPx) < THRESH;
                    if (!isCol && !isRow) return;
                    e.preventDefault();
                    const onMove = (ev: MouseEvent) => {
                      if (isCol) setGridColSplit(pct => Math.max(20, Math.min(80, ((ev.clientX - rect.left) / rect.width) * 100)));
                      if (isRow) setGridRowSplit(pct => Math.max(20, Math.min(80, ((ev.clientY - rect.top) / rect.height) * 100)));
                    };
                    const onUp = () => { window.removeEventListener("mousemove", onMove); window.removeEventListener("mouseup", onUp); };
                    window.addEventListener("mousemove", onMove);
                    window.addEventListener("mouseup", onUp);
                  } : undefined}
                >
                  {/* Empty state (tabs mode only) */}
                  {viewMode === "tabs" && openTerminals.length === 0 && (
                    <div className="absolute inset-0 flex items-center justify-center text-neutral-400 dark:text-neutral-500 text-xs font-mono">
                      No active tab — click a session (terminal) or open a file from the left (editor).
                    </div>
                  )}

                  {/* Grid empty slots — show "+" placeholder for unfilled positions */}
                  {viewMode === "grid" && (() => {
                    const filled = validGridKeys.length;
                    const slots = filled === 0 ? 1 : filled < 4 ? filled + 1 : 0;
                    if (slots === 0) return null;
                    return Array.from({ length: slots > 4 - filled ? 4 - filled : 1 }).map((_, i) => {
                      const slotIdx = filled + i;
                      const col = (slotIdx % 2) + 1;
                      const row = Math.floor(slotIdx / 2) + 1;
                      return (
                        <button
                          key={`empty-slot-${i}`}
                          type="button"
                          onClick={() => setNewAgentOpen(true)}
                          style={{ gridColumn: col, gridRow: row }}
                          className="flex flex-col items-center justify-center gap-2 rounded border-2 border-dashed border-neutral-700 hover:border-indigo-500 bg-neutral-900/50 hover:bg-indigo-950/20 text-neutral-600 hover:text-indigo-400 transition-colors cursor-pointer group"
                        >
                          <Plus className="h-6 w-6 group-hover:scale-110 transition-transform" />
                          <span className="text-[10px] font-mono">New Agent</span>
                        </button>
                      );
                    });
                  })()}

                  {openTerminals.map((tm) => {
                    const gridIdx = viewMode === "grid" ? validGridKeys.indexOf(tm.key) : -1;
                    const inGrid = gridIdx !== -1;
                    const isActiveTab = viewMode === "tabs" && tm.key === activeTerminalKey;
                    const show = inGrid || isActiveTab;

                    const gridCol = (gridIdx % 2) + 1;
                    const gridRow = Math.floor(gridIdx / 2) + 1;

                    if (tm.kind === "editor" || tm.kind === "mdview" || tm.kind === "imgview" || tm.kind === "pdfview") {
                      return (
                        <div
                          key={tm.key}
                          style={viewMode === "tabs"
                            ? { position: "absolute", inset: "12px", display: isActiveTab ? "flex" : "none", flexDirection: "column" }
                            : { display: "none" }}
                          className="overflow-hidden bg-white dark:bg-[#25272b] rounded-lg border border-neutral-200 dark:border-neutral-700 shadow-inner"
                        >
                          <Suspense fallback={<div className="flex-1 flex items-center justify-center text-xs text-neutral-400">Loading…</div>}>
                            {tm.kind === "mdview" ? (
                              <MarkdownView
                                filePath={tm.filePath!}
                                active={isActiveTab}
                                reloadTick={fsTick}
                                onEdit={(p) => { closeTerminal(tm.key); openEditor(p); }}
                              />
                            ) : tm.kind === "imgview" ? (
                              <ImageViewer path={tm.filePath!} />
                            ) : tm.kind === "pdfview" ? (
                              <PdfViewer path={tm.filePath!} />
                            ) : (
                              <FileEditor
                                path={tm.filePath!}
                                theme={effectiveTheme}
                                active={isActiveTab}
                                reloadTick={fsTick}
                                onDirtyChange={(d) => setDirtyTabs(prev => ({ ...prev, [tm.key]: d }))}
                              />
                            )}
                          </Suspense>
                        </div>
                      );
                    }

                    return (
                      <div
                        key={tm.key}
                        style={viewMode === "tabs"
                          ? { position: "absolute", inset: "12px", display: isActiveTab ? "flex" : "none", flexDirection: "column" }
                          : inGrid
                            ? { display: "flex", flexDirection: "column", gridColumn: gridCol, gridRow: gridRow, minWidth: 0, minHeight: 0 }
                            : { display: "none" }}
                        className={viewMode === "grid"
                          ? `overflow-hidden rounded border ${gridDragOver === tm.key ? "border-indigo-500" : "border-neutral-700"} bg-[#25272b]`
                          : "overflow-hidden bg-[#25272b] rounded-lg border border-neutral-800 shadow-inner"}
                        onDragOver={viewMode === "grid" ? (e) => { e.preventDefault(); setGridDragOver(tm.key); } : undefined}
                        onDragLeave={viewMode === "grid" ? (e) => { if (!e.currentTarget.contains(e.relatedTarget as Node)) setGridDragOver(null); } : undefined}
                        onDrop={viewMode === "grid" ? (e) => {
                          e.preventDefault();
                          const from = gridDragFromRef.current;
                          if (from && from !== tm.key) {
                            setGridKeys(prev => {
                              const next = [...prev];
                              const fi = next.indexOf(from), ti = next.indexOf(tm.key);
                              if (fi !== -1 && ti !== -1) [next[fi], next[ti]] = [next[ti], next[fi]];
                              return next;
                            });
                          }
                          gridDragFromRef.current = null; setGridDragOver(null);
                        } : undefined}
                      >
                        {/* Grid title bar with drag handle */}
                        {viewMode === "grid" && inGrid ? (
                          <div
                            draggable
                            onDragStart={(e) => { e.dataTransfer.effectAllowed = "move"; gridDragFromRef.current = tm.key; }}
                            onDragEnd={() => { gridDragFromRef.current = null; setGridDragOver(null); }}
                            className="flex items-center gap-1.5 px-2 py-1 border-b border-neutral-700 bg-neutral-900 shrink-0 select-none cursor-grab active:cursor-grabbing"
                          >
                            <GripHorizontal className="h-3 w-3 text-neutral-500 shrink-0" />
                            <Terminal className="h-3 w-3 text-indigo-400 shrink-0" />
                            <span className="text-[10px] font-mono text-neutral-300 truncate flex-1">{tm.name}</span>
                            <button type="button" onClick={() => setGridKeys(prev => prev.filter(k => k !== tm.key))} className="text-neutral-500 hover:text-rose-400 transition-colors cursor-pointer shrink-0">
                              <X className="h-3 w-3" />
                            </button>
                          </div>
                        ) : viewMode === "tabs" ? (
                          <div className="px-3 py-1 border-b border-neutral-800 text-[10px] font-mono text-neutral-400 shrink-0 truncate flex items-center justify-between">
                            <span>{tm.cwd ?? "~ (home)"}</span>
                            {tm.initialCommand && <span className="text-emerald-400">● {tm.initialCommand}</span>}
                          </div>
                        ) : null}
                        <div className="flex-1 overflow-hidden p-2">
                          <AgentTerminal
                            cwd={tm.cwd}
                            initialCommand={tm.initialCommand}
                            sshServerId={tm.sshServerId}
                            autoAcceptTrust={tm.autoAcceptTrust}
                            theme={effectiveTheme}
                            active={show}
                            onPtyReady={(ptyId) => setTerminalPtyIds(prev => ({ ...prev, [tm.key]: ptyId }))}
                            onPathMenu={(resolved, kind, x, y) => setPathMenu({ resolved, kind, x, y })}
                          />
                        </div>
                      </div>
                    );
                  })}
                </div>
              );
            })()}

          </div>
        </section>

        {/* ----------------- Panel 3: RIGHT SIDEBAR (Open Branch / WIP / PRD Release Tracker) ----------------- */}
        {/* Right resize handle */}
        {rightOpen && (
          <div
            onMouseDown={(e) => startDragPanel("right", e.clientX, rightWidth)}
            className="w-1 shrink-0 cursor-col-resize hover:bg-indigo-400/40 active:bg-indigo-400/60 transition-colors z-10"
          />
        )}

        {/* Hover-reveal Sessions flyout — right panel is collapsed, but nudging
            the mouse to the far right edge lets you pick a session without
            permanently reopening the panel. */}
        {!rightOpen && (
          <div
            className="fixed top-10 right-0 bottom-7 z-40 flex"
            onMouseEnter={() => setRightPeek(true)}
            onMouseLeave={() => setRightPeek(false)}
          >
            {rightPeek && (
              <aside className="w-[280px] bg-white dark:bg-[#25272b] border-l border-neutral-200 dark:border-[#3d3f44] shadow-2xl flex flex-col overflow-hidden">
                <div className="px-3 py-2 border-b border-neutral-200 dark:border-[#3d3f44] bg-neutral-50 dark:bg-[#1e1f23] flex items-center justify-between shrink-0">
                  <span className="text-[9px] font-mono tracking-wider uppercase font-bold text-neutral-500 dark:text-neutral-400 flex items-center gap-1">
                    <TerminalSquare className="h-3 w-3" /> Sessions
                  </span>
                  <button
                    type="button"
                    onClick={() => { setRightOpen(true); setRightTab("sessions"); setRightPeek(false); }}
                    title="Pin panel open"
                    className="text-neutral-400 hover:text-indigo-500 dark:hover:text-indigo-400 cursor-pointer"
                  >
                    <PanelRight className="h-3.5 w-3.5" />
                  </button>
                </div>
                <div className="flex-1 overflow-y-auto">
                  <SessionsPanel
                    terminals={openTerminals.filter(t => t.kind === "terminal")}
                    activeKey={activeTerminalKey}
                    terminalPtyIds={terminalPtyIds}
                    liveCwds={liveCwds}
                    waitingKeys={blinkKeys}
                    doneKeys={doneBlinkKeys}
                    workingKeys={workingKeys}
                    renamingKey={renamingKey}
                    renameValue={renameValue}
                    setRenamingKey={setRenamingKey}
                    setRenameValue={setRenameValue}
                    onActivate={(key) => { activateTerminal(key); setRightPeek(false); }}
                    onClose={(key) => { void closeTerminal(key); }}
                    onReorder={(from, to) => {
                      setOpenTerminals(prev => {
                        const next = [...prev];
                        const fi = next.findIndex(t => t.key === from);
                        if (fi === -1) return prev;
                        const [item] = next.splice(fi, 1);
                        const ti = next.findIndex(t => t.key === to);
                        if (ti === -1) { next.push(item); return next; }
                        next.splice(ti, 0, item);
                        return next;
                      });
                    }}
                    onRename={(key, name) => setOpenTerminals(prev => prev.map(t => t.key === key ? { ...t, name, userRenamed: true } : t))}
                    onNewTerminal={() => setNewAgentOpen(true)}
                    onDuplicate={duplicateTerminal}
                    onRevealInFinder={revealTerminalInFinder}
                  />
                </div>
              </aside>
            )}
            {/* Thin always-present edge sliver — hovering here triggers the reveal above. */}
            <div className="w-2 h-full" />
          </div>
        )}

        {rightOpen && (
        <aside id="branch-wip-prd-tracker" style={{ width: rightWidth }} className="border-l border-neutral-200 dark:border-[#3d3f44] bg-white dark:bg-[#25272b] flex flex-col shrink-0 overflow-hidden">

          {/* Tabbed header: sessions | markdown | branch */}
          <div className="flex border-b border-neutral-200 dark:border-[#3d3f44] bg-neutral-50 dark:bg-[#1e1f23] shrink-0">
            {(["sessions", "branch"] as const).map((tab) => (
              <button
                key={tab}
                type="button"
                onClick={() => setRightTab(tab)}
                className={`flex-1 px-2 py-2 text-[9px] font-mono tracking-wider uppercase font-bold flex items-center justify-center gap-1 border-b-2 transition-colors cursor-pointer ${
                  rightTab === tab
                    ? "border-indigo-500 text-indigo-700 dark:text-white bg-white dark:bg-[#25272b]"
                    : "border-transparent text-neutral-500 dark:text-neutral-400 hover:text-neutral-800 dark:hover:text-neutral-200"
                }`}
              >
                {tab === "sessions" && <><TerminalSquare className="h-3 w-3" /> Sessions</>}
                {tab === "branch"   && <><GitBranch className="h-3 w-3" /> Branch</>}
              </button>
            ))}
          </div>

          {rightTab === "sessions" ? (
            <SessionsPanel
              terminals={openTerminals.filter(t => t.kind === "terminal")}
              activeKey={activeTerminalKey}
              terminalPtyIds={terminalPtyIds}
                    liveCwds={liveCwds}
                    waitingKeys={blinkKeys}
                    doneKeys={doneBlinkKeys}
                    workingKeys={workingKeys}
              renamingKey={renamingKey}
              renameValue={renameValue}
              setRenamingKey={setRenamingKey}
              setRenameValue={setRenameValue}
              onActivate={(key) => { activateTerminal(key); }}
              onClose={(key) => { void closeTerminal(key); }}
              onReorder={(from, to) => {
                setOpenTerminals(prev => {
                  const next = [...prev];
                  const fi = next.findIndex(t => t.key === from);
                  if (fi === -1) return prev;
                  const [item] = next.splice(fi, 1);
                  const ti = next.findIndex(t => t.key === to); // re-find after splice
                  if (ti === -1) { next.push(item); return next; }
                  next.splice(ti, 0, item);
                  return next;
                });
              }}
              onRename={(key, name) => setOpenTerminals(prev => prev.map(t => t.key === key ? { ...t, name, userRenamed: true } : t))}
              onNewTerminal={() => setNewAgentOpen(true)}
              onDuplicate={duplicateTerminal}
              onRevealInFinder={revealTerminalInFinder}
            />
          ) : (
          <div className="flex-1 overflow-y-auto custom-scrollbar p-3 space-y-4">

            {/* Multi-repo selector */}
            {repoList.length > 1 && (
              <div className="flex items-center gap-2">
                <GitBranch className="h-3.5 w-3.5 text-indigo-500 dark:text-indigo-400 shrink-0" />
                <select
                  value={branchRepo}
                  onChange={(e) => setSelectedBranchRepo(e.target.value)}
                  className="flex-1 text-[10px] font-mono bg-white dark:bg-[#2d2f34] border border-neutral-200 dark:border-neutral-700 rounded px-2 py-1 text-neutral-700 dark:text-neutral-300 cursor-pointer"
                >
                  {repoList.map((r) => (
                    <option key={r} value={r}>
                      {r.split("/").filter(Boolean).slice(-2).join("/")}
                      {" "}({(branchMap[r] ?? []).length})
                    </option>
                  ))}
                </select>
              </div>
            )}

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
                <span className="text-[10px] font-mono uppercase tracking-widest font-bold text-emerald-600 dark:text-green-400 flex items-center gap-1">
                  <ShieldCheck className="h-3 w-3" /> Production Branches (PRD)
                </span>
                <span className="text-[9px] font-mono bg-neutral-100 dark:bg-neutral-800 text-emerald-700 dark:text-green-400 px-1 border border-neutral-250 dark:border-neutral-700 rounded font-semibold">
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
                      className="p-2 border border-emerald-100 dark:border-green-900 bg-emerald-50/10 dark:bg-green-900/20 hover:border-emerald-200 dark:hover:border-green-800 rounded cursor-pointer transition-colors shadow-sm"
                    >
                      <div className="flex items-start justify-between gap-1.5">
                        <span className="font-mono text-xs font-bold text-emerald-800 dark:text-green-400 truncate max-w-[140px]">
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
                <span className="text-[10px] font-mono uppercase tracking-widest font-semibold text-amber-600 dark:text-amber-400 flex items-center gap-1">
                  <Zap className="h-3 w-3 animate-pulse" /> Active Workspace WIP
                </span>
                <span className="text-[9px] font-mono bg-neutral-100 dark:bg-neutral-800 text-amber-700 dark:text-amber-400 px-1 border border-neutral-250 dark:border-neutral-700 rounded font-semibold">
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
                            ? "bg-amber-50/40 dark:bg-amber-900/25 border-amber-500"
                            : "border-neutral-200 dark:border-neutral-700 hover:border-neutral-300 dark:hover:border-neutral-700 bg-white dark:bg-[#25272b]"
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
                          <div className="mt-2 p-1 bg-neutral-50 dark:bg-[#2d2f34] rounded border border-neutral-200 dark:border-neutral-700 flex items-center justify-between text-[9px] font-mono text-neutral-600 dark:text-neutral-400">
                            <span className="text-indigo-650 dark:text-indigo-400 font-bold">
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
                <span className="text-[9px] font-mono bg-neutral-100 dark:bg-neutral-800 text-indigo-700 dark:text-indigo-400 px-1 border border-neutral-250 dark:border-neutral-700 rounded font-semibold">
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
                      className="p-2 border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-[#25272b] hover:border-neutral-300 dark:hover:border-neutral-600 rounded cursor-pointer transition-colors shadow-sm"
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
      <footer className="h-7 border-t border-neutral-200 dark:border-[#3d3f44] bg-white dark:bg-[#1e1f23] px-3 flex items-center justify-between z-10 shrink-0 text-[10px] font-mono text-neutral-500 dark:text-neutral-400 select-none shadow-sm">
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
            <strong className={collisionReport.collisions.length > 0 ? "text-rose-600 dark:text-red-400" : "text-neutral-700 dark:text-neutral-300"}>
              {collisionReport.collisions.length}
            </strong>
          </span>
        </div>

        <div className="flex items-center space-x-4 text-neutral-600 dark:text-neutral-400">
          <span>Muya <strong className="text-indigo-600 dark:text-indigo-400 font-semibold">v{appVersion || "…"}</strong></span>
          <span className="text-neutral-300 dark:text-neutral-600">|</span>
          <span>UTF-8</span>
        </div>
      </footer>

      <NewAgentModal
        open={newAgentOpen}
        onClose={() => setNewAgentOpen(false)}
        workspaces={[...new Set([...workspaces, ...agents.map((a) => a.worktree).filter(Boolean)])].sort()}
        defaultWorkspace={selectedRoot}
        onLaunch={launchAgent}
      />

      <SettingsModal open={settingsOpen} onClose={() => setSettingsOpen(false)} />

      <ScheduledPromptModal
        open={scheduleOpen}
        onClose={() => setScheduleOpen(false)}
        terminals={openTerminals.filter(t => t.kind === "terminal").map(t => ({ key: t.key, name: t.name }))}
        scheduled={scheduledPrompts}
        onAdd={(p) => setScheduledPrompts(prev => [...prev, { ...p, id: crypto.randomUUID(), fired: false }])}
        onEdit={(id, p) => setScheduledPrompts(prev => prev.map(sp => sp.id === id ? { ...sp, ...p, fired: false } : sp))}
        onCancel={(id) => setScheduledPrompts(prev => prev.filter(p => p.id !== id))}
      />

      {/* Transient "press ⌘Q again to quit" hint. NOT a full-screen overlay (no
          `fixed inset-0 z-50`) so it never blocks terminal input. */}
      {quitHint && (
        <div className="fixed bottom-6 left-1/2 -translate-x-1/2 z-[80] px-3 py-1.5 rounded-lg bg-neutral-900/90 dark:bg-neutral-100/90 text-neutral-100 dark:text-neutral-900 text-[11px] font-mono font-semibold shadow-2xl pointer-events-none">
          Press ⌘Q again to quit
        </div>
      )}

      {/* Action menu for a path clicked in terminal output */}
      {pathMenu && (
        <>
          <div className="fixed inset-0 z-[60]" onClick={() => setPathMenu(null)} onContextMenu={(e) => { e.preventDefault(); setPathMenu(null); }} />
          <div
            style={{ position: "fixed", top: Math.min(pathMenu.y, window.innerHeight - 160), left: Math.min(pathMenu.x, window.innerWidth - 210), zIndex: 61 }}
            className="min-w-[190px] bg-white dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-700 rounded-lg shadow-2xl py-1 text-xs font-mono"
          >
            <div className="px-3 py-1 text-[9px] text-neutral-400 dark:text-neutral-500 truncate border-b border-neutral-100 dark:border-neutral-700 mb-1" title={pathMenu.resolved}>
              {pathMenu.kind === "dir" ? "📁" : "📄"} {pathMenu.resolved.split("/").pop()}
            </div>
            {pathMenu.kind === "file" && (
              <button type="button" className="w-full text-left px-3 py-1.5 hover:bg-indigo-50 dark:hover:bg-indigo-950/40 cursor-pointer text-neutral-700 dark:text-neutral-200"
                onClick={() => { openEditor(pathMenu.resolved); setView("control"); setPathMenu(null); }}>
                Open in Muya
              </button>
            )}
            {pathMenu.kind === "dir" && (
              <button type="button" className="w-full text-left px-3 py-1.5 hover:bg-indigo-50 dark:hover:bg-indigo-950/40 cursor-pointer text-neutral-700 dark:text-neutral-200"
                onClick={() => {
                  ensureWorktreeTracked(pathMenu.resolved);
                  openTerminal({ key: `term-${Date.now()}`, name: pathMenu.resolved.split("/").pop() ?? "Terminal", kind: "terminal", cwd: pathMenu.resolved });
                  setView("control"); setPathMenu(null);
                }}>
                Open Terminal Here
              </button>
            )}
            <button type="button" className="w-full text-left px-3 py-1.5 hover:bg-indigo-50 dark:hover:bg-indigo-950/40 cursor-pointer text-neutral-700 dark:text-neutral-200"
              onClick={() => { void invoke("reveal_in_finder", { path: pathMenu.resolved }); setPathMenu(null); }}>
              Reveal in Finder
            </button>
            <button type="button" className="w-full text-left px-3 py-1.5 hover:bg-indigo-50 dark:hover:bg-indigo-950/40 cursor-pointer text-neutral-700 dark:text-neutral-200"
              onClick={() => { void copyToClipboard(pathMenu.resolved); setPathMenu(null); }}>
              Copy Path
            </button>
          </div>
        </>
      )}
    </div>
  );
}

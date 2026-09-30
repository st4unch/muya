import React, { useState, useEffect, useLayoutEffect, useRef, useCallback, useMemo, lazy, Suspense } from "react";
import { createPortal } from "react-dom";
import { pickNextActiveKey, newSshTabKey, addSshSession, canResumeTab, resumeCommand } from "./lib/tabs";
import { terminalIsVisible } from "./lib/terminalVisibility";
import { installNoAutocorrect } from "./lib/noAutocorrect";
import AgentTerminal from "./components/Terminal";
import FileTree from "./components/FileTree";
import ChatView from "./components/ChatView";
import SessionsPage from "./components/SessionsPage";
import BranchesPage from "./components/BranchesPage";
import ViewerErrorBoundary from "./components/ViewerErrorBoundary";
const FileEditor = lazy(() => import("./components/FileEditor"));
const MarkdownView = lazy(() => import("./components/MarkdownView"));
const ImageViewer = lazy(() => import("./components/ImageViewer"));
const PdfViewer = lazy(() => import("./components/PdfViewer"));
import FileAccessGate from "./components/FileAccessGate";
import NewAgentModal, { type NewAgentSpec } from "./components/NewAgentModal";
import QueuePage from "./components/QueuePage";
import ResourcesPage from "./components/ResourcesPage";
import SshPage from "./components/SshPage";
import PrdBoard from "./components/PrdBoard";
import ScheduledPromptModal, { type ScheduledPrompt } from "./components/ScheduledPromptModal";
import SettingsModal from "./components/SettingsModal";
import { buildAgentCommand, singleQuote, detectAgent, AGENT_BASE_COMMAND, type AgentKind } from "./lib/agent";
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
import { useTheme } from "./theme/theme";
import "./redesign/redesign.css";
import { ControlScreen } from "./redesign/ControlScreen";
import { GridScreen } from "./redesign/GridScreen";
import { ControlHeader } from "./redesign/ControlHeader";
import { AppFrameBody } from "./redesign/AppFrameBody";
import { Rail } from "./redesign/Rail";
import { Footer } from "./redesign/Footer";
import { BroadcastModal } from "./redesign/BroadcastModal";
import { CommandPalette } from "./redesign/CommandPalette";
import { ActivityPanel } from "./redesign/ActivityPanel";
import { AgentPickerDialog, MenuHeading, MenuItem, MenuPopover, MenuSeparator, RenameDialog, anchorFromRect, type Anchor } from "./redesign/Menus";
import { useAgentModel } from "./redesign/useAgentModel";
import { abbreviateHome, pickGridPanels, type SessionStatus } from "./redesign/agentModel";
import { adoptHosts, createHost, POOL_STYLE } from "./redesign/terminalHosts";
import type { AgentVM, ChangeVM, FileVM, GridLayout, InspectorVM, PermissionMode, RailItem } from "./redesign/types";
import type { AgentFilter } from "./redesign/AgentList";
import type { InspectorTab } from "./redesign/Inspector";
import { shouldExitGridOnEscape } from "./redesign/gridKeys";

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

// One open, persistent tab — a terminal or a file viewer. Kept alive across switches.
interface OpenTerminal {
  key: string; // unique tab id (session id, "resume:<id>", or "edit:<path>")
  name: string;
  kind: "terminal" | "editor" | "mdview" | "imgview" | "pdfview";
  cwd?: string;
  initialCommand?: string; // terminals: auto-run on spawn, e.g. `claude attach <id>`
  filePath?: string; // editors + mdview + imgview + pdfview: absolute file path
  /** This tab runs a Claude session (vs a plain shell) — drives the icon + resume.
   *  Kept alongside `agent` because it is derived, never authoritative (see
   *  src/lib/tabs.ts): a tab persisted before opencode support simply re-derives. */
  isClaude?: boolean;
  /** Which agent CLI this tab runs, when it runs one. Derived from the command the
   *  same way `isClaude` is, so no migration of persisted tabs is needed. */
  agent?: AgentKind;
  /** The Claude session THIS tab was running, captured live and persisted so a
   *  restored tab resumes its own conversation (not merely the newest one). */
  sessionId?: string;
  /** The shell's live folder when this tab's Claude session was first seen — where
   *  `claude --resume` must run (the tab's own `cwd` is only where it was opened). */
  sessionCwd?: string;
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
  /** Editor tab opened from "Review diff": start in the diff-against-HEAD view. */
  startInDiff?: boolean;
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

type View = "control" | "sessions" | "queue" | "tools" | "prd" | "ssh" | "chat" | "branches";
type Screen = "control" | "grid";

const isFileTab = (t: { kind: OpenTerminal["kind"] }) => t.kind !== "terminal";

/** Load a persisted string[] from localStorage (last-session memory). */
function loadList(key: string): string[] {
  try {
    const v = JSON.parse(localStorage.getItem(key) || "[]");
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

/** Restore open tabs. Terminals re-open as a fresh shell in their folder
 *  (initialCommand dropped so we never auto re-launch/attach). File viewers are not
 *  restored: a file is a transient view in Control's main area now, and a hidden
 *  restored viewer would have no way back on screen. */
function loadTabs(): OpenTerminal[] {
  try {
    const v = JSON.parse(localStorage.getItem("apex.openTabs") || "[]");
    if (!Array.isArray(v)) return [];
    return (v as OpenTerminal[])
      .filter((t) => t.kind === "terminal")
      .map((t) =>
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
        ({ ...t, initialCommand: undefined, sshServerId: undefined, needsResume: canResumeTab(t) }),
      );
  } catch {
    return [];
  }
}

const GRID_CAPACITY: Record<GridLayout, number> = { "1": 1, "1x2": 2, "2x2": 4, "3x2": 6 };

function readGridLayout(): GridLayout {
  const v = localStorage.getItem("muya.gridLayout");
  return v === "1" || v === "1x2" || v === "2x2" || v === "3x2" ? v : "2x2";
}

/** Modes Shift+Tab can reach, in Claude's cycle order. Bypass is a launch flag: it is
 *  not in the cycle, so it is never offered here. */
const MODE_ITEMS: { mode: PermissionMode; label: string }[] = [
  { mode: "default", label: "Manual" },
  { mode: "acceptEdits", label: "Accept edits" },
  { mode: "plan", label: "Plan" },
  { mode: "auto", label: "Auto" },
];

const PALETTE_COMMANDS = [
  { id: "new-agent", label: "New agent" },
  { id: "new-terminal", label: "New terminal" },
  { id: "control", label: "Control" },
  { id: "grid", label: "Grid" },
  { id: "sessions", label: "Sessions" },
  { id: "branches", label: "Branches" },
  { id: "queue", label: "Queue" },
  { id: "kanban", label: "Kanban" },
  { id: "resources", label: "Resources" },
  { id: "ssh", label: "SSH" },
  { id: "chat", label: "Chat" },
  { id: "settings", label: "Settings" },
  { id: "theme", label: "Cycle theme (system, light, dark)" },
  { id: "schedule", label: "Schedule prompt" },
  { id: "add-workspace", label: "Add workspace" },
];

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/** A file open in Control's main area. Module-level on purpose: declared inside App it
 *  would be a new component type every render and remount the editor under the user. */
function FileTabView({
  tab,
  theme,
  active,
  reloadTick,
  fileTick,
  onDirtyChange,
  onEditMarkdown,
}: {
  tab: OpenTerminal;
  theme: "dark" | "light";
  active: boolean;
  reloadTick: number;
  /** Bumps when THIS file changed on disk (watcher's fast `fs-files-changed` lane). */
  fileTick: number;
  onDirtyChange: (dirty: boolean) => void;
  onEditMarkdown: (path: string) => void;
}) {
  return (
    <div className="rd-legacy overflow-hidden" style={{ display: "flex", flexDirection: "column", width: "100%", height: "100%", background: "var(--bg-panel)" }}>
      <ViewerErrorBoundary label={tab.filePath ?? tab.key}>
        <Suspense fallback={<div className="flex-1 flex items-center justify-center text-xs text-neutral-400">Loading…</div>}>
          {tab.kind === "mdview" ? (
            <MarkdownView filePath={tab.filePath!} active={active} reloadTick={reloadTick} fileTick={fileTick} onEdit={onEditMarkdown} />
          ) : tab.kind === "imgview" ? (
            <ImageViewer path={tab.filePath!} />
          ) : tab.kind === "pdfview" ? (
            <PdfViewer path={tab.filePath!} />
          ) : (
            <FileEditor path={tab.filePath!} theme={theme} active={active} reloadTick={reloadTick} fileTick={fileTick} onDirtyChange={onDirtyChange} startInDiff={tab.startInDiff} />
          )}
        </Suspense>
      </ViewerErrorBoundary>
    </div>
  );
}

export default function App() {
  // Claude Agent Sessions (`claude agents --json`): feeds the file tree's agent badges,
  // the New-agent workspace list, the Kanban roots, the branch view and — where a tab's
  // cwd matches — the branch pill in the session header.
  const [agents, setAgents] = useState<AgentSession[]>([]);
  const [selectedAgentId, setSelectedAgentId] = useState<string>("");

  // Live metrics of the app process
  const [cpuUsage, setCpuUsage] = useState(0); // app process CPU %
  const [ramUsage, setRamUsage] = useState(0); // app process RAM, MB
  const [clock, setClock] = useState("");

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

  // Open, persistent tabs — one PTY per terminal, alive while you look elsewhere.
  const [openTerminals, setOpenTerminals] = useState<OpenTerminal[]>(loadTabs);
  const openTerminalsRef = useRef(openTerminals);
  openTerminalsRef.current = openTerminals;
  // The selected AGENT (a terminal tab). Files are tracked separately in viewFileKey.
  const [activeTerminalKey, setActiveTerminalKey] = useState<string | null>(() => {
    const tabs = loadTabs();
    const stored = localStorage.getItem("muya.selectedAgent");
    return tabs.find((t) => t.key === stored)?.key ?? tabs[0]?.key ?? null;
  });
  const activeKeyRef = useRef(activeTerminalKey);
  activeKeyRef.current = activeTerminalKey;
  useEffect(() => {
    if (activeTerminalKey) localStorage.setItem("muya.selectedAgent", activeTerminalKey);
  }, [activeTerminalKey]);
  // The file currently shown in Control's main area instead of the terminal.
  const [viewFileKey, setViewFileKey] = useState<string | null>(null);
  // Bumped every time the operator deliberately picks an agent (list, ⌘1–7, palette).
  // Grid terminals are all `active` at once, so a pick there would otherwise leave the
  // keyboard wherever it was.
  const [tabPickCount, setTabPickCount] = useState(0);
  const pickTab = useCallback((key: string) => {
    setActiveTerminalKey(key);
    setTabPickCount((n) => n + 1);
  }, []);

  // Screens: Control (one agent + inspector) or Grid (several agents side by side).
  // Persisted under the pre-redesign key so a saved "grid" survives the upgrade.
  const [screen, setScreen] = useState<Screen>(() => (localStorage.getItem("apex.viewMode") === "grid" ? "grid" : "control"));
  useEffect(() => {
    localStorage.setItem("apex.viewMode", screen === "grid" ? "grid" : "tabs");
  }, [screen]);
  const [gridLayout, setGridLayout] = useState<GridLayout>(readGridLayout);
  useEffect(() => {
    localStorage.setItem("muya.gridLayout", gridLayout);
  }, [gridLayout]);
  // Agents the operator chose for the grid panels, in panel order (topped up in list order).
  const [gridKeys, setGridKeys] = useState<string[]>(() => {
    try { return JSON.parse(localStorage.getItem("apex.gridKeys") ?? "[]"); } catch { return []; }
  });
  useEffect(() => {
    localStorage.setItem("apex.gridKeys", JSON.stringify(gridKeys));
  }, [gridKeys]);
  const [gridFocusedKey, setGridFocusedKey] = useState<string | null>(null);
  const layoutBeforeMaximizeRef = useRef<GridLayout | null>(null);

  const [dirtyTabs, setDirtyTabs] = useState<Record<string, boolean>>({});
  const dirtyTabsRef = useRef(dirtyTabs);
  dirtyTabsRef.current = dirtyTabs;

  // Top-level page. Control/Grid are one page ("control") with two screens.
  const [view, setView] = useState<View>("control");
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
  const showControl = useCallback(() => {
    setView("control");
    setScreen("control");
  }, []);

  // Action menu for a path clicked in a terminal's output.
  const [pathMenu, setPathMenu] = useState<{ resolved: string; kind: "file" | "dir"; x: number; y: number } | null>(null);
  // Branch picked for inspection — shown as a detail card on the Queue page.
  const [branchInspect, setBranchInspect] = useState<{ repo: string; name: string } | null>(null);
  // App-wide color theme. "system" follows the OS until the user explicitly picks
  // one. useTheme() (src/theme/theme.ts) owns the "system"/"light"/"dark"
  // preference + live prefers-color-scheme tracking, persists it under the
  // legacy "apex.theme" key, and keeps <html data-theme> + the legacy `.dark`
  // class in sync — the resolved theme drives the terminal and the Monaco
  // editor too, so one toggle themes the whole app together.
  const { preference: themeMode, resolved: effectiveTheme, setPreference: setThemeMode, cycle: cycleTheme } = useTheme();

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
  // Native title bar / menu bar theme — useTheme() only owns the web-side
  // data-theme/.dark class; the OS chrome needs its own Tauri call.
  useEffect(() => {
    getCurrentWindow()
      .setTheme(effectiveTheme === "dark" ? "dark" : "light")
      .catch((e) => console.warn("[apex] window setTheme failed (native title bar/menu bar may stay light):", e));
  }, [effectiveTheme]);

  // The inspector is dropped below 1280px (PROMPT.md §5).
  const [innerWidth, setInnerWidth] = useState(() => window.innerWidth);
  useEffect(() => {
    const onResize = () => setInnerWidth(window.innerWidth);
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

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

  // Fast lane: the watcher names the OPEN files that changed (fs-files-changed), so
  // an editor reflects an agent's write in ~150 ms instead of waiting out the tree
  // channel's 1.5 s debounce — which never ends when a busy root (e.g. the home
  // folder) keeps it open. fs-changed below stays as the safety net.
  const [fileTicks, setFileTicks] = useState<Record<string, number>>({});
  useEffect(() => {
    const un = listen<string[]>("fs-files-changed", (e) =>
      setFileTicks((prev) => {
        const next = { ...prev };
        for (const p of e.payload) next[p] = (next[p] ?? 0) + 1;
        return next;
      }),
    );
    return () => {
      void un.then((f) => f());
    };
  }, []);
  useEffect(() => {
    const un = listen("fs-changed", () => setFsTick((t) => t + 1));
    return () => {
      void un.then((f) => f());
    };
  }, []);

  // ── Sequential 60-min auto-refresh coordinator ────────────────────────────
  // The secondary pages are always mounted (hidden off-view) so they load
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

  // Workspace roots — user-picked project folders shown in the file tree.
  // Persisted to localStorage so they reload on app restart (last-session memory).
  const [workspaces, setWorkspaces] = useState<string[]>(() => loadList("apex.workspaces"));

  // All paths the PM/watcher tracks: workspaces + created worktrees.
  // Memoized: FileTree/QueuePage key their git-spawning effects on this array's
  // identity, so a fresh array per render ran `git status` on every App render.
  const trackedPaths = useMemo(
    () => [...new Set([...workspaces, ...worktrees])],
    [workspaces, worktrees],
  );

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
  // open tabs: it self-heals for every current and future call site. Deliberately
  // NOT folded into `trackedPaths` — that also drives the ssh_scp local-path
  // guardrail and the workspace list, and an incidentally-opened file shouldn't
  // widen either of those.
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

  // Tell the watcher which files are open (fast lane, see fileTicks).
  const openFilePathsKey = openTerminals
    .filter((t) => (t.kind === "editor" || t.kind === "mdview") && t.filePath)
    .map((t) => t.filePath)
    .join("\n");
  useEffect(() => {
    void invoke("set_watched_files", { paths: openFilePathsKey ? openFilePathsKey.split("\n") : [] }).catch(() => {});
  }, [openFilePathsKey]);

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

  // ── Opening / closing tabs ────────────────────────────────────────────────

  // A clean file is a throw-away view; a file with unsaved edits stays open (hidden)
  // until the operator closes it, so nothing is ever lost by looking at something else.
  const dropCleanFiles = useCallback((keepKey: string | null) => {
    setOpenTerminals((prev) => {
      const next = prev.filter((t) => !isFileTab(t) || t.key === keepKey || dirtyTabsRef.current[t.key]);
      return next.length === prev.length ? prev : next;
    });
  }, []);

  // Open (or focus) a persistent tab. A terminal becomes the selected agent; a file
  // replaces the terminal in Control's main area.
  const openTerminal = (spec: OpenTerminal) => {
    // Derive the agent from the command whenever the caller didn't state one.
    // `detectAgent` replaces the old inline regex: it also matches an absolute
    // path (which is what the backend resolver hands us on machines where the bare
    // name isn't on PATH) and refuses substrings like "opencoded".
    const withKind: OpenTerminal =
      spec.agent === undefined && spec.isClaude === undefined && spec.kind === "terminal"
        ? (() => {
            const agent = detectAgent(spec.initialCommand);
            return { ...spec, agent: agent ?? undefined, isClaude: agent === "claude" };
          })()
        : spec;
    if (withKind.kind === "terminal") {
      setOpenTerminals((prev) => (prev.some((tm) => tm.key === withKind.key) ? prev : [...prev, withKind]));
      setActiveTerminalKey(withKind.key);
      setViewFileKey(null);
      dropCleanFiles(null);
    } else {
      setOpenTerminals((prev) => {
        const kept = prev.filter((t) => !isFileTab(t) || t.key === withKind.key || dirtyTabsRef.current[t.key]);
        return kept.some((tm) => tm.key === withKind.key) ? kept : [...kept, withKind];
      });
      setViewFileKey(withKind.key);
      showControl();
    }
  };

  /** Select an agent and show it. If the tab was restored from a previous run, resume
   *  ITS OWN Claude session (with --dangerously-skip-permissions) instead of leaving an
   *  empty shell. Runs once per tab — the flag clears after the command is sent. */
  const activateTerminal = (key: string) => {
    pickTab(key);
    setViewFileKey(null);
    dropCleanFiles(null);
    const tab = openTerminalsRef.current.find((t) => t.key === key);
    if (!tab?.needsResume || !tab.sessionId) return;
    const ptyId = terminalPtyIdsRef.current[key];
    if (!ptyId) return; // shell not ready yet — try again on the next click
    setOpenTerminals((prev) =>
      prev.map((t) => (t.key === key ? { ...t, needsResume: false } : t))
    );
    void invoke("pty_write", {
      id: ptyId,
      data: `${resumeCommand({ sessionId: tab.sessionId, sessionCwd: tab.sessionCwd }, singleQuote)}\r`,
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
      initialCommand = resumeCommand({ sessionId: t.sessionId, sessionCwd: t.sessionCwd }, singleQuote);
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

  // Open a file from the tree in a Monaco editor tab.
  const openEditor = (filePath: string, opts?: { diff?: boolean }) => {
    openTerminal({
      key: `edit:${filePath}`,
      name: filePath.split("/").pop() || filePath,
      kind: "editor",
      filePath,
      startInDiff: opts?.diff,
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

  const closeTerminal = async (key: string) => {
    const list = openTerminalsRef.current;
    const tab = list.find((t) => t.key === key);
    if (dirtyTabsRef.current[key]) {
      const ok = await confirmDialog(
        `"${tab?.name ?? key}" has unsaved changes. Close anyway?`,
        { title: "Unsaved changes", kind: "warning", okLabel: "Close", cancelLabel: "Cancel" }
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
      // Ref, not a state closure — this can run from a mount-once listener
      // (muya://close-agent-session) whose captured state would be stale.
      if (tab?.name) void invoke("release_agent_session", { name: tab.name }).catch(() => {});
    }
    if (tab && isFileTab(tab)) {
      setViewFileKey((cur) => (cur === key ? null : cur));
    } else {
      // Focus a neighbouring AGENT — never a file (L19: a file close must not land the
      // next ⌘W on a running Claude session, and a terminal close must not select a file).
      const next = pickNextActiveKey(list, key);
      const nextAgent = list.find((t) => t.key === next && t.kind === "terminal") ? next : null;
      setActiveTerminalKey((cur) => (cur === key ? nextAgent : cur));
    }
    setOpenTerminals((prev) => prev.filter((tm) => tm.key !== key));
    setGridKeys((prev) => prev.filter((k) => k !== key));
    setDirtyTabs((prev) => { const n = { ...prev }; delete n[key]; return n; });
  };

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
  // what is on screen in Control — the open file if there is one, else the selected
  // agent (no confirmation for terminals; files still get the unsaved-changes prompt
  // via closeTerminal's dirty check). No-op when none is open.
  const viewFileKeyRef = useRef(viewFileKey);
  viewFileKeyRef.current = viewFileKey;
  useEffect(() => {
    const un = listen("menu:close-tab", () => {
      const key = viewFileKeyRef.current ?? activeKeyRef.current;
      if (key && openTerminalsRef.current.some((t) => t.key === key)) void closeTerminal(key);
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

  // The existing updater flow: download, install, relaunch. Reached from the progress
  // strip's "Restart" button.
  const runUpdate = async () => {
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
  };

  // New-agent modal (app-managed: optional git worktree + command in a PTY).
  const [newAgentOpen, setNewAgentOpen] = useState(false);

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
    showControl();
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
      files.forEach((p) => { openFile(p); });
    });
    // Files opened while app is already running.
    const un = listen<string>("apex://open-file", (e) => {
      openFile(e.payload);
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
        for (const path of p.paths) {
          try {
            const kind = await invoke<string>("path_kind", { path });
            if (kind === "dir") {
              setWorkspaces((prev) => (prev.includes(path) ? prev : [...prev, path]));
            } else if (kind === "file") {
              openFile(path);
            }
          } catch { /* ignore unreadable drops */ }
        }
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
    setViewFileKey(null);
    setView("control");
    setScreen("control");
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

  // muya-mcp → app: agent asked to open a NEW local agent session (open_session,
  // PRD agent-session-open — the local analog of ssh_open). Reuses the exact same
  // command-building `launchAgent` uses for the "+ New Agent" button (buildAgentCommand
  // + singleQuote) so an MCP-triggered open and a UI-clicked one behave identically.
  useEffect(() => {
    const un = listen<{ name: string; cwd?: string; initialMessage?: string; agent?: AgentKind }>(
      "muya://open-agent-session",
      (e) => {
        const { name, cwd, initialMessage, agent } = e.payload;
        const ws = cwd || selectedRoot || workspaces[0];
        if (!ws) return; // no workspace to run in — nothing sensible to open
        // Only Claude can be told its own name on the command line; opencode has no
        // --name for its TUI, so there the Muya tab name IS the name — which is what
        // send_to_session addresses anyway, since delivery types into the PTY.
        const kind: AgentKind = agent === "opencode" ? "opencode" : "claude";
        const base =
          kind === "claude"
            ? `${AGENT_BASE_COMMAND.claude} --name ${singleQuote(name)}`
            : AGENT_BASE_COMMAND.opencode;
        const initialCommand = buildAgentCommand({
          command: base,
          prompt: initialMessage ?? "",
          files: [],
        });
        // "aopen:" (not "ssh:"/"new:") marks this tab as MCP-opened via open_session —
        // closeTerminal uses the prefix to know it must release the broker's ownership
        // registry entry (PRD close-session) when this tab closes, by any means.
        const key = `aopen:${Date.now()}:${Math.random().toString(36).slice(2, 7)}`;
        openTerminal({ key, name, kind: "terminal", cwd: ws, initialCommand, autoAcceptTrust: true });
        showControl();
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
    localStorage.setItem("apex.openTabs", JSON.stringify(openTerminals.filter((t) => t.kind === "terminal")));
  }, [openTerminals]);

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
  const probeSoonRef = useRef(false);
  const tickNowRef = useRef<() => void>(() => {});

  // ── The agent model: the ONE source the list, header bell, inspector, grid, footer
  // and palette all read (see src/redesign/useAgentModel.ts).
  const branchByCwd = useMemo(() => {
    const out: Record<string, string> = {};
    for (const a of agents) if (a.worktree && a.branch) out[a.worktree] = a.branch;
    return out;
  }, [agents]);
  const model = useAgentModel({ tabs: openTerminals, liveCwds, branchByCwd });
  const modelRef = useRef(model);
  modelRef.current = model;
  const agentVMs = model.agents;
  const agentVMsRef = useRef(agentVMs);
  agentVMsRef.current = agentVMs;

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
        // ride the fast cwd tick — run it every SESSION_EVERY ticks instead (or once
        // right after new terminals came up, so their status isn't blank for ~15s).
        if (probeSoonRef.current) {
          probeSoonRef.current = false;
          sessionTickRef.current = SESSION_EVERY - 1;
        }
        sessionTickRef.current = (sessionTickRef.current + 1) % SESSION_EVERY;
        if (sessionTickRef.current !== 0) return;
        const byPtySession = await invoke<Record<string, { id: string; name: string; status: string }>>(
          "pty_session_ids", { ids: entries.map(([, ptyId]) => ptyId) });
        if (cancelled) return;
        // Feed the agent model: working / waiting-for-input / idle per tab.
        const statusByKey: Record<string, SessionStatus | undefined> = {};
        for (const [key, ptyId] of entries) {
          const st = byPtySession[ptyId]?.status;
          if (st) statusByKey[key] = st as SessionStatus;
        }
        modelRef.current.reportSessionStatus(statusByKey);
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
            // Where this session runs: the shell's live folder while Claude is up.
            // A NEW session id takes the current folder; the same session keeps the
            // first one it was seen in (its project never changes mid-session).
            const sessionCwd = running
              ? (sessionId !== t.sessionId ? byKey[t.key] : t.sessionCwd ?? byKey[t.key])
              : t.sessionCwd;
            if (t.isClaude === running && t.name === name && t.sessionId === sessionId && t.sessionCwd === sessionCwd) return t;
            changed = true;
            return { ...t, isClaude: running, name, sessionId, sessionCwd };
          });
          return changed ? next : prev;
        });
      } catch {
        /* probe unavailable — list falls back to the spawn cwd, resume stays as-is */
      }
    };
    tickNowRef.current = () => void tick();
    void tick();
    const t = setInterval(() => { if (!document.hidden) void tick(); }, 3000);
    return () => { cancelled = true; clearInterval(t); };
  }, []);

  // New terminals came up: probe their session status shortly after, instead of waiting
  // for the next ~15s session tick (the agent list would show them idle until then).
  const ptyCount = Object.keys(terminalPtyIds).length;
  useEffect(() => {
    if (ptyCount === 0) return;
    const t = setTimeout(() => {
      probeSoonRef.current = true;
      tickNowRef.current();
    }, 300);
    return () => clearTimeout(t);
  }, [ptyCount]);

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

  const launchAgent = async (spec: NewAgentSpec) => {
    const ws = spec.workspace || selectedRoot || workspaces[0];
    if (!ws) throw new Error("Pick a workspace first (+ Workspace).");
    let cwd = ws;
    // Every agent gets the worktree + command treatment; only a blank terminal
    // opts out. Testing for "claude" here was how opencode would have silently
    // launched as an empty shell.
    const isAgent = spec.type !== "terminal";
    if (isAgent && spec.branch.trim()) {
      cwd = await invoke<string>("create_worktree", { repo: ws, branch: spec.branch.trim() });
      setWorktrees((prev) => (prev.includes(cwd) ? prev : [...prev, cwd]));
    }
    const initialCommand = isAgent ? buildAgentCommand(spec) : undefined;
    const defaultName = spec.title.trim() || spec.branch.trim() || ws.split("/").filter(Boolean).pop() || (isAgent ? "agent" : "terminal");
    openTerminal({
      key: `new:${Date.now()}`,
      name: defaultName,
      kind: "terminal",
      cwd,
      initialCommand,
    });
    showControl();
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

  // branchList for the currently viewed repo.
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

  // Clock + live resource usage of the app's own process (not the machine).
  useEffect(() => {
    const tickClock = () => setClock(new Date().toTimeString().slice(0, 5));
    tickClock();
    const timer = setInterval(tickClock, 10_000);
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

  // ── Talking to the terminals (everything goes through pty_write) ──────────

  const writePty = useCallback((key: string, data: string): boolean => {
    const id = terminalPtyIdsRef.current[key];
    if (!id) return false;
    void invoke("pty_write", { id, data }).catch(() => {});
    return true;
  }, []);

  /** Type a line and submit it. Text and Enter go as SEPARATE writes: one chunk
   *  "text\r" reads as a paste to Claude's TUI, where \r is a newline, not submit
   *  (same fix the scheduled-prompt timer above carries). */
  const sendLine = useCallback((key: string, text: string) => {
    if (!writePty(key, text)) return;
    setTimeout(() => writePty(key, "\r"), 150);
  }, [writePty]);

  /** Answer a parsed permission dialog with the key IT advertises for that kind —
   *  never a hard-coded number. */
  const respond = useCallback((key: string, kind: "approve" | "approveAlways" | "deny") => {
    const option = modelRef.current.screenOf(key)?.permission?.options.find((o) => o.kind === kind);
    if (!option) return;
    if (writePty(key, option.key)) modelRef.current.markAnswered(key);
  }, [writePty]);

  const modeOf = (key: string): PermissionMode | undefined => agentVMsRef.current.find((a) => a.key === key)?.mode;

  /** Shift+Tab until Claude reports `target` (max 4 tries; stop as soon as a press
   *  changes nothing — the mode is not reachable, e.g. bypass without its flag). */
  const setModeTo = async (key: string, target: PermissionMode) => {
    for (let i = 0; i < 4; i++) {
      const before = modeOf(key);
      if (before === target) return;
      if (!writePty(key, "\x1b[Z")) return;
      await sleep(700); // 300ms screen-parse throttle + Claude's repaint
      if (modeOf(key) === before) return;
    }
  };

  // Composer drafts, per agent (shared by Control's box and each grid panel's box).
  const [composerValues, setComposerValues] = useState<Record<string, string>>({});
  const setDraft = (key: string, value: string) => setComposerValues((prev) => ({ ...prev, [key]: value }));
  const sendMessage = (key: string, text: string) => {
    sendLine(key, text);
    setDraft(key, "");
  };

  const attachFile = async (key: string) => {
    const shell = !agentVMsRef.current.find((a) => a.key === key)?.agentRunning;
    const sel = await openDialog({ multiple: false, directory: false, title: shell ? "Add path" : "Add file" });
    if (typeof sel !== "string") return;
    // An agent reads "@path" as a file reference; a shell needs the path itself, quoted.
    const token = shell ? singleQuote(sel) : `@${sel}`;
    setComposerValues((prev) => {
      const cur = prev[key] ?? "";
      return { ...prev, [key]: `${cur}${cur && !cur.endsWith(" ") ? " " : ""}${token} ` };
    });
    document.getElementById("rd-composer")?.focus();
  };

  // ── Inspector data ────────────────────────────────────────────────────────
  const selectedTab = openTerminals.find((t) => t.key === activeTerminalKey && t.kind === "terminal");
  const selectedCwd = selectedTab ? liveCwds[selectedTab.key] ?? selectedTab.cwd : undefined;
  const [changes, setChanges] = useState<ChangeVM[]>([]);
  const gitRunRef = useRef<{ cwd?: string; at: number }>({ at: 0 });
  // git_status of the selected agent's repo. Refreshes on the existing fs-changed tick
  // (fsTick), throttled to one run per 5s per repo so an fs storm can't become a git storm (L31).
  useEffect(() => {
    if (!selectedCwd || view !== "control" || screen !== "control") return;
    const sameRepo = gitRunRef.current.cwd === selectedCwd;
    const wait = sameRepo ? Math.max(0, 5000 - (Date.now() - gitRunRef.current.at)) : 0;
    let cancelled = false;
    const timer = setTimeout(() => {
      gitRunRef.current = { cwd: selectedCwd, at: Date.now() };
      invoke<[string, string][]>("git_status", { root: selectedCwd })
        .then((pairs) => { if (!cancelled) setChanges(pairs.map(([path, code]) => ({ code, path }))); })
        .catch(() => { if (!cancelled) setChanges([]); });
    }, wait);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [selectedCwd, fsTick, view, screen]);

  const absoluteInRepo = (rel: string) => `${(selectedCwd ?? "").replace(/\/+$/, "")}/${rel}`;
  const openChange = (rel: string) => {
    if (!selectedCwd || rel.endsWith("/")) return;
    openFile(absoluteInRepo(rel));
  };
  const reviewDiff = () => {
    const first = changes.find((c) => !c.path.endsWith("/"));
    if (!first || !selectedCwd) return;
    const abs = absoluteInRepo(first.path);
    const existing = openTerminalsRef.current.find((t) => t.key === `edit:${abs}`);
    if (existing) setViewFileKey(existing.key);
    else openEditor(abs, { diff: true });
    showControl();
  };
  // Commit…: put `git commit` in the terminal, unsent, and focus it.
  const startCommit = () => {
    if (!activeTerminalKey) return;
    if (writePty(activeTerminalKey, "git commit ")) {
      setViewFileKey(null);
      setTabPickCount((n) => n + 1);
    }
  };

  const inspectorVM: InspectorVM = {
    changes,
    worktreesWatched: trackedPaths.length,
    collisions: collisionReport.collisions,
  };

  // ── Screens / navigation state ────────────────────────────────────────────
  const [agentFilter, setAgentFilter] = useState<AgentFilter>("all");
  const [inspectorTab, setInspectorTab] = useState<InspectorTab>("changes");
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [broadcastOpen, setBroadcastOpen] = useState(false);
  const [broadcastText, setBroadcastText] = useState("");
  const [menu, setMenu] = useState<null | { kind: "actions" | "workspaces" | "mode"; anchor: Anchor }>(null);
  const [renameKey, setRenameKey] = useState<string | null>(null);
  const [swapKey, setSwapKey] = useState<string | null>(null);

  const selectedAgentKey = selectedTab ? selectedTab.key : null;
  const selectedVM = agentVMs.find((a) => a.key === selectedAgentKey) ?? null;
  const viewedFile = viewFileKey ? openTerminals.find((t) => t.key === viewFileKey && isFileTab(t)) : undefined;
  const fileVM: FileVM | null = viewedFile ? { name: viewedFile.name, path: abbreviateHome(viewedFile.filePath ?? "") } : null;

  const gridPanels = useMemo(
    () => pickGridPanels(agentVMs, gridKeys, GRID_CAPACITY[gridLayout]),
    [agentVMs, gridKeys, gridLayout],
  );
  // Focus defaults to the agent the operator was working with (the Control selection)
  // when it's on the grid — not blindly to the first panel. Opening the grid straight
  // (restored screen, ⌘K "Grid") used to land focus on whatever sorted first.
  const focusedPanelKey = gridPanels.some((p) => p.key === gridFocusedKey)
    ? gridFocusedKey
    : gridPanels.some((p) => p.key === selectedAgentKey)
      ? selectedAgentKey
      : gridPanels[0]?.key ?? null;

  const railActive: RailItem | null =
    view === "control" ? "control" : view === "queue" ? "queue" : view === "prd" ? "kanban" : view === "tools" ? "resources" : view === "ssh" ? "ssh" : view === "chat" ? "chat" : null;

  const navigateRail = (item: RailItem) => {
    if (item === "settings") return setSettingsOpen(true);
    if (item === "control") {
      // From the grid, "Control" lands on the agent the operator was looking at.
      if (view === "control" && screen === "grid" && focusedPanelKey) activateTerminal(focusedPanelKey);
      return showControl();
    }
    setView(item === "kanban" ? "prd" : item === "resources" ? "tools" : item);
  };

  const selectAgent = (key: string) => {
    showControl();
    activateTerminal(key);
  };

  const jumpToWaiting = () => {
    const first = agentVMs.find((a) => a.status === "waiting");
    if (first) selectAgent(first.key);
  };

  const reorderAgents = (fromKey: string, toKey: string) => {
    setOpenTerminals((prev) => {
      const next = [...prev];
      const fi = next.findIndex((t) => t.key === fromKey);
      if (fi === -1) return prev;
      const [item] = next.splice(fi, 1);
      const ti = next.findIndex((t) => t.key === toKey); // re-find after splice
      if (ti === -1) return prev;
      next.splice(ti, 0, item);
      return next;
    });
  };

  const exitGrid = () => {
    if (focusedPanelKey) activateTerminal(focusedPanelKey);
    setScreen("control");
  };

  const splitToGrid = () => {
    if (selectedAgentKey) setGridKeys((prev) => [selectedAgentKey, ...prev.filter((k) => k !== selectedAgentKey)]);
    if (selectedAgentKey) setGridFocusedKey(selectedAgentKey);
    setScreen("grid");
  };

  const maximizePanel = (key: string) => {
    if (gridLayout === "1" && layoutBeforeMaximizeRef.current) {
      setGridLayout(layoutBeforeMaximizeRef.current);
      layoutBeforeMaximizeRef.current = null;
      return;
    }
    layoutBeforeMaximizeRef.current = gridLayout;
    setGridKeys(() => [key, ...gridPanels.map((p) => p.key).filter((k) => k !== key)]);
    setGridFocusedKey(key);
    setGridLayout("1");
  };

  const waitingFirst = () => {
    const waiting = agentVMs.filter((a) => a.status === "waiting").map((a) => a.key);
    const rest = gridPanels.map((p) => p.key).filter((k) => !waiting.includes(k));
    setGridKeys([...waiting, ...rest]);
  };

  const broadcast = () => {
    const text = broadcastText.trim();
    if (text) for (const p of gridPanels) sendLine(p.key, text);
    setBroadcastOpen(false);
    setBroadcastText("");
  };

  const swapPanel = (targetKey: string, newKey: string) => {
    const keys = gridPanels.map((p) => p.key).filter((k) => k !== newKey);
    // An "empty:<n>" cell has no agent to replace — the pick fills it (appends).
    if (targetKey.startsWith("empty:")) keys.push(newKey);
    else {
      const i = keys.indexOf(targetKey);
      if (i === -1) return;
      keys[i] = newKey;
    }
    setGridKeys(keys);
    setSwapKey(null);
  };

  const runCommand = (id: string) => {
    setPaletteOpen(false);
    switch (id) {
      case "new-agent": return setNewAgentOpen(true);
      case "new-terminal": return openBlankTerminal();
      case "control": return showControl();
      case "grid": setView("control"); return setScreen("grid");
      case "sessions": return setView("sessions");
      case "branches": return setView("branches");
      case "queue": return setView("queue");
      case "kanban": return setView("prd");
      case "resources": return setView("tools");
      case "ssh": return setView("ssh");
      case "chat": return setView("chat");
      case "settings": return setSettingsOpen(true);
      case "theme": return cycleTheme();
      case "schedule": return setScheduleOpen(true);
      case "add-workspace": return void addWorkspace();
    }
  };

  // Palette "Files": the files already open, then the selected agent's changed files.
  const paletteFileMap = useMemo(() => {
    const map = new Map<string, string>();
    for (const t of openTerminals) if (isFileTab(t) && t.filePath) map.set(abbreviateHome(t.filePath), t.filePath);
    if (selectedCwd) {
      for (const c of changes) {
        if (c.path.endsWith("/")) continue;
        map.set(c.path, `${selectedCwd.replace(/\/+$/, "")}/${c.path}`);
      }
    }
    return map;
  }, [openTerminals, changes, selectedCwd]);
  const paletteFiles = useMemo(() => [...paletteFileMap.keys()].map((path) => ({ path })), [paletteFileMap]);

  // ⌘K / ⌘1–9 / grid shortcuts. Capture phase: xterm owns ⌘K (kill-to-EOL) and swallows
  // keys typed into a focused terminal, so a bubbling listener would never see them.
  const overlayOpen = paletteOpen || broadcastOpen || swapKey !== null || menu !== null || renameKey !== null || settingsOpen || newAgentOpen;
  const shortcutRef = useRef({ screen, view, selectAgent, respond, maximize: maximizePanel, focused: focusedPanelKey, exitGrid, overlayOpen });
  shortcutRef.current = { screen, view, selectAgent, respond, maximize: maximizePanel, focused: focusedPanelKey, exitGrid, overlayOpen };
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const s = shortcutRef.current;
      if (e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey) {
        if (e.key.toLowerCase() === "k") {
          e.preventDefault();
          e.stopPropagation();
          setPaletteOpen((o) => !o);
          return;
        }
        const n = Number(e.key);
        if (Number.isInteger(n) && n >= 1 && n <= 9) {
          const target = agentVMsRef.current[n - 1];
          if (target) {
            e.preventDefault();
            e.stopPropagation();
            s.selectAgent(target.key);
          }
          return;
        }
        if (e.key === "Enter" && s.view === "control" && s.screen === "grid" && s.focused) {
          e.preventDefault();
          e.stopPropagation();
          s.maximize(s.focused);
          return;
        }
      }
      // Esc leaves the grid (unless it belongs to a terminal / field / dialog).
      if (s.view === "control" && s.screen === "grid" && shouldExitGridOnEscape(e, s.overlayOpen)) {
        e.preventDefault();
        s.exitGrid();
        return;
      }
      // Y / N inside a focused grid terminal answer a waiting panel's prompt instead of
      // being typed into the PTY (GridPanel handles the same keys when the panel itself
      // has focus).
      if (s.view === "control" && s.screen === "grid" && !e.metaKey && !e.ctrlKey && !e.altKey) {
        const slotKey = (e.target as HTMLElement | null)?.closest?.("[data-terminal-slot]")?.getAttribute("data-terminal-slot");
        const lower = e.key.toLowerCase();
        if (slotKey && (lower === "y" || lower === "n")) {
          const agent = agentVMsRef.current.find((a) => a.key === slotKey);
          if (agent?.status === "waiting" && agent.approval?.actionable !== false) {
            e.preventDefault();
            e.stopPropagation();
            s.respond(slotKey, lower === "y" ? "approve" : "deny");
          }
        }
      }
    };
    window.addEventListener("keydown", onKeyDown, true);
    return () => window.removeEventListener("keydown", onKeyDown, true);
  }, []);

  // Tab moves DOM focus to the focused grid panel: entering the grid (or Tab-cycling)
  // must not leave the keyboard inside whichever xterm happened to mount last.
  useEffect(() => {
    if (view !== "control" || screen !== "grid" || !focusedPanelKey) return;
    const name = agentVMsRef.current.find((a) => a.key === focusedPanelKey)?.name;
    if (!name) return;
    const t = setTimeout(() => {
      const section = document.querySelector<HTMLElement>(`section[aria-label="${CSS.escape(name)}"]`);
      if (section && !section.contains(document.activeElement)) section.focus();
    }, 80);
    return () => clearTimeout(t);
  }, [view, screen, focusedPanelKey]);

  // ── Terminal pool ─────────────────────────────────────────────────────────
  // Every terminal and file viewer renders ONCE into its own host element (a portal);
  // screens render empty [data-terminal-slot=<tabKey>] boxes and adoptHosts() moves
  // each host into its slot (or back to the hidden pool). No second xterm, no second PTY.
  const poolRef = useRef<HTMLDivElement>(null);
  const hostsRef = useRef<Map<string, HTMLDivElement>>(new Map());
  const hostFor = (key: string): HTMLDivElement => {
    let host = hostsRef.current.get(key);
    if (!host) {
      host = createHost(key);
      hostsRef.current.set(key, host);
    }
    return host;
  };
  useLayoutEffect(() => {
    if (poolRef.current) adoptHosts(hostsRef.current, poolRef.current);
  });
  useEffect(() => {
    const open = new Set(openTerminals.map((t) => t.key));
    for (const [key, host] of hostsRef.current) {
      if (!open.has(key)) {
        host.remove();
        hostsRef.current.delete(key);
      }
    }
  }, [openTerminals]);

  const controlVisible = view === "control" && screen === "control";
  // Every grid panel shows its terminal — idle ones included (GridPanel.tsx). This set
  // used to skip idle panels, from when they showed a placeholder; after that changed,
  // idle terminals were on screen but `active=false`, so their WebGL renderer stayed
  // suspended and the panel was blank (caught live, 2026-09-30 — see L54).
  const gridVisibleKeys = new Set(view === "control" && screen === "grid" ? gridPanels.map((p) => p.key) : []);

  // ── Render ────────────────────────────────────────────────────────────────
  const headerVM = {
    workspaceName: (selectedRoot ?? workspaces[0] ?? "").split("/").filter(Boolean).pop() ?? "No workspace",
    workspaceCount: workspaces.length,
    cpu: `${cpuUsage}%`,
    ram: ramUsage < 1024 ? `${Math.round(ramUsage)} MB` : `${(ramUsage / 1024).toFixed(1)} GB`,
    clock,
    hasNotifications: model.counts.waiting > 0,
  };
  const footerVM = {
    workspaceCount: workspaces.length,
    agents: model.counts.agents,
    working: model.counts.working,
    waiting: model.counts.waiting,
    collisions: collisionReport.collisions.length,
    version: appVersion || "…",
    variant: "control" as const,
  };
  const updateReady = Boolean(updateAvailable && updateAvailable.version);

  const openWorkspaceMenu = (e: React.MouseEvent<HTMLElement>) =>
    setMenu({ kind: "workspaces", anchor: anchorFromRect(e.currentTarget.getBoundingClientRect(), "left") });
  const openActionsMenu = (e: React.MouseEvent<HTMLElement>) =>
    setMenu({ kind: "actions", anchor: anchorFromRect(e.currentTarget.getBoundingClientRect(), "right") });
  // One rename path for every kind of session (terminal, Claude, opencode): the name is
  // the tab's, and userRenamed stops a live Claude session name from overwriting it.
  const renameTerminal = (key: string, name: string) =>
    setOpenTerminals((prev) => prev.map((t) => (t.key === key ? { ...t, name, userRenamed: true } : t)));
  // Right-click on a session in the agents list: select it, then its actions menu at the pointer.
  const openAgentContextMenu = (key: string, e: React.MouseEvent) => {
    selectAgent(key);
    setMenu({ kind: "actions", anchor: { x: e.clientX, y: e.clientY, align: "left", place: "below" } });
  };
  const openModeMenu = (e: React.MouseEvent<HTMLElement>) =>
    setMenu({ kind: "mode", anchor: anchorFromRect(e.currentTarget.getBoundingClientRect(), "left", "above") });

  const headerProps = {
    header: headerVM,
    themePreference: themeMode,
    onThemeCycle: cycleTheme,
    onNotificationsClick: jumpToWaiting,
    onWorkspaceClick: openWorkspaceMenu,
    onOpenPalette: () => setPaletteOpen(true),
  };

  // rd-legacy: the tree predates the redesign and is laid out for Tailwind's preflight
  // (see redesign.css).
  const filesSlot = (
    <div className="rd-legacy" style={{ height: "100%", minHeight: 0 }}>
    <FileTree
      roots={trackedPaths}
      removableRoots={new Set(trackedPaths)}
      onOpenFile={openFile}
      onOpenFileEditable={openEditor}
      onRemoveRoot={(path) => {
        setWorkspaces((prev) => prev.filter((w) => w !== path));
        setWorktrees((prev) => prev.filter((w) => w !== path));
      }}
      onOpenTerminalHere={(cwd) => {
        openTerminal({ key: `term-${Date.now()}`, name: cwd.split("/").pop() ?? "Terminal", kind: "terminal", cwd });
        showControl();
      }}
      onOpenClaudeHere={(cwd) => {
        // Open a terminal in the folder and launch Claude straight away.
        // isClaude is derived from the command by openTerminal.
        openTerminal({
          key: `claude-${Date.now()}`,
          name: cwd.split("/").pop() ?? "Claude",
          kind: "terminal",
          cwd,
          initialCommand: "claude --dangerously-skip-permissions",
        });
        showControl();
      }}
      onAddAtRef={() => {
        // clipboard already written inside FileTree
      }}
      agents={agents}
      activeCwd={selectedTab?.cwd}
      selectedRoot={selectedRoot}
      onSelectRoot={(r) => setSelectedRoot((prev) => (prev === r ? undefined : r))}
      refreshSignal={fsTick}
      onAddWorkspace={() => void addWorkspace()}
    />
    </div>
  );

  const pageClass = (v: View) => `flex-1 flex overflow-hidden ${view !== v ? "hidden" : ""}`;

  return (
    <div id="vs-ctrl-plane" style={{ width: "100vw", height: "100vh", overflow: "hidden", background: "var(--bg-app)", color: "var(--text)" }}>
      {/* macOS file-access gate: blocks on App Translocation, otherwise offers a
          one-time, explained permission request. Renders nothing once granted. */}
      <FileAccessGate />

      {/* OS drag-drop hint: shown while a file/folder is dragged over the window. */}
      {dropActive && (
        <div className="rd-root" style={{ position: "fixed", inset: 0, zIndex: 10000, display: "flex", alignItems: "center", justifyContent: "center", background: "var(--bg-selected)", pointerEvents: "none" }}>
          <div style={{ padding: "16px 24px", borderRadius: 12, border: "2px dashed var(--accent)", background: "var(--bg-panel)", color: "var(--text-strong)", fontFamily: "var(--font-mono)", fontSize: 14 }}>
            Drop to open — file → editor · folder → workspace
          </div>
        </div>
      )}

      {/* The terminal pool: hosts parked here while no screen shows them. */}
      <div ref={poolRef} aria-hidden style={POOL_STYLE} />
      {openTerminals.map((tm) =>
        createPortal(
          tm.kind === "terminal" ? (
            <AgentTerminal
              cwd={tm.cwd}
              initialCommand={tm.initialCommand}
              sshServerId={tm.sshServerId}
              autoAcceptTrust={tm.autoAcceptTrust}
              theme={effectiveTheme}
              // Every layer that can hide a terminal counts: the page, the screen, the
              // file replacing it, and (grid) whether its panel shows a terminal at all.
              active={terminalIsVisible({
                controlPageVisible: view === "control",
                inGrid: gridVisibleKeys.has(tm.key),
                isActiveTab: controlVisible && !viewedFile && tm.key === activeTerminalKey,
              })}
              focusToken={controlVisible && tm.key === activeTerminalKey ? tabPickCount : undefined}
              onPtyReady={(ptyId) => setTerminalPtyIds((prev) => ({ ...prev, [tm.key]: ptyId }))}
              onPathMenu={(resolved, kind, x, y) => setPathMenu({ resolved, kind, x, y })}
              onScreen={(state) => model.reportScreen(tm.key, state)}
            />
          ) : (
            <FileTabView
              tab={tm}
              theme={effectiveTheme}
              active={controlVisible && viewFileKey === tm.key}
              reloadTick={fsTick}
              fileTick={fileTicks[tm.filePath ?? ""] ?? 0}
              onDirtyChange={(d) => setDirtyTabs((prev) => (prev[tm.key] === d ? prev : { ...prev, [tm.key]: d }))}
              onEditMarkdown={(p) => { void closeTerminal(tm.key); openEditor(p); }}
            />
          ),
          hostFor(tm.key),
          tm.key,
        ),
      )}

      {/* ================= Secondary pages (ALWAYS mounted, hidden off-view) =================
          They used to be conditionally rendered, so navigating away unmounted them and
          navigating back remounted them → a fresh fetch on every click. They are mounted on
          first visit and then only hidden, so they load ONCE and refresh via their manual
          Refresh button or the hourly sequential coordinator above. */}
      <div style={{ display: view === "control" ? "none" : "flex", flexDirection: "column", width: "100%", height: "100%", background: "var(--bg-app)" }}>
        <div className="rd-root" style={{ display: "contents" }}>
          <ControlHeader {...headerProps} />
        </div>
        <div style={{ flexGrow: 1, minHeight: 0, display: "flex" }}>
          <div className="rd-root" style={{ display: "contents" }}>
            <Rail active={railActive} onNavigate={navigateRail} />
          </div>
          <AppFrameBody>
            <div className={pageClass("sessions")}>
              {mountedViews.has("sessions") && (
                <SessionsPage
                  onRegisterRefresh={registerSessionsRefresh}
                  onOpen={(spec) => {
                    if (spec.cwd) ensureWorktreeTracked(spec.cwd);
                    openTerminal({ ...spec, kind: "terminal" });
                    showControl();
                  }}
                />
              )}
            </div>
            <div className={pageClass("tools")}>
              {mountedViews.has("tools") && (
                <ResourcesPage
                  onRegisterRefresh={registerToolsRefresh}
                  onOpenTerminal={(spec) => {
                    openTerminal({ ...spec, kind: "terminal" });
                    showControl();
                  }}
                />
              )}
            </div>
            <div className={pageClass("queue")}>
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
            <div className={pageClass("prd")}>
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
                  onOpenFile={(path) => openEditor(path)}
                />
              )}
            </div>
            {/* SSH config page — mounted on first visit, then kept alive (hidden off-view)
                so an in-progress add/edit-server form (or CyberArk session) survives
                navigation. Deferred off startup so its load doesn't contend (L32). */}
            <div className={pageClass("ssh")}>
              {mountedViews.has("ssh") && <SshPage onConnect={openSshServer} />}
            </div>
            {/* Claude-to-Claude chat bridge — mounted on first visit, then kept alive so an
                active pairing / conversation survives navigation. Its bridge data-fetches
                (peers/inbound/local_ip) no longer run at app startup (L32). */}
            <div className={pageClass("chat")}>
              {mountedViews.has("chat") && <ChatView />}
            </div>
            <div className={pageClass("branches")}>
              {mountedViews.has("branches") && (
                <BranchesPage
                  repoList={repoList}
                  branchRepo={branchRepo}
                  onSelectRepo={setSelectedBranchRepo}
                  branchMap={branchMap}
                  branchList={branchList}
                  agents={agents}
                  selectedAgentId={selectedAgentId}
                  onSelectAgent={setSelectedAgentId}
                  onInspect={(name) => {
                    setBranchInspect({ repo: branchRepo, name });
                    setView("queue");
                  }}
                />
              )}
            </div>
          </AppFrameBody>
        </div>
        <div className="rd-root" style={{ display: "contents" }}>
          <Footer {...footerVM} />
        </div>
      </div>

      {/* ================= Control / Grid ================= */}
      {controlVisible && (
        <div style={{ width: "100%", height: "100%" }}>
          <ControlScreen
            onRenameAgent={renameTerminal}
            onAgentContextMenu={openAgentContextMenu}
            {...headerProps}
            footer={footerVM}
            railActive="control"
            onRailNavigate={navigateRail}
            agents={agentVMs}
            selectedAgentKey={selectedAgentKey}
            agentFilter={agentFilter}
            onAgentFilterChange={setAgentFilter}
            onSelectAgent={selectAgent}
            onNewAgent={() => setNewAgentOpen(true)}
            onReorderAgents={reorderAgents}
            openFile={fileVM}
            onCloseFile={() => { if (viewFileKey) void closeTerminal(viewFileKey); }}
            fileSlot={viewedFile ? <div data-terminal-slot={viewedFile.key} data-terminal-pad="0" style={{ flexGrow: 1, minHeight: 0 }} /> : undefined}
            onCompact={() => selectedAgentKey && sendLine(selectedAgentKey, "/compact")}
            onSplitToGrid={splitToGrid}
            onStop={() => selectedAgentKey && writePty(selectedAgentKey, "\x1b")}
            onMoreActions={openActionsMenu}
            composerValue={selectedAgentKey ? composerValues[selectedAgentKey] ?? "" : ""}
            onComposerChange={(v) => selectedAgentKey && setDraft(selectedAgentKey, v)}
            onSendMessage={(text) => selectedAgentKey && sendMessage(selectedAgentKey, text)}
            onCycleMode={() => selectedAgentKey && writePty(selectedAgentKey, "\x1b[Z")}
            onModeMenu={openModeMenu}
            onAttachFile={() => selectedAgentKey && void attachFile(selectedAgentKey)}
            onOpenCommands={() => {
              if (!selectedAgentKey) return;
              setDraft(selectedAgentKey, (composerValues[selectedAgentKey] ?? "") + "/");
              document.getElementById("rd-composer")?.focus();
            }}
            updateReady={updateReady}
            onRestartForUpdate={() => void runUpdate()}
            inspector={inspectorVM}
            inspectorTab={inspectorTab}
            onInspectorTabChange={setInspectorTab}
            onApprove={(key) => respond(key, "approve")}
            onDeny={(key) => respond(key, "deny")}
            onOpenApproval={selectAgent}
            onReviewDiff={reviewDiff}
            onCommit={startCommit}
            onOpenChange={openChange}
            onNewTerminal={openBlankTerminal}
            filesSlot={filesSlot}
            activitySlot={
              <ActivityPanel collisions={collisionReport.collisions} editedFiles={collisionReport.editedFiles} worktreesWatched={trackedPaths.length} />
            }
            inspectorOpen={innerWidth >= 1280}
            filesCount={trackedPaths.length}
          />
        </div>
      )}
      {view === "control" && screen === "grid" && (
        <GridScreen
          onRenameAgent={renameTerminal}
          railActive="control"
          onRailNavigate={navigateRail}
          footer={footerVM}
          panels={gridPanels}
          layout={gridLayout}
          onLayoutChange={setGridLayout}
          onWaitingFirst={waitingFirst}
          onBroadcastOpen={() => setBroadcastOpen(true)}
          onExitGrid={exitGrid}
          focusedKey={focusedPanelKey}
          onFocusPanel={setGridFocusedKey}
          onMaximizePanel={maximizePanel}
          onApprove={(key) => respond(key, "approve")}
          onDeny={(key) => respond(key, "deny")}
          onAlwaysAllow={(key) => respond(key, "approveAlways")}
          composerValues={composerValues}
          onComposerChange={setDraft}
          onSendMessage={sendMessage}
          onAssignFromQueue={() => setView("queue")}
          onReplacePanel={setSwapKey}
        />
      )}

      {/* ================= Overlays ================= */}
      <div className="rd-root" style={{ display: "contents" }}>
        <CommandPalette
          open={paletteOpen}
          onOpenChange={setPaletteOpen}
          agents={agentVMs}
          files={paletteFiles}
          commands={PALETTE_COMMANDS}
          onSelectAgent={(key) => { setPaletteOpen(false); selectAgent(key); }}
          onOpenFile={(p) => { setPaletteOpen(false); openFile(paletteFileMap.get(p) ?? p); }}
          onRunCommand={runCommand}
        />
        <BroadcastModal
          open={broadcastOpen}
          panelCount={gridPanels.length}
          value={broadcastText}
          onChange={setBroadcastText}
          onCancel={() => { setBroadcastOpen(false); setBroadcastText(""); }}
          onConfirm={broadcast}
        />
        {menu?.kind === "actions" && selectedAgentKey && (
          <MenuPopover anchor={menu.anchor} label="Agent actions" onClose={() => setMenu(null)}>
            <MenuItem label="Rename…" onSelect={() => { setRenameKey(selectedAgentKey); setMenu(null); }} />
            <MenuItem label="Duplicate" onSelect={() => { duplicateTerminal(selectedAgentKey); setMenu(null); }} />
            <MenuItem label="Reveal in Finder" onSelect={() => { revealTerminalInFinder(selectedAgentKey); setMenu(null); }} />
            <MenuItem
              label="Schedule prompt…"
              hint={scheduledPrompts.some((p) => !p.fired) ? `${scheduledPrompts.filter((p) => !p.fired).length} pending` : undefined}
              onSelect={() => { setScheduleOpen(true); setMenu(null); }}
            />
            <MenuSeparator />
            <MenuItem label="Close agent" danger onSelect={() => { void closeTerminal(selectedAgentKey); setMenu(null); }} />
          </MenuPopover>
        )}
        {menu?.kind === "workspaces" && (
          <MenuPopover anchor={menu.anchor} width={420} label="Workspaces" onClose={() => setMenu(null)}>
            <MenuHeading>WORKSPACES</MenuHeading>
            {workspaces.length === 0 && <div style={{ padding: "6px 10px", color: "var(--text-muted)" }}>No workspace yet.</div>}
            {workspaces.map((w) => (
              <MenuItem key={w} label={w.split("/").filter(Boolean).pop() ?? w} hint={abbreviateHome(w)} checked={w === (selectedRoot ?? workspaces[0])} onSelect={() => { setSelectedRoot(w); setMenu(null); }} />
            ))}
            <MenuSeparator />
            <MenuItem label="Add workspace…" onSelect={() => { setMenu(null); void addWorkspace(); }} />
            {selectedRoot && workspaces.includes(selectedRoot) && (
              <MenuItem
                label="Remove selected workspace"
                danger
                onSelect={() => {
                  setWorkspaces((prev) => prev.filter((w) => w !== selectedRoot));
                  setWorktrees((prev) => prev.filter((w) => w !== selectedRoot));
                  setMenu(null);
                }}
              />
            )}
          </MenuPopover>
        )}
        {menu?.kind === "mode" && selectedAgentKey && (
          <MenuPopover anchor={menu.anchor} width={300} label="Permission mode" onClose={() => setMenu(null)}>
            <MenuHeading>PERMISSION MODE</MenuHeading>
            {selectedVM?.mode === "bypass" ? (
              <div style={{ padding: "4px 10px 8px", display: "flex", flexDirection: "column", gap: 3, fontSize: 12 }}>
                <span style={{ color: "var(--danger-text)" }}>Bypass permissions is on</span>
                <span style={{ color: "var(--text-muted)" }}>Fixed at launch, outside the Shift+Tab cycle</span>
              </div>
            ) : (
              MODE_ITEMS.map(({ mode, label }) => (
                <MenuItem key={mode} label={label} checked={selectedVM?.mode === mode} onSelect={() => { setMenu(null); void setModeTo(selectedAgentKey, mode); }} />
              ))
            )}
          </MenuPopover>
        )}
        {renameKey && (
          <RenameDialog
            initial={openTerminals.find((t) => t.key === renameKey)?.name ?? ""}
            onClose={() => setRenameKey(null)}
            onSubmit={(name) => renameTerminal(renameKey, name)}
          />
        )}
        {swapKey && (
          <AgentPickerDialog
            title="Swap panel"
            agents={agentVMs.filter((a) => !gridPanels.some((p) => p.key === a.key))}
            onClose={() => setSwapKey(null)}
            onPick={(key) => swapPanel(swapKey, key)}
          />
        )}
      </div>

      <NewAgentModal
        open={newAgentOpen}
        onClose={() => setNewAgentOpen(false)}
        workspaces={[...new Set([...workspaces, ...agents.map((a) => a.worktree).filter(Boolean)])].sort()}
        defaultWorkspace={selectedRoot}
        onLaunch={launchAgent}
      />

      <SettingsModal open={settingsOpen} onClose={() => setSettingsOpen(false)} themePreference={themeMode} onThemePreferenceChange={setThemeMode} />

      <ScheduledPromptModal
        open={scheduleOpen}
        onClose={() => setScheduleOpen(false)}
        terminals={openTerminals.filter(t => t.kind === "terminal").map(t => ({ key: t.key, name: t.name }))}
        scheduled={scheduledPrompts}
        onAdd={(p) => setScheduledPrompts(prev => [...prev, { ...p, id: crypto.randomUUID(), fired: false }])}
        onEdit={(id, p) => setScheduledPrompts(prev => prev.map(sp => sp.id === id ? { ...sp, ...p, fired: false } : sp))}
        onCancel={(id) => setScheduledPrompts(prev => prev.filter(p => p.id !== id))}
      />

      {/* Updater progress (the strip's Restart button starts the flow; this shows where it is). */}
      {updateProgress && (
        <div className="rd-root" style={{ position: "fixed", right: 16, bottom: 44, zIndex: 80, padding: "8px 12px", borderRadius: 8, border: "1px solid var(--border-strong)", background: "var(--bg-panel)", color: "var(--text)", fontSize: 12, display: "flex", alignItems: "center", gap: 10 }}>
          <span>{updateProgress}</span>
          {updateProgress.startsWith("Update failed") && (
            <button type="button" onClick={() => setUpdateProgress(null)} className="rd-btn2" style={{ height: 24, padding: "0 8px", borderRadius: 6, border: "1px solid var(--border-control)", background: "transparent", color: "var(--text)", fontSize: 12 }}>
              Dismiss
            </button>
          )}
        </div>
      )}

      {/* Transient "press ⌘Q again to quit" hint. NOT a full-screen overlay (no
          `fixed inset-0 z-50`) so it never blocks terminal input. */}
      {quitHint && (
        <div className="rd-root" style={{ position: "fixed", bottom: 44, left: "50%", transform: "translateX(-50%)", zIndex: 80, padding: "6px 12px", borderRadius: 8, background: "var(--bg-panel)", border: "1px solid var(--border-strong)", color: "var(--text-strong)", fontFamily: "var(--font-mono)", fontSize: 12, fontWeight: 600, pointerEvents: "none" }}>
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
                onClick={() => { openEditor(pathMenu.resolved); setPathMenu(null); }}>
                Open in Muya
              </button>
            )}
            {pathMenu.kind === "dir" && (
              <button type="button" className="w-full text-left px-3 py-1.5 hover:bg-indigo-50 dark:hover:bg-indigo-950/40 cursor-pointer text-neutral-700 dark:text-neutral-200"
                onClick={() => {
                  ensureWorktreeTracked(pathMenu.resolved);
                  openTerminal({ key: `term-${Date.now()}`, name: pathMenu.resolved.split("/").pop() ?? "Terminal", kind: "terminal", cwd: pathMenu.resolved });
                  showControl(); setPathMenu(null);
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

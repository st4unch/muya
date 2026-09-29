// Browser-only mock Tauri backend — lets the Muya frontend boot and render in
// plain Chromium (no Tauri runtime) for pixel comparison against the v0.4 redesign
// references. NEVER installs anything inside the real Tauri app.
//
// GUARDING (two independent layers — both must pass):
//
//   1. Build-time: `import.meta.env.DEV || import.meta.env.MODE === "mock"`.
//      A production `tauri build` runs Vite in `mode: "production"`, so this
//      condition is statically false there and Vite's dead-code elimination drops
//      every call site (and, transitively, this module and its `@tauri-apps/api/
//      mocks` import) from the signed app bundle. This is what actually keeps the
//      mock out of what ships.
//   2. Runtime: `!('__TAURI_INTERNALS__' in window) && ?mock=1`.
//      Belt-and-braces for the case the build-time guard alone doesn't cover: a dev
//      build (`import.meta.env.DEV` true) can still be loaded *inside* the real
//      Tauri webview, where `__TAURI_INTERNALS__` already exists — installing
//      `mockIPC` there would silently hijack the real IPC bridge. And a bare
//      `npm run dev` opened in an ordinary browser tab must stay completely inert
//      unless the URL explicitly opts in with `?mock=1`, so it never surprises
//      someone just checking the dev server works.
//
// Both checks must pass before `maybeInstallMock()` touches anything.

import { mockIPC, mockWindows } from "@tauri-apps/api/mocks";
import {
  MOCK_AGENTS,
  MOCK_APP_METRICS,
  MOCK_APP_VERSION,
  MOCK_BRANCHES,
  MOCK_COLLISION_REPORT,
  MOCK_GIT_STATUS,
  MOCK_PROJECT_STATUS,
  MOCK_TERMINAL_LINES,
  MOCK_UPDATE_METADATA,
  MOCK_WORKSPACES,
} from "./fixtures";

const PRIMARY_WORKSPACE = MOCK_WORKSPACES[0];

/** Grid panel order — matches the 2×2 layout in grid.reference.html (top-left,
 *  top-right, bottom-left, bottom-right). Tab `key === agent id`: that's how
 *  App.tsx's `openTerminal({ key: a.id, ... })` keys a terminal opened from an
 *  agent card (src/App.tsx:413), so seeding `apex.openTabs`/`apex.gridKeys` with
 *  these same ids is what makes a restored tab resolve back to its agent. */
const GRID_AGENT_IDS = ["documents-44", "muya-all", "opencode-review", "iptv-2a"];

/** Frozen clock: 2026-09-30T23:21:00 local — matches the reference header clock. */
const FROZEN_MS = new Date(2026, 8, 30, 23, 21, 0).getTime();

let installed = false;

export function maybeInstallMock(): boolean {
  if (installed) return true; // idempotent — a second call (e.g. StrictMode) is a no-op
  if (!(import.meta.env.DEV || import.meta.env.MODE === "mock")) return false;
  if (typeof window === "undefined") return false;
  if ("__TAURI_INTERNALS__" in window) return false;

  const params = new URLSearchParams(window.location.search);
  if (params.get("mock") !== "1") return false;

  const screen = params.get("screen") === "grid" ? "grid" : "control";
  const theme = params.get("theme"); // "light" | "dark" | null

  seedLocalStorage(screen, theme);
  freezeClock();
  mockWindows("main");
  mockIPC(handleInvoke, { shouldMockEvents: true });

  installed = true;
  return true;
}

// ---------------------------------------------------------------------------
// localStorage seeding — read by App.tsx BEFORE the first render (useState
// initializers), so this must run before `../main` (React root) is imported.
// ---------------------------------------------------------------------------

function seedLocalStorage(screen: "control" | "grid", theme: string | null) {
  const set = (k: string, v: string) => {
    try {
      window.localStorage.setItem(k, v);
    } catch {
      /* private window / storage disabled — app still boots, just un-seeded */
    }
  };

  set("apex.workspaces", JSON.stringify(MOCK_WORKSPACES));
  set("apex.worktrees", "[]"); // keeps tracked-path count == workspaces.length == 3
  set("apex.selectedRoot", PRIMARY_WORKSPACE);

  // Terminal tabs for the 4 agents the grid view shows. Ordered [muya-all, ...]
  // so `loadTabs()[0]` (the initial `activeTerminalKey`) is muya-all — the agent
  // the Control reference shows open/highlighted.
  const tabOrder = ["muya-all", "documents-44", "opencode-review", "iptv-2a"];
  const cwdFor: Record<string, string> = {
    "muya-all": PRIMARY_WORKSPACE,
    "documents-44": PRIMARY_WORKSPACE,
    "opencode-review": PRIMARY_WORKSPACE,
    "iptv-2a": MOCK_WORKSPACES[1],
  };
  const tabs = tabOrder.map((key) => ({
    key,
    name: key,
    kind: "terminal" as const,
    cwd: cwdFor[key],
  }));
  set("apex.openTabs", JSON.stringify(tabs));
  set("apex.gridKeys", JSON.stringify(GRID_AGENT_IDS));
  set("apex.viewMode", screen === "grid" ? "grid" : "tabs");

  if (theme === "light" || theme === "dark") set("apex.theme", theme);
}

// ---------------------------------------------------------------------------
// Frozen clock — only under mock mode. Header clock + any "Xm Ys ago" style
// duration math reads `Date.now()`/`new Date()`, so both are pinned.
// ---------------------------------------------------------------------------

function freezeClock() {
  const RealDate = Date;

  class FrozenDate extends RealDate {
    // `ConstructorParameters<typeof Date>` picks Date's LAST overload (fixed arity), so
    // TypeScript would call the no-argument branch impossible. Take the args untyped and
    // hand them to the one overload that accepts a spread.
    constructor(...args: unknown[]) {
      if (args.length === 0) super(FROZEN_MS);
      else super(...(args as [number, number, number?, number?, number?, number?, number?]));
    }
    static now() {
      return FROZEN_MS;
    }
  }

  // @ts-expect-error — intentional global override, mock mode only
  window.Date = FrozenDate;
}

// ---------------------------------------------------------------------------
// PTY channel feed — Channel<InvokeResponseBody> expects `runCallback(id, {index,
// message})` where `message` becomes `msg` in the component's `channel.onmessage`.
// Terminal.tsx only handles `msg instanceof ArrayBuffer` (text) or `{type:"exit"}`,
// so text chunks must be real ArrayBuffers, not plain strings.
// ---------------------------------------------------------------------------

function feedPtyChannel(channel: unknown, lines: string[]) {
  const internals = (window as unknown as {
    __TAURI_INTERNALS__?: { runCallback?: (id: number, data: unknown) => void };
  }).__TAURI_INTERNALS__;
  const id = (channel as { id?: number } | undefined)?.id;
  if (!internals?.runCallback || typeof id !== "number") return;
  lines.forEach((line, i) => {
    setTimeout(() => {
      const bytes = new TextEncoder().encode(`${line}\r\n`);
      internals.runCallback!(id, { index: i, message: bytes.buffer });
    }, i * 40);
  });
}

let ptyCounter = 0;
const ptyCwdById = new Map<string, string>();

function spawnMockPty(payload: Record<string, unknown> | undefined): string {
  const id = `mock-pty-${++ptyCounter}`;
  const cwd = typeof payload?.cwd === "string" ? (payload.cwd as string) : PRIMARY_WORKSPACE;
  ptyCwdById.set(id, cwd);
  feedPtyChannel(payload?.onEvent, MOCK_TERMINAL_LINES);
  return id;
}

// ---------------------------------------------------------------------------
// Command dispatch
// ---------------------------------------------------------------------------

const warnedOnce = new Set<string>();

function warnUnknown(cmd: string) {
  if (warnedOnce.has(cmd)) return;
  warnedOnce.add(cmd);
  // eslint-disable-next-line no-console
  console.warn(`[mock] unhandled Tauri command "${cmd}" — returning null`);
}

/** Result<(),String>-shaped commands — a bare success is all any caller needs. */
const NULL_OK = new Set([
  "allow_asset_path",
  "bridge_pair_confirm_sas",
  "bridge_pair_connect",
  "bridge_pair_start_listener",
  "bridge_pair_stop_listener",
  "bridge_remote_listen",
  "bridge_remote_send",
  "bridge_revoke_peer",
  "bridge_send",
  "bridge_set_auto_run",
  "bridge_set_capability",
  "bridge_execute_task",
  "bridge_fan_out",
  "create_dir",
  "create_file",
  "credstore_cred_remove",
  "credstore_disable_biometric_unlock",
  "credstore_enable_biometric_unlock",
  "credstore_import_key",
  "credstore_import_secret",
  "credstore_init",
  "credstore_lock",
  "credstore_unlock",
  "credstore_unlock_biometric",
  "cyberark_logoff",
  "cyberark_test_connection",
  "debug_log_set",
  "delete_entry",
  "frontend_log",
  "install_mcp",
  "install_skill",
  "open_privacy_settings",
  "pty_kill",
  "pty_resize",
  "pty_write",
  "relaunch_in_place",
  "release_agent_session",
  "rename_entry",
  "reveal_in_finder",
  "set_workspace_roots",
  "ssh_release_session",
  "ssh_remove_psmp_profile",
  "ssh_remove_server",
  "ssh_set_cyberark_config",
  "start_watching",
  "vault_restart",
  "vault_set_path",
  "write_file",
]);

/** Vec<T>-shaped commands with nothing interesting to say. */
const EMPTY_ARRAY = new Set([
  "bridge_audit_log",
  "bridge_list_peers",
  "bridge_poll_inbound",
  "cyberark_list_accounts",
  "fetch_skill_marketplace",
  "get_startup_files",
  "list_dir",
  "list_session_history",
  "scan_prd_docs",
  "search_session_contents",
  "vault_detect_candidates",
]);

/** Result<String,String>-shaped commands returning an empty-but-valid string. */
const EMPTY_STRING = new Set([
  "credstore_export",
  "credstore_export_cred",
  "credstore_export_master",
  "credstore_reveal_cred",
  "export_session_markdown",
  "install_muya_plugin",
  "kill_session",
  "read_file",
  "read_head_file",
  "read_session_transcript",
  "remove_worktree",
  "stop_agent",
]);

function handleInvoke(cmd: string, rawPayload?: unknown): unknown {
  const payload = (rawPayload ?? {}) as Record<string, unknown>;

  // --- plugin:* commands (app/window/updater/dialog/opener/process/clipboard) ---
  if (cmd.startsWith("plugin:")) return handlePlugin(cmd, payload);

  if (NULL_OK.has(cmd)) return null;
  if (EMPTY_ARRAY.has(cmd)) return [];
  if (EMPTY_STRING.has(cmd)) return "";

  switch (cmd) {
    // --- agents / sessions -------------------------------------------------
    case "list_agent_sessions":
      return MOCK_AGENTS;

    // --- pty -----------------------------------------------------------------
    case "pty_spawn":
    case "ssh_pty_connect":
      return spawnMockPty(payload);
    case "pty_cwds": {
      const ids = Array.isArray(payload.ids) ? (payload.ids as string[]) : [];
      const out: Record<string, string> = {};
      for (const id of ids) out[id] = ptyCwdById.get(id) ?? PRIMARY_WORKSPACE;
      return out;
    }
    case "pty_session_ids":
      return {};

    // --- git / project manager ------------------------------------------------
    case "git_status":
      return payload.root === PRIMARY_WORKSPACE ? MOCK_GIT_STATUS : [];
    case "pm_status": {
      const paths = Array.isArray(payload.paths) ? (payload.paths as string[]) : [];
      return paths.map(
        (p) =>
          MOCK_PROJECT_STATUS[p] ?? {
            path: p,
            name: p.split("/").pop() || p,
            isGit: false,
            branch: "",
            base: "",
            ahead: 0,
            behind: 0,
            dirty: 0,
            changed: 0,
            lastActivity: 0,
          },
      );
    }
    case "pm_check_merge":
      return { clean: true, detail: "would merge cleanly" };
    case "pm_collisions":
      return MOCK_COLLISION_REPORT;
    case "list_branches":
      return MOCK_BRANCHES;
    case "branch_detail":
      return {
        name: payload.branch ?? "main",
        base: "main",
        ahead: 0,
        behind: 0,
        commits: [],
        changedFiles: MOCK_GIT_STATUS.map(([, path]) => path),
      };
    case "create_worktree":
      return `${PRIMARY_WORKSPACE}-wt-${String(payload.branch ?? "branch")}`;

    // --- filesystem misc -------------------------------------------------------
    case "path_kind":
      return "dir";
    case "resolve_path_kind":
      return { resolved: String(payload.path ?? ""), kind: "dir" };
    case "file_access_status":
      // Snake_case on purpose — FileAccessStatus (src-tauri/src/fs.rs) has no
      // `#[serde(rename_all = "camelCase")]`, unlike almost every other struct
      // in this codebase; FileAccessGate.tsx's TS interface confirms it.
      return {
        translocated: false,
        exe_path: "",
        folders: [],
        original_path: null,
        relaunch_fixes_it: false,
      };
    case "local_ip":
      return "127.0.0.1";

    // --- app metrics / version -------------------------------------------------
    case "app_metrics":
      return MOCK_APP_METRICS;

    // --- credstore ---------------------------------------------------------------
    case "credstore_status":
      return { initialized: false, unlocked: false };
    case "credstore_biometric_available":
      return false;
    case "credstore_cred_list":
      return [];
    case "credstore_cred_upsert":
      return `mock-cred-${Date.now()}`;

    // --- ssh -----------------------------------------------------------------------
    case "ssh_get_config":
      return { version: 1, servers: [], psmpProfiles: [], cyberark: null };
    case "ssh_upsert_server":
    case "ssh_upsert_psmp_profile":
      return `mock-ssh-${Date.now()}`;

    // --- cyberark --------------------------------------------------------------------
    case "cyberark_status":
      return false;

    // --- vault (Obsidian RAG) ---------------------------------------------------------
    case "vault_get_status":
      return { configuredPath: null, resolvedPath: null, serverInstalled: false };

    // --- debug log -------------------------------------------------------------------
    case "debug_log_get":
      return {};

    // --- resources / marketplace -------------------------------------------------------
    case "list_claude_resources":
      return { skills: [], agents: [], hooks: [], mcps: [] };
    case "fetch_mcp_marketplace":
      return { mcps: [] };

    // --- bridge (a few with non-null, non-array shapes) ---------------------------------
    case "bridge_check_port":
      return false;
    case "bridge_local_listen":
      return 0;
    case "bridge_pair_invite":
      return "";
    case "bridge_run_claude":
      return "";

    default:
      warnUnknown(cmd);
      return null;
  }
}

function handlePlugin(cmd: string, payload: Record<string, unknown>): unknown {
  switch (cmd) {
    case "plugin:app|version":
      return MOCK_APP_VERSION;
    case "plugin:updater|check":
      return MOCK_UPDATE_METADATA;
    case "plugin:updater|download_and_install":
      return null;
    case "plugin:window|is_fullscreen":
      return false;
    case "plugin:window|set_theme":
    case "plugin:window|set_fullscreen":
      return null;
    case "plugin:window|theme":
      return "dark";
    case "plugin:dialog|open":
    case "plugin:dialog|save":
      return null;
    case "plugin:dialog|message":
      return null;
    case "plugin:opener|open_url":
    case "plugin:opener|open_path":
    case "plugin:opener|reveal_item_in_dir":
      return null;
    case "plugin:process|restart":
    case "plugin:process|exit":
      return null;
    case "plugin:clipboard-manager|write_text":
      return null;
    case "plugin:clipboard-manager|read_text":
      return "";
    default:
      // plugin:event|* is handled internally by mockIPC's `shouldMockEvents`
      // before it ever reaches this function. Anything else unrecognized here
      // (window/webview getters this app doesn't call) — a safe `null` covers
      // both void and "falsy" typed responses without crashing a `.then()`.
      if (!cmd.startsWith("plugin:event|")) warnUnknown(cmd);
      return null;
  }
}

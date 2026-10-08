import { memo, useCallback, useEffect, useRef, useState } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { SearchAddon } from "@xterm/addon-search";
import { acquireWebgl, type WebglLease } from "../lib/webglRenderer";
import { Channel, invoke } from "@tauri-apps/api/core";
import { X, ChevronUp, ChevronDown } from "lucide-react";
import "@xterm/xterm/css/xterm.css";
import { altArrowSeq } from "../lib/keys";
import { schemeTheme } from "../theme/terminalThemes";
import { stepTerminalFont, useTerminalPrefs } from "../lib/terminalPrefs";
import { parseClaudeScreen, readScreenLines, type ScreenState } from "../lib/screenState";
import { isMuyaChannelWarning } from "../lib/channelPrompt";
import { applyLaunchFlags } from "../lib/statusline";
import { appModalOpen } from "../lib/modalOpen";

// Output bytes arrive as a raw ArrayBuffer (binary fetch path — no JSON byte
// bloat); process-exit arrives as a small JSON object. See src-tauri/src/pty.rs.
type PtyMsg = ArrayBuffer | { type: "exit" };

export type TermTheme = "dark" | "light";

/**
 * Real interactive terminal: an xterm.js view wired to a PTY-backed login shell in
 * the Rust backend (commands pty_spawn / pty_write / pty_resize / pty_kill). Opens
 * in `cwd`; respawns when `cwd` changes. From here the user can run `claude`,
 * `claude attach <id>`, `claude --resume <id>`, git, etc.
 */
const MOUSE_SEQ = [0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x30]; // ESC [ ? 1 0 0

/**
 * Last mouse-tracking mode switch in a PTY chunk: true for `ESC[?1000h`/`1002h`/`1003h`,
 * false for the matching `…l`, undefined when the chunk has none. Scans the bytes
 * directly — decoding every chunk of every terminal to a string just to run two regexes
 * was pure allocation churn. (A sequence split across two chunks is missed, as before.)
 */
export function mouseTrackingChange(b: Uint8Array): boolean | undefined {
  let out: boolean | undefined;
  for (let i = b.indexOf(0x1b); i !== -1 && i + 7 < b.length; i = b.indexOf(0x1b, i + 1)) {
    let j = 1;
    while (j < MOUSE_SEQ.length && b[i + j] === MOUSE_SEQ[j]) j++;
    if (j < MOUSE_SEQ.length) continue;
    const variant = b[i + 6];
    const end = b[i + 7];
    if ((variant === 0x30 || variant === 0x32 || variant === 0x33) && (end === 0x68 || end === 0x6c)) out = end === 0x68;
  }
  return out;
}

/** Memoized: the app re-renders often (agent status, clock…) and every open terminal is
 *  mounted, so an unmemoized Terminal re-ran for all of them each time. Pass stable
 *  callbacks (App keeps one handler set per tab) or the memo never hits. */
export default memo(Terminal);

function Terminal({
  cwd,
  initialCommand,
  sshServerId,
  autoAcceptTrust,
  theme = "dark",
  active = true,
  focusToken,
  onPtyReady,
  onPromptSubmit,
  onPathMenu,
  onScreen,
}: {
  cwd?: string;
  initialCommand?: string;
  /** When set, spawn the `ssh` process directly via `ssh_pty_connect` (Rust
   *  builds the command and injects the stored/CyberArk password into the PTY —
   *  the secret never reaches JS) instead of a login shell + initialCommand. */
  sshServerId?: string;
  /** After the initial command runs, also send a bare Enter a few seconds later to
   *  accept claude's "is this folder trusted?" prompt if `cwd` is new to it — without
   *  this, a freshly opened session can sit stuck on that prompt before it's even
   *  discoverable via `claude agents --json` for anyone to answer it. Empirically safe
   *  to send unconditionally: when no such prompt appears (an already-trusted cwd),
   *  the stray Enter lands on claude's own idle prompt line and is a no-op. */
  autoAcceptTrust?: boolean;
  theme?: TermTheme;
  active?: boolean;
  /** Bumped by the parent when the operator deliberately picks THIS tab. `active`
   *  alone can't carry that: in grid mode every grid terminal stays `active`, so
   *  picking one produces no flip and the show-effect below never runs. Undefined
   *  for every terminal that isn't the picked one. */
  focusToken?: number;
  /** Called once with the PTY id after the shell spawns — lets the parent send pty_write. */
  onPtyReady?: (id: string) => void;
  /**
   * Fire-and-forget callback when the user presses Enter.
   * Receives the keystroke buffer content for sidebar updates (e.g. vault search).
   * Does NOT intercept or modify the PTY input — Enter passes through normally.
   */
  onPromptSubmit?: (prompt: string) => void;
  /** A path in the terminal output was clicked/right-clicked — parent shows an action menu. */
  onPathMenu?: (resolved: string, kind: "file" | "dir", x: number, y: number) => void;
  /** What the visible screen shows (Claude's spinner line, permission dialog, mode
   *  footer), parsed from the xterm buffer. Throttled to ~300ms after the last output
   *  and reported ONLY when it changed — the backend exposes none of this. */
  onScreen?: (state: ScreenState) => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const termRef = useRef<XTerm | null>(null);
  const searchRef = useRef<SearchAddon | null>(null);
  const searchInputRef = useRef<HTMLInputElement>(null);
  // Set by the lifecycle effect to its `syncSize` (fit xterm + push size to the PTY).
  // The `active` effect calls it on show without reaching into the other effect's scope.
  const syncRef = useRef<() => void>(() => {});
  // WebGL renderer lease — live while visible, suspended while hidden (acquireWebgl).
  const webglRef = useRef<WebglLease | null>(null);
  const activeRef = useRef(active);
  activeRef.current = active;
  const focusTokenRef = useRef(focusToken);
  focusTokenRef.current = focusToken;
  // Consecutive GPU losses while visible; reset on a normal hide.
  const gpuLossesRef = useRef(0);
  // Acquire the GPU renderer for a visible, laid-out terminal. Without WebGL the DOM
  // renderer stays, and one swapped in unpainted draws nothing until refreshed.
  const attachRenderer = useCallback(function attach() {
    const t = termRef.current;
    if (!t || webglRef.current?.live || !activeRef.current) return;
    webglRef.current?.release();
    webglRef.current = acquireWebgl(t, () => {
      webglRef.current = null;
      // GPU reset / sleep-wake under a visible tab: take a fresh context, unless the
      // GPU keeps dropping them — then settle on the DOM renderer.
      if (activeRef.current && ++gpuLossesRef.current <= 3) requestAnimationFrame(attach);
      else t.refresh(0, t.rows - 1);
    });
    if (!webglRef.current) t.refresh(0, t.rows - 1);
  }, []);
  // Stable ref to the show-search setter — used inside the xterm key handler closure.
  const openSearchRef = useRef<() => void>(() => {});
  // Keystroke buffer: accumulates printable chars typed by the user so they can be
  // Accumulates printable chars so onPromptSubmit receives the typed text on Enter.
  const keystrokeBufferRef = useRef<string>("");
  // Stable ref to onPromptSubmit so the xterm key handler closure never goes stale.
  const onPromptSubmitRef = useRef<((p: string) => void) | undefined>(undefined);
  // Stable refs for the path-link provider closure (registered once).
  const onPathMenuRef = useRef<typeof onPathMenu>(undefined);
  const cwdRef = useRef<string | undefined>(cwd);
  useEffect(() => { onPathMenuRef.current = onPathMenu; }, [onPathMenu]);
  const onScreenRef = useRef<typeof onScreen>(undefined);
  onScreenRef.current = onScreen;
  useEffect(() => { cwdRef.current = cwd; }, [cwd]);
  // Cache of resolved path candidates (key: `${cwd}\0${token}`) → {resolved, kind}.
  const pathKindCacheRef = useRef<Map<string, { resolved: string; kind: string }>>(new Map());
  // The link currently under the mouse (for right-click → same menu).
  const hoveredLinkRef = useRef<{ resolved: string; kind: "file" | "dir" } | null>(null);

  // Operator-picked font size + color scheme (shared by every terminal). Read through a
  // ref at creation so changing them never respawns the PTY; the effects below apply them live.
  const prefs = useTerminalPrefs();
  const prefsRef = useRef(prefs);
  prefsRef.current = prefs;
  const xtheme = schemeTheme(prefs.scheme, theme);

  const [showSearch, setShowSearch] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");

  const closeSearch = useCallback(() => {
    setShowSearch(false);
    setSearchQuery("");
    // Return focus to the terminal.
    termRef.current?.focus();
  }, []);

  // Wire up the stable openSearch ref whenever closeSearch is recreated.
  useEffect(() => {
    openSearchRef.current = () => {
      setShowSearch(true);
      // Focus the search input on next paint.
      requestAnimationFrame(() => searchInputRef.current?.focus());
    };
  }, []);

  useEffect(() => {
    onPromptSubmitRef.current = onPromptSubmit;
  }, [onPromptSubmit]);

  // When search becomes visible, auto-focus the input.
  useEffect(() => {
    if (showSearch) {
      requestAnimationFrame(() => searchInputRef.current?.focus());
    }
  }, [showSearch]);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    const term = new XTerm({
      fontFamily: '"JetBrains Mono", ui-monospace, monospace',
      fontSize: prefsRef.current.fontSize,
      lineHeight: prefsRef.current.lineHeight,
      letterSpacing: prefsRef.current.letterSpacing,
      cursorBlink: true,
      scrollback: 5000,
      theme: schemeTheme(prefsRef.current.scheme, theme),
    });
    termRef.current = term;
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(el);

    // When a TUI program (vim, less, htop) enables PTY mouse-tracking mode it sends
    // escape sequences like \x1b[?1000h. xterm.js already forwards wheel events to the
    // PTY in that case — calling term.scrollLines() on top would double-scroll.
    // Track the active mouse-tracking state by watching for the mode-set/reset sequences
    // in the PTY output stream, and only scroll the viewport when tracking is inactive.
    let mouseTrackingActive = false;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault(); // always prevent browser native scroll
      if (!mouseTrackingActive) {
        const lines = Math.sign(e.deltaY) * Math.max(1, Math.round(Math.abs(e.deltaY) / 40));
        term.scrollLines(lines);
      }
    };
    el.addEventListener("wheel", onWheel, { passive: false });

    // Full-text search inside the terminal buffer (Cmd+F).
    const search = new SearchAddon();
    term.loadAddon(search);
    searchRef.current = search;

    // ── Path links: detect filesystem paths in output and make them actionable.
    // A candidate is linkified ONLY after resolve_path_kind confirms it exists,
    // which kills false positives (PRD AC-6).
    const PATH_RE = /(?:~\/|\.{0,2}\/)[^\s"'<>|()]+|[\w.\-]+\/[^\s"'<>|()]+/g;
    const resolveCandidate = async (token: string) => {
      const c = cwdRef.current ?? "";
      const key = `${c}\0${token}`;
      const cached = pathKindCacheRef.current.get(key);
      if (cached) return cached;
      let res = { resolved: token, kind: "none" };
      try {
        res = await invoke<{ resolved: string; kind: string }>("resolve_path_kind", {
          path: token, cwd: cwdRef.current,
        });
      } catch { /* leave as none */ }
      pathKindCacheRef.current.set(key, res);
      // Bound the cache so a long session doesn't grow it forever.
      if (pathKindCacheRef.current.size > 2000) pathKindCacheRef.current.clear();
      return res;
    };
    term.registerLinkProvider({
      provideLinks(bufferLineNumber, callback) {
        const line = term.buffer.active.getLine(bufferLineNumber - 1);
        if (!line) { callback(undefined); return; }
        const text = line.translateToString(true);
        const candidates: { token: string; index: number }[] = [];
        let m: RegExpExecArray | null;
        PATH_RE.lastIndex = 0;
        while ((m = PATH_RE.exec(text)) !== null) {
          let token = m[0];
          // Trim trailing punctuation the CLI often prints after a path.
          const trimmed = token.replace(/[.,:;)\]]+$/, "");
          candidates.push({ token: trimmed, index: m.index });
        }
        if (candidates.length === 0) { callback(undefined); return; }
        void Promise.all(candidates.map((c) => resolveCandidate(c.token))).then((kinds) => {
          const links = candidates.flatMap((c, i) => {
            const k = kinds[i];
            if (k.kind !== "file" && k.kind !== "dir") return [];
            const resolved = k.resolved;
            const kind = k.kind as "file" | "dir";
            return [{
              range: {
                start: { x: c.index + 1, y: bufferLineNumber },
                end: { x: c.index + c.token.length, y: bufferLineNumber },
              },
              text: c.token,
              activate: (event: MouseEvent) => {
                onPathMenuRef.current?.(resolved, kind, event.clientX, event.clientY);
              },
              hover: () => { hoveredLinkRef.current = { resolved, kind }; },
              leave: () => { hoveredLinkRef.current = null; },
            }];
          });
          callback(links.length ? links : undefined);
        });
      },
    });
    // Right-click over a hovered path link → the same action menu.
    const onCtxMenu = (e: MouseEvent) => {
      const link = hoveredLinkRef.current;
      if (link && onPathMenuRef.current) {
        e.preventDefault();
        onPathMenuRef.current(link.resolved, link.kind, e.clientX, e.clientY);
      }
    };
    el.addEventListener("contextmenu", onCtxMenu);

    // The GPU renderer is attached by the `active` effect, not here: a live context per
    // mounted terminal exceeds WebKit's cap of 16, and evicted tabs fell back to DOM.
    try {
      fit.fit();
    } catch {
      /* element not laid out yet */
    }

    let ptyId: string | null = null;
    let disposed = false;

    // Screen parse: trailing-edge throttle, so a burst of output costs one parse.
    let screenTimer: number | undefined;
    let lastScreen = "";
    const scheduleScreenParse = () => {
      if (!onScreenRef.current || screenTimer !== undefined) return;
      screenTimer = window.setTimeout(() => {
        screenTimer = undefined;
        if (disposed) return;
        try {
          const state = parseClaudeScreen(readScreenLines(term));
          // The spinner glyph animates several times a second and nothing shows it;
          // leaving it in the signature re-rendered the whole app on every frame.
          const sig = JSON.stringify(state, (k, v) => (k === "glyph" ? undefined : v));
          if (sig === lastScreen) return;
          lastScreen = sig;
          onScreenRef.current?.(state);
        } catch {
          /* buffer read raced a dispose */
        }
      }, 300);
    };

    // Claude Code asks once per session before loading Muya's channel (CHANNEL_FLAG in
    // statusline.ts). Muya confirms it (operator decision, PRD bridge-channel-delivery):
    // only output that could be that screen triggers a look, and the screen must name
    // Muya's channel alone with option 1 selected (isMuyaChannelWarning).
    const decoder = new TextDecoder();
    // The phrase can straddle two PTY reads: test it against the recent tail, not one chunk.
    let outputTail = "";
    let channelTimer: number | undefined;
    let channelAcceptedAt = 0;
    const checkChannelWarning = (bytes: Uint8Array) => {
      outputTail = (outputTail + decoder.decode(bytes, { stream: true })).slice(-400);
      if (channelTimer !== undefined || !/development\s+channels/i.test(outputTail)) return;
      outputTail = "";
      // xterm renders asynchronously and the screen then stays still (no more output to
      // re-trigger us), so look a few times before giving up.
      const look = (triesLeft: number) => {
        channelTimer = window.setTimeout(() => {
          channelTimer = undefined;
          if (disposed || !ptyId || Date.now() - channelAcceptedAt < 5000) return;
          let found = false;
          try {
            found = isMuyaChannelWarning(readScreenLines(term));
          } catch {
            return;
          }
          if (!found) {
            if (triesLeft > 0) look(triesLeft - 1);
            return;
          }
          channelAcceptedAt = Date.now();
          void invoke("pty_write", { id: ptyId, data: "\r" }).catch(() => {});
        }, 250);
      };
      look(4);
    };

    // xterm measures its cell size from the font at term.open() time. JetBrains Mono is
    // bundled (fontsource) but may not have finished loading yet on a cold start, so the
    // very first fit above can use a fallback-font cell size and mis-measure cols/rows.
    // Refit once the font is actually ready — a no-op if it already was.
    void document.fonts?.ready.then(() => {
      if (disposed) return;
      try {
        fit.fit();
        if (ptyId) void invoke("pty_resize", { id: ptyId, cols: term.cols, rows: term.rows });
      } catch {
        /* element unmounted or hidden by the time fonts resolved */
      }
    });

    // Reset keystroke buffer for this new PTY session.
    keystrokeBufferRef.current = "";

    // Shift+Enter → newline (not submit) in the Claude prompt. Claude Code treats a
    // bare LF (\n, the byte Ctrl+J sends) as "insert newline" and CR (\r) as "submit".
    // Legacy terminal encoding sends \r for both Enter and Shift+Enter, so xterm can't
    // tell them apart — we intercept Shift+Enter and write \n ourselves. This is the
    // Ctrl+J sequence Claude accepts in every terminal without /terminal-setup; the old
    // \x16\r (readline quoted-insert) inserted a literal ^M instead of a real newline.
    // Cmd+F → open the in-terminal search overlay.
    // Plain Enter with onBeforeSubmit: buffer → augment → \x15 (Ctrl+U clear) → augmented\r.
    term.attachCustomKeyEventHandler((e: KeyboardEvent) => {
      // A modal/overlay owns the keyboard: do NOT let keys reach the PTY while
      // one is open. Returning false makes xterm ignore the key WITHOUT calling
      // preventDefault, so the event still bubbles to the modal's own handler
      // (e.g. Esc closes it). Without this, Esc typed at an open modal went into
      // the terminal and interrupted the running Claude session. (L19)
      if (appModalOpen()) {
        return false;
      }
      // AC-0-2: Shift+Enter → \n (newline, not submit). Always preserved.
      if (e.key === "Enter" && e.shiftKey && !e.ctrlKey && !e.altKey && !e.metaKey) {
        if (e.type === "keydown" && ptyId)
          void invoke("pty_write", { id: ptyId, data: "\n" });
        return false;
      }
      // Cmd+F → in-terminal search overlay.
      if (e.key === "f" && e.metaKey && !e.shiftKey && !e.ctrlKey && !e.altKey) {
        if (e.type === "keydown") openSearchRef.current();
        return false;
      }

      // Cmd+= / Cmd+- / Cmd+0 → terminal font bigger / smaller / default (all terminals).
      if (e.metaKey && !e.ctrlKey && !e.altKey && (e.key === "=" || e.key === "+" || e.key === "-" || e.key === "0")) {
        if (e.type === "keydown") stepTerminalFont(e.key === "-" ? -1 : e.key === "0" ? 0 : 1);
        e.preventDefault();
        return false;
      }

      // Cmd+Shift+C → launch claude session
      if (e.metaKey && e.shiftKey && !e.ctrlKey && !e.altKey && e.type === "keydown" && e.key.toLowerCase() === "c" && ptyId) {
        const id = ptyId;
        void applyLaunchFlags("claude --dangerously-skip-permissions")
          .then((cmd) => invoke("pty_write", { id, data: `${cmd}\r` }))
          .catch(() => {});
        e.preventDefault();
        return false;
      }

      // macOS terminal shortcuts — Cmd+key → Ctrl char to PTY.
      // Tauri webview swallows these (e.g. Cmd+R = reload). We intercept
      // and send the terminal control equivalent so they work like iTerm/Terminal.app.
      if (e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey && e.type === "keydown" && ptyId) {
        const cmdMap: Record<string, string> = {
          r: "\x12",   // Ctrl+R — reverse history search
          k: "\x0b",   // Ctrl+K — kill to end of line
          l: "\x0c",   // Ctrl+L — clear screen
          a: "\x01",   // Ctrl+A — beginning of line
          e: "\x05",   // Ctrl+E — end of line
          d: "\x04",   // Ctrl+D — EOF / delete forward
          c: "\x03",   // Ctrl+C — SIGINT (only when no text selected)
          u: "\x15",   // Ctrl+U — kill line (backward)
          w: "",       // Cmd+W handled by Tauri menu — skip
        };
        const ctrl = cmdMap[e.key.toLowerCase()];
        if (ctrl !== undefined && ctrl !== "") {
          // Cmd+C: only send SIGINT if no text is selected; otherwise let webview copy
          if (e.key.toLowerCase() === "c") {
            const sel = termRef.current?.getSelection();
            if (sel && sel.length > 0) return true; // let default copy happen
          }
          void invoke("pty_write", { id: ptyId, data: ctrl });
          e.preventDefault();
          return false;
        }
      }

      // Option/Alt + arrows. macOS xterm emits the modified-arrow CSI
      // (\x1b[1;3D / \x1b[1;3C / …), which zsh/bash render as literal ";3D"/";3C"
      // noise when the sequence isn't bound. Send what the shell already
      // understands instead — the readline meta word-nav for Left/Right, and the
      // plain arrow for Up/Down — exactly like Terminal.app / iTerm2.
      if (e.altKey && !e.metaKey && !e.ctrlKey && !e.shiftKey && e.type === "keydown" && ptyId) {
        const seq = altArrowSeq(e.key);
        if (seq) {
          void invoke("pty_write", { id: ptyId, data: seq });
          e.preventDefault();
          return false;
        }
      }

      // Only keydown events carry semantic key info for the buffer logic.
      if (e.type !== "keydown") return true;

      const promptSubmit = onPromptSubmitRef.current;
      if (promptSubmit) {
        if (e.key === "Enter" && !e.shiftKey && !e.ctrlKey && !e.altKey && !e.metaKey) {
          const prompt = keystrokeBufferRef.current;
          keystrokeBufferRef.current = "";
          promptSubmit(prompt);
          return true; // let xterm send \r normally
        }

        if (e.key === "Backspace") {
          keystrokeBufferRef.current = keystrokeBufferRef.current.slice(0, -1);
          return true;
        }

        if (e.key === "u" && e.ctrlKey && !e.shiftKey && !e.altKey && !e.metaKey) {
          keystrokeBufferRef.current = "";
          return true;
        }

        if (e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
          keystrokeBufferRef.current += e.key;
        }
      }

      return true;
    });

    // Fit xterm to the element and push the resulting grid to the PTY. Bails while the
    // element is hidden (0×0) — fitting then would shrink the PTY to ~0 and corrupt a
    // full-screen TUI. Shared by the ResizeObserver, the post-spawn sync, and (via
    // syncRef) the `active` effect when a hidden tab is re-shown.
    const syncSize = () => {
      if (el.offsetWidth === 0 || el.offsetHeight === 0) return;
      try {
        fit.fit();
      } catch {
        return;
      }
      if (ptyId)
        void invoke("pty_resize", { id: ptyId, cols: term.cols, rows: term.rows });
    };
    syncRef.current = syncSize;

    const channel = new Channel<PtyMsg>();
    channel.onmessage = (msg) => {
      // Output can still arrive after the component unmounts (StrictMode double-mount
      // in dev, or a fast close). Writing to a disposed xterm throws — guard it.
      if (disposed) return;
      try {
        if (msg instanceof ArrayBuffer) {
          // Detect mouse-tracking mode-set/reset sequences in PTY output so the wheel
          // handler knows whether xterm is already forwarding scroll events to the PTY.
          const bytes = new Uint8Array(msg);
          const mode = mouseTrackingChange(bytes);
          if (mode !== undefined) mouseTrackingActive = mode;
          term.write(bytes);
          scheduleScreenParse();
          checkChannelWarning(bytes);
        } else if (msg && msg.type === "exit") {
          mouseTrackingActive = false;
          term.write("\r\n\x1b[2m[process exited — close or reselect a session]\x1b[0m\r\n");
        }
      } catch {
        /* terminal disposed mid-write */
      }
    };

    // SSH tabs spawn the `ssh` process directly (Rust injects the password into
    // the PTY); every other tab spawns a login shell and optionally auto-runs a
    // command. The two paths differ only in the spawn invoke.
    const spawn = sshServerId
      ? invoke<string>("ssh_pty_connect", {
          onEvent: channel,
          serverId: sshServerId,
          cols: term.cols,
          rows: term.rows,
        })
      : invoke<string>("pty_spawn", {
          onEvent: channel,
          cwd,
          cols: term.cols,
          rows: term.rows,
        });
    spawn
      .then((id) => {
        if (disposed) {
          void invoke("pty_kill", { id });
          return;
        }
        ptyId = id;
        onPtyReady?.(id);
        term.onData((d) => void invoke("pty_write", { id, data: d }));
        // The element may have been laid out (or resized) between open() and now while
        // ptyId was still null — syncSize then skipped the pty_resize. Push the real
        // size now that the PTY exists so the shell never starts at a stale 80×24.
        syncSize();
        // Auto-run the initial command (e.g. attach/resume) once the prompt is ready.
        // Not used for SSH tabs (the ssh process is the child itself).
        if (initialCommand && !sshServerId) {
          setTimeout(() => {
            if (!disposed && ptyId) {
              const id = ptyId;
              void applyLaunchFlags(initialCommand)
                .then((cmd) => (disposed ? undefined : invoke("pty_write", { id, data: `${cmd}\r` })))
                .catch(() => {});
            }
          }, 600);
          // 4.6s = the 600ms above (before claude's own process even starts) + a
          // live-tested 4s for claude's own startup + the trust prompt rendering,
          // whether or not one actually appears (empirically a no-op either way).
          if (autoAcceptTrust) {
            setTimeout(() => {
              if (!disposed && ptyId) void invoke("pty_write", { id: ptyId, data: "\r" });
            }, 4600);
          }
        }
      })
      .catch((e) =>
        term.write(`\r\n\x1b[31mpty spawn failed: ${String(e)}\x1b[0m\r\n`)
      );

    // Live resize while this tab is visible. While hidden the element is 0×0, so
    // syncSize bails and the resize is deferred to the `active` effect on re-show.
    const ro = new ResizeObserver(syncSize);
    ro.observe(el);
    // A rebuild (cwd/ssh change) of an already-visible tab gets no `active` flip.
    const rendererRaf = activeRef.current ? requestAnimationFrame(attachRenderer) : 0;

    return () => {
      disposed = true;
      if (screenTimer !== undefined) window.clearTimeout(screenTimer);
      cancelAnimationFrame(rendererRaf);
      syncRef.current = () => {};
      webglRef.current?.release();
      webglRef.current = null;
      keystrokeBufferRef.current = "";
      ro.disconnect();
      el.removeEventListener("wheel", onWheel);
      el.removeEventListener("contextmenu", onCtxMenu);
      if (ptyId) void invoke("pty_kill", { id: ptyId });
      term.dispose();
      termRef.current = null;
      searchRef.current = null;
    };
  }, [cwd, sshServerId]);

  // Show: fresh GPU renderer first (it measures the laid-out element), then fit — a
  // resize while hidden never reached the PTY. Hide: free the GPU context.
  useEffect(() => {
    if (!active) {
      webglRef.current?.suspend();
      gpuLossesRef.current = 0;
      return;
    }
    // Focus now, not in the rAF: keys typed during the renderer swap would be lost.
    // Only the SELECTED terminal (the one given a focusToken): when a split or the grid
    // shows several at once, each one focusing itself left the keyboard in whichever
    // ran last, not in the pane the operator picked.
    if (focusTokenRef.current !== undefined) termRef.current?.focus();
    const raf = requestAnimationFrame(() => {
      attachRenderer();
      syncRef.current();
    });
    return () => cancelAnimationFrame(raf);
  }, [active]);

  // Deliberate pick of this tab. Reads `active` through the ref so a pick can't be
  // the thing that focuses a terminal the operator can't see.
  useEffect(() => {
    if (focusToken === undefined || !activeRef.current) return;
    termRef.current?.focus();
  }, [focusToken]);

  // Live theme / scheme switch — recolors the existing terminal without touching the PTY.
  useEffect(() => {
    if (termRef.current) termRef.current.options.theme = xtheme;
  }, [xtheme]);

  // Live font size: new cell size → refit and tell the PTY its new grid. A hidden tab
  // can't be measured; it refits when shown (the `active` effect calls syncRef).
  useEffect(() => {
    const t = termRef.current;
    if (!t || t.options.fontSize === prefs.fontSize) return;
    t.options.fontSize = prefs.fontSize;
    syncRef.current();
  }, [prefs.fontSize]);

  // Live line / letter spacing: same cell-size change as the font, same refit.
  useEffect(() => {
    const t = termRef.current;
    if (!t || (t.options.lineHeight === prefs.lineHeight && t.options.letterSpacing === prefs.letterSpacing)) return;
    t.options.lineHeight = prefs.lineHeight;
    t.options.letterSpacing = prefs.letterSpacing;
    syncRef.current();
  }, [prefs.lineHeight, prefs.letterSpacing]);

  const handleSearchChange = (q: string) => {
    setSearchQuery(q);
    if (searchRef.current && q)
      searchRef.current.findNext(q, { incremental: true });
  };

  const handleSearchKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "Enter") {
      if (e.shiftKey) searchRef.current?.findPrevious(searchQuery);
      else searchRef.current?.findNext(searchQuery);
    }
    if (e.key === "Escape") closeSearch();
    // Don't let keystrokes bubble into xterm.
    e.stopPropagation();
  };

  return (
    <div className="relative h-full w-full overflow-hidden">
      {/* Padding lives on this WRAPPER, never on the element xterm opens into, and the
          wrapper is explicitly border-box. FitAddon sizes the grid from the computed
          height of xterm's parent. Measured live (2026-09-30): this wrapper resolved to
          content-box, so h-full + 40px padding made it 618px in a 578px slot, xterm's
          parent stayed 578px, and the terminal drew 22 rows where 20 fit — the status
          line sat clipped under the progress strip and the right columns ran to the
          edge. The slot that adopts this terminal sets --term-pad (Control 20/28,
          Grid 14/16). */}
      <div
        className="h-full w-full overflow-hidden bg-[var(--bg-terminal)]"
        style={{
          padding: "var(--term-pad, 20px 28px)",
          boxSizing: "border-box",
          // A fixed scheme paints its own background, so the padding around the grid matches.
          ...(prefs.scheme === "muya" ? null : { background: xtheme.background }),
        }}
      >
        <div ref={ref} data-xterm-host className="h-full w-full overflow-hidden" />
      </div>

      {/* In-terminal search overlay — toggled by Cmd+F */}
      {showSearch && (
        <div className="absolute top-2 right-2 z-10 flex items-center gap-1 bg-[var(--bg-control)] border border-[var(--border-strong)] rounded shadow-lg px-2 py-1">
          <input
            ref={searchInputRef}
            type="text"
            value={searchQuery}
            onChange={(e) => handleSearchChange(e.target.value)}
            onKeyDown={handleSearchKeyDown}
            placeholder="Search…"
            className="w-44 bg-transparent text-[var(--text)] text-xs font-mono outline-none placeholder-neutral-500"
          />
          <button
            type="button"
            onClick={() => searchRef.current?.findPrevious(searchQuery)}
            title="Previous match (Shift+Enter)"
            className="text-neutral-400 hover:text-white cursor-pointer p-0.5 transition-colors"
          >
            <ChevronUp className="h-3 w-3" />
          </button>
          <button
            type="button"
            onClick={() => searchRef.current?.findNext(searchQuery)}
            title="Next match (Enter)"
            className="text-neutral-400 hover:text-white cursor-pointer p-0.5 transition-colors"
          >
            <ChevronDown className="h-3 w-3" />
          </button>
          <button
            type="button"
            onClick={closeSearch}
            title="Close (Escape)"
            className="text-neutral-400 hover:text-white cursor-pointer p-0.5 transition-colors ml-0.5"
          >
            <X className="h-3 w-3" />
          </button>
        </div>
      )}
    </div>
  );
}

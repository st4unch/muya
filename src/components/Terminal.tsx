import { useCallback, useEffect, useRef, useState } from "react";
import { Terminal as XTerm, type ITheme } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebglAddon } from "@xterm/addon-webgl";
import { SearchAddon } from "@xterm/addon-search";
import { Channel, invoke } from "@tauri-apps/api/core";
import { X, ChevronUp, ChevronDown } from "lucide-react";
import "@xterm/xterm/css/xterm.css";

// Output bytes arrive as a raw ArrayBuffer (binary fetch path — no JSON byte
// bloat); process-exit arrives as a small JSON object. See src-tauri/src/pty.rs.
type PtyMsg = ArrayBuffer | { type: "exit" };

export type TermTheme = "dark" | "light";

// The integrated terminal stays the same soft-black (#25272b) in BOTH app themes —
// an always-dark terminal (like VS Code's) the operator asked for. The `theme` prop is
// still accepted for API symmetry but resolves to this one palette either way, so a
// light-on-dark, readable terminal shows even when the rest of the app is light.
const DARK_TERMINAL: ITheme = {
  background: "#25272b",
  foreground: "#e5e5e5",
  cursor: "#818cf8",
};
const THEMES: Record<TermTheme, ITheme> = {
  dark: DARK_TERMINAL,
  light: DARK_TERMINAL,
};

/**
 * Real interactive terminal: an xterm.js view wired to a PTY-backed login shell in
 * the Rust backend (commands pty_spawn / pty_write / pty_resize / pty_kill). Opens
 * in `cwd`; respawns when `cwd` changes. From here the user can run `claude`,
 * `claude attach <id>`, `claude --resume <id>`, git, etc.
 */
export default function Terminal({
  cwd,
  initialCommand,
  theme = "dark",
  active = true,
  onPtyReady,
  onBeforeSubmit,
}: {
  cwd?: string;
  initialCommand?: string;
  theme?: TermTheme;
  active?: boolean;
  /** Called once with the PTY id after the shell spawns — lets the parent send pty_write. */
  onPtyReady?: (id: string) => void;
  /**
   * Called with the current keystroke-buffer content when the user presses Enter.
   * The returned (or resolved) string is sent to the PTY after a Ctrl+U clear.
   * Sequence: \x15 → augmented prompt → \r.
   * If not provided, Enter passes through to the PTY unchanged.
   */
  onBeforeSubmit?: (prompt: string) => string | Promise<string>;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const termRef = useRef<XTerm | null>(null);
  const searchRef = useRef<SearchAddon | null>(null);
  const searchInputRef = useRef<HTMLInputElement>(null);
  // Set by the lifecycle effect to its `syncSize` (fit xterm + push size to the PTY).
  // The `active` effect calls it on show without reaching into the other effect's scope.
  const syncRef = useRef<() => void>(() => {});
  // Stable ref to the show-search setter — used inside the xterm key handler closure.
  const openSearchRef = useRef<() => void>(() => {});
  // Keystroke buffer: accumulates printable chars typed by the user so they can be
  // passed to onBeforeSubmit on Enter. Paste bypasses this (goes via term.onData).
  const keystrokeBufferRef = useRef<string>("");
  // Stable ref to onBeforeSubmit so the xterm key handler closure never goes stale.
  const onBeforeSubmitRef = useRef<((p: string) => string | Promise<string>) | undefined>(undefined);

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

  // Keep onBeforeSubmitRef in sync with the prop so the xterm key handler
  // closure (created once per cwd mount) always calls the latest version.
  useEffect(() => {
    onBeforeSubmitRef.current = onBeforeSubmit;
  }, [onBeforeSubmit]);

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
      fontSize: 12,
      cursorBlink: true,
      scrollback: 5000,
      theme: THEMES[theme],
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

    // GPU-accelerated renderer — the default DOM renderer adds visible input-echo
    // latency. Fall back silently to DOM if WebGL is unavailable / context is lost.
    try {
      const webgl = new WebglAddon();
      webgl.onContextLoss(() => webgl.dispose());
      term.loadAddon(webgl);
    } catch {
      /* WebGL unavailable — DOM renderer */
    }
    try {
      fit.fit();
    } catch {
      /* element not laid out yet */
    }

    let ptyId: string | null = null;
    let disposed = false;

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

      // Only keydown events carry semantic key info for the buffer logic.
      if (e.type !== "keydown") return true;

      const beforeSubmit = onBeforeSubmitRef.current;
      if (beforeSubmit) {
        // AC-0-1: Plain Enter → intercept, call onBeforeSubmit, then \x15 + augmented + \r.
        if (e.key === "Enter" && !e.shiftKey && !e.ctrlKey && !e.altKey && !e.metaKey) {
          if (ptyId) {
            const capturedPtyId = ptyId;
            const prompt = keystrokeBufferRef.current;
            keystrokeBufferRef.current = "";
            void (async () => {
              const augmented = await Promise.resolve(beforeSubmit(prompt));
              // \x15 (Ctrl+U) clears the TUI's accumulated input buffer first,
              // then we write the (possibly augmented) prompt followed by \r.
              void invoke("pty_write", { id: capturedPtyId, data: "\x15" });
              void invoke("pty_write", { id: capturedPtyId, data: augmented + "\r" });
            })();
          }
          return false; // prevent xterm from sending the raw \r
        }

        // AC-0-4: Backspace (\x7f) → remove last char from buffer.
        if (e.key === "Backspace") {
          keystrokeBufferRef.current = keystrokeBufferRef.current.slice(0, -1);
          return true; // let xterm echo the delete
        }

        // AC-0-4: Ctrl+U → clear entire buffer (mirrors readline kill-line).
        if (e.key === "u" && e.ctrlKey && !e.shiftKey && !e.altKey && !e.metaKey) {
          keystrokeBufferRef.current = "";
          return true; // let xterm send \x15 to PTY so TUI also clears
        }

        // Printable characters (single char, no modifier): append to buffer.
        // AC-0-3: paste arrives via term.onData, not here, so paste never touches
        // the buffer and paste's \r never reaches this branch.
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
          const text = new TextDecoder().decode(msg);
          if (/\x1b\[\?(?:1000|1002|1003)h/.test(text)) mouseTrackingActive = true;
          if (/\x1b\[\?(?:1000|1002|1003)l/.test(text)) mouseTrackingActive = false;
          term.write(new Uint8Array(msg));
        } else if (msg && msg.type === "exit") {
          mouseTrackingActive = false;
          term.write("\r\n\x1b[2m[process exited — close or reselect a session]\x1b[0m\r\n");
        }
      } catch {
        /* terminal disposed mid-write */
      }
    };

    invoke<string>("pty_spawn", {
      onEvent: channel,
      cwd,
      cols: term.cols,
      rows: term.rows,
    })
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
        if (initialCommand) {
          setTimeout(() => {
            if (!disposed && ptyId)
              void invoke("pty_write", {
                id: ptyId,
                data: `${initialCommand}\r`,
              });
          }, 600);
        }
      })
      .catch((e) =>
        term.write(`\r\n\x1b[31mpty spawn failed: ${String(e)}\x1b[0m\r\n`)
      );

    // Live resize while this tab is visible. While hidden the element is 0×0, so
    // syncSize bails and the resize is deferred to the `active` effect on re-show.
    const ro = new ResizeObserver(syncSize);
    ro.observe(el);

    return () => {
      disposed = true;
      syncRef.current = () => {};
      keystrokeBufferRef.current = "";
      ro.disconnect();
      el.removeEventListener("wheel", onWheel);
      if (ptyId) void invoke("pty_kill", { id: ptyId });
      term.dispose();
      termRef.current = null;
      searchRef.current = null;
    };
  }, [cwd]);

  // On the hidden→visible transition, re-sync the size (a window resize while hidden
  // never reached this PTY) and focus the shell so the user can type immediately. rAF
  // defers one frame so the element has its laid-out dimensions before we fit.
  useEffect(() => {
    if (!active) return;
    const raf = requestAnimationFrame(() => {
      syncRef.current();
      termRef.current?.focus();
    });
    return () => cancelAnimationFrame(raf);
  }, [active]);

  // Live theme switch — recolors the existing terminal without touching the PTY.
  useEffect(() => {
    if (termRef.current) termRef.current.options.theme = THEMES[theme];
  }, [theme]);

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
      <div ref={ref} className="h-full w-full overflow-hidden" />

      {/* In-terminal search overlay — toggled by Cmd+F */}
      {showSearch && (
        <div className="absolute top-2 right-2 z-10 flex items-center gap-1 bg-[#1e1f23] border border-[#3d3f44] rounded shadow-lg px-2 py-1">
          <input
            ref={searchInputRef}
            type="text"
            value={searchQuery}
            onChange={(e) => handleSearchChange(e.target.value)}
            onKeyDown={handleSearchKeyDown}
            placeholder="Search…"
            className="w-44 bg-transparent text-[#e5e5e5] text-xs font-mono outline-none placeholder-neutral-500"
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

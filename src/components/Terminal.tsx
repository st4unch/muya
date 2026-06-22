import { useEffect, useRef } from "react";
import { Terminal as XTerm, type ITheme } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebglAddon } from "@xterm/addon-webgl";
import { Channel, invoke } from "@tauri-apps/api/core";
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
}: {
  cwd?: string;
  /** If set, auto-run this command once the shell is ready (e.g. `claude attach <id>`). */
  initialCommand?: string;
  /** Color theme; switches live without respawning the PTY. */
  theme?: TermTheme;
  /**
   * Whether this terminal is the visible/active tab. While `false` the host hides it
   * with `display:none`, so the element is 0×0 and any window resize that happens
   * meanwhile never reaches its PTY. On the false→true transition we re-fit, push the
   * real size to the PTY, and focus the shell so the user can type without a stray
   * click. Defaults to `true` for standalone use.
   */
  active?: boolean;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const termRef = useRef<XTerm | null>(null);
  // Set by the lifecycle effect to its `syncSize` (fit xterm + push size to the PTY).
  // The `active` effect calls it on show without reaching into the other effect's scope.
  const syncRef = useRef<() => void>(() => {});

  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    const term = new XTerm({
      fontFamily: '"JetBrains Mono", ui-monospace, monospace',
      fontSize: 12,
      cursorBlink: true,
      theme: THEMES[theme],
    });
    termRef.current = term;
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(el);
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

    // Shift+Enter → insert a literal newline in the shell command buffer (readline
    // quoted-insert: Ctrl-V tells readline to take the next char literally, then \r
    // inserts a newline). Allows multiline commands without submitting.
    term.attachCustomKeyEventHandler((e: KeyboardEvent) => {
      if (e.key === "Enter" && e.shiftKey && !e.ctrlKey && !e.altKey && !e.metaKey) {
        if (e.type === "keydown" && ptyId)
          void invoke("pty_write", { id: ptyId, data: "\x16\r" });
        return false;
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
        if (msg instanceof ArrayBuffer) term.write(new Uint8Array(msg));
        else if (msg && msg.type === "exit")
          term.write("\r\n\x1b[2m[process exited — close or reselect a session]\x1b[0m\r\n");
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
      ro.disconnect();
      if (ptyId) void invoke("pty_kill", { id: ptyId });
      term.dispose();
      termRef.current = null;
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

  return <div ref={ref} className="h-full w-full overflow-hidden" />;
}

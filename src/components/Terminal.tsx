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

// Color palettes for the two themes. The light palette darkens the ANSI brights so
// output stays readable on a white background.
const THEMES: Record<TermTheme, ITheme> = {
  dark: {
    background: "#0a0a0a",
    foreground: "#e5e5e5",
    cursor: "#818cf8",
  },
  light: {
    background: "#ffffff",
    foreground: "#1a1a1a",
    cursor: "#4f46e5",
    selectionBackground: "#c7d2fe",
    black: "#1a1a1a",
    red: "#c0392b",
    green: "#1e8449",
    yellow: "#b7791f",
    blue: "#2563eb",
    magenta: "#9333ea",
    cyan: "#0e7490",
    white: "#4b5563",
    brightBlack: "#6b7280",
    brightRed: "#e74c3c",
    brightGreen: "#27ae60",
    brightYellow: "#d97706",
    brightBlue: "#3b82f6",
    brightMagenta: "#a855f7",
    brightCyan: "#0891b2",
    brightWhite: "#111827",
  },
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
}: {
  cwd?: string;
  /** If set, auto-run this command once the shell is ready (e.g. `claude attach <id>`). */
  initialCommand?: string;
  /** Color theme; switches live without respawning the PTY. */
  theme?: TermTheme;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const termRef = useRef<XTerm | null>(null);

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

    const onResize = () => {
      // When the tab is hidden (display:none) the element is 0×0. Fitting then would
      // shrink the PTY to ~0 rows/cols and corrupt a full-screen TUI like
      // `claude attach`. Skip while hidden; the observer fires again on re-show.
      if (el.offsetWidth === 0 || el.offsetHeight === 0) return;
      try {
        fit.fit();
      } catch {
        return;
      }
      if (ptyId)
        void invoke("pty_resize", { id: ptyId, cols: term.cols, rows: term.rows });
    };
    const ro = new ResizeObserver(onResize);
    ro.observe(el);

    return () => {
      disposed = true;
      ro.disconnect();
      if (ptyId) void invoke("pty_kill", { id: ptyId });
      term.dispose();
      termRef.current = null;
    };
  }, [cwd]);

  // Live theme switch — recolors the existing terminal without touching the PTY.
  useEffect(() => {
    if (termRef.current) termRef.current.options.theme = THEMES[theme];
  }, [theme]);

  return <div ref={ref} className="h-full w-full overflow-hidden" />;
}

// Created by Claude — Classification: INTERNAL
import { WebglAddon } from "@xterm/addon-webgl";
import type { Terminal } from "@xterm/xterm";

/** A WebGL renderer bound to one terminal. */
export interface WebglLease {
  /** False once suspended or lost — the renderer is still attached but draws nothing. */
  readonly live: boolean;
  /** Hidden tab: free the GPU context but keep the inert renderer attached, so the
   *  terminal never falls back to xterm's DOM renderer while it can't be seen. */
  suspend(): void;
  /** Detach the renderer and free its context (unmount, or before re-acquiring). */
  release(): void;
}

/** Attach WebGL to a visible, laid-out `term`; null if WebGL is unavailable. `onLost`
 *  fires only for a loss we didn't cause (GPU reset, WebKit's 16-context eviction). */
export function acquireWebgl(
  term: Terminal,
  onLost: () => void,
): WebglLease | null {
  const host = term.element;
  const before = new Set(host ? host.querySelectorAll("canvas") : []);
  let addon: WebglAddon;
  try {
    addon = new WebglAddon();
    term.loadAddon(addon);
  } catch {
    return null;
  }
  // The addon's own canvases, captured now: dispose() removes them from the DOM.
  const canvases = host
    ? [...host.querySelectorAll("canvas")].filter((c) => !before.has(c))
    : [];

  let state: "live" | "suspended" | "released" = "live";
  // Neither dispose() nor dropping the canvas frees the GPU context (xterm.js issue 6068);
  // losing it explicitly does, without waiting for GC.
  const loseContexts = () => {
    for (const c of canvases) {
      const gl = c.getContext("webgl2") as WebGL2RenderingContext | null;
      if (gl && !gl.isContextLost())
        gl.getExtension("WEBGL_lose_context")?.loseContext();
    }
  };
  addon.onContextLoss(() => {
    if (state !== "live") return;
    state = "released";
    addon.dispose();
    onLost();
  });
  return {
    get live() {
      return state === "live";
    },
    suspend() {
      if (state !== "live") return;
      state = "suspended";
      loseContexts();
    },
    release() {
      if (state === "released") return;
      state = "released";
      addon.dispose();
      loseContexts();
    },
  };
}

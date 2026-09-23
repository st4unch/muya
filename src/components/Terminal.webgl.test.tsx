// Created by Claude — Classification: INTERNAL
import React from "react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, waitFor } from "@testing-library/react";

// xterm itself is irrelevant here: any method is a no-op returning a disposable.
const focus = vi.fn();
vi.mock("@xterm/xterm", () => ({
  Terminal: class {
    cols = 80;
    rows = 24;
    element?: HTMLElement;
    options = {};
    buffer = { active: { getLine: () => undefined } };
    focus = focus;
    constructor() {
      return new Proxy(this, {
        get: (t, k) =>
          k in t ? t[k as keyof typeof t] : () => ({ dispose() {} }),
      });
    }
    open(el: HTMLElement) {
      this.element = el;
    }
  },
}));
vi.mock("@xterm/addon-fit", () => ({
  FitAddon: class {
    fit() {}
    proposeDimensions() {}
  },
}));
vi.mock("@xterm/addon-search", () => ({ SearchAddon: class {} }));
vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(async (cmd: string) => (cmd === "pty_spawn" ? "pty-1" : null)),
  Channel: class {
    onmessage = () => {};
  },
}));

type Lease = {
  live: boolean;
  suspend: ReturnType<typeof vi.fn>;
  release: ReturnType<typeof vi.fn>;
};
const leases: Lease[] = [];
const lostHandlers: (() => void)[] = [];
vi.mock("../lib/webglRenderer", () => ({
  acquireWebgl: vi.fn((_t: unknown, onLost: () => void) => {
    const lease: Lease = {
      live: true,
      suspend: vi.fn(() => {
        lease.live = false;
      }),
      release: vi.fn(() => {
        lease.live = false;
      }),
    };
    leases.push(lease);
    lostHandlers.push(onLost);
    return lease;
  }),
}));

import Terminal from "./Terminal";

// jsdom has no ResizeObserver; the terminal only uses it to refit on resize.
globalThis.ResizeObserver ??= class {
  observe() {}
  disconnect() {}
  unobserve() {}
} as unknown as typeof ResizeObserver;

const frame = () =>
  new Promise((r) => requestAnimationFrame(() => r(undefined)));

/**
 * Regression: every mounted terminal held a WebGL context, WebKit evicts past 16, and
 * an evicted hidden tab fell back to xterm's DOM renderer — whose scroll-driven
 * repaints force a synchronous layout per glyph while hidden, freezing the app.
 */
describe("Terminal: WebGL lease follows visibility", () => {
  beforeEach(() => {
    leases.length = 0;
    lostHandlers.length = 0;
    focus.mockClear();
  });

  it("a hidden terminal never acquires a GPU context", async () => {
    render(<Terminal active={false} />);
    await frame();
    await frame();
    expect(leases).toHaveLength(0);
  });

  it("suspends on hide (renderer kept) and takes a fresh context on show", async () => {
    const { rerender } = render(<Terminal active />);
    await waitFor(() => expect(leases).toHaveLength(1));

    rerender(<Terminal active={false} />);
    expect(leases[0].suspend).toHaveBeenCalledTimes(1);
    expect(leases[0].release).not.toHaveBeenCalled();

    rerender(<Terminal active />);
    await waitFor(() => expect(leases).toHaveLength(2));
    expect(leases[0].release).toHaveBeenCalledTimes(1);
  });

  it("focuses synchronously on show, before the renderer swap", () => {
    const { rerender } = render(<Terminal active={false} />);
    focus.mockClear();
    rerender(<Terminal active />);
    // No frame awaited: keys typed right after a switch must already land.
    expect(focus).toHaveBeenCalled();
  });

  it("re-acquires after a GPU loss while visible, but gives up after 3 in a row", async () => {
    render(<Terminal active />);
    await waitFor(() => expect(leases).toHaveLength(1));
    for (let i = 0; i < 4; i++) {
      leases[leases.length - 1].live = false;
      lostHandlers[lostHandlers.length - 1]();
      await frame();
    }
    expect(leases).toHaveLength(4); // the original + 3 retries
  });

  it("releases the context on unmount", async () => {
    const { unmount } = render(<Terminal active />);
    await waitFor(() => expect(leases).toHaveLength(1));
    unmount();
    expect(leases[0].release).toHaveBeenCalled();
  });
});

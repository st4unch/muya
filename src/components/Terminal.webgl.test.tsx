// Created by Claude — Classification: INTERNAL
import React from "react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { act, render, waitFor } from "@testing-library/react";

// xterm itself is irrelevant here: any method is a no-op returning a disposable.
const focus = vi.fn();
const xterms: { options: Record<string, unknown> }[] = [];
vi.mock("@xterm/xterm", () => ({
  Terminal: class {
    cols = 80;
    rows = 24;
    element?: HTMLElement;
    options: Record<string, unknown> = {};
    buffer = { active: { getLine: () => undefined } };
    focus = focus;
    constructor(opts: Record<string, unknown> = {}) {
      this.options = { ...opts };
      xterms.push(this);
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

import Terminal, { mouseTrackingChange } from "./Terminal";
import { LETTER_DEFAULT, LINE_DEFAULT, setTerminalPrefs } from "../lib/terminalPrefs";

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

  // Grid mode keeps every grid terminal `active`, so picking one in the sessions list
  // produces no flip for the effect above to see — the keyboard would stay wherever
  // the click left it.
  it("focuses a visible terminal when the operator picks its tab, with no active flip", () => {
    const { rerender } = render(<Terminal active focusToken={1} />);
    focus.mockClear();
    rerender(<Terminal active focusToken={2} />);
    expect(focus).toHaveBeenCalled();
  });

  it("ignores a pick aimed at a terminal that is off screen", () => {
    const { rerender } = render(<Terminal active={false} focusToken={1} />);
    focus.mockClear();
    rerender(<Terminal active={false} focusToken={2} />);
    expect(focus).not.toHaveBeenCalled();
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

  // Live bug: FitAddon measures the element xterm opens into and ignores padding on
  // it (border-box), so a padded host clipped the last row and the right columns.
  it("opens xterm into an unpadded host whose wrapper carries the padding", () => {
    const { container } = render(<Terminal active />);
    const host = container.querySelector("[data-xterm-host]") as HTMLElement;
    expect(host).toBeTruthy();
    expect(host.style.padding).toBe("");
    const wrapper = host.parentElement as HTMLElement;
    expect(wrapper.style.padding).toContain("--term-pad");
    // Without this the padding ADDS to the height and xterm is fitted too tall.
    expect(wrapper.style.boxSizing).toBe("border-box");
  });

  it("releases the context on unmount", async () => {
    const { unmount } = render(<Terminal active />);
    await waitFor(() => expect(leases).toHaveLength(1));
    unmount();
    expect(leases[0].release).toHaveBeenCalled();
  });
});

describe("Terminal: spacing prefs", () => {
  it("starts with the saved spacing and re-spaces an open terminal live", () => {
    xterms.length = 0;
    setTerminalPrefs({ lineHeight: 1.2, letterSpacing: 1 });
    render(<Terminal active />);
    const t = xterms[xterms.length - 1];
    expect(t.options).toMatchObject({ lineHeight: 1.2, letterSpacing: 1 });
    act(() => setTerminalPrefs({ lineHeight: 1.0, letterSpacing: 3 }));
    expect(t.options).toMatchObject({ lineHeight: 1.0, letterSpacing: 3 });
    act(() => setTerminalPrefs({ lineHeight: LINE_DEFAULT, letterSpacing: LETTER_DEFAULT }));
  });
});

describe("mouseTrackingChange", () => {
  const enc = (s: string) => new TextEncoder().encode(s);
  it("reads the last mouse-mode switch in a chunk, or nothing", () => {
    expect(mouseTrackingChange(enc("plain output, no escapes"))).toBeUndefined();
    expect(mouseTrackingChange(enc("\x1b[31mred\x1b[0m"))).toBeUndefined();
    expect(mouseTrackingChange(enc("a\x1b[?1000hb"))).toBe(true);
    expect(mouseTrackingChange(enc("\x1b[?1002h"))).toBe(true);
    expect(mouseTrackingChange(enc("\x1b[?1003l"))).toBe(false);
    expect(mouseTrackingChange(enc("\x1b[?1000h then \x1b[?1000l"))).toBe(false);
    expect(mouseTrackingChange(enc("\x1b[?1001h"))).toBeUndefined(); // not a tracking mode
    expect(mouseTrackingChange(enc("\x1b[?1000"))).toBeUndefined(); // cut off
  });
});

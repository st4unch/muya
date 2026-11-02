// Created by Claude — Classification: INTERNAL
import React from "react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { act, render, waitFor } from "@testing-library/react";

// xterm itself is irrelevant here: any method is a no-op returning a disposable.
const focus = vi.fn();
const termWrites: (string | Uint8Array)[] = [];
const xterms: { options: Record<string, unknown> }[] = [];
vi.mock("@xterm/xterm", () => ({
  Terminal: class {
    cols = 80;
    rows = 24;
    element?: HTMLElement;
    options: Record<string, unknown> = {};
    buffer = { active: { getLine: () => undefined } };
    focus = focus;
    write = (d: string | Uint8Array) => {
      termWrites.push(d);
    };
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
    onmessage: (m: unknown) => void = () => {};
    constructor() {
      channels.push(this);
    }
  },
}));

type Lease = {
  live: boolean;
  suspend: ReturnType<typeof vi.fn<() => void>>;
  release: ReturnType<typeof vi.fn<() => void>>;
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
  parkWebgl: vi.fn((l: Lease) => parked.push(l)),
  unparkWebgl: vi.fn((l: Lease) => {
    const i = parked.indexOf(l);
    if (i >= 0) parked.splice(i, 1);
  }),
}));
const parked: Lease[] = [];

const channels: { onmessage: (m: unknown) => void }[] = [];
import Terminal, { HIDDEN_FLUSH_MS, mouseTrackingChange } from "./Terminal";
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
    parked.length = 0;
    lostHandlers.length = 0;
    focus.mockClear();
  });

  it("a hidden terminal never acquires a GPU context", async () => {
    render(<Terminal active={false} />);
    await frame();
    await frame();
    expect(leases).toHaveLength(0);
  });

  it("parks its renderer on hide and reuses it on show — no new context per switch", async () => {
    const { rerender } = render(<Terminal active />);
    await waitFor(() => expect(leases).toHaveLength(1));

    rerender(<Terminal active={false} />);
    expect(parked).toEqual([leases[0]]);
    expect(leases[0].suspend).not.toHaveBeenCalled();
    expect(leases[0].release).not.toHaveBeenCalled();

    rerender(<Terminal active />);
    expect(parked).toEqual([]);
    await new Promise((r) => requestAnimationFrame(() => r(null)));
    expect(leases).toHaveLength(1);
    expect(leases[0].release).not.toHaveBeenCalled();
  });

  it("takes a fresh context on show when the pool suspended its parked renderer", async () => {
    const { rerender } = render(<Terminal active />);
    await waitFor(() => expect(leases).toHaveLength(1));
    rerender(<Terminal active={false} />);
    leases[0].suspend(); // evicted: more than WARM_HIDDEN tabs were parked after it
    rerender(<Terminal active />);
    await waitFor(() => expect(leases).toHaveLength(2));
    expect(leases[0].release).toHaveBeenCalledTimes(1);
  });

  it("focuses synchronously on show, before the renderer swap", () => {
    const { rerender } = render(<Terminal active={false} focusToken={1} />);
    focus.mockClear();
    rerender(<Terminal active focusToken={1} />);
    // No frame awaited: keys typed right after a switch must already land.
    expect(focus).toHaveBeenCalled();
  });

  // Split / grid show several terminals at once: only the selected one (it holds a
  // focusToken) takes the keyboard, or it ends up in whichever pane ran last.
  it("a terminal shown next to the selected one does not take the keyboard", () => {
    const { rerender } = render(<Terminal active={false} />);
    focus.mockClear();
    rerender(<Terminal active />);
    expect(focus).not.toHaveBeenCalled();
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

// Load test finding: WebKit pays per term.write, so a hidden tab's output is held and
// written in one go; the visible tab still writes each chunk at once.
describe("Terminal: output of a hidden tab is batched", () => {
  const chunk = (s: string) => {
    const buf = new ArrayBuffer(s.length); // ASCII only; same realm as Terminal's instanceof
    new Uint8Array(buf).set([...s].map((c) => c.charCodeAt(0)));
    return buf;
  };
  const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

  it("holds hidden output, writes it once, and flushes on show", async () => {
    channels.length = 0;
    const { rerender } = render(<Terminal active={false} />);
    const ch = channels[channels.length - 1];
    termWrites.length = 0;
    ch.onmessage(chunk("ab"));
    ch.onmessage(chunk("cd"));
    expect(termWrites).toHaveLength(0);
    await wait(HIDDEN_FLUSH_MS + 50);
    expect(termWrites).toHaveLength(1);
    expect(String.fromCharCode(...(termWrites[0] as Uint8Array))).toBe("abcd");

    ch.onmessage(chunk("ef"));
    rerender(<Terminal active />);
    expect(termWrites).toHaveLength(2); // shown: held output is written right away
    ch.onmessage(chunk("gh"));
    expect(termWrites).toHaveLength(3); // visible: no holding
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

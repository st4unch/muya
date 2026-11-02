// Created by Claude — Classification: INTERNAL
import { describe, it, expect, vi, beforeEach } from "vitest";

// A fake addon: records dispose and exposes its onContextLoss handler to the test.
const addons: { dispose: ReturnType<typeof vi.fn>; fireLoss: () => void }[] =
  [];
let loadThrows = false;
vi.mock("@xterm/addon-webgl", () => ({
  WebglAddon: class {
    private lossHandler = () => {};
    dispose = vi.fn();
    constructor() {
      addons.push({
        dispose: this.dispose,
        fireLoss: () => this.lossHandler(),
      });
    }
    onContextLoss(fn: () => void) {
      this.lossHandler = fn;
      return { dispose() {} };
    }
  },
}));

import { acquireWebgl, parkWebgl, parkedWebglCount, unparkWebgl, WARM_HIDDEN } from "./webglRenderer";

/** A term whose loadAddon appends one WebGL canvas, like the real addon does. */
function fakeTerm() {
  const element = document.createElement("div");
  const lose = vi.fn();
  let lost = false;
  const gl = {
    isContextLost: () => lost,
    getExtension: () => ({
      loseContext: () => {
        lost = true;
        lose();
      },
    }),
  };
  const term = {
    element,
    loadAddon: vi.fn(() => {
      if (loadThrows) throw new Error("no webgl2");
      const c = document.createElement("canvas");
      c.getContext = (() => gl) as unknown as HTMLCanvasElement["getContext"];
      element.appendChild(c);
    }),
  };
  return { term: term as never, lose, markLost: () => (lost = true) };
}

describe("acquireWebgl lease", () => {
  beforeEach(() => {
    addons.length = 0;
    loadThrows = false;
  });

  it("returns null when WebGL can't be loaded, leaving the DOM renderer", () => {
    loadThrows = true;
    expect(acquireWebgl(fakeTerm().term, () => {})).toBeNull();
  });

  it("suspend frees the GPU context but keeps the renderer attached", () => {
    const { term, lose } = fakeTerm();
    const lease = acquireWebgl(term, () => {})!;
    lease.suspend();
    lease.suspend();
    expect(lease.live).toBe(false);
    expect(lose).toHaveBeenCalledTimes(1);
    // Disposing would swap in xterm's DOM renderer, whose hidden repaints force a
    // synchronous layout per glyph — the freeze this lease exists to prevent.
    expect(addons[0].dispose).not.toHaveBeenCalled();
  });

  it("release disposes and loses the context exactly once", () => {
    const { term, lose } = fakeTerm();
    const lease = acquireWebgl(term, () => {})!;
    lease.release();
    lease.release();
    expect(addons[0].dispose).toHaveBeenCalledTimes(1);
    expect(lose).toHaveBeenCalledTimes(1);
  });

  it("release after suspend disposes without re-losing a lost context", () => {
    const { term, lose } = fakeTerm();
    const lease = acquireWebgl(term, () => {})!;
    lease.suspend();
    lease.release();
    expect(addons[0].dispose).toHaveBeenCalledTimes(1);
    expect(lose).toHaveBeenCalledTimes(1);
  });

  it("a loss we didn't cause disposes and reports it", () => {
    const { term, markLost } = fakeTerm();
    const onLost = vi.fn();
    const lease = acquireWebgl(term, onLost)!;
    markLost();
    addons[0].fireLoss();
    expect(lease.live).toBe(false);
    expect(addons[0].dispose).toHaveBeenCalledTimes(1);
    expect(onLost).toHaveBeenCalledTimes(1);
  });

  it("the loss caused by our own suspend is not reported", () => {
    const { term } = fakeTerm();
    const onLost = vi.fn();
    const lease = acquireWebgl(term, onLost)!;
    lease.suspend();
    addons[0].fireLoss(); // xterm fires this ~3s after the context goes
    expect(onLost).not.toHaveBeenCalled();
    expect(addons[0].dispose).not.toHaveBeenCalled();
  });
});

describe("parked renderers (warm pool)", () => {
  beforeEach(() => {
    addons.length = 0;
    loadThrows = false;
  });

  it("keeps the last WARM_HIDDEN hidden renderers live and suspends the oldest past it", () => {
    const leases = Array.from({ length: WARM_HIDDEN + 1 }, () => {
      const { term, lose } = fakeTerm();
      return { lease: acquireWebgl(term, () => {})!, lose };
    });
    for (const { lease } of leases) parkWebgl(lease);
    expect(parkedWebglCount()).toBe(WARM_HIDDEN);
    expect(leases[0].lease.live).toBe(false);
    expect(leases[0].lose).toHaveBeenCalledTimes(1);
    for (const { lease, lose } of leases.slice(1)) {
      expect(lease.live).toBe(true);
      expect(lose).not.toHaveBeenCalled();
    }
    for (const { lease } of leases) lease.release();
    expect(parkedWebglCount()).toBe(0);
  });

  it("unpark on show and release on unmount take a lease out of the pool", () => {
    const a = acquireWebgl(fakeTerm().term, () => {})!;
    const b = acquireWebgl(fakeTerm().term, () => {})!;
    parkWebgl(a);
    parkWebgl(b);
    expect(parkedWebglCount()).toBe(2);
    unparkWebgl(a);
    expect(parkedWebglCount()).toBe(1);
    expect(a.live).toBe(true);
    b.release();
    expect(parkedWebglCount()).toBe(0);
    a.release();
  });

  it("parking twice counts once; a suspended lease is not parked", () => {
    const a = acquireWebgl(fakeTerm().term, () => {})!;
    parkWebgl(a);
    parkWebgl(a);
    expect(parkedWebglCount()).toBe(1);
    a.suspend();
    expect(parkedWebglCount()).toBe(0);
    parkWebgl(a);
    expect(parkedWebglCount()).toBe(0);
    a.release();
  });
});

import { act, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import RailPanda from "./RailPanda";
import { SCENE_MS, SLEEP_AFTER_MS, setPandaEnabled } from "../lib/panda";

const rive = vi.hoisted(() => {
  const cleanup = vi.fn();
  const made: { src: string; canvas: Element; stateMachines: string; layout: Record<string, unknown> }[] = [];
  class Rive {
    cleanup = cleanup;
    constructor(opts: (typeof made)[number]) {
      made.push(opts);
    }
  }
  class Layout {
    constructor(p: Record<string, unknown>) {
      Object.assign(this, p);
    }
  }
  return { cleanup, made, Rive, Layout, setWasmUrl: vi.fn() };
});
vi.mock("@rive-app/canvas-lite", () => ({
  Rive: rive.Rive,
  Layout: rive.Layout,
  Fit: { Contain: "contain" },
  Alignment: { Center: "center" },
  RuntimeLoader: { setWasmUrl: rive.setWasmUrl },
}));
vi.mock("@rive-app/canvas-lite/rive.wasm?url", () => ({ default: "/assets/rive.wasm" }));

const panda = () => screen.queryByRole("img");

describe("RailPanda", () => {
  beforeEach(() => localStorage.removeItem("apex.panda"));
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("the teacher with Claude's status when agents start, waving while idle", () => {
    const { rerender } = render(<RailPanda busy={false} />);
    expect(panda()?.getAttribute("data-mood")).toBe("idle");
    expect(panda()?.getAttribute("data-scene")).toBe("wave");
    rerender(<RailPanda busy status="Thinking…" />);
    expect(panda()?.getAttribute("data-mood")).toBe("busy");
    expect(panda()?.getAttribute("data-scene")).toBe("teacher");
    expect(document.querySelector(".rp-board")?.textContent).toContain("Thinking…");
    rerender(<RailPanda busy status="Reading…" />);
    expect(document.querySelector(".rp-board")?.textContent).toContain("Reading…");
  });

  it("no board without a status, and none on other scenes", () => {
    vi.useFakeTimers();
    vi.spyOn(Math, "random").mockReturnValue(0);
    const { rerender } = render(<RailPanda busy />);
    expect(document.querySelector(".rp-board")).toBeNull();
    rerender(<RailPanda busy status="Thinking…" />);
    act(() => vi.advanceTimersByTime(SCENE_MS.teacher));
    expect(panda()?.getAttribute("data-scene")).toBe("gaming");
    expect(document.querySelector(".rp-board")).toBeNull();
  });

  it("celebrates once when the work is done, then carries on idle", () => {
    vi.useFakeTimers();
    vi.spyOn(Math, "random").mockReturnValue(0);
    const { rerender } = render(<RailPanda busy />);
    rerender(<RailPanda busy={false} />);
    expect(panda()?.getAttribute("data-scene")).toBe("celebrate");
    act(() => vi.advanceTimersByTime(SCENE_MS.celebrate));
    expect(panda()?.getAttribute("data-scene")).toBe("wave");
    expect(panda()?.getAttribute("data-mood")).toBe("idle");
  });

  it("falls asleep after 5 quiet minutes and wakes on a key press", () => {
    vi.useFakeTimers();
    render(<RailPanda busy={false} />);
    act(() => vi.advanceTimersByTime(SLEEP_AFTER_MS - 10_000));
    expect(panda()?.getAttribute("data-mood")).toBe("idle");
    act(() => vi.advanceTimersByTime(15_000));
    expect(panda()?.getAttribute("data-mood")).toBe("asleep");
    expect(panda()?.getAttribute("data-scene")).toBe("sleep");
    act(() => void window.dispatchEvent(new KeyboardEvent("keydown", { key: "a" })));
    expect(panda()?.getAttribute("data-mood")).toBe("idle");
    expect(panda()?.getAttribute("data-scene")).toBe("wave");
  });

  it("activity keeps it awake; a working agent never lets it sleep", () => {
    vi.useFakeTimers();
    const { rerender } = render(<RailPanda busy={false} />);
    for (let i = 0; i < 4; i++) {
      act(() => vi.advanceTimersByTime(2 * 60_000));
      act(() => void window.dispatchEvent(new Event("pointerdown")));
    }
    expect(panda()?.getAttribute("data-mood")).toBe("idle");
    rerender(<RailPanda busy />);
    act(() => vi.advanceTimersByTime(SLEEP_AFTER_MS * 3));
    expect(panda()?.getAttribute("data-mood")).toBe("busy");
    // the countdown starts when the work stops
    rerender(<RailPanda busy={false} />);
    act(() => vi.advanceTimersByTime(SLEEP_AFTER_MS - 10_000));
    expect(panda()?.getAttribute("data-mood")).toBe("idle");
  });

  it("takes turns between scenes while it is on screen", () => {
    vi.useFakeTimers();
    vi.spyOn(Math, "random").mockReturnValue(0);
    render(<RailPanda busy={false} />);
    expect(panda()?.getAttribute("data-scene")).toBe("wave");
    act(() => vi.advanceTimersByTime(SCENE_MS.wave));
    expect(panda()?.getAttribute("data-scene")).toBe("flip");
    act(() => vi.advanceTimersByTime(SCENE_MS.flip));
    expect(panda()?.getAttribute("data-scene")).toBe("wave");
  });

  it("each scene plays its own Rive file on the panda's canvas, framed for the rail, and stops when it goes away", async () => {
    rive.made.length = 0;
    rive.cleanup.mockClear();
    const { rerender } = render(<RailPanda busy={false} />);
    await vi.waitFor(() => expect(rive.made).toHaveLength(1));
    expect(rive.setWasmUrl).toHaveBeenCalledWith("/assets/rive.wasm"); // the bundled wasm, no CDN
    const first = rive.made[0];
    expect(first.src).toMatch(/wave/);
    expect(first.canvas).toBe(panda()?.querySelector("canvas"));
    expect(first.stateMachines).toBe("State Machine 1");
    expect(first.layout).toMatchObject({ fit: "contain" });
    // the canvas is the whole artboard, shifted so the scene's crop square fills the 62 px box
    const c = first.canvas as HTMLCanvasElement;
    expect(parseFloat(c.style.width)).toBeGreaterThan(62);
    expect(parseFloat(c.style.left)).toBeLessThan(0);
    expect((panda() as HTMLElement).style.overflow).toBe("hidden");
    rerender(<RailPanda busy status="Thinking…" />);
    expect(rive.cleanup).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => expect(rive.made).toHaveLength(2));
    expect(rive.made[1].src).toMatch(/teacher/);
  });

  it("the Settings switch hides and brings it back", () => {
    render(<RailPanda busy={false} />);
    act(() => setPandaEnabled(false));
    expect(panda()).toBeNull();
    act(() => setPandaEnabled(true));
    expect(panda()).not.toBeNull();
  });

  it("stops while the window is hidden", () => {
    render(<RailPanda busy={false} />);
    Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
    act(() => document.dispatchEvent(new Event("visibilitychange")));
    expect(panda()).toBeNull();
    Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
    act(() => document.dispatchEvent(new Event("visibilitychange")));
    expect(panda()).not.toBeNull();
  });
});

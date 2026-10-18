import { act, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import RailPanda from "./RailPanda";
import { SCENE_MS, SLEEP_AFTER_MS, setPandaEnabled } from "../lib/panda";

const lottie = vi.hoisted(() => {
  const destroy = vi.fn();
  return { destroy, loadAnimation: vi.fn(() => ({ destroy })) };
});
vi.mock("lottie-web/build/player/lottie_light", () => ({ default: { loadAnimation: lottie.loadAnimation } }));

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
    expect(panda()?.getAttribute("data-scene")).toBe("waving");
    rerender(<RailPanda busy status="Thinking…" />);
    expect(panda()?.getAttribute("data-mood")).toBe("busy");
    expect(panda()?.getAttribute("data-scene")).toBe("teaching");
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
    act(() => vi.advanceTimersByTime(SCENE_MS.teaching));
    expect(panda()?.getAttribute("data-scene")).toBe("dance");
    expect(document.querySelector(".rp-board")).toBeNull();
  });

  it("celebrates once when the work is done, then carries on idle", () => {
    vi.useFakeTimers();
    vi.spyOn(Math, "random").mockReturnValue(0);
    const { rerender } = render(<RailPanda busy />);
    rerender(<RailPanda busy={false} />);
    expect(panda()?.getAttribute("data-scene")).toBe("celebrating");
    act(() => vi.advanceTimersByTime(SCENE_MS.celebrating));
    expect(panda()?.getAttribute("data-scene")).toBe("waving");
    expect(panda()?.getAttribute("data-mood")).toBe("idle");
  });

  it("falls asleep after 5 quiet minutes and wakes on a key press", () => {
    vi.useFakeTimers();
    render(<RailPanda busy={false} />);
    act(() => vi.advanceTimersByTime(SLEEP_AFTER_MS - 10_000));
    expect(panda()?.getAttribute("data-mood")).toBe("idle");
    act(() => vi.advanceTimersByTime(15_000));
    expect(panda()?.getAttribute("data-mood")).toBe("asleep");
    expect(panda()?.getAttribute("src")).toMatch(/sleeping/);
    act(() => void window.dispatchEvent(new KeyboardEvent("keydown", { key: "a" })));
    expect(panda()?.getAttribute("data-mood")).toBe("idle");
    expect(panda()?.getAttribute("data-scene")).toBe("waving");
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
    expect(panda()?.getAttribute("data-scene")).toBe("waving");
    act(() => vi.advanceTimersByTime(SCENE_MS.waving));
    expect(panda()?.getAttribute("data-scene")).toBe("rolling");
    act(() => vi.advanceTimersByTime(SCENE_MS.rolling));
    expect(panda()?.getAttribute("data-scene")).toBe("waving");
  });

  it("each Lottie scene plays as SVG and its player stops when it goes away", async () => {
    lottie.loadAnimation.mockClear();
    lottie.destroy.mockClear();
    const { rerender } = render(<RailPanda busy={false} />);
    await vi.waitFor(() => expect(lottie.loadAnimation).toHaveBeenCalledTimes(1));
    const opts = (lottie.loadAnimation.mock.calls[0] as unknown[])[0] as { renderer: string; loop: boolean; container: Element; animationData: { nm?: string } };
    expect(opts.renderer).toBe("svg");
    expect(opts.loop).toBe(true);
    expect(opts.container).toBe(panda());
    expect(opts.animationData.nm).toMatch(/Panda waving/);
    rerender(<RailPanda busy status="Thinking…" />);
    expect(lottie.destroy).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => expect(lottie.loadAnimation).toHaveBeenCalledTimes(2));
    const busyOpts = (lottie.loadAnimation.mock.calls[1] as unknown[])[0] as { animationData: { nm?: string } };
    expect(busyOpts.animationData.nm).toMatch(/teaching/i);
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

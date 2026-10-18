import { act, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import RailPanda from "./RailPanda";
import { SCENE_MS, SLEEP_AFTER_MS, setPandaEnabled } from "../lib/panda";

const panda = () => screen.queryByRole("img");

describe("RailPanda", () => {
  beforeEach(() => localStorage.removeItem("apex.panda"));
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("plays the game when agents start, awake while idle", () => {
    const { rerender } = render(<RailPanda busy={false} />);
    expect(panda()?.getAttribute("data-mood")).toBe("idle");
    expect(panda()?.getAttribute("src")).toMatch(/roll/);
    rerender(<RailPanda busy />);
    expect(panda()?.getAttribute("data-mood")).toBe("busy");
    expect(panda()?.getAttribute("src")).toMatch(/gaming/);
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
    expect(panda()?.getAttribute("data-scene")).toBe("roll");
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
    render(<RailPanda busy />);
    expect(panda()?.getAttribute("data-scene")).toBe("gaming");
    act(() => vi.advanceTimersByTime(SCENE_MS.gaming));
    expect(panda()?.getAttribute("data-scene")).toBe("bamboo");
    expect(panda()?.getAttribute("src")).toMatch(/bamboo/);
    act(() => vi.advanceTimersByTime(SCENE_MS.bamboo));
    expect(panda()?.getAttribute("data-scene")).toBe("gaming");
  });

  it("a change of mood starts over with that mood's first scene", () => {
    vi.useFakeTimers();
    vi.spyOn(Math, "random").mockReturnValue(0.999);
    const { rerender } = render(<RailPanda busy={false} />);
    act(() => vi.advanceTimersByTime(SCENE_MS.roll));
    expect(panda()?.getAttribute("data-scene")).toBe("manti");
    rerender(<RailPanda busy />);
    expect(panda()?.getAttribute("data-scene")).toBe("gaming");
    rerender(<RailPanda busy={false} />);
    expect(panda()?.getAttribute("data-scene")).toBe("roll");
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

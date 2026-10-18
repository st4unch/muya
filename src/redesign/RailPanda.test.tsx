import { act, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import RailPanda from "./RailPanda";
import { SCENE_MS, setPandaEnabled } from "../lib/panda";

const panda = () => screen.queryByRole("img");

describe("RailPanda", () => {
  beforeEach(() => localStorage.removeItem("apex.panda"));
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("sleeps while nothing runs and plays while agents work", () => {
    const { rerender } = render(<RailPanda busy={false} />);
    expect(panda()?.getAttribute("data-mood")).toBe("idle");
    expect(panda()?.getAttribute("src")).toMatch(/sleeping/);
    rerender(<RailPanda busy />);
    expect(panda()?.getAttribute("data-mood")).toBe("busy");
    expect(panda()?.getAttribute("src")).toMatch(/gaming/);
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
    act(() => vi.advanceTimersByTime(SCENE_MS.sleeping));
    expect(panda()?.getAttribute("data-scene")).toBe("roll");
    rerender(<RailPanda busy />);
    expect(panda()?.getAttribute("data-scene")).toBe("gaming");
    rerender(<RailPanda busy={false} />);
    expect(panda()?.getAttribute("data-scene")).toBe("sleeping");
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

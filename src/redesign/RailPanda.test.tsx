import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import RailPanda from "./RailPanda";
import { HOVER_COOLDOWN_MS, REACTION_MS, SCENE_MS, setPandaEnabled } from "../lib/panda";

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

  it("gets angry when clicked, every click, then carries on with its scene", () => {
    vi.useFakeTimers();
    render(<RailPanda busy={false} />);
    const button = screen.getByRole("button", { name: "Poke the panda" });
    fireEvent.click(button);
    expect(panda()?.getAttribute("data-scene")).toBe("angry");
    const first = panda();
    fireEvent.click(button);
    expect(panda()?.getAttribute("data-scene")).toBe("angry");
    expect(panda()).not.toBe(first); // restarted, not left running
    act(() => vi.advanceTimersByTime(REACTION_MS.angry));
    expect(panda()?.getAttribute("data-scene")).toBe("sleeping");
  });

  it("waves when the pointer arrives, not again right away", () => {
    vi.useFakeTimers();
    render(<RailPanda busy />);
    const button = screen.getByRole("button", { name: "Poke the panda" });
    fireEvent.pointerEnter(button);
    expect(panda()?.getAttribute("data-scene")).toBe("hello");
    act(() => vi.advanceTimersByTime(REACTION_MS.hello));
    expect(panda()?.getAttribute("data-scene")).toBe("gaming");
    fireEvent.pointerEnter(button);
    expect(panda()?.getAttribute("data-scene")).toBe("gaming");
    act(() => vi.advanceTimersByTime(HOVER_COOLDOWN_MS));
    fireEvent.pointerEnter(button);
    expect(panda()?.getAttribute("data-scene")).toBe("hello");
  });

  it("Enter pokes it too", () => {
    render(<RailPanda busy={false} />);
    fireEvent.keyDown(screen.getByRole("button", { name: "Poke the panda" }), { key: "Enter" });
    expect(panda()?.getAttribute("data-scene")).toBe("angry");
  });
});

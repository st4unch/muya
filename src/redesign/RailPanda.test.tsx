import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import RailPanda from "./RailPanda";
import { setPandaEnabled } from "../lib/panda";

const scene = () => screen.getByRole("button", { name: /Panda/ }).getAttribute("data-scene");

describe("RailPanda", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    localStorage.removeItem("apex.panda");
  });
  afterEach(() => vi.useRealTimers());

  it("idle: eats, then moves on to the next lazy scene", () => {
    render(<RailPanda busy={false} />);
    expect(scene()).toBe("eat");
    act(() => vi.advanceTimersByTime(6600));
    expect(scene()).toBe("flip");
  });

  it("work starts: wakes up, then gets busy; work ends: lazy again", () => {
    const { rerender } = render(<RailPanda busy={false} />);
    rerender(<RailPanda busy />);
    expect(scene()).toBe("wake");
    act(() => vi.advanceTimersByTime(1900));
    expect(scene()).toBe("chop");
    rerender(<RailPanda busy={false} />);
    expect(["eat", "flip", "sleep", "roll", "kungfu"]).toContain(scene());
  });

  it("a click does a trick", () => {
    render(<RailPanda busy={false} />);
    fireEvent.click(screen.getByRole("button", { name: /Panda/ }));
    expect(scene()).not.toBe("eat");
    expect(scene()).not.toBe("sleep");
  });

  it("the Settings switch hides and brings it back", () => {
    render(<RailPanda busy={false} />);
    act(() => setPandaEnabled(false));
    expect(screen.queryByRole("button", { name: /Panda/ })).toBeNull();
    act(() => setPandaEnabled(true));
    expect(screen.getByRole("button", { name: /Panda/ })).toBeTruthy();
  });
});

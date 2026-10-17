import { act, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";
import RailPanda from "./RailPanda";
import { setPandaEnabled } from "../lib/panda";

const panda = () => screen.queryByRole("img");

describe("RailPanda", () => {
  beforeEach(() => localStorage.removeItem("apex.panda"));

  it("sleeps while nothing runs and plays while agents work", () => {
    const { rerender } = render(<RailPanda busy={false} />);
    expect(panda()?.getAttribute("data-mood")).toBe("idle");
    expect(panda()?.getAttribute("src")).toMatch(/sleeping/);
    rerender(<RailPanda busy />);
    expect(panda()?.getAttribute("data-mood")).toBe("busy");
    expect(panda()?.getAttribute("src")).toMatch(/gaming/);
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

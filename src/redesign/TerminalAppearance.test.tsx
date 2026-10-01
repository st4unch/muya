import { describe, it, expect, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { TerminalAppearanceMenu } from "./TerminalAppearance";
import { FONT_DEFAULT, FONT_MAX, getTerminalPrefs, setTerminalPrefs, stepTerminalFont } from "../lib/terminalPrefs";
import { schemeTheme, terminalTheme } from "../theme/terminalThemes";

const anchor = { x: 400, y: 60, align: "right" as const, place: "below" as const };

beforeEach(() => {
  setTerminalPrefs({ fontSize: FONT_DEFAULT, scheme: "muya" });
  localStorage.clear();
});

describe("terminal prefs", () => {
  it("steps, clamps, resets and persists the font size", () => {
    stepTerminalFont(1);
    expect(getTerminalPrefs().fontSize).toBe(FONT_DEFAULT + 1);
    expect(JSON.parse(localStorage.getItem("muya.terminalPrefs")!)).toEqual({ fontSize: FONT_DEFAULT + 1, scheme: "muya" });
    setTerminalPrefs({ fontSize: 999 });
    expect(getTerminalPrefs().fontSize).toBe(FONT_MAX);
    stepTerminalFont(0);
    expect(getTerminalPrefs().fontSize).toBe(FONT_DEFAULT);
  });

  it("rejects an unknown scheme and lets muya follow the app theme", () => {
    setTerminalPrefs({ scheme: "nope" as never });
    expect(getTerminalPrefs().scheme).toBe("muya");
    expect(schemeTheme("muya", "light")).toBe(terminalTheme("light"));
    expect(schemeTheme("dracula", "light").background).toBe(schemeTheme("dracula", "dark").background);
  });
});

describe("TerminalAppearanceMenu", () => {
  it("changes the size and the color scheme", () => {
    render(<TerminalAppearanceMenu anchor={anchor} appTheme="dark" onClose={() => {}} />);
    fireEvent.click(screen.getByRole("button", { name: "Larger text" }));
    fireEvent.click(screen.getByRole("button", { name: "Larger text" }));
    expect(screen.getByLabelText("Font size")).toHaveTextContent(`${FONT_DEFAULT + 2} px`);
    fireEvent.click(screen.getByRole("button", { name: "Smaller text" }));
    expect(getTerminalPrefs().fontSize).toBe(FONT_DEFAULT + 1);

    expect(screen.getByRole("radio", { name: /Muya/ })).toHaveAttribute("aria-checked", "true");
    fireEvent.click(screen.getByRole("radio", { name: /Nord/ }));
    expect(screen.getByRole("radio", { name: /Nord/ })).toHaveAttribute("aria-checked", "true");
    expect(getTerminalPrefs().scheme).toBe("nord");
  });
});

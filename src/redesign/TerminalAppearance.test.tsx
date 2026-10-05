import { describe, it, expect, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { TerminalAppearanceMenu } from "./TerminalAppearance";
import {
  FONT_DEFAULT,
  FONT_MAX,
  LETTER_DEFAULT,
  LETTER_MAX,
  LINE_DEFAULT,
  LINE_MIN,
  getTerminalPrefs,
  setTerminalPrefs,
  stepTerminalFont,
  stepTerminalLetter,
  stepTerminalLine,
} from "../lib/terminalPrefs";
import { schemeTheme, terminalTheme } from "../theme/terminalThemes";

const anchor = { x: 400, y: 60, align: "right" as const, place: "below" as const };

beforeEach(() => {
  setTerminalPrefs({ fontSize: FONT_DEFAULT, lineHeight: LINE_DEFAULT, letterSpacing: LETTER_DEFAULT, scheme: "muya" });
  localStorage.clear();
});

describe("terminal prefs", () => {
  it("steps, clamps, resets and persists the font size", () => {
    stepTerminalFont(1);
    expect(getTerminalPrefs().fontSize).toBe(FONT_DEFAULT + 1);
    expect(JSON.parse(localStorage.getItem("muya.terminalPrefs")!)).toEqual({
      fontSize: FONT_DEFAULT + 1,
      lineHeight: LINE_DEFAULT,
      letterSpacing: LETTER_DEFAULT,
      scheme: "muya",
    });
    setTerminalPrefs({ fontSize: 999 });
    expect(getTerminalPrefs().fontSize).toBe(FONT_MAX);
    stepTerminalFont(0);
    expect(getTerminalPrefs().fontSize).toBe(FONT_DEFAULT);
  });

  it("steps line spacing in clean tenths, clamps, and resets", () => {
    for (let i = 0; i < 3; i++) stepTerminalLine(-1);
    expect(getTerminalPrefs().lineHeight).toBe(1.3);
    for (let i = 0; i < 20; i++) stepTerminalLine(-1);
    expect(getTerminalPrefs().lineHeight).toBe(LINE_MIN);
    setTerminalPrefs({ lineHeight: 9 });
    expect(getTerminalPrefs().lineHeight).toBe(2);
    stepTerminalLine(0);
    expect(getTerminalPrefs().lineHeight).toBe(LINE_DEFAULT);
  });

  it("steps and clamps letter spacing", () => {
    stepTerminalLetter(1);
    expect(getTerminalPrefs().letterSpacing).toBe(1);
    stepTerminalLetter(-1);
    stepTerminalLetter(-1);
    expect(getTerminalPrefs().letterSpacing).toBe(0);
    setTerminalPrefs({ letterSpacing: 50 });
    expect(getTerminalPrefs().letterSpacing).toBe(LETTER_MAX);
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

  it("tightens line and letter spacing", () => {
    render(<TerminalAppearanceMenu anchor={anchor} appTheme="dark" onClose={() => {}} />);
    expect(screen.getByLabelText("Line spacing")).toHaveTextContent("1.6");
    expect(screen.getByRole("button", { name: "Reset line spacing" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "Less line spacing" }));
    fireEvent.click(screen.getByRole("button", { name: "Less line spacing" }));
    expect(screen.getByLabelText("Line spacing")).toHaveTextContent("1.4");
    fireEvent.click(screen.getByRole("button", { name: "Reset line spacing" }));
    expect(getTerminalPrefs().lineHeight).toBe(LINE_DEFAULT);

    expect(screen.getByRole("button", { name: "Less letter spacing" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "More letter spacing" }));
    expect(screen.getByLabelText("Letter spacing")).toHaveTextContent("1 px");
    expect(getTerminalPrefs().letterSpacing).toBe(1);
  });
});

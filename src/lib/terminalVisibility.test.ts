// Created by Claude — Classification: INTERNAL
import { describe, it, expect } from "vitest";
import { terminalIsVisible } from "./terminalVisibility";

/**
 * Regression (L54): the old expression was `inGrid || isActiveTab` — it knew about the
 * tab strip and the grid but not about the page. Leaving Control for Kanban and coming
 * back left every terminal at `active === true` for the whole round trip, so the
 * show-effect that returns the keyboard never fired: the terminal was on screen and
 * deaf. Reproduced on the live app before the fix.
 */
describe("terminalIsVisible", () => {
  it("hides the selected tab while another page is on top", () => {
    expect(
      terminalIsVisible({ controlPageVisible: false, inGrid: false, isActiveTab: true }),
    ).toBe(false);
  });

  it("hides a grid terminal while another page is on top", () => {
    expect(
      terminalIsVisible({ controlPageVisible: false, inGrid: true, isActiveTab: false }),
    ).toBe(false);
  });

  it("shows the selected tab on the Control page", () => {
    expect(
      terminalIsVisible({ controlPageVisible: true, inGrid: false, isActiveTab: true }),
    ).toBe(true);
  });

  it("shows a grid terminal on the Control page even when it is not the selected tab", () => {
    expect(
      terminalIsVisible({ controlPageVisible: true, inGrid: true, isActiveTab: false }),
    ).toBe(true);
  });

  it("hides a background tab that is in neither the grid nor the selection", () => {
    expect(
      terminalIsVisible({ controlPageVisible: true, inGrid: false, isActiveTab: false }),
    ).toBe(false);
  });
});

// Created by Claude — Classification: INTERNAL
import { describe, expect, it } from "vitest";
import { addPane, closePane, isEmptyPane, MAX_SPLIT, neighbourAfterClose, placeAgent, resolvePanes, splitLayout } from "./controlSplit";

describe("splitLayout", () => {
  it.each([
    [1, 1, 1],
    [2, 2, 1],
    [3, 3, 1],
    [4, 2, 2],
    [5, 3, 2],
    [6, 3, 2],
    [7, 4, 2],
    [8, 4, 2],
  ])("%i panes → %i×%i", (n, cols, rows) => {
    expect(splitLayout(n)).toEqual({ cols, rows });
  });
});

describe("addPane", () => {
  const order = ["a", "b", "c"];
  it("splits a single terminal: current first, next unshown agent second", () => {
    expect(addPane([], "b", order)).toEqual({ panes: ["b", "a"], added: "a" });
  });
  it("adds an empty pane when every agent is shown", () => {
    expect(addPane(["a", "b", "c"], "a", order)).toEqual({ panes: ["a", "b", "c", "empty:1"], added: "empty:1" });
    expect(addPane(["a", "empty:1"], "a", ["a"])?.added).toBe("empty:2");
  });
  it(`stops at ${MAX_SPLIT}`, () => {
    let panes: string[] = [];
    for (let i = 0; i < 20; i++) panes = addPane(panes, "a", order)?.panes ?? panes;
    expect(panes).toHaveLength(MAX_SPLIT);
    expect(addPane(panes, "a", order)).toBeNull();
  });
  it("needs a current agent to start from", () => {
    expect(addPane([], null, [])).toEqual({ panes: ["empty:1"], added: "empty:1" });
  });
});

describe("closePane / neighbourAfterClose", () => {
  it("removes the pane; one left means not split", () => {
    expect(closePane(["a", "b", "c"], "b")).toEqual(["a", "c"]);
    expect(closePane(["a", "b"], "a")).toEqual([]);
  });
  it("focuses the right neighbour, else the left", () => {
    expect(neighbourAfterClose(["a", "b", "c"], "b")).toBe("c");
    expect(neighbourAfterClose(["a", "b", "c"], "c")).toBe("b");
    expect(neighbourAfterClose(["a"], "x")).toBeNull();
  });
});

describe("placeAgent", () => {
  it("fills the focused empty pane", () => {
    expect(placeAgent(["a", "empty:1"], "empty:1", "c")).toEqual(["a", "c"]);
  });
  it("replaces the agent in the focused pane", () => {
    expect(placeAgent(["a", "b"], "b", "c")).toEqual(["a", "c"]);
  });
  it("leaves panes alone when the agent is already shown", () => {
    expect(placeAgent(["a", "b"], "a", "b")).toEqual(["a", "b"]);
  });
});

describe("resolvePanes", () => {
  it("drops closed agents and duplicates, keeps placeholders", () => {
    expect(resolvePanes(["a", "gone", "empty:1", "a", "b"], new Set(["a", "b"]))).toEqual(["a", "empty:1", "b"]);
  });
  it("one survivor means not split", () => {
    expect(resolvePanes(["a", "gone"], new Set(["a"]))).toEqual([]);
  });
  it("caps at the limit", () => {
    const keys = Array.from({ length: 12 }, (_, i) => `k${i}`);
    expect(resolvePanes(keys, new Set(keys))).toHaveLength(MAX_SPLIT);
  });
  it("recognises placeholders", () => {
    expect(isEmptyPane("empty:3")).toBe(true);
    expect(isEmptyPane("claude-1")).toBe(false);
  });
});

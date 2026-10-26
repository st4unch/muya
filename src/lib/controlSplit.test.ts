// Created by Claude — Classification: INTERNAL
import { describe, expect, it } from "vitest";
import { addToGroup, asSplitGroups, canSplit, groupOf, joinGroup, MAX_SPLIT, neighbourAfterClose, removeFromGroups, resolveGroups, splitForOpenSession, splitLayout, type SplitGroup } from "./controlSplit";

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

describe("addToGroup", () => {
  it("a first split starts a group of the source and its clone", () => {
    expect(addToGroup([], "a", "a2", "g1")).toEqual([{ id: "g1", keys: ["a", "a2"] }]);
  });
  it("splitting a grouped terminal adds the clone to that group", () => {
    const groups: SplitGroup[] = [{ id: "g1", keys: ["a", "a2"] }, { id: "g2", keys: ["b", "b2"] }];
    expect(addToGroup(groups, "b2", "b3", "new")).toEqual([{ id: "g1", keys: ["a", "a2"] }, { id: "g2", keys: ["b", "b2", "b3"] }]);
  });
  it("refuses a clone key that is already used", () => {
    const groups: SplitGroup[] = [{ id: "g1", keys: ["a", "a2"] }];
    expect(addToGroup(groups, "a", "a2", "g")).toBeNull();
    expect(addToGroup(groups, "a", "a", "g")).toBeNull();
  });
  it(`stops at ${MAX_SPLIT} panes per group`, () => {
    let groups: SplitGroup[] = [];
    for (let i = 1; i < 20; i++) groups = addToGroup(groups, "a", `c${i}`, "g") ?? groups;
    expect(groups[0].keys).toHaveLength(MAX_SPLIT);
    expect(canSplit(groups, "a")).toBe(false);
    expect(addToGroup(groups, "c3", "x", "g")).toBeNull();
    expect(canSplit(groups, "lonely")).toBe(true);
    expect(canSplit(groups, null)).toBe(false);
  });
});

describe("removeFromGroups / neighbourAfterClose", () => {
  it("removes the terminal; a group of one dissolves", () => {
    const groups: SplitGroup[] = [{ id: "g1", keys: ["a", "b", "c"] }, { id: "g2", keys: ["d", "e"] }];
    expect(removeFromGroups(groups, "b")).toEqual([{ id: "g1", keys: ["a", "c"] }, { id: "g2", keys: ["d", "e"] }]);
    expect(removeFromGroups(groups, "d")).toEqual([{ id: "g1", keys: ["a", "b", "c"] }]);
  });
  it("focuses the right neighbour, else the left", () => {
    expect(neighbourAfterClose(["a", "b", "c"], "b")).toBe("c");
    expect(neighbourAfterClose(["a", "b", "c"], "c")).toBe("b");
    expect(neighbourAfterClose(["a"], "x")).toBeNull();
  });
});

describe("groupOf / resolveGroups", () => {
  it("finds a terminal's group", () => {
    const groups: SplitGroup[] = [{ id: "g1", keys: ["a", "b"] }];
    expect(groupOf(groups, "b")?.id).toBe("g1");
    expect(groupOf(groups, "z")).toBeNull();
  });
  it("drops closed tabs, keys claimed twice, and groups left with one", () => {
    const groups: SplitGroup[] = [
      { id: "g1", keys: ["a", "gone", "b"] },
      { id: "g2", keys: ["b", "c"] },
      { id: "g3", keys: ["d", "e"] },
    ];
    expect(resolveGroups(groups, new Set(["a", "b", "c", "d", "e"]))).toEqual([
      { id: "g1", keys: ["a", "b"] },
      { id: "g3", keys: ["d", "e"] },
    ]);
  });
  it("caps a group at the limit", () => {
    const keys = Array.from({ length: 12 }, (_, i) => `k${i}`);
    expect(resolveGroups([{ id: "g", keys }], new Set(keys))[0].keys).toHaveLength(MAX_SPLIT);
  });
});

describe("asSplitGroups", () => {
  it("keeps well-formed groups only", () => {
    expect(asSplitGroups([{ id: "g", keys: ["a", 1, "b"] }, { id: 2 }, null, "x"])).toEqual([{ id: "g", keys: ["a", "b"] }]);
    expect(asSplitGroups("nope")).toBeNull();
  });
});

describe("splitForOpenSession", () => {
  const ids = { "sess-1": "tab-a" };
  const open = new Set(["tab-a", "tab-b"]);
  it("joins the new tab to the caller's terminal, starting or extending its group", () => {
    expect(splitForOpenSession([], "sess-1", ids, open, "aopen:1", "g1")).toEqual([{ id: "g1", keys: ["tab-a", "aopen:1"] }]);
    const g: SplitGroup[] = [{ id: "g0", keys: ["tab-b", "tab-a"] }];
    expect(splitForOpenSession(g, "sess-1", ids, open, "aopen:1", "g1")).toEqual([{ id: "g0", keys: ["tab-b", "tab-a", "aopen:1"] }]);
  });
  it("returns null without an id, for an unknown id, a closed tab or a full group", () => {
    expect(splitForOpenSession([], undefined, ids, open, "aopen:1", "g1")).toBeNull();
    expect(splitForOpenSession([], "other", ids, open, "aopen:1", "g1")).toBeNull();
    expect(splitForOpenSession([], "sess-1", ids, new Set(["tab-b"]), "aopen:1", "g1")).toBeNull();
    const full: SplitGroup[] = [{ id: "g0", keys: ["tab-a", ...Array.from({ length: MAX_SPLIT - 1 }, (_, i) => `t${i}`)] }];
    expect(splitForOpenSession(full, "sess-1", ids, open, "aopen:1", "g1")).toBeNull();
  });
});

describe("joinGroup", () => {
  const g = (id: string, ...keys: string[]): SplitGroup => ({ id, keys });
  it("pairs two ungrouped sessions in a new group, target first", () => {
    expect(joinGroup([], "b", "a", "n")).toEqual([g("n", "a", "b")]);
  });
  it("joins the target's existing group", () => {
    expect(joinGroup([g("x", "a", "c")], "b", "a", "n")).toEqual([g("x", "a", "c", "b")]);
  });
  it("moves a session between groups and dissolves the group it leaves", () => {
    expect(joinGroup([g("x", "a", "b"), g("y", "c", "d")], "b", "c", "n")).toEqual([g("y", "c", "d", "b")]);
  });
  it("refuses a full target group, the same group and itself", () => {
    const full = g("x", ...Array.from({ length: MAX_SPLIT }, (_, i) => `k${i}`));
    expect(joinGroup([full], "z", "k0", "n")).toBeNull();
    expect(joinGroup([g("x", "a", "b")], "b", "a", "n")).toBeNull();
    expect(joinGroup([], "a", "a", "n")).toBeNull();
  });
});

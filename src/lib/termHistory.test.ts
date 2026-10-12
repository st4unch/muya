// Created by Claude — Classification: INTERNAL
import { describe, expect, it } from "vitest";
import { groupByDay, historyKeyOf, historyText, localDay } from "./termHistory";

describe("historyKeyOf", () => {
  it("gives plain terminals their own history", () => {
    expect(historyKeyOf({ key: "term-1712", kind: "terminal" })).toBe("term-1712");
  });
  it("leaves agent, SSH and file tabs on the shared history", () => {
    expect(historyKeyOf({ key: "claude-1", kind: "terminal", isClaude: true })).toBeUndefined();
    expect(historyKeyOf({ key: "t", kind: "terminal", agent: "opencode" })).toBeUndefined();
    expect(historyKeyOf({ key: "t", kind: "terminal", sessionId: "abc" })).toBeUndefined();
    expect(historyKeyOf({ key: "t", kind: "terminal", initialCommand: "claude" })).toBeUndefined();
    expect(historyKeyOf({ key: "t", kind: "terminal", sshServerId: "s1" })).toBeUndefined();
    expect(historyKeyOf({ key: "edit:/a", kind: "editor" })).toBeUndefined();
  });
  it("rejects keys that are not safe file names", () => {
    expect(historyKeyOf({ key: "../x", kind: "terminal" })).toBeUndefined();
    expect(historyKeyOf({ key: "resume:abc", kind: "terminal" })).toBeUndefined();
  });
});


describe("groupByDay", () => {
  const now = new Date(2026, 9, 12, 18, 0).getTime();
  const at = (d: number, h: number) => new Date(2026, 9, d, h, 5).getTime() / 1000;
  it("groups by day, newest day and terminal first, undated last", () => {
    const groups = groupByDay(
      [
        { key: "a", name: "api", cwd: "/w", updatedMs: 0, entries: [{ ts: null, cmd: "old" }, { ts: at(11, 9), cmd: "ls" }, { ts: at(12, 10), cmd: "git pull" }, { ts: at(12, 11), cmd: "make" }] },
        { key: "b", name: "web", cwd: "/x", updatedMs: 0, entries: [{ ts: at(12, 17), cmd: "npm test" }] },
      ],
      now,
    );
    expect(groups.map((g) => g.label)).toEqual(["Today", "Yesterday", "Earlier (no date)"]);
    expect(groups[0].terminals.map((t) => t.key)).toEqual(["b", "a"]);
    expect(groups[0].terminals[1].entries.map((e) => e.cmd)).toEqual(["make", "git pull"]);
    expect(groups[1].day).toBe(localDay(at(11, 9) * 1000));
  });
  it("exports one dated line per command", () => {
    expect(historyText("api", "/w", [{ ts: at(12, 10), cmd: "git pull" }])).toBe("# api — /w\n2026-10-12 10:05  git pull\n");
  });
});

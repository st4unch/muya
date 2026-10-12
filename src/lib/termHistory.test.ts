// Created by Claude — Classification: INTERNAL
import { describe, expect, it } from "vitest";
import { historyKeyOf } from "./termHistory";

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

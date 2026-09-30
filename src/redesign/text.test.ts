// Created by Claude — Classification: INTERNAL
import { describe, it, expect } from "vitest";
import { messageHint, plural, shortName, withDetail } from "./text";

describe("shortName", () => {
  it("leaves names that fit alone", () => {
    expect(shortName("muya-all")).toBe("muya-all");
    expect(shortName("x".repeat(24))).toBe("x".repeat(24));
  });
  it("cuts long names to the limit, including the ellipsis", () => {
    const out = shortName("a-very-long-agent-name-that-should-truncate");
    expect([...out]).toHaveLength(24);
    expect(out.endsWith("…")).toBe(true);
  });
  it("never splits a multi-byte character", () => {
    const out = shortName("ğ".repeat(30), 5);
    expect(out).toBe("ğğğğ…");
  });
});

describe("messageHint", () => {
  it("ends with exactly one ellipsis whether or not the name was cut", () => {
    expect(messageHint("muya-all")).toBe("Message muya-all…");
    const long = messageHint("a-very-long-agent-name-that-should-truncate");
    expect(long.endsWith("…")).toBe(true);
    expect(long).not.toContain("……");
  });
});

describe("withDetail", () => {
  it("joins with a separator only when there is a detail", () => {
    expect(withDetail("Working", "4m 15s")).toBe("Working · 4m 15s");
    expect(withDetail("Working", undefined)).toBe("Working");
    expect(withDetail("Working", "  ")).toBe("Working");
  });
});

describe("plural", () => {
  it("uses the singular only for exactly one", () => {
    expect(plural(1, "agent")).toBe("1 agent");
    expect(plural(0, "agent")).toBe("0 agents");
    expect(plural(7, "agent")).toBe("7 agents");
    expect(plural(1, "worktree watched", "worktrees watched")).toBe("1 worktree watched");
    expect(plural(2, "change")).toBe("2 changes");
  });
});

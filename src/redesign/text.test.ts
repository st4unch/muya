// Created by Claude — Classification: INTERNAL
import { describe, it, expect } from "vitest";
import { messageHint, shortName } from "./text";

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

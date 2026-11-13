import { describe, it, expect } from "vitest";
import { decideOpen, canRenderMarkdown, formatSize, longestLine, LARGE_BYTES, PROMPT_BYTES, MD_RENDER_MAX, LONG_LINE_CHARS, MB } from "./largeFile";

const t = (size: number, binary = false) => ({ size, binary });

describe("decideOpen", () => {
  it("opens small files normally", () => {
    expect(decideOpen(t(0))).toBe("normal");
    expect(decideOpen(t(LARGE_BYTES - 1))).toBe("normal");
  });
  it("opens everything up to 50 MB with the full editor (measured, not guessed)", () => {
    expect(LARGE_BYTES).toBe(50 * MB);
    for (const mb of [1, 3, 5, 10, 20, 49]) expect(decideOpen(t(mb * MB))).toBe("normal");
  });
  it("switches to the degraded (still editable) mode from 50 MB", () => {
    expect(decideOpen(t(LARGE_BYTES))).toBe("large");
    expect(decideOpen(t(100 * MB))).toBe("large");
    expect(decideOpen(t(PROMPT_BYTES))).toBe("large");
  });
  it("asks before loading anything above the prompt limit", () => {
    expect(PROMPT_BYTES).toBe(128 * MB);
    expect(decideOpen(t(PROMPT_BYTES + 1))).toBe("prompt");
    expect(decideOpen(t(500 * MB))).toBe("prompt");
  });
  it("never loads binary as text, whatever its size", () => {
    expect(decideOpen(t(10, true))).toBe("binary");
    expect(decideOpen(t(500 * MB, true))).toBe("binary");
  });
  it("markdown renders only up to its own, lower limit", () => {
    expect(decideOpen(t(MD_RENDER_MAX), { markdown: true })).toBe("normal");
    expect(decideOpen(t(MD_RENDER_MAX + 1), { markdown: true })).toBe("large");
    expect(decideOpen(t(MD_RENDER_MAX + 1))).toBe("normal"); // plain text editor is fine at that size
    expect(canRenderMarkdown(t(3 * MB))).toBe(false);
    expect(canRenderMarkdown(t(MD_RENDER_MAX))).toBe(true);
    expect(canRenderMarkdown(t(1000))).toBe(true);
  });
});

describe("longestLine", () => {
  it("measures the longest line, with or without a trailing newline", () => {
    expect(longestLine("")).toBe(0);
    expect(longestLine("abc")).toBe(3);
    expect(longestLine("a\nbcd\ne\n")).toBe(3);
    expect(longestLine("x".repeat(LONG_LINE_CHARS + 5))).toBe(LONG_LINE_CHARS + 5);
  });
  it("a 20 MB file with ordinary lines is nowhere near the long-line limit", () => {
    expect(longestLine(("x".repeat(100) + "\n").repeat(1000))).toBeLessThan(LONG_LINE_CHARS);
  });
});

describe("formatSize", () => {
  it("is human readable", () => {
    expect(formatSize(500)).toBe("500 B");
    expect(formatSize(2048)).toBe("2 KB");
    expect(formatSize(3.2 * MB)).toBe("3.2 MB");
  });
});

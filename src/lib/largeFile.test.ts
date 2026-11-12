import { describe, it, expect } from "vitest";
import { decideOpen, canRenderMarkdown, formatSize, LARGE_BYTES, PROMPT_BYTES, MD_RENDER_MAX, MB } from "./largeFile";

const t = (size: number, binary = false) => ({ size, binary });

describe("decideOpen", () => {
  it("opens small files normally", () => {
    expect(decideOpen(t(0))).toBe("normal");
    expect(decideOpen(t(LARGE_BYTES - 1))).toBe("normal");
  });
  it("switches to large-file mode from 1 MB", () => {
    expect(decideOpen(t(LARGE_BYTES))).toBe("large");
    expect(decideOpen(t(3 * MB))).toBe("large");
    expect(decideOpen(t(PROMPT_BYTES))).toBe("large");
  });
  it("asks before loading anything above the prompt limit", () => {
    expect(decideOpen(t(PROMPT_BYTES + 1))).toBe("prompt");
    expect(decideOpen(t(50 * MB))).toBe("prompt");
  });
  it("never loads binary as text, whatever its size", () => {
    expect(decideOpen(t(10, true))).toBe("binary");
    expect(decideOpen(t(50 * MB, true))).toBe("binary");
  });
  it("markdown renders only up to its own, lower limit", () => {
    expect(decideOpen(t(MD_RENDER_MAX), { markdown: true })).toBe("normal");
    expect(decideOpen(t(MD_RENDER_MAX + 1), { markdown: true })).toBe("large");
    expect(decideOpen(t(MD_RENDER_MAX + 1))).toBe("normal"); // plain text editor is fine at that size
    expect(canRenderMarkdown(t(3 * MB))).toBe(false);
    expect(canRenderMarkdown(t(1000))).toBe(true);
  });
});

describe("formatSize", () => {
  it("is human readable", () => {
    expect(formatSize(500)).toBe("500 B");
    expect(formatSize(2048)).toBe("2 KB");
    expect(formatSize(3.2 * MB)).toBe("3.2 MB");
  });
});

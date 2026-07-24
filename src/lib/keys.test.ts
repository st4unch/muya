import { describe, it, expect } from "vitest";
import { altArrowSeq } from "./keys";

describe("altArrowSeq — Option+Arrow sends shell-understood sequences (no ';3C' noise)", () => {
  it("Left/Right map to readline word-nav (meta-b / meta-f)", () => {
    expect(altArrowSeq("ArrowLeft")).toBe("\x1bb");
    expect(altArrowSeq("ArrowRight")).toBe("\x1bf");
  });

  it("Up/Down strip the modifier to the plain arrow (history)", () => {
    expect(altArrowSeq("ArrowUp")).toBe("\x1b[A");
    expect(altArrowSeq("ArrowDown")).toBe("\x1b[B");
  });

  it("never emits the broken modified-arrow CSI", () => {
    for (const k of ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"]) {
      expect(altArrowSeq(k)).not.toContain("1;3");
    }
  });

  it("returns null for non-arrow keys", () => {
    expect(altArrowSeq("a")).toBeNull();
    expect(altArrowSeq("Enter")).toBeNull();
  });
});

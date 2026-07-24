import { describe, it, expect } from "vitest";
import { pickNextActiveKey, type TabLike } from "./tabs";

const T = (key: string, kind: TabLike["kind"]): TabLike => ({ key, kind });

describe("pickNextActiveKey — closing a file never lands on a terminal", () => {
  const tabs = [T("f1", "editor"), T("f2", "editor"), T("f3", "editor"), T("t1", "terminal")];

  it("closing a middle file focuses the adjacent file, not the terminal", () => {
    // REGRESSION: it used to jump to the terminal, so the next ⌘W killed it.
    expect(pickNextActiveKey(tabs, "f2")).toBe("f1"); // nearest same-kind before
  });

  it("closing the last file focuses the previous file", () => {
    expect(pickNextActiveKey(tabs, "f3")).toBe("f2");
  });

  it("closing the first file focuses the next file", () => {
    expect(pickNextActiveKey(tabs, "f1")).toBe("f2");
  });

  it("only falls back to a terminal when no files remain", () => {
    expect(pickNextActiveKey([T("f1", "editor"), T("t1", "terminal")], "f1")).toBe("t1");
  });

  it("closing a terminal prefers another terminal", () => {
    const two = [T("t1", "terminal"), T("f1", "editor"), T("t2", "terminal")];
    expect(pickNextActiveKey(two, "t1")).toBe("t2");
  });

  it("returns null when the last tab is closed", () => {
    expect(pickNextActiveKey([T("f1", "editor")], "f1")).toBeNull();
  });
});

import { describe, expect, it } from "vitest";
import { kanbanRoots } from "./kanbanRoots";

describe("kanbanRoots", () => {
  it("is empty on a first install, whatever Claude did before", () => {
    expect(kanbanRoots([], [], [], {})).toEqual([]);
  });
  it("scans workspaces, worktrees and the live folders of Muya's own terminals", () => {
    expect(
      kanbanRoots(["/w"], ["/t"], [{ key: "a", cwd: "/start" }, { key: "b", cwd: "/b" }, { key: "c" }], { a: "/moved" }),
    ).toEqual(["/b", "/moved", "/t", "/w"]);
  });
  it("drops duplicates and non-absolute paths", () => {
    expect(kanbanRoots(["/w", "~/x"], ["/w"], [{ key: "a", cwd: "/w" }], {})).toEqual(["/w"]);
  });
});

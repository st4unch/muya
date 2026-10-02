// Created by Claude — Classification: INTERNAL
import { describe, it, expect } from "vitest";
import { belongsTo, inScope, workspaceOf } from "./workspaceScope";

const A = "/home/u/projects/muya";
const B = "/home/u/projects/padas";

describe("workspace scope", () => {
  it("a tab belongs to the folder it was opened in and everything below it", () => {
    expect(belongsTo({ cwd: A }, A)).toBe(true);
    expect(belongsTo({ cwd: A + "/src" }, A)).toBe(true);
    expect(belongsTo({ cwd: A + "/" }, A + "/")).toBe(true);
  });

  it("a sibling folder with the same prefix is not inside", () => {
    expect(belongsTo({ cwd: A + "-old" }, A)).toBe(false);
    expect(belongsTo({ cwd: B }, A)).toBe(false);
  });

  it("worktrees Muya creates next to the repo count as the repo's", () => {
    expect(belongsTo({ cwd: "/home/u/projects/muya-worktrees/feat-x" }, A)).toBe(true);
    expect(belongsTo({ cwd: "/home/u/projects/padas-worktrees/feat-x" }, A)).toBe(false);
  });

  it("SSH tabs show in every workspace; tabs without a folder only under All", () => {
    expect(inScope({ sshServerId: "srv1" }, A)).toBe(true);
    expect(inScope({}, A)).toBe(false);
    expect(inScope({}, undefined)).toBe(true);
    expect(inScope({ cwd: B }, undefined)).toBe(true);
    expect(inScope({ cwd: B }, A)).toBe(false);
  });

  it("the most specific root wins; no match gives undefined", () => {
    const roots = ["/home/u/projects", A, B];
    expect(workspaceOf({ cwd: A + "/src" }, roots)).toBe(A);
    expect(workspaceOf({ cwd: "/home/u/projects/other" }, roots)).toBe("/home/u/projects");
    expect(workspaceOf({ cwd: "/tmp" }, roots)).toBeUndefined();
    expect(workspaceOf({}, roots)).toBeUndefined();
  });
});

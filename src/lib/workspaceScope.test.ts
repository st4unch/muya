// Created by Claude — Classification: INTERNAL
import { describe, it, expect } from "vitest";
import { belongsTo, inScope, workspaceOf, workspaceShortcut } from "./workspaceScope";

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

describe("workspaceShortcut", () => {
  const ws = ["/w/a", "/w/b", "/w/c"];
  const k = (code: string, mods: Partial<Record<"altKey" | "metaKey" | "ctrlKey" | "shiftKey", boolean>> = { altKey: true, metaKey: true }) =>
    ({ code, altKey: false, metaKey: false, ctrlKey: false, shiftKey: false, ...mods });
  it("⌥⌘N picks the Nth workspace", () => {
    expect(workspaceShortcut(k("Digit1"), ws)).toBe("/w/a");
    expect(workspaceShortcut(k("Digit3"), ws)).toBe("/w/c");
  });
  it("⌥⌘0 picks all workspaces", () => {
    expect(workspaceShortcut(k("Digit0"), ws)).toBe("all");
    expect(workspaceShortcut(k("Digit0"), [])).toBeNull();
  });
  it("ignores numbers past the list, other modifiers and other keys", () => {
    expect(workspaceShortcut(k("Digit4"), ws)).toBeNull();
    expect(workspaceShortcut(k("Digit1", { altKey: true, metaKey: true, shiftKey: true }), ws)).toBeNull();
    expect(workspaceShortcut(k("Digit1", { metaKey: true }), ws)).toBeNull();
    expect(workspaceShortcut(k("KeyA"), ws)).toBeNull();
    expect(workspaceShortcut(k("Numpad1"), ws)).toBeNull();
  });
  it("never takes ⌥N (types signs) or ⌃N (terminals use it: vim ⌃6, ⌃2, ⌃3)", () => {
    expect(workspaceShortcut(k("Digit2", { altKey: true }), ws)).toBeNull();
    expect(workspaceShortcut(k("Digit2", { ctrlKey: true }), ws)).toBeNull();
    expect(workspaceShortcut(k("Digit2", { ctrlKey: true, altKey: true, metaKey: true }), ws)).toBeNull();
  });
});

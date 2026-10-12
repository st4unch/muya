// Created by Claude — Classification: INTERNAL
import { describe, expect, it } from "vitest";
import { approvableIds, approvableKeys, keyOfApprovableId } from "./autoApprove";

describe("approvableKeys", () => {
  it("picks only waiting agents with a readable prompt", () => {
    expect(
      approvableKeys([
        { key: "a", status: "waiting", approval: { actionable: true } },
        { key: "b", status: "waiting", approval: {} },
        { key: "c", status: "waiting", approval: { actionable: false } },
        { key: "d", status: "waiting" },
        { key: "e", status: "working", approval: { actionable: true } },
      ]),
    ).toEqual(["a", "b"]);
  });
});

describe("approvableIds", () => {
  it("gives a different id when another prompt replaces the one on screen", () => {
    const a = approvableIds([{ key: "s1", status: "waiting", approval: { tool: "Bash", target: "ls" } }]);
    const b = approvableIds([{ key: "s1", status: "waiting", approval: { tool: "Bash", target: "rm -rf build\nls" } }]);
    expect(a[0]).not.toEqual(b[0]);
    expect([keyOfApprovableId(a[0]), keyOfApprovableId(b[0])]).toEqual(["s1", "s1"]);
    expect(b[0]).not.toContain("\u0002");
  });
});

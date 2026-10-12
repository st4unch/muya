// Created by Claude — Classification: INTERNAL
import { describe, expect, it } from "vitest";
import { approvableKeys } from "./autoApprove";

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

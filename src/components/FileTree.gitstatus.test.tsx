// Created by Claude — Classification: INTERNAL
import React from "react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, waitFor } from "@testing-library/react";

const invoke = vi.fn(async (_cmd: string, _args?: unknown) => [] as unknown[]);
vi.mock("@tauri-apps/api/core", () => ({
  invoke: (c: string, a?: unknown) => invoke(c, a),
}));
vi.mock("@tauri-apps/api/event", () => ({
  listen: () => Promise.resolve(() => {}),
}));

import FileTree from "./FileTree";

const gitCalls = () =>
  invoke.mock.calls.filter(([c]) => c === "git_status").length;

/**
 * Regression: App passed a fresh `roots` array on every render, and the git-status
 * effect was keyed on its identity — so every App re-render (terminal/agent status
 * churn from busy subagents) shelled `git status` per root, ~13 spawns/s, which
 * under endpoint-security exec hooks froze the Mac and stalled new terminals.
 */
describe("FileTree: git status must not re-run on a same-content roots array", () => {
  beforeEach(() => invoke.mockClear());

  it("does not shell git status again when re-rendered with an equal roots array", async () => {
    const { rerender } = render(
      <FileTree roots={["/r1", "/r2"]} onOpenFile={() => {}} />,
    );
    await waitFor(() => expect(gitCalls()).toBe(2));

    for (let i = 0; i < 5; i++) {
      rerender(<FileTree roots={["/r1", "/r2"]} onOpenFile={() => {}} />);
    }
    await new Promise((r) => setTimeout(r, 50));
    expect(gitCalls()).toBe(2);
  });

  it("still refreshes git status when the set of roots actually changes", async () => {
    const { rerender } = render(
      <FileTree roots={["/r1"]} onOpenFile={() => {}} />,
    );
    await waitFor(() => expect(gitCalls()).toBe(1));

    rerender(<FileTree roots={["/r1", "/r2"]} onOpenFile={() => {}} />);
    await waitFor(() => expect(gitCalls()).toBe(3));
  });
});

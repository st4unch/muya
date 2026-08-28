import React from "react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";

// The tree calls list_dir through Tauri; give it a stable listing.
const invoke = vi.fn(async (cmd: string, _args?: unknown) => {
  if (cmd === "list_dir") return [{ name: "a.txt", path: "/r/a.txt", isDirectory: false }];
  return [];
});
vi.mock("@tauri-apps/api/core", () => ({ invoke: (c: string, a?: unknown) => invoke(c, a) }));
vi.mock("@tauri-apps/api/event", () => ({ listen: () => Promise.resolve(() => {}) }));

import FileTree from "./FileTree";

/**
 * Regression: the "…" placeholder is an extra ROW. Showing it on every refresh
 * made each open folder grow and shrink by a line, and the fs-watcher fires on
 * every file event — so with agents writing files the tree visibly shook and the
 * right-click menu looked like it was vibrating. A refresh must be silent.
 */
describe("FileTree: a refresh must not flash the loading placeholder", () => {
  beforeEach(() => invoke.mockClear());

  it("shows no placeholder row when refreshSignal changes on an already-loaded tree", async () => {
    const { rerender } = render(
      <FileTree roots={["/r"]} onOpenFile={() => {}} refreshSignal={1} />,
    );
    await waitFor(() => expect(screen.queryByText("a.txt")).toBeTruthy());

    // Bump the watcher signal the way a file event does.
    rerender(<FileTree roots={["/r"]} onOpenFile={() => {}} refreshSignal={2} />);

    // The "…" row must never appear: its presence/absence is exactly the
    // one-line grow/shrink that produced the shake.
    expect(screen.queryByText("…")).toBeNull();
    await waitFor(() => expect(screen.queryByText("a.txt")).toBeTruthy());
    expect(screen.queryByText("…")).toBeNull();
  });
});

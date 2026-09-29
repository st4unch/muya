// Created by Claude — Classification: INTERNAL
import React from "react";
import { describe, it, expect, vi } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/react";

vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(async (cmd: string) =>
    cmd === "list_dir" ? [{ name: "a.txt", path: "/r/a.txt", isDirectory: false }] : [],
  ),
}));
vi.mock("@tauri-apps/api/event", () => ({ listen: () => Promise.resolve(() => {}) }));

import FileTree from "./FileTree";

/**
 * Regression (L55): the menu's item and separator components were declared inside
 * FileTree's render, so every render handed React a brand-new component type and it
 * replaced every menu button with a fresh DOM node. FileTree re-renders constantly
 * (git-status poll, the parent's polls, new inline callbacks), so the hover highlight
 * blinked, and a click whose mousedown hit the old button and mouseup the new one
 * never became a `click` at all — "it flickers and the first click doesn't take".
 */
describe("FileTree: the context menu survives a re-render", () => {
  it("keeps the same button element across a parent re-render", async () => {
    const { rerender } = render(<FileTree roots={["/r"]} onOpenFile={() => {}} />);
    await waitFor(() => expect(screen.getByText("a.txt")).toBeTruthy());

    fireEvent.contextMenu(screen.getByText("a.txt"));
    const before = screen.getByText("Copy Path");

    // A new inline callback is exactly what the parent passes on every render.
    rerender(<FileTree roots={["/r"]} onOpenFile={() => {}} />);

    expect(screen.getByText("Copy Path")).toBe(before);
  });
});

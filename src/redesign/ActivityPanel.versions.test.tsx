// Created by Claude — Classification: INTERNAL
import { render, screen, fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

const invoke = vi.fn(async (cmd: string, _args?: unknown) => {
  if (cmd === "file_history_list") return [
    { id: "2", at: Date.now() - 1000, size: 2048, kind: "saved" },
    { id: "1", at: Date.now() - 5000, size: 10, kind: "draft" },
  ];
  return [];
});
vi.mock("@tauri-apps/api/core", () => ({ invoke: (cmd: string, args: unknown) => invoke(cmd, args) }));
import { ActivityPanel } from "./ActivityPanel";
import { VERSIONS_EVENT } from "../lib/fileVersions";

const base = { collisions: [], editedFiles: 0, worktreesWatched: 1, onOpenFile: vi.fn() };

describe("ActivityPanel versions", () => {
  it("lists the active file's versions and opens one on click", async () => {
    const onOpenVersion = vi.fn();
    render(<ActivityPanel {...base} activeFile="/r/src/a.ts" onOpenVersion={onOpenVersion} />);
    expect(screen.getByText("VERSIONS · a.ts")).toBeInTheDocument();
    const rows = await screen.findAllByTitle("Compare with the file now, or restore it");
    expect(rows).toHaveLength(2);
    expect(screen.getByText("saved")).toBeInTheDocument();
    expect(screen.getByText("unsaved edit")).toBeInTheDocument();
    expect(screen.getByText("2.0 KB")).toBeInTheDocument();
    fireEvent.click(rows[1]);
    expect(onOpenVersion).toHaveBeenCalledWith("/r/src/a.ts", "1");
  });

  it("reloads when a new version of that file is stored, and hides without a file", async () => {
    const { rerender } = render(<ActivityPanel {...base} activeFile="/r/a.ts" />);
    await screen.findAllByTitle("Compare with the file now, or restore it");
    const calls = invoke.mock.calls.filter((c) => c[0] === "file_history_list").length;
    window.dispatchEvent(new CustomEvent(VERSIONS_EVENT, { detail: { path: "/r/a.ts" } }));
    window.dispatchEvent(new CustomEvent(VERSIONS_EVENT, { detail: { path: "/r/other.ts" } }));
    expect(invoke.mock.calls.filter((c) => c[0] === "file_history_list").length).toBe(calls + 1);
    rerender(<ActivityPanel {...base} />);
    expect(screen.queryByText(/VERSIONS/)).toBeNull();
  });
});

import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const invoke = vi.fn();
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a: unknown[]) => invoke(...a) }));

import { ActivityPanel, displayPath } from "./ActivityPanel";

const base = { collisions: [], editedFiles: 0, worktreesWatched: 1 };

beforeEach(() => {
  invoke.mockReset();
  invoke.mockResolvedValue([
    { path: "/w/proj/src/app.ts", action: "modified", count: 2, lastAt: "t2" },
    { path: "/etc/hosts", action: "read", count: 1, lastAt: "t1" },
  ]);
});

describe("ActivityPanel agent files", () => {
  it("lists modified and read files of the session and opens the absolute path on click", async () => {
    const open = vi.fn();
    render(<ActivityPanel {...base} sessionId="abc-1" sessionCwd="/w/proj" onOpenFile={open} />);
    expect(invoke).toHaveBeenCalledWith("session_touched_files", { cwd: "/w/proj", sessionId: "abc-1" });
    await screen.findByText("app.ts");
    expect(screen.getByText("MODIFIED · 1")).toBeTruthy();
    expect(screen.getByText("READ · 1")).toBeTruthy();
    expect(screen.getByText("×2")).toBeTruthy();
    fireEvent.click(screen.getByTitle("/etc/hosts"));
    expect(open).toHaveBeenCalledWith("/etc/hosts");
    fireEvent.click(screen.getByTitle("/w/proj/src/app.ts"));
    expect(open).toHaveBeenLastCalledWith("/w/proj/src/app.ts");
  });

  it("asks for a Claude tab when there is no session and never calls the backend", () => {
    render(<ActivityPanel {...base} onOpenFile={vi.fn()} />);
    expect(screen.getByText(/Select a Claude session tab/)).toBeTruthy();
    expect(invoke).not.toHaveBeenCalled();
  });

  it("shows the backend error", async () => {
    invoke.mockRejectedValue("invalid session id");
    render(<ActivityPanel {...base} sessionId="x" onOpenFile={vi.fn()} />);
    await waitFor(() => expect(screen.getByText("invalid session id")).toBeTruthy());
  });

  it("shows paths relative to the session folder only when inside it", () => {
    expect(displayPath("/w/proj/a/b.ts", "/w/proj")).toBe("a/b.ts");
    expect(displayPath("/w/proj/a/b.ts", "/w/proj/")).toBe("a/b.ts");
    expect(displayPath("/w/project2/x.ts", "/w/proj")).toBe("/w/project2/x.ts");
    expect(displayPath("/x.ts")).toBe("/x.ts");
  });
});

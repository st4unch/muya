// Created by Claude — Classification: INTERNAL
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
import { invoke } from "@tauri-apps/api/core";
import TerminalHistoryView from "./TerminalHistoryView";

const invokeMock = invoke as unknown as ReturnType<typeof vi.fn>;
const ts = Math.floor(Date.now() / 1000);
const cmds = (n: number) => Array.from({ length: n }, (_, i) => ({ ts: ts - (n - i), cmd: `cmd-${i}` }));

beforeEach(() => invokeMock.mockReset());

describe("TerminalHistoryView", () => {
  it("lists the capped preview and loads a terminal in full only on View all", async () => {
    invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "term_history_entries") return [{ key: "terminal-1", name: "api", cwd: "/w", updatedMs: 0, total: 8, entries: cmds(8).slice(-6) }];
      if (cmd === "term_history_full") return { key: "terminal-1", name: "api", cwd: "/w", updatedMs: 0, total: 8, entries: cmds(8) };
      return null;
    });
    render(<TerminalHistoryView query="" refreshToken={0} onReopen={() => {}} />);
    await screen.findByText("cmd-7");
    expect(screen.queryByText("cmd-0")).toBeNull();
    expect(invokeMock).not.toHaveBeenCalledWith("term_history_full", expect.anything());

    await userEvent.click(screen.getByText(/View all/));
    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith("term_history_full", { key: "terminal-1" }));
    await screen.findByText("cmd-0");
  });

  it("does not refetch a terminal whose list already holds all of it", async () => {
    invokeMock.mockImplementation(async (cmd: string) =>
      cmd === "term_history_entries" ? [{ key: "t2", name: "web", cwd: "/x", updatedMs: 0, total: 7, entries: cmds(7) }] : null,
    );
    render(<TerminalHistoryView query="" refreshToken={0} onReopen={() => {}} />);
    await userEvent.click(await screen.findByText(/View all/));
    await screen.findByText("cmd-0");
    expect(invokeMock).not.toHaveBeenCalledWith("term_history_full", expect.anything());
  });
});

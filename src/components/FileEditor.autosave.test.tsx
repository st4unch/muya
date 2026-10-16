// Created by Claude — Classification: INTERNAL
import { act, render, screen, fireEvent } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const invoke = vi.fn(async (cmd: string, _args?: unknown) => (cmd === "read_file" ? "hello" : null));
vi.mock("@tauri-apps/api/core", () => ({ invoke: (cmd: string, args: unknown) => invoke(cmd, args) }));
vi.mock("./monacoSetup", () => ({}));
vi.mock("monaco-editor", () => ({ KeyMod: { CtrlCmd: 0 }, KeyCode: { KeyS: 0 } }));
vi.mock("@monaco-editor/react", () => ({
  default: ({ value, onChange }: { value: string; onChange: (v: string) => void }) => (
    <textarea aria-label="code" value={value} onChange={(e) => onChange(e.target.value)} />
  ),
  DiffEditor: () => null,
}));
import FileEditor from "./FileEditor";
import { saveAutoSave } from "../lib/fileVersions";

const calls = (cmd: string) => invoke.mock.calls.filter((c) => c[0] === cmd);

describe("FileEditor versions + auto-save", () => {
  beforeEach(() => { vi.useFakeTimers(); invoke.mockClear(); localStorage.clear(); });
  afterEach(() => vi.useRealTimers());

  async function open() {
    render(<FileEditor path="/r/a.ts" active />);
    await act(async () => { await vi.advanceTimersByTimeAsync(10); });
    expect(calls("file_history_snapshot")[0]?.[1]).toEqual({ path: "/r/a.ts", content: "hello", kind: "opened" });
  }

  it("auto-save off: a pause keeps a draft version, nothing is written", async () => {
    await open();
    fireEvent.change(screen.getByLabelText("code"), { target: { value: "hello world" } });
    await act(async () => { await vi.advanceTimersByTimeAsync(3100); });
    expect(calls("write_file")).toHaveLength(0);
    expect(calls("file_history_snapshot").slice(-1)[0]?.[1]).toEqual({ path: "/r/a.ts", content: "hello world", kind: "draft" });
  });

  it("auto-save on: writes 1 s after typing stops and keeps a saved version", async () => {
    saveAutoSave(true);
    await open();
    fireEvent.change(screen.getByLabelText("code"), { target: { value: "hello!" } });
    await act(async () => { await vi.advanceTimersByTimeAsync(500); });
    expect(calls("write_file")).toHaveLength(0);
    await act(async () => { await vi.advanceTimersByTimeAsync(600); });
    expect(calls("write_file")[0]?.[1]).toEqual({ path: "/r/a.ts", content: "hello!" });
    expect(calls("file_history_snapshot").slice(-1)[0]?.[1]).toEqual({ path: "/r/a.ts", content: "hello!", kind: "saved" });
    expect(screen.queryByText("● unsaved")).toBeNull();
  });
});

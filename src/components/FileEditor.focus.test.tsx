// Created by Claude — Classification: INTERNAL
import { act, render } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useEffect } from "react";

vi.mock("@tauri-apps/api/core", () => ({ invoke: async (cmd: string) => (cmd === "read_file" ? "hello" : null) }));
vi.mock("./monacoSetup", () => ({}));
vi.mock("monaco-editor", () => ({ KeyMod: { CtrlCmd: 0 }, KeyCode: { KeyS: 0 } }));
const focus = vi.fn();
vi.mock("@monaco-editor/react", () => ({
  default: ({ onMount }: { onMount: (e: unknown) => void }) => {
    useEffect(() => onMount({ focus, addCommand: () => {}, getAction: () => null }), [onMount]);
    return <div />;
  },
  DiffEditor: () => null,
}));
import FileEditor from "./FileEditor";

async function settle(ms = 10) {
  await act(async () => { await vi.advanceTimersByTimeAsync(ms); });
}

describe("FileEditor keyboard focus", () => {
  beforeEach(() => { vi.useFakeTimers(); focus.mockClear(); document.body.innerHTML = ""; });
  afterEach(() => vi.useRealTimers());

  it("opening a shown file hands it the keyboard", async () => {
    render(<FileEditor path="/r/a.ts" active />);
    await settle();
    expect(focus).toHaveBeenCalled();
  });

  it("a hidden file never takes the keyboard", async () => {
    render(<FileEditor path="/r/a.ts" active={false} />);
    await settle();
    expect(focus).not.toHaveBeenCalled();
  });

  it("waits for a closing dialog (the ⌘K palette), then takes the keyboard", async () => {
    const dlg = document.createElement("div");
    dlg.setAttribute("role", "dialog");
    document.body.append(dlg);
    render(<FileEditor path="/r/a.ts" active />);
    await settle();
    expect(focus).not.toHaveBeenCalled();
    dlg.remove();
    await settle(60);
    expect(focus).toHaveBeenCalled();
  });

  it("does not take the keyboard from a field the operator is typing in", async () => {
    const input = document.createElement("input");
    document.body.append(input);
    input.focus();
    render(<FileEditor path="/r/a.ts" active />);
    await settle();
    expect(focus).not.toHaveBeenCalled();
  });
});

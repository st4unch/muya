// Created by Claude — Classification: INTERNAL
import { act, render, fireEvent } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const MB = 1024 * 1024;
let probe = { size: 5, binary: false };
const calls: Array<[string, unknown]> = [];
vi.mock("@tauri-apps/api/core", () => ({
  invoke: async (cmd: string, args?: unknown) => {
    calls.push([cmd, args]);
    if (cmd === "file_probe") return probe;
    if (cmd === "read_file") return "hello";
    if (cmd === "read_file_prefix") return "head of a huge file";
    return null;
  },
}));
vi.mock("./monacoSetup", () => ({}));
vi.mock("monaco-editor", () => ({ KeyMod: { CtrlCmd: 0 }, KeyCode: { KeyS: 0 } }));
let lastOptions: Record<string, unknown> = {};
let lastLanguage: string | undefined;
vi.mock("@monaco-editor/react", () => ({
  default: ({ options, language }: { options: Record<string, unknown>; language?: string }) => {
    lastOptions = options;
    lastLanguage = language;
    return <div data-testid="monaco" />;
  },
  DiffEditor: () => null,
}));
import FileEditor from "./FileEditor";

const settle = () => act(async () => { await new Promise((r) => setTimeout(r, 30)); });

describe("FileEditor large-file handling", () => {
  beforeEach(() => { calls.length = 0; lastOptions = {}; lastLanguage = undefined; });

  it("a small file is untouched: no banner, normal options", async () => {
    probe = { size: 5, binary: false };
    const { queryByTestId } = render(<FileEditor path="/r/a.ts" />);
    await settle();
    expect(queryByTestId("large-file-banner")).toBeNull();
    expect(lastOptions.folding).toBeUndefined();
    expect(lastLanguage).toBeUndefined();
  });

  it("3 MB opens in large-file mode: banner, plain text, features off, still editable", async () => {
    probe = { size: 3 * MB, binary: false };
    const { getByTestId, getByText } = render(<FileEditor path="/r/big.log" />);
    await settle();
    expect(getByTestId("large-file-banner").textContent).toContain("3.0 MB");
    expect(lastLanguage).toBe("plaintext");
    expect(lastOptions.folding).toBe(false);
    expect(lastOptions.minimap).toEqual({ enabled: false });
    expect(lastOptions.readOnly).toBe(false);
    expect((getByText("Wrap") as HTMLButtonElement).disabled).toBe(true);
    expect((getByText("Diff") as HTMLButtonElement).disabled).toBe(true);
    expect(calls.some(([c]) => c === "file_history_snapshot")).toBe(false);
  });

  it("50 MB is not loaded until asked; Open anyway shows the head read-only", async () => {
    probe = { size: 50 * MB, binary: false };
    const { getByTestId, getByText, queryByTestId } = render(<FileEditor path="/r/huge.json" />);
    await settle();
    expect(getByTestId("large-file-prompt")).toBeTruthy();
    expect(queryByTestId("monaco")).toBeNull();
    expect(calls.map(([c]) => c)).not.toContain("read_file");
    expect(calls.map(([c]) => c)).not.toContain("read_file_prefix");
    fireEvent.click(getByText("Open anyway"));
    await settle();
    expect(calls.map(([c]) => c)).toContain("read_file_prefix");
    expect(calls.map(([c]) => c)).not.toContain("read_file");
    expect(lastOptions.readOnly).toBe(true);
    expect(getByTestId("large-file-banner").textContent).toContain("read-only");
  });

  it("a binary file is never read as text", async () => {
    probe = { size: 2 * MB, binary: true };
    const { getByTestId, queryByTestId } = render(<FileEditor path="/r/x.dat" />);
    await settle();
    expect(getByTestId("binary-file")).toBeTruthy();
    expect(queryByTestId("monaco")).toBeNull();
    expect(calls.map(([c]) => c)).not.toContain("read_file");
  });
});

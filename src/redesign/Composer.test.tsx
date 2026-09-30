import { render, screen, fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn(() => Promise.resolve([{ name: "release", description: "Cut a release", source: "project" }])) }));
import { Composer } from "./Composer";

function setup(overrides: Partial<React.ComponentProps<typeof Composer>> = {}) {
  const onSend = vi.fn();
  const onChange = vi.fn();
  const onCycleMode = vi.fn();
  render(
    <Composer
      agentName="muya-all"
      value="hello"
      onChange={onChange}
      onSend={onSend}
      mode="bypass"
      onCycleMode={onCycleMode}
      onAttachFile={vi.fn()}
      onCommands={vi.fn()}
      {...overrides}
    />,
  );
  return { onSend, onChange, onCycleMode };
}

describe("Composer", () => {
  it("Enter sends the trimmed message", () => {
    const { onSend } = setup();
    fireEvent.keyDown(screen.getByPlaceholderText(/Message muya-all/), { key: "Enter" });
    expect(onSend).toHaveBeenCalledWith("hello");
  });

  it("Shift+Enter does not send", () => {
    const { onSend } = setup();
    fireEvent.keyDown(screen.getByPlaceholderText(/Message muya-all/), { key: "Enter", shiftKey: true });
    expect(onSend).not.toHaveBeenCalled();
  });

  it("does not send an empty/whitespace-only message", () => {
    const { onSend } = setup({ value: "   " });
    fireEvent.keyDown(screen.getByPlaceholderText(/Message muya-all/), { key: "Enter" });
    expect(onSend).not.toHaveBeenCalled();
  });

  it("renders the bypass mode chip in the danger palette", () => {
    setup();
    expect(screen.getByText(/Mode: bypass/)).toBeInTheDocument();
  });

  it("send button click sends the message", () => {
    const { onSend } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Send" }));
    expect(onSend).toHaveBeenCalledWith("hello");
  });

  it("in a plain shell, says text runs as a command and hides agent-only controls", () => {
    setup({ target: "shell" });
    expect(screen.getByPlaceholderText(/Run a shell command in muya-all/)).toBeInTheDocument();
    expect(screen.queryByText(/Mode:/)).not.toBeInTheDocument();
    expect(screen.queryByText("/ Commands")).not.toBeInTheDocument();
    expect(screen.getByText("Add path")).toBeInTheDocument();
    expect(screen.getByText(/⏎ run/)).toBeInTheDocument();
  });

  it("Shift+Tab does not cycle a permission mode in a shell", () => {
    const { onCycleMode } = setup({ target: "shell" });
    fireEvent.keyDown(screen.getByPlaceholderText(/Run a shell command/), { key: "Tab", shiftKey: true });
    expect(onCycleMode).not.toHaveBeenCalled();
  });

  it("/ Commands without slashAgent still calls onCommands", () => {
    const onCommands = vi.fn();
    setup({ onCommands });
    fireEvent.click(screen.getByText("/ Commands"));
    expect(onCommands).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("/ Commands with slashAgent opens the popover and picking inserts `/name `", async () => {
    const onCommands = vi.fn();
    const { onChange } = setup({ onCommands, slashAgent: "claude", slashCwd: "/tmp/x", value: "" });
    fireEvent.click(screen.getByText("/ Commands"));
    expect(onCommands).not.toHaveBeenCalled();
    expect(screen.getByRole("dialog", { name: "Slash commands" })).toBeTruthy();
    expect(await screen.findByText("/release")).toBeTruthy();
    fireEvent.mouseDown(screen.getByText("/release"));
    expect(onChange).toHaveBeenCalledWith("/release ");
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(document.activeElement).toBe(screen.getByPlaceholderText(/Message muya-all/));
  });
});

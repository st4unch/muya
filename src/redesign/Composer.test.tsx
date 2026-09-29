import { render, screen, fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
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
});
